using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using WidBar.SDK;

namespace NexoBar.Widget;

internal sealed class WidgetSettingsView : UserControl
{
    internal WidgetSettingsView(IWidgetSettingsContext context, WidgetInstanceSettings settings, int inheritedWidth)
    {
        var panel = new StackPanel { Margin = new Thickness(20), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = "Opções desta instância", FontSize = 20 });
        panel.Children.Add(new TextBlock { Text = "Organize os indicadores em NexoBar → Personalizar barra → WidBar. Estas opções ajustam somente esta cópia do widget.", TextWrapping = TextWrapping.Wrap });
        var inherit = new CheckBox { Content = $"Herdar largura do NexoBar ({inheritedWidth} px)", IsChecked = settings.WidthOverride is null };
        var width = new Slider { Minimum = 120, Maximum = 600, StepFrequency = 1, Value = settings.EffectiveWidth(inheritedWidth), IsEnabled = settings.WidthOverride is not null };
        var caption = new TextBlock();
        var names = new CheckBox { Content = "Mostrar nomes", IsChecked = settings.ShowNames };
        var example = new Border { HorizontalAlignment = HorizontalAlignment.Left, BorderThickness = new Thickness(1), Padding = new Thickness(3) };
        example.SetBinding(Border.BorderBrushProperty, new Binding { Source = caption, Path = new PropertyPath("Foreground"), Mode = BindingMode.OneWay });
        panel.Children.Add(inherit); panel.Children.Add(caption); panel.Children.Add(width); panel.Children.Add(names);
        panel.Children.Add(new TextBlock { Text = "O host pode limitar a largura disponível na taskbar. A prévia abaixo usa valores demonstrativos.", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new ScrollViewer { Content = example, HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        void Refresh(bool save)
        {
            int effective = inherit.IsChecked == true ? inheritedWidth : (int)Math.Round(width.Value);
            caption.Text = inherit.IsChecked == true ? $"Largura herdada: {effective} px" : $"Largura própria: {effective} px";
            width.IsEnabled = inherit.IsChecked != true;
            example.Width = effective;
            var demo = new Grid();
            var rows = new[] {
                new[] { (Id:"cpu", Label:"CPU", Value:"24%"), (Id:"memory", Label:"Memória", Value:"12/32 GiB") },
                new[] { (Id:"claude", Label:"Claude", Value:"38% | 12%"), (Id:"codex", Label:"Codex", Value:"12% | 8%"), (Id:"kiro", Label:"Kiro", Value:"8%") }
            };
            foreach (var row in rows)
            {
                var line = new Grid();
                foreach (var item in row)
                {
                    line.ColumnDefinitions.Add(new ColumnDefinition());
                    var cell = new Grid { Margin = new Thickness(3, 0, 3, 0), VerticalAlignment = VerticalAlignment.Center };
                    cell.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); cell.ColumnDefinitions.Add(new ColumnDefinition());
                    var text = new TextBlock { Text = (names.IsChecked == true ? item.Label + " · " : "") + item.Value,
                        FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                    cell.Children.Add(IndicatorIcon.Create(item.Id, text)); Grid.SetColumn(text, 1); cell.Children.Add(text);
                    ToolTipService.SetToolTip(cell, item.Label + " · " + item.Value + " · demonstrativo");
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, item.Label + " · " + item.Value + " · demonstrativo");
                    Grid.SetColumn(cell, line.Children.Count); line.Children.Add(cell);
                }
                demo.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                Grid.SetRow(line, demo.RowDefinitions.Count - 1); demo.Children.Add(line);
            }
            example.Child = demo;
            if (save) context.SaveSettings(settings.With(inherit.IsChecked == true ? null : effective, names.IsChecked == true).ToJson());
        }
        inherit.Checked += (_, _) => Refresh(true); inherit.Unchecked += (_, _) => Refresh(true);
        width.ValueChanged += (_, _) => Refresh(true);
        names.Checked += (_, _) => Refresh(true); names.Unchecked += (_, _) => Refresh(true);
        var reset = new Button { Content = "Restaurar largura herdada" };
        reset.Click += (_, _) => { inherit.IsChecked = true; Refresh(true); };
        panel.Children.Add(reset);
        Refresh(false); Content = new ScrollViewer { Content = panel };
    }
}
