namespace NexoBar.Widget;

internal enum PreviewLayoutState { NotMeasured, FitsMeasuredRoot, InsufficientHeight }
internal sealed record PreviewLayoutMeasurement(
    int Generation, int LayoutRevision, DateTimeOffset MeasuredAt, bool IsLoaded, bool IsHostPreviewVisible,
    double ActualWidth, double ActualHeight, double DesiredHeight, double RequiredHeight, int RowCount,
    int MaximumQuotaLineCount, double RowGap, double ContentTop, double ContentBottom,
    PreviewLayoutState State, double MissingHeight, bool WasValidWhenMeasured, bool WasInsufficientWhenMeasured)
{
    internal PreviewLayoutMeasurement Invalidate() => this with { IsLoaded = false, IsHostPreviewVisible = false, State = PreviewLayoutState.NotMeasured };
    internal static double Required(IReadOnlyList<IReadOnlyList<int>> rows, double iconHeight, double lineHeight,
        double internalGap, double verticalPadding, double rowGap, double rootPadding = 0)
    {
        var nonempty = rows.Where(row => row.Count > 0).ToArray();
        return nonempty.Sum(row => row.Max(count => Math.Max(iconHeight,
            count * lineHeight + internalGap * Math.Max(0, count - 1)) + verticalPadding)) +
            rowGap * Math.Max(0, nonempty.Length - 1) + rootPadding;
    }
    internal static PreviewLayoutMeasurement Measure(int generation, int revision, int currentRevision,
        bool loaded, bool visible, double width, double height, double desired, double required,
        int rowCount, int maximumLines, double gap, double top, double bottom, bool compressed)
    {
        bool valid = loaded && visible && revision == currentRevision &&
            double.IsFinite(width) && width > 0 && double.IsFinite(height) && height > 0 &&
            double.IsFinite(desired) && desired > 0 && double.IsFinite(top) && double.IsFinite(bottom) &&
            double.IsFinite(required) && required > 0 && rowCount > 0;
        bool insufficient = required > height + .5 || top < -.5 || bottom > height + .5 || compressed;
        return new(generation, revision, DateTimeOffset.UtcNow, loaded, visible, width, height, desired,
            required, rowCount, maximumLines, gap, top, bottom,
            !valid ? PreviewLayoutState.NotMeasured : insufficient ? PreviewLayoutState.InsufficientHeight : PreviewLayoutState.FitsMeasuredRoot,
            valid ? Math.Max(0, Math.Max(required - height, Math.Max(bottom - height, -top))) : 0, valid, valid && insufficient);
    }
    internal string Caption(bool current) => !current && WasValidWhenMeasured ?
        $"Última altura medida: {ActualHeight:0.#} px · conteúdo: {RequiredHeight:0.#} px · {MeasuredAt.ToLocalTime():HH:mm:ss}. " +
        (WasInsufficientWhenMeasured ? "A altura era insuficiente na medição. " : "O conteúdo cabia na área medida. ") +
        "Aguardando medir este ajuste com o widget visível." :
        State == PreviewLayoutState.NotMeasured ? "Altura do preview ainda não medida. Exiba o widget para conferir o espaço." :
        State == PreviewLayoutState.FitsMeasuredRoot ?
        $"Altura medida: {ActualHeight:0.#} px · conteúdo: {RequiredHeight:0.#} px. O conteúdo cabe na área medida do preview." :
        $"Altura medida: {ActualHeight:0.#} px · conteúdo: {RequiredHeight:0.#} px. " +
        (MissingHeight > .5 ? $"Faltam {MissingHeight:0.#} px; " : "Bloco de texto comprimido; ") +
        "reduza o espaço entre linhas ou reorganize os indicadores no NexoBar.";
}
