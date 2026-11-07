namespace NexoBar.Core;

public readonly record struct OverlayRectangle(int Left, int Top, int Right, int Bottom)
{
    public bool IsValid => Right > Left && Bottom > Top;

    public bool Covers(OverlayRectangle bounds) => IsValid && bounds.IsValid &&
        Left <= bounds.Left && Top <= bounds.Top && Right >= bounds.Right && Bottom >= bounds.Bottom;
}

public static class OverlayPolicy
{
    public static bool ShouldDefer(int? notificationState, bool eligibleForeground, bool sameMonitor,
        bool maximized, OverlayRectangle? foregroundBounds, OverlayRectangle monitorBounds)
    {
        // Presentation mode is an explicit global request; BUSY alone also includes ordinary windows.
        if (notificationState == 4) return true;
        if (!eligibleForeground || !sameMonitor) return false;
        if (notificationState == 3) return true;
        return !maximized && foregroundBounds is { } bounds && bounds.Covers(monitorBounds);
    }
}
