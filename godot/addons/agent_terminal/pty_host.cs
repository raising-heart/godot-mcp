// Agent Terminal console host.
//
// Runs a shell inside a Windows pseudo console (ConPTY) and relays raw bytes:
//   our stdin  -> the shell's keyboard input
//   the shell's screen output -> our stdout
// so that the Godot plugin can draw a real terminal.
//
// Resize requests arrive on stdin as  ESC ] 7777 ; <cols> ; <rows> BEL
// and are not passed to the shell.
//
// The shell is put in a job object that is killed when this process ends,
// so closing Godot never leaves a shell (or anything started in it) running.
//
// Usage: pty_host.exe <working dir> <cols> <rows> <command line>
//
// Uses only Windows APIs (kernel32). No network access. Compiled on first
// use with the C# compiler that ships with Windows (.NET Framework csc.exe).

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

static class PtyHost
{
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint CREATE_SUSPENDED = 0x00000004;
    const int STARTF_USESTDHANDLES = 0x00000100;
    const uint INFINITE = 0xFFFFFFFF;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const int JobObjectExtendedLimitInformation = 9;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
    static readonly byte[] ResizeMarker = Encoding.ASCII.GetBytes("\x1b]7777;");

    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int ResizePseudoConsole(IntPtr hPC, COORD size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr hThread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int cbInfoLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    static IntPtr pseudoConsole;
    static IntPtr childProcess;

    static int Main(string[] args)
    {
        if (args.Length < 4)
        {
            Console.Error.WriteLine("usage: pty_host <working dir> <cols> <rows> <command line>");
            return 2;
        }
        string cwd = args[0];
        short cols = Clamp(args[1]);
        short rows = Clamp(args[2]);
        string commandLine = string.Join(" ", args, 3, args.Length - 3);

        SafeFileHandle ptyInRead, ptyInWrite, ptyOutRead, ptyOutWrite;
        if (!CreatePipe(out ptyInRead, out ptyInWrite, IntPtr.Zero, 0) ||
            !CreatePipe(out ptyOutRead, out ptyOutWrite, IntPtr.Zero, 0))
            return Fail("CreatePipe");

        COORD size = new COORD { X = cols, Y = rows };
        int hr = CreatePseudoConsole(size, ptyInRead, ptyOutWrite, 0, out pseudoConsole);
        if (hr != 0) return Fail("CreatePseudoConsole (needs Windows 10 1809 or newer), HRESULT " + hr);

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize)) return Fail("InitializeProcThreadAttributeList");
        if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pseudoConsole, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            return Fail("UpdateProcThreadAttribute");

        STARTUPINFOEX si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        // Our own stdin/stdout are pipes to Godot; make sure the shell uses the
        // pseudo console instead of inheriting them.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.lpAttributeList = attrList;

        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
                IntPtr.Zero, cwd, ref si, out pi))
            return Fail("CreateProcess for: " + commandLine);
        childProcess = pi.hProcess;

        // Kill the whole shell process tree when this host exits for any reason
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job != IntPtr.Zero)
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
            AssignProcessToJobObject(job, pi.hProcess);
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);

        // The pseudo console owns its ends of the pipes now
        ptyInRead.Dispose();
        ptyOutWrite.Dispose();

        Stream stdout = Console.OpenStandardOutput();
        Stream stdin = Console.OpenStandardInput();
        FileStream toShell = new FileStream(ptyInWrite, FileAccess.Write, 1, false);
        FileStream fromShell = new FileStream(ptyOutRead, FileAccess.Read, 1, false);

        Thread output = new Thread(delegate () { Pump(fromShell, stdout); });
        output.IsBackground = true;
        output.Start();

        Thread input = new Thread(delegate () { ForwardInput(stdin, toShell); });
        input.IsBackground = true;
        input.Start();

        WaitForSingleObject(pi.hProcess, INFINITE);
        uint exitCode;
        GetExitCodeProcess(pi.hProcess, out exitCode);

        // Closing the pseudo console flushes the last output and ends the pump
        ClosePseudoConsole(pseudoConsole);
        output.Join(2000);
        try { stdout.Flush(); } catch (IOException) { }
        DeleteProcThreadAttributeList(attrList);
        Marshal.FreeHGlobal(attrList);
        return (int)exitCode;
    }

    static short Clamp(string value)
    {
        int n;
        if (!int.TryParse(value, out n)) n = 80;
        return (short)Math.Max(2, Math.Min(1000, n));
    }

    static int Fail(string what)
    {
        Console.Error.WriteLine("pty_host: " + what + " failed (error " + Marshal.GetLastWin32Error() + ")");
        return 1;
    }

    static void Pump(Stream from, Stream to)
    {
        byte[] buffer = new byte[16384];
        try
        {
            int n;
            while ((n = from.Read(buffer, 0, buffer.Length)) > 0)
            {
                to.Write(buffer, 0, n);
                to.Flush();
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    // Forward keyboard input to the shell, taking out resize requests.
    static void ForwardInput(Stream from, Stream to)
    {
        byte[] buffer = new byte[4096];
        List<byte> pending = new List<byte>();
        try
        {
            int n;
            while ((n = from.Read(buffer, 0, buffer.Length)) > 0)
            {
                for (int i = 0; i < n; i++) pending.Add(buffer[i]);
                byte[] passThrough = ExtractResizes(pending);
                if (passThrough.Length > 0)
                {
                    to.Write(passThrough, 0, passThrough.Length);
                    to.Flush();
                }
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        // Godot went away: end the shell instead of leaving it running
        if (childProcess != IntPtr.Zero) TerminateProcess(childProcess, 1);
    }

    // Removes complete resize requests from `pending` (applying them) and
    // returns the bytes to send to the shell. A request that is only partly
    // received stays in `pending` until the rest arrives.
    static byte[] ExtractResizes(List<byte> pending)
    {
        List<byte> output = new List<byte>();
        int i = 0;
        while (i < pending.Count)
        {
            if (pending[i] != 0x1b) { output.Add(pending[i]); i++; continue; }

            int matched = 0;
            while (matched < ResizeMarker.Length && i + matched < pending.Count && pending[i + matched] == ResizeMarker[matched]) matched++;
            if (matched < ResizeMarker.Length)
            {
                if (i + matched == pending.Count) break; // could be the start of a request; wait for more
                output.Add(pending[i]); i++; continue;
            }

            int end = pending.IndexOf(0x07, i + ResizeMarker.Length);
            if (end < 0)
            {
                if (pending.Count - i > 64) { output.Add(pending[i]); i++; continue; }
                break; // wait for the rest
            }
            string body = Encoding.ASCII.GetString(pending.GetRange(i + ResizeMarker.Length, end - i - ResizeMarker.Length).ToArray());
            string[] parts = body.Split(';');
            if (parts.Length == 2)
            {
                COORD size = new COORD { X = Clamp(parts[0]), Y = Clamp(parts[1]) };
                ResizePseudoConsole(pseudoConsole, size);
            }
            i = end + 1;
        }
        pending.RemoveRange(0, i);
        return output.ToArray();
    }
}
