using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace NexoBar.Widget;

internal static class IndicatorIcon
{
    internal static UIElement Create(string id, TextBlock foregroundSource)
    {
        var geometry = new PathGeometry { FillRule = FillRule.EvenOdd };
        if (ProviderIconPaths.All.TryGetValue(id, out var loops))
        {
            // Some original outlines extend outside 0..1; fit the complete bounding box without clipping.
            double minX = loops.SelectMany(x => x).Min(p => p.X), minY = loops.SelectMany(x => x).Min(p => p.Y);
            double width = loops.SelectMany(x => x).Max(p => p.X) - minX, height = loops.SelectMany(x => x).Max(p => p.Y) - minY;
            double scale = 16 / Math.Max(width, height);
            Point Fit(IconPoint p) => new((p.X - minX) * scale + (16 - width * scale) / 2,
                (p.Y - minY) * scale + (16 - height * scale) / 2);
            foreach (var loop in loops)
            {
                var figure = new PathFigure { StartPoint = Fit(loop[0]), IsClosed = true, IsFilled = true };
                var segment = new PolyLineSegment();
                foreach (var p in loop.Skip(1)) segment.Points.Add(Fit(p));
                figure.Segments.Add(segment); geometry.Figures.Add(figure);
            }
        }
        else
        {
            double[][] points = id == "memory" ? [[1, 4, 15, 4, 15, 12, 1, 12], [3, 6, 5, 6, 5, 10, 3, 10], [7, 6, 9, 6, 9, 10, 7, 10], [11, 6, 13, 6, 13, 10, 11, 10]] :
                id == "cpu" ? [[2, 2, 14, 2, 14, 14, 2, 14], [5, 5, 11, 5, 11, 11, 5, 11]] :
                id.StartsWith("gpu:", StringComparison.Ordinal) ? [[0, 3, 15, 3, 15, 12, 0, 12], [3, 5, 10, 5, 10, 10, 3, 10], [2, 12, 4, 12, 4, 15, 2, 15]] :
                [[8, 0, 16, 8, 8, 16, 0, 8], [8, 4, 12, 8, 8, 12, 4, 8]];
            foreach (var loop in points)
            {
                var figure = new PathFigure { StartPoint = new(loop[0], loop[1]), IsClosed = true, IsFilled = true };
                var segment = new PolyLineSegment();
                for (int i = 2; i < loop.Length; i += 2) segment.Points.Add(new(loop[i], loop[i + 1]));
                figure.Segments.Add(segment); geometry.Figures.Add(figure);
            }
        }
        var path = new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Width = 16, Height = 16 };
        path.SetBinding(Microsoft.UI.Xaml.Shapes.Shape.FillProperty,
            new Binding { Source = foregroundSource, Path = new PropertyPath("Foreground"), Mode = BindingMode.OneWay });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(path, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return new Viewbox { Width = 16, Height = 16, Child = path };
    }
}
