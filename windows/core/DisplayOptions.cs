namespace NexoBar.Core;

public sealed record WidgetPlacement(string Id, int Row, int Order);
public sealed record WidgetCell<T>(T Item, int Row, int Column);

// Presentation switches are independent; collection belongs to the application, never to a display.
public sealed class DisplayOptions
{
    public bool BarEnabled { get; set; } = true;
    public bool BarReserveSpace { get; set; }
    public double BarOpacity { get; set; } = .75;
    public bool TrayEnabled { get; set; }
    public bool WidgetEnabled { get; set; }
    public int WidgetItemsPerPage { get; set; } = 2;
    public string WidgetLayout { get; set; } = "horizontal";
    public int WidgetRotationSeconds { get; set; } = 5;
    public bool WidgetRotate { get; set; } = true;
    public int WidgetWidth { get; set; } = 320;
    public bool WidgetPauseOnHover { get; set; } = true;
    public List<WidgetPlacement> WidgetPlacements { get; set; } = [];
    public void Normalize()
    {
        BarOpacity = double.IsFinite(BarOpacity) ? Math.Clamp(BarOpacity, .1, 1) : .75;
        WidgetItemsPerPage = Math.Clamp(WidgetItemsPerPage, 1, 8);
        WidgetLayout = WidgetPaging.NormalizeLayout(WidgetLayout);
        WidgetRotationSeconds = Math.Clamp(WidgetRotationSeconds, 2, 60);
        WidgetWidth = Math.Clamp(WidgetWidth, 120, 600);
        WidgetPlacements = WidgetPaging.NormalizePlacements(WidgetPlacements).ToList();
    }

    public void UseCustomLayout(IReadOnlyList<string> ids)
    {
        Normalize();
        if (WidgetPlacements.Count == 0)
            WidgetPlacements = ids.Select((id, index) => new WidgetPlacement(id,
                WidgetPaging.Cell(index % WidgetItemsPerPage, ids.Count, WidgetLayout).Row, index)).ToList();
        WidgetLayout = "customRows";
        EnsurePlacements(ids);
    }
    public void EnsurePlacements(IReadOnlyList<string> ids)
    {
        Normalize();
        int order = WidgetPlacements.Count(x => x.Row == 0);
        foreach (string id in ids)
            if (!WidgetPlacements.Any(x => x.Id == id)) WidgetPlacements.Add(new(id, 0, order++));
        Normalize();
    }
    public void UseHardwareAgentsPreset()
    {
        Normalize();
        string[] ids = ["cpu", "memory", "claude", "codex", "kiro"];
        var preset = ids.Select((id, i) => new WidgetPlacement(id, i < 2 ? 0 : 1, i < 2 ? i : i - 2)).ToList();
        preset.AddRange(WidgetPlacements.Where(x => !ids.Contains(x.Id)).Select(x => x with { Order = x.Order + 5 }));
        WidgetPlacements = preset; WidgetItemsPerPage = 5; WidgetLayout = "customRows"; Normalize();
    }
    public void MoveWidget(string id, int direction, IReadOnlyList<string> enabledIds)
    {
        EnsurePlacements(enabledIds);
        var item = WidgetPlacements.FirstOrDefault(x => x.Id == id);
        if (item is null) return;
        var row = WidgetPlacements.Where(x => x.Row == item.Row && enabledIds.Contains(x.Id)).ToArray();
        int index = Array.FindIndex(row, x => x.Id == id), to = index + Math.Sign(direction);
        if (to < 0 || to >= row.Length) return;
        var other = row[to];
        WidgetPlacements = WidgetPlacements.Select(x => x.Id == id ? x with { Order = other.Order } :
            x.Id == other.Id ? x with { Order = item.Order } : x).ToList();
        Normalize();
    }
    public void ChangeWidgetRow(string id, IReadOnlyList<string> enabledIds)
    {
        EnsurePlacements(enabledIds);
        var item = WidgetPlacements.FirstOrDefault(x => x.Id == id);
        if (item is null) return;
        int row = 1 - item.Row, order = WidgetPlacements.Count(x => x.Row == row);
        WidgetPlacements = WidgetPlacements.Select(x => x.Id == id ? x with { Row = row, Order = order } : x).ToList();
        Normalize();
    }
}

public static class WidgetPaging
{
    public static string NormalizeLayout(string? layout) => layout is "twoRows" or "customRows" ? layout : "horizontal";
    public static bool ValidId(string? id) => !string.IsNullOrWhiteSpace(id) && id.Length <= 256 && !id.Any(char.IsControl);
    public static IReadOnlyList<WidgetPlacement> NormalizePlacements(IEnumerable<WidgetPlacement>? placements)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var valid = (placements ?? []).Where(x => x is not null && ValidId(x.Id) && seen.Add(x.Id)).Take(128)
            .Select(x => x with { Row = Math.Clamp(x.Row, 0, 1) }).OrderBy(x => x.Row).ThenBy(x => x.Order)
            .ThenBy(x => x.Id, StringComparer.Ordinal).ToArray();
        return Array.AsReadOnly(valid.GroupBy(x => x.Row).SelectMany(row => row.Select((x, order) => x with { Order = order })).ToArray());
    }
    public static int PageCount(int itemCount, int itemsPerPage) =>
        itemCount <= 0 ? 0 : (itemCount + Math.Clamp(itemsPerPage, 1, 8) - 1) / Math.Clamp(itemsPerPage, 1, 8);
    public static IReadOnlyList<T> Page<T>(IReadOnlyList<T> items, int page, int itemsPerPage)
    {
        int count = PageCount(items.Count, itemsPerPage);
        if (count == 0) return [];
        int normalized = ((page % count) + count) % count;
        return items.Skip(normalized * Math.Clamp(itemsPerPage, 1, 8)).Take(Math.Clamp(itemsPerPage, 1, 8)).ToArray();
    }
    public static (int Row, int Column) Cell(int index, int visibleCount, string layout) => layout == "twoRows" ?
        (index % 2, index / 2) : (0, index);

    public static IReadOnlyList<WidgetCell<T>> LayoutPage<T>(IReadOnlyList<T> items, Func<T, string> id,
        int page, int itemsPerPage, string layout, IEnumerable<WidgetPlacement>? placements = null)
    {
        if (layout != "customRows") return Page(items, page, itemsPerPage)
            .Select((item, i) => { var cell = Cell(i, items.Count, layout); return new WidgetCell<T>(item, cell.Row, cell.Column); }).ToArray();
        var positions = NormalizePlacements(placements).ToDictionary(x => x.Id, StringComparer.Ordinal);
        var ordered = items.Select((item, index) => (item, index, placement: positions.GetValueOrDefault(id(item))))
            .OrderBy(x => x.placement?.Row ?? 0).ThenBy(x => x.placement?.Order ?? int.MaxValue)
            .ThenBy(x => x.placement is null ? x.index : 0).ThenBy(x => id(x.item), StringComparer.Ordinal).ToArray();
        int[] columns = [0, 0];
        return Page(ordered, page, itemsPerPage).Select(x => {
            int row = x.placement?.Row ?? 0;
            return new WidgetCell<T>(x.item, row, columns[row]++);
        }).ToArray();
    }
}
