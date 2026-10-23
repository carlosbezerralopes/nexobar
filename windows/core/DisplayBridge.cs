using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace NexoBar.Core;

public sealed record DisplayWidgetOptions(int ItemsPerPage = 2, string Layout = "horizontal",
    int RotationSeconds = 5, bool Rotate = true, int Width = 320, bool PauseOnHover = true,
    IReadOnlyList<WidgetPlacement>? Placements = null, int RowGap = 4)
{
    public DisplayWidgetOptions Normalize() => this with { ItemsPerPage = Math.Clamp(ItemsPerPage, 1, 8),
        Layout = WidgetPaging.NormalizeLayout(Layout), RotationSeconds = Math.Clamp(RotationSeconds, 2, 60),
        Width = Math.Clamp(Width, 120, 600), RowGap = Math.Clamp(RowGap, 0, 12), Placements = WidgetPaging.NormalizePlacements(Placements) };
}
public sealed record DisplayIndicator(string Id, string Label, Reading Reading, bool ShowTemperature);
public sealed record DisplaySnapshot(int SchemaVersion, DateTimeOffset CapturedAt, bool WidgetEnabled,
    DisplayWidgetOptions WidgetOptions, IReadOnlyList<DisplayIndicator> Indicators,
    bool MemoryNominal, bool StackedQuotas, bool DetailedCountdown, bool ShowQuotaReset = true);

/// <summary>One length-prefixed JSON response per connection; never accepts commands or writes quota data.</summary>
public static class DisplayBridge
{
    public const int MaximumFrameBytes = 256 * 1024;
    public static readonly TimeSpan MaximumAge = TimeSpan.FromSeconds(15);
    public static string PipeName(string? isolationKey = null)
    {
        string identity = Environment.UserDomainName + "\\" + Environment.UserName + "\n" + (isolationKey ?? "default");
        return "NexoBar.Display.v1." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..24];
    }
    public static bool IsFresh(DisplaySnapshot? snapshot, DateTimeOffset now) => snapshot is not null &&
        snapshot.SchemaVersion == 1 && snapshot.WidgetOptions is not null && snapshot.Indicators is not null &&
        (snapshot.WidgetOptions.Placements is null || snapshot.WidgetOptions.Placements.Count <= 128 &&
            snapshot.WidgetOptions.Placements.All(x => x is not null && WidgetPaging.ValidId(x.Id))) &&
        snapshot.Indicators.Count <= 128 && snapshot.Indicators.All(x => x is not null && x.Reading is not null &&
            !string.IsNullOrWhiteSpace(x.Id) && x.Id.Length <= 256 && x.Label is { Length: <= 64 } &&
            x.Reading.Id == x.Id && (x.Reading.Windows is null || x.Reading.Windows.Count <= 64 &&
                x.Reading.Windows.All(w => w is not null && w.Label is { Length: <= 256 }))) &&
        snapshot.CapturedAt <= now.AddSeconds(2) && now - snapshot.CapturedAt <= MaximumAge;

    public static async Task<DisplaySnapshot?> ReadAsync(CancellationToken cancellationToken = default, string? isolationKey = null)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(1));
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName(isolationKey), PipeDirection.In,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
            byte[] header = new byte[4];
            await pipe.ReadExactlyAsync(header, timeout.Token).ConfigureAwait(false);
            int size = BinaryPrimitives.ReadInt32LittleEndian(header);
            if (size is <= 0 or > MaximumFrameBytes) return null;
            byte[] data = new byte[size];
            await pipe.ReadExactlyAsync(data, timeout.Token).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<DisplaySnapshot>(data);
            if (!IsFresh(result, DateTimeOffset.UtcNow)) return null;
            return result! with { WidgetOptions = result!.WidgetOptions.Normalize(), Indicators = Array.AsReadOnly(result.Indicators.ToArray()) };
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or JsonException or UnauthorizedAccessException or System.Net.Sockets.SocketException)
        { return null; }
    }
}

public sealed class DisplayBridgeServer : IDisposable
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task worker;
    private int disposed;
    private long lastClientTicks;
    public DateTimeOffset? LastClientAt => Interlocked.Read(ref lastClientTicks) is var ticks && ticks > 0 ? new DateTimeOffset(ticks, TimeSpan.Zero) : null;
    public bool HasClient => LastClientAt is { } at && DateTimeOffset.UtcNow - at < TimeSpan.FromSeconds(15);
    public DisplayBridgeServer(Func<DisplaySnapshot> snapshot, string? isolationKey = null)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        worker = Task.Run(async () =>
        {
            while (!lifetime.IsCancellationRequested)
            {
                try
                {
                    using var pipe = new NamedPipeServerStream(DisplayBridge.PipeName(isolationKey), PipeDirection.Out,
                        1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await pipe.WaitForConnectionAsync(lifetime.Token).ConfigureAwait(false);
                    Interlocked.Exchange(ref lastClientTicks, DateTimeOffset.UtcNow.Ticks);
                    // The producer supplies an immutable snapshot, without blocking the application's dispatcher.
                    var value = snapshot();
                    // Disabled frames contain no numbers, even to an already connected local client.
                    if (!value.WidgetEnabled) value = value with { Indicators = [] };
                    byte[] data = JsonSerializer.SerializeToUtf8Bytes(value);
                    if (data.Length > DisplayBridge.MaximumFrameBytes) continue;
                    using var writeTimeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    writeTimeout.CancelAfter(TimeSpan.FromSeconds(1));
                    byte[] header = new byte[4];
                    BinaryPrimitives.WriteInt32LittleEndian(header, data.Length);
                    await pipe.WriteAsync(header, writeTimeout.Token).ConfigureAwait(false);
                    await pipe.WriteAsync(data, writeTimeout.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
                catch (Exception e) when (e is IOException or OperationCanceledException or UnauthorizedAccessException or JsonException or ArgumentException or System.Net.Sockets.SocketException)
                { try { await Task.Delay(250, lifetime.Token).ConfigureAwait(false); } catch (OperationCanceledException) { break; } }
            }
        });
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel();
        // The worker only uses an immutable snapshot; it never waits on the UI thread.
        try { worker.GetAwaiter().GetResult(); } finally { lifetime.Dispose(); }
    }
}
