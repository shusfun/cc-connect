using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Remodex;

internal sealed class BridgeOwner : IDisposable
{
    private Process? process;
    private IntPtr job;
    public bool Running => process is { HasExited: false };
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits { public long ProcessTime; public long JobTime; public uint Flags; public UIntPtr MinWorkingSet; public UIntPtr MaxWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadCount; public ulong WriteCount; public ulong OtherCount; public ulong ReadBytes; public ulong WriteBytes; public ulong OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory; public UIntPtr JobMemory; public UIntPtr PeakProcessMemory; public UIntPtr PeakJobMemory; }
    public void Start(DeviceAccess access)
    {
        if (Running) return;
        if (!access.Activated) throw new AccessException("请先登录并激活设备");
        var runtime = Path.Combine(AppContext.BaseDirectory, "RemodexRuntime");
        var node = Path.Combine(runtime, "node", "node.exe");
        var helper = Path.Combine(runtime, "bridge", "bin", "remodex-app-helper.js");
        if (!File.Exists(node) || !File.Exists(helper)) throw new IOException("内置运行时不完整，请重新安装 Remodex。");
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } };
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>())) { Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
        var start = new ProcessStartInfo(node) { WorkingDirectory = Path.Combine(runtime, "bridge"), UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add(helper); start.ArgumentList.Add("run");
        start.Environment["REMODEX_RELAY"] = access.Relay;
        start.Environment["REMODEX_DEVICE_STATE_DIR"] = Path.Combine(DeviceAccess.StateDirectory, "bridge");
        start.Environment["REMODEX_DESKTOP_IPC_LIVE_SYNC"] = "1";
        start.Environment["REMODEX_DESKTOP_AUTO_FOLLOW"] = "1";
        try
        {
            process = Process.Start(start) ?? throw new IOException("无法启动 Bridge。");
            if (!AssignProcessToJobObject(job, process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
            process.BeginOutputReadLine(); process.BeginErrorReadLine();
            process.StandardInput.WriteLine(access.State.ToJsonString()); process.StandardInput.Flush();
        }
        catch { if (process is { HasExited: false }) process.Kill(entireProcessTree: true); Dispose(); throw; }
    }
    public void Dispose()
    {
        if (process is { HasExited: false }) process.StandardInput.Close();
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        process?.Dispose(); process = null;
    }
}
