namespace NexoBar.Core;

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
    public void Normalize()
    {
        BarOpacity = double.IsFinite(BarOpacity) ? Math.Clamp(BarOpacity, .1, 1) : .75;
        WidgetItemsPerPage = Math.Clamp(WidgetItemsPerPage, 1, 4);
        WidgetLayout = WidgetLayout == "twoRows" ? "twoRows" : "horizontal";
        WidgetRotationSeconds = Math.Clamp(WidgetRotationSeconds, 2, 60);
        WidgetWidth = Math.Clamp(WidgetWidth, 120, 600);
    }
}

public static class WidgetPaging
{
    public static int PageCount(int itemCount, int itemsPerPage) =>
        itemCount <= 0 ? 0 : (itemCount + Math.Clamp(itemsPerPage, 1, 4) - 1) / Math.Clamp(itemsPerPage, 1, 4);
    public static IReadOnlyList<T> Page<T>(IReadOnlyList<T> items, int page, int itemsPerPage)
    {
        int count = PageCount(items.Count, itemsPerPage);
        if (count == 0) return [];
        int normalized = ((page % count) + count) % count;
        return items.Skip(normalized * Math.Clamp(itemsPerPage, 1, 4)).Take(Math.Clamp(itemsPerPage, 1, 4)).ToArray();
    }
    public static (int Row, int Column) Cell(int index, int visibleCount, string layout) => layout == "twoRows" ?
        (index % 2, index / 2) : (0, index);
}
