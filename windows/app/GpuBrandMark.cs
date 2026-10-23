using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NexoBar.Core;

namespace NexoBar.Windows;

internal static class GpuBrandMark
{
    internal static FrameworkElement Create(Reading reading, Brush foreground, bool compact)
    {
        string? wordmark = GpuBrand.Wordmark(reading.Vendor);
        FrameworkElement element;
        if (wordmark is not null)
        {
            element = new TextBlock
            {
                Text = wordmark, Foreground = foreground, FontFamily = new FontFamily("Segoe UI"),
                FontSize = compact ? 11 : 16, FontWeight = FontWeights.Bold,
                FontStyle = reading.Vendor == GpuVendor.Intel ? FontStyles.Italic : FontStyles.Normal
            };
        }
        else
        {
            // Independent generic board outline for hardware whose manufacturer is not known.
            element = new System.Windows.Shapes.Path
            {
                Data = Geometry.Parse("M2,5 L19,5 L19,18 L2,18 Z M19,9 L22,9 M19,14 L22,14 M6,9 L12,9 L12,14 L6,14 Z M15,9 L15,14 M5,18 L5,21 M10,18 L10,21 M15,18 L15,21"),
                Stroke = foreground, StrokeThickness = 1.4, Stretch = Stretch.Uniform,
                Width = compact ? 18 : 25, Height = compact ? 18 : 25
            };
        }
        element.VerticalAlignment = VerticalAlignment.Center;
        element.Margin = new Thickness(0, 0, compact ? 8 : 12, 0);
        System.Windows.Automation.AutomationProperties.SetName(element, wordmark is null ? "GPU · fabricante não identificado" : "GPU · " + wordmark);
        return element;
    }
}
