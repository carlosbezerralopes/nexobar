using System.Text.Json;

namespace NexoBar.Setup.Core;

public sealed class InstallTransaction(InstallEnvironment environment, InstallManifest manifest, string manifestHash)
{
    public InstallState? ReadState()
    {
        SafePaths.NoReparseParents(environment.StatePath);
        if (!File.Exists(environment.StatePath)) return null;
        try { return JsonSerializer.Deserialize<InstallState>(File.ReadAllBytes(environment.StatePath)) ?? throw new JsonException(); }
        catch (JsonException e) { throw new IOException("Recibo desconhecido; instalação interrompida para preservar o estado.", e); }
    }
    public InstallPlan Plan() => InstallPlan.Create(manifest, environment.Root, ReadState(), manifestHash);
    public async Task<InstallResult> ExecuteAsync(Func<Stream> openPayload, InstallOptions options,
        byte[]? observedPreferences, CancellationToken cancellationToken, IProgress<string>? progress = null)
    {
        var messages = new List<string>(); var plan = Plan();
        if (plan.Kind is InstallKind.RefuseDowngrade or InstallKind.UnknownCollision or InstallKind.Repair) throw new IOException(plan.Message);
        if (environment.Services.IsAppRunning()) throw new IOException("NexoBar está em execução. Use Sair no aplicativo e depois Verificar novamente.");
        if (!PreferencesPatch.Matches(environment.Preferences, observedPreferences)) throw new IOException("As preferências mudaram. Verifique novamente.");
        var prefs = PreferencesPatch.Prepare(observedPreferences, options);
        if (prefs.Warning is not null) messages.Add(prefs.Warning);
        SafePaths.NoReparseParents(environment.Root);
        Directory.CreateDirectory(environment.Root);
        using var installLock = new FileStream(Path.Combine(environment.Root, ".install.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        // Recompute after the single-writer lock; a competing installer may have just committed.
        plan = Plan();
        if (plan.Kind is InstallKind.RefuseDowngrade or InstallKind.UnknownCollision or InstallKind.Repair) throw new IOException(plan.Message);
        string staging = Path.Combine(environment.Root, ".staging-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        var rollback = new Stack<Action>(); bool appCommitted = false; bool createdTarget = false;
        try
        {
            progress?.Report("Conferindo todos os arquivos do pacote…");
            using (var stream = openPayload()) manifest.ExtractVerified(stream, staging, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            if (environment.Services.IsAppRunning()) throw new IOException("Use Sair no NexoBar e Verificar novamente.");
            var stateBefore = ReadOptional(environment.StatePath);
            var shortcutBefore = ReadOptional(environment.StartMenuShortcut);
            var startupBefore = options.AutoStart is null ? null : ReadOptional(environment.StartupShortcut);
            CheckShortcut(shortcutBefore); if (options.AutoStart is not null) CheckShortcut(startupBefore);
            string exe = Path.Combine(plan.Target, "NexoBar.exe");
            byte[] shortcut = environment.Services.CreateShortcut(exe);
            cancellationToken.ThrowIfCancellationRequested();
            progress?.Report(plan.Message);
            if (plan.Kind != InstallKind.Reuse)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(plan.Target)!);
                Directory.Move(Path.Combine(staging, "app"), plan.Target); createdTarget = true;
            }
            WriteTracked(environment.StartMenuShortcut, shortcut, shortcutBefore, rollback);
            byte[] stateAfter = JsonSerializer.SerializeToUtf8Bytes(new InstallState("NexoBar", manifest.Version, exe, manifestHash));
            WriteTracked(environment.StatePath, stateAfter, stateBefore, rollback);
            if (options.AutoStart is true) WriteTracked(environment.StartupShortcut, shortcut, startupBefore, rollback);
            else if (options.AutoStart is false && startupBefore is not null)
            {
                if (!PreferencesPatch.Matches(environment.StartupShortcut, startupBefore)) throw new IOException("Inicialização automática mudou.");
                File.Delete(environment.StartupShortcut); rollback.Push(() => AtomicFiles.Write(environment.StartupShortcut, startupBefore, null));
            }
            if (PreferencesPatch.Write(environment.Preferences, prefs)) rollback.Push(() => RestoreIfUnchanged(environment.Preferences, prefs.After!, prefs.Before));
            appCommitted = true; rollback.Clear();
            progress?.Report("Aplicativo instalado.");
            if (options.WidgetEnabled is true)
            {
                try
                {
                    var result = await environment.Services.EnsureWidgetAsync(Path.Combine(staging, "companion", "NexoBar.Widget.msix"), cancellationToken, progress);
                    messages.Add(result.Message);
                    if (!result.Success) return new(true, false, exe, messages);
                }
                catch (Exception e) { messages.Add("WidBar/companion pendente: " + e.Message); return new(true, false, exe, messages); }
            }
            return new(true, prefs.Warning is null, exe, messages);
        }
        catch (Exception failure)
        {
            if (!appCommitted)
            {
                var errors = new List<Exception>();
                foreach (var undo in rollback) { try { undo(); } catch (Exception e) { errors.Add(e); } }
                if (createdTarget && errors.Count == 0) DeleteOwnedTree(plan.Target);
                if (errors.Count != 0)
                    throw new IOException("Instalação interrompida; rollback incompleto. A versão preparada foi preservada para revisão. " + string.Join("; ", errors.Select(e => e.Message)), new AggregateException([failure, .. errors]));
            }
            throw;
        }
        finally { DeleteOwnedTree(staging); }
    }
    void CheckShortcut(byte[]? before)
    { if (before is not null && !environment.Services.OwnsShortcut(before, environment.Root)) throw new IOException("Atalho existente desconhecido foi preservado."); }
    static byte[]? ReadOptional(string path) { SafePaths.NoReparseParents(path); return File.Exists(path) ? File.ReadAllBytes(path) : null; }
    static void WriteTracked(string path, byte[] after, byte[]? before, Stack<Action> rollback)
    {
        if (before is not null && before.AsSpan().SequenceEqual(after)) return;
        AtomicFiles.Write(path, after, before); rollback.Push(() => RestoreIfUnchanged(path, after, before));
    }
    static void RestoreIfUnchanged(string path, byte[] after, byte[]? before)
    {
        if (!PreferencesPatch.Matches(path, after)) return;
        if (before is null) File.Delete(path); else AtomicFiles.Write(path, before, after);
    }
    static void DeleteOwnedTree(string path)
    {
        SafePaths.NoReparseParents(path);
        if (!Directory.Exists(path)) return;
        foreach (var entry in Directory.EnumerateFileSystemEntries(path))
        {
            if ((File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0) throw new IOException("Limpeza suspensa: link inesperado.");
            if (Directory.Exists(entry)) DeleteOwnedTree(entry); else File.Delete(entry);
        }
        Directory.Delete(path);
    }
}
