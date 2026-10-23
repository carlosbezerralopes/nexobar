using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Screen = System.Windows.Forms.Screen;

namespace NexoBar.Windows;

// Public Shell AppBar registration reserves its own row; Explorer/taskbar are never modified.
internal sealed class AppBarDock : IDisposable
{
    private readonly Window window;
    private readonly Action reposition;
    private readonly IntPtr handle;
    private readonly uint callback, taskbarCreated;
    private readonly HwndSource? source;
    private bool registered, positioning, fullscreen, disposed;
    private string? monitor;
    private int height;
    private NativeRect last;
    internal AppBarDock(Window window, Action reposition)
    {
        this.window = window; this.reposition = reposition;
        handle = new WindowInteropHelper(window).Handle;
        callback = RegisterWindowMessage("NexoBar.AppBar.Callback.v1");
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        source = HwndSource.FromHwnd(handle);
        source?.AddHook(Hook);
    }
    internal void Position(Screen screen, double dipHeight, bool visible, bool reserveSpace)
    {
        if (disposed || positioning) return;
        if (!visible) { Release(); return; }
        if (!reserveSpace)
        {
            Release();
            DesktopIntegration.PositionBar(window, DesktopIntegration.Selected(screen.DeviceName), dipHeight);
            return;
        }
        int pixels = (int)Math.Ceiling(dipHeight * DesktopIntegration.Scale(screen));
        bool needsPosition = !registered || monitor != screen.DeviceName || height != pixels || last.Left != screen.Bounds.Left || last.Right != screen.Bounds.Right;
        monitor = screen.DeviceName; height = pixels;
        if (!registered)
        {
            var registration = Data(); registration.Callback = callback;
            registered = SHAppBarMessage(0, ref registration) != UIntPtr.Zero;
            if (!registered) { DesktopIntegration.Position(window, screen, window.Width, dipHeight); return; }
        }
        if (needsPosition) SetPosition(screen);
    }
    private void SetPosition(Screen screen)
    {
        if (positioning || !registered || disposed) return;
        positioning = true;
        try
        {
            var data = Data(); data.Edge = 3;
            // Query from monitor Bounds, never from our own shrinking WorkingArea.
            data.Rect = new() { Left = screen.Bounds.Left, Top = screen.Bounds.Top, Right = screen.Bounds.Right, Bottom = screen.Bounds.Bottom };
            SHAppBarMessage(2, ref data);
            data.Rect.Top = data.Rect.Bottom - height;
            SHAppBarMessage(3, ref data);
            last = data.Rect;
            SetWindowPos(handle, fullscreen ? new IntPtr(1) : new IntPtr(-1), last.Left, last.Top,
                last.Right - last.Left, last.Bottom - last.Top, 0x10);
        }
        finally { positioning = false; }
    }
    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message == callback)
        {
            if (wparam.ToInt32() == 1 && !positioning)
                window.Dispatcher.BeginInvoke(() => { if (monitor is not null) SetPosition(DesktopIntegration.Selected(monitor)); });
            if (wparam.ToInt32() == 2)
            {
                fullscreen = lparam != IntPtr.Zero;
                SetWindowPos(handle, fullscreen ? new IntPtr(1) : new IntPtr(-1), 0, 0, 0, 0, 0x13);
            }
            handled = true;
        }
        if (message == taskbarCreated)
        {
            registered = false;
            window.Dispatcher.BeginInvoke(reposition);
        }
        if (registered && !positioning && message is 0x0006 or 0x0047)
        {
            var data = Data();
            SHAppBarMessage(message == 0x0006 ? 6u : 9u, ref data);
        }
        if (message is 0x02E0 or 0x007E) window.Dispatcher.BeginInvoke(reposition);
        return IntPtr.Zero;
    }
    internal void Release()
    {
        if (!registered) return;
        var data = Data(); SHAppBarMessage(1, ref data); registered = false;
    }
    public void Dispose() { if (disposed) return; Release(); disposed = true; source?.RemoveHook(Hook); }
    private AppBarData Data() => new() { Size = (uint)Marshal.SizeOf<AppBarData>(), Handle = handle };
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct AppBarData { public uint Size; public IntPtr Handle; public uint Callback, Edge; public NativeRect Rect; public IntPtr LParam; }
    [DllImport("shell32.dll")] private static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
}
