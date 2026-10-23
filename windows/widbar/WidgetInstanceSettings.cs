using System.Text.Json;
using System.Text.Json.Nodes;
using NexoBar.Core;

namespace NexoBar.Widget;

// Owned by one plugin instance. Unknown JSON fields survive edits by this version.
internal sealed class WidgetInstanceSettings
{
    private readonly JsonObject fields;
    internal int? WidthOverride { get; }
    internal bool ShowNames { get; }
    private WidgetInstanceSettings(JsonObject fields, int? width, bool names)
    { this.fields = fields; WidthOverride = width; ShowNames = names; }
    internal static WidgetInstanceSettings Parse(string? json)
    {
        try
        {
            var fields = string.IsNullOrWhiteSpace(json) ? new() : JsonNode.Parse(json) as JsonObject ?? new();
            if (fields["schemaVersion"] is not JsonValue version || !version.TryGetValue<int>(out int schema) || schema != 1)
                return new(fields, null, false);
            int? width = fields["widthOverride"] is JsonValue widthValue && widthValue.TryGetValue<int>(out int number) ? Math.Clamp(number, 120, 600) : null;
            bool names = fields["showNames"] is JsonValue nameValue && nameValue.TryGetValue<bool>(out bool show) && show;
            return new(fields, width, names);
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException)
        { return new(new(), null, false); }
    }
    internal int EffectiveWidth(int? inheritedWidth) => WidthOverride ?? Math.Clamp(inheritedWidth ?? 320, 120, 600);
    internal IReadOnlyList<string> PreviewQuotaValues(Reading reading, DateTimeOffset now, bool detailedCountdown)
    {
        if (reading.Unavailable is not null) return ["indisponível"];
        var values = (reading.Windows ?? []).Where(window => window.AccountWindow).Select(window =>
            Presentation.QuotaValue(window) + (!ShowNames || window.ResetsAt is null ? "" :
                " · " + Presentation.Countdown(window.ResetsAt, now, detailedCountdown))).ToArray();
        return values.Length == 0 ? ["—"] : values;
    }
    internal WidgetInstanceSettings With(int? width, bool names) => new((JsonObject)fields.DeepClone(),
        width is { } number ? Math.Clamp(number, 120, 600) : null, names);
    internal string ToJson()
    {
        var result = (JsonObject)fields.DeepClone();
        result["schemaVersion"] = 1; result["widthOverride"] = WidthOverride; result["showNames"] = ShowNames;
        return result.ToJsonString();
    }
}
