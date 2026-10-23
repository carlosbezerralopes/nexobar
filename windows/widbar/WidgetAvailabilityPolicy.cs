namespace NexoBar.Widget;

// Retain only the last explicit display switch, never a stale reading.
public sealed class WidgetAvailabilityPolicy
{
    public bool? LastKnownEnabled { get; private set; }
    public bool IsPreviewVisible => LastKnownEnabled != false;
    public bool KeepAvailabilityProbe => LastKnownEnabled == false;
    public void Observe(bool? enabled)
    {
        if (enabled.HasValue) LastKnownEnabled = enabled;
    }
}
