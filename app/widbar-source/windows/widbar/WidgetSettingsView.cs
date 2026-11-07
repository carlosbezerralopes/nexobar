using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using NexoBar.Core;
using WidBar.SDK;

namespace NexoBar.Widget;

internal sealed class WidgetSettingsView : UserControl
{
    internal WidgetSettingsView(IWidgetSettingsContext context, WidgetInstanceSettings settings,
        Func<DisplaySnapshot?> readOptions, Func<string> readMeasurement, Func<Action, Action> subscribe)
    {
        int InheritedWidth() => readOptions()?.WidgetOptions.Width ?? 320;
        var panel = new StackPanel { Margin = new Thickness(20), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = "Opções desta instância", FontSize = 20 });
        panel.Children.Add(new TextBlock { Text = "Organize livremente as duas linhas de componentes em NexoBar → Personalizar barra → WidBar. 2+3 é um preset; o limite é de oito indicadores no total por página. Cotas empilhadas são linhas internas de cada indicador.", TextWrapping = TextWrapping.Wrap });
        var inherit = new CheckBox { Content = $"Herdar largura do NexoBar ({InheritedWidth()} px)", IsChecked = settings.WidthOverride is null };
        var width = new Slider { Minimum = 120, Maximum = 600, StepFrequency = 1,
            Value = settings.EffectiveWidth(InheritedWidth()), IsEnabled = settings.WidthOverride is not null };
        var caption = new TextBlock();
        var names = new CheckBox { Content = "Mostrar nomes", IsChecked = settings.ShowNames };
        var measurement = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var example = new Border { HorizontalAlignment = HorizontalAlignment.Left, BorderThickness = new Thickness(1), Padding = new Thickness(3) };
        example.SetBinding(Border.BorderBrushProperty, new Binding { Source = caption, Path = new PropertyPath("Foreground"), Mode = BindingMode.OneWay });
        panel.Children.Add(inherit); panel.Children.Add(caption); panel.Children.Add(width); panel.Children.Add(names);
        panel.Children.Add(new TextBlock { Text = "O host pode limitar a largura e a altura do preview. A prévia abaixo usa valores demonstrativos; a medida é somente do preview hospedado. Renovação e cotas empilhadas: NexoBar → Personalizar barra. Espaço entre linhas: NexoBar → Personalizar barra → WidBar.", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(measurement);
        panel.Children.Add(new ScrollViewer { Content = example, HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        bool refreshing = false;
        string? demoShape = null;
        void Refresh(bool save)
        {
            if (refreshing) return;
            refreshing = true;
            try
            {
                int inheritedWidth = InheritedWidth();
                int effective = inherit.IsChecked == true ? inheritedWidth : (int)Math.Round(width.Value);
                inherit.Content = $"Herdar largura do NexoBar ({inheritedWidth} px)";
                caption.Text = inherit.IsChecked == true ? $"Largura herdada: {effective} px" : $"Largura própria: {effective} px";
                width.IsEnabled = inherit.IsChecked != true;
                example.Width = effective;
                measurement.Text = readMeasurement();
                var current = readOptions();
                // Offline settings retain a labelled default demo, never a measurement of the host.
                var options = current ?? new DisplaySnapshot(1, PresentationDemo.ReferenceTime, true,
                    new(5, "customRows", Placements: [new("cpu", 0, 0), new("memory", 0, 1),
                        new("claude", 1, 0), new("codex", 1, 1), new("kiro", 1, 2)]), [], true, false, false);
                var demoItems = (current?.Indicators ?? new[] {
                    new DisplayIndicator("cpu", "CPU", PresentationDemo.Reading("cpu", "CPU"), true),
                    new DisplayIndicator("memory", "Memória", PresentationDemo.Reading("memory", "Memória"), true),
                    new DisplayIndicator("claude", "Claude", PresentationDemo.Reading("claude", "Claude"), true),
                    new DisplayIndicator("codex", "Codex", PresentationDemo.Reading("codex", "Codex"), true),
                    new DisplayIndicator("kiro", "Kiro", PresentationDemo.Reading("kiro", "Kiro"), true)
                }).Select(item => item with { Reading = PresentationDemo.Reading(item.Id, item.Label) }).ToArray();
                string shape = System.Text.Json.JsonSerializer.Serialize(new { options.WidgetOptions,
                    options.MemoryNominal, options.StackedQuotas, options.DetailedCountdown, options.ShowQuotaReset,
                    Names = names.IsChecked, Width = effective,
                    Items = demoItems.Select(item => new { item.Id, item.Label, item.ShowTemperature }) });
                if (demoShape != shape)
                {
                    var demo = new Grid();
                    var cells = WidgetPaging.LayoutPage(demoItems, item => item.Id, 0, options.WidgetOptions.ItemsPerPage,
                        options.WidgetOptions.Layout, options.WidgetOptions.Placements);
                    new WidgetPreviewRenderer().Build(demo, cells, settings.With(inherit.IsChecked == true ? null : effective,
                        names.IsChecked == true), options, PresentationDemo.ReferenceTime, demonstration: true);
                    example.Child = demo; demoShape = shape;
                }
                if (save) context.SaveSettings(settings.With(inherit.IsChecked == true ? null : effective, names.IsChecked == true).ToJson());
            }
            finally { refreshing = false; }
        }
        inherit.Checked += (_, _) => Refresh(true); inherit.Unchecked += (_, _) => Refresh(true);
        width.ValueChanged += (_, _) => Refresh(true);
        names.Checked += (_, _) => Refresh(true); names.Unchecked += (_, _) => Refresh(true);
        var reset = new Button { Content = "Restaurar largura herdada" };
        reset.Click += (_, _) => { inherit.IsChecked = true; Refresh(true); };
        panel.Children.Add(reset);
        Action? unsubscribe = null;
        Loaded += (_, _) => { unsubscribe?.Invoke(); unsubscribe = subscribe(() => Refresh(false)); Refresh(false); };
        Unloaded += (_, _) => { unsubscribe?.Invoke(); unsubscribe = null; };
        Refresh(false); Content = new ScrollViewer { Content = panel };
    }
}
