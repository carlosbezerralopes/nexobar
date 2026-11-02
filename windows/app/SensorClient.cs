using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using NexoBar.Core;

namespace NexoBar.Windows;

// Reads the elevated sensor service. The pipe server must be the service binary under Program Files,
// so a process that squats the pipe name cannot feed values to the app.
internal static class SensorClient
{
    internal static SensorSnapshot? Read()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", SensorProtocol.PipeName, PipeDirection.In);
            pipe.Connect(300);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out uint pid) || !ServerIsService(pid)) return null;
            var buffer = new byte[SensorProtocol.MaxBytes + 1]; int total = 0, read;
            while (total < buffer.Length && (read = pipe.Read(buffer, total, buffer.Length - total)) > 0) total += read;
            return total > SensorProtocol.MaxBytes ? null : SensorProtocol.Parse(Encoding.UTF8.GetString(buffer, 0, total).Trim(), DateTimeOffset.UtcNow);
        }
        catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }
    // A LocalSystem process cannot be opened by the user, so the Service Control Manager is asked instead:
    // the pipe server must be the running NexoBarSensors service, whose binary (admin-only config) is the Program Files copy.
    private static bool ServerIsService(uint pid)
    {
        IntPtr manager = OpenSCManager(null, null, 0x1), service = IntPtr.Zero; // SC_MANAGER_CONNECT
        if (manager == IntPtr.Zero) return false;
        try
        {
            service = OpenService(manager, SensorProtocol.ServiceName, 0x1 | 0x4); // QUERY_CONFIG | QUERY_STATUS
            if (service == IntPtr.Zero) return false;
            var status = new byte[36];
            if (!QueryServiceStatusEx(service, 0, status, status.Length, out _) || BitConverter.ToUInt32(status, 28) != pid) return false;
            QueryServiceConfig(service, IntPtr.Zero, 0, out int needed);
            if (needed is <= 0 or > 64 * 1024) return false;
            IntPtr config = Marshal.AllocHGlobal(needed);
            try
            {
                if (!QueryServiceConfig(service, config, needed, out _)) return false;
                string binary = (Marshal.PtrToStringUni(Marshal.ReadIntPtr(config, 16)) ?? "").Trim().Trim('"');
                string expected = SensorProtocol.ExecutablePath(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
                return string.Equals(binary, expected, StringComparison.OrdinalIgnoreCase);
            }
            finally { Marshal.FreeHGlobal(config); }
        }
        finally { if (service != IntPtr.Zero) CloseServiceHandle(service); CloseServiceHandle(manager); }
    }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "OpenSCManagerW", SetLastError = true)]
    private static extern IntPtr OpenSCManager(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "OpenServiceW", SetLastError = true)]
    private static extern IntPtr OpenService(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(IntPtr service, int level, byte[] buffer, int size, out int needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "QueryServiceConfigW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(IntPtr service, IntPtr config, int size, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);
}

// Volume-to-disk mapping and SSD detection both work without elevation (handles opened with no data access).
internal static class DiskProbe
{
    internal static IReadOnlyList<DiskVolume> Volumes()
    {
        List<DiskVolume> result = [];
        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (drive.DriveType != DriveType.Fixed || !drive.IsReady) continue;
                using var handle = CreateFile(@"\\.\" + drive.Name.TrimEnd('\\'), 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (handle.IsInvalid) continue;
                var extents = new byte[8 + 24 * 4];
                // A volume spanning several disks is ambiguous; it is not attributed to any single disk.
                if (!DeviceIoControl(handle, 0x00560000, IntPtr.Zero, 0, extents, extents.Length, out _, IntPtr.Zero) || BitConverter.ToUInt32(extents, 0) != 1) continue;
                result.Add(new((int)BitConverter.ToUInt32(extents, 8), (ulong)drive.TotalSize, (ulong)drive.TotalFreeSpace));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return result;
    }
    // IOCTL_DISK_PERFORMANCE: the counters Resource Monitor uses; FILE_ANY_ACCESS, so no elevation.
    internal static DiskCounters? Counters(int disk)
    {
        using var handle = CreateFile(@"\\.\PhysicalDrive" + disk, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        var output = new byte[88];
        if (!DeviceIoControl(handle, 0x00070020, IntPtr.Zero, 0, output, output.Length, out int returned, IntPtr.Zero) || returned < 64) return null;
        return new(BitConverter.ToInt64(output, 0), BitConverter.ToInt64(output, 8), BitConverter.ToInt64(output, 32), BitConverter.ToInt64(output, 56));
    }
    internal static bool? SolidState(int disk)
    {
        using var handle = CreateFile(@"\\.\PhysicalDrive" + disk, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        var query = new byte[12]; BitConverter.GetBytes(7).CopyTo(query, 0); // StorageDeviceSeekPenaltyProperty, PropertyStandardQuery
        var output = new byte[12];
        var pinned = GCHandle.Alloc(query, GCHandleType.Pinned);
        try
        {
            if (!DeviceIoControl(handle, 0x002D1400, pinned.AddrOfPinnedObject(), query.Length, output, output.Length, out int returned, IntPtr.Zero) || returned < 9) return null;
            return output[8] == 0;
        }
        finally { pinned.Free(); }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateFileW", SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(SafeFileHandle device, uint code, IntPtr input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);
}
