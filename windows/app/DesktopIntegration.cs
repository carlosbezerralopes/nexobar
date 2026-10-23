using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using NexoBar.Core;
using Screen = System.Windows.Forms.Screen;

namespace NexoBar.Windows;

internal static class DesktopIntegration
{
    public static bool LightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", false);
            return key?.GetValue("SystemUsesLightTheme") is not int value || value != 0;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException) { return true; }
    }
    public static void Theme(Window window)
    {
        bool light = LightTheme();
        window.Background = new SolidColorBrush(light ? Color.FromRgb(247, 247, 247) : Color.FromRgb(30, 30, 30));
        window.Foreground = new SolidColorBrush(light ? Color.FromRgb(25, 25, 25) : Color.FromRgb(244, 244, 244));
        window.FontFamily = new FontFamily("Segoe UI");
        window.FontSize = 12;
        window.Resources[typeof(Button)] = ButtonStyle(light);
    }
    private static Style ButtonStyle(bool light)
    {
        var border = new FrameworkElementFactory(typeof(Border));
        border.Name = "Chrome";
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.ForegroundProperty));
        border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(3));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(FrameworkElement.MarginProperty, new TemplateBindingExtension(Control.PaddingProperty));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        style.Setters.Add(new Setter(Control.BackgroundProperty, new SolidColorBrush(light ? Color.FromRgb(240, 240, 240) : Color.FromRgb(40, 40, 40))));
        style.Setters.Add(new Setter(Control.ForegroundProperty, new SolidColorBrush(light ? Colors.Black : Colors.White)));
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(light ? Color.FromRgb(218, 218, 218) : Color.FromRgb(65, 65, 65)), "Chrome"));
        // Triggers on the template override a button's local background during interaction.
        template.Triggers.Add(hover);
        var press = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        press.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(light ? Color.FromRgb(195, 195, 195) : Color.FromRgb(85, 85, 85)), "Chrome"));
        template.Triggers.Add(press);
        return style;
    }
    public static Screen Selected(string? id) => Screen.AllScreens.FirstOrDefault(s => s.DeviceName == id) ?? Screen.PrimaryScreen ?? Screen.AllScreens[0];
    public static void NonActivating(Window window)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        SetWindowLongPtr(handle, -20, new IntPtr(GetWindowLongPtr(handle, -20).ToInt64() | 0x08000000 | 0x80));
        HwndSource.FromHwnd(handle)?.AddHook((IntPtr hwnd, int msg, IntPtr wparam, IntPtr lparam, ref bool handled) =>
        {
            if (msg == 0x21) { handled = true; return new IntPtr(3); } // WM_MOUSEACTIVATE -> MA_NOACTIVATE.
            return IntPtr.Zero;
        });
    }
    public static double Scale(Screen screen)
    {
        try
        {
            var point = new NativePoint { X = screen.Bounds.Left + 1, Y = screen.Bounds.Top + 1 };
            if (GetDpiForMonitor(MonitorFromPoint(point, 2), 0, out uint x, out _) == 0) return x / 96d;
        }
        catch (DllNotFoundException) { }
        return 1;
    }
    public static void Position(Window window, Screen screen, double width, double height)
    {
        double scale = Scale(screen);
        var area = screen.WorkingArea;
        int pixelsWidth = (int)Math.Ceiling(width * scale), pixelsHeight = (int)Math.Ceiling(height * scale);
        int margin = (int)Math.Ceiling(6 * scale);
        SetWindowPos(new WindowInteropHelper(window).Handle, new IntPtr(-1), area.Right - pixelsWidth - margin,
            area.Bottom - pixelsHeight - margin, pixelsWidth, pixelsHeight, 0x10); // SWP_NOACTIVATE.
    }
    public static void PositionBar(Window window, Screen screen, double height)
    {
        double scale = Scale(screen);
        var area = screen.WorkingArea;
        int pixelsHeight = (int)Math.Ceiling(height * scale);
        IntPtr handle = new WindowInteropHelper(window).Handle;
        bool deferToFullscreen = DeferOverlay(handle, screen);
        SetWindowPos(handle, deferToFullscreen ? new IntPtr(1) : new IntPtr(-1), area.Left,
            area.Bottom - pixelsHeight, area.Width, pixelsHeight, 0x10);
    }
    private static bool DeferOverlay(IntPtr bar, Screen screen)
    {
        int? state = SHQueryUserNotificationState(out int reportedState) >= 0 ? reportedState : null;
        if (state == 4) return true;
        IntPtr foreground = GetForegroundWindow();
        bool eligible = EligibleForeground(foreground, bar);
        IntPtr monitor = MonitorFromPoint(new NativePoint { X = screen.Bounds.Left + 1, Y = screen.Bounds.Top + 1 }, 2);
        bool sameMonitor = eligible && monitor != IntPtr.Zero && MonitorFromWindow(foreground, 0) == monitor;
        OverlayRectangle? bounds = null;
        bool maximized = false;
        if (eligible && sameMonitor)
        {
            maximized = IsZoomed(foreground);
            // DWM excludes invisible resize borders; GetWindowRect is the documented fallback.
            if (DwmGetWindowRectangle(foreground, 9, out NativeRectangle rectangle, Marshal.SizeOf<NativeRectangle>()) >= 0 ||
                GetWindowRect(foreground, out rectangle))
                bounds = new(rectangle.Left, rectangle.Top, rectangle.Right, rectangle.Bottom);
        }
        var screenBounds = screen.Bounds;
        bool defer = OverlayPolicy.ShouldDefer(state, eligible, sameMonitor, maximized, bounds,
            new(screenBounds.Left, screenBounds.Top, screenBounds.Right, screenBounds.Bottom));
        // Discard a foreground snapshot that changed while collecting its attributes.
        return GetForegroundWindow() == foreground && defer;
    }
    private static bool EligibleForeground(IntPtr foreground, IntPtr bar)
    {
        if (foreground == IntPtr.Zero || foreground == bar || !IsWindowVisible(foreground) || IsIconic(foreground) ||
            foreground == GetDesktopWindow() || foreground == GetShellWindow()) return false;
        if (GetWindowThreadProcessId(foreground, out uint processId) == 0 || processId == 0 || processId == Environment.ProcessId)
            return false;
        var className = new StringBuilder(256);
        if (GetClassName(foreground, className, className.Capacity) == 0 ||
            className.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return false;
        return DwmGetWindowCloaked(foreground, 14, out int cloaked, sizeof(int)) < 0 || cloaked == 0;
    }
    [DllImport("shell32.dll")] private static extern int SHQueryUserNotificationState(out int state);
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRectangle { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr handle, StringBuilder name, int capacity);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr handle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsZoomed(IntPtr handle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr handle, out NativeRectangle rectangle);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr handle, uint flags);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] private static extern int DwmGetWindowCloaked(IntPtr handle, int attribute, out int value, int size);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] private static extern int DwmGetWindowRectangle(IntPtr handle, int attribute, out NativeRectangle value, int size);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr handle, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr handle, int index, IntPtr value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
}
