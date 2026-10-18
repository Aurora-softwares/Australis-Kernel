namespace Australis.User {
    public interface INativeUserServices {
        int ChannelAccept(int processId, int version);
        int ChannelSend(int processId, int handle, int version,
            byte[] source, int length);
        int ChannelReceive(int processId, int handle, byte[] destination);
        int ChannelQueuedFor(int processId, int handle);
        int ChannelPeer(int processId, int handle);
        int ChannelClose(int processId, int handle);
        int FileOpen(int processId, byte[] path, int length, int mode);
        int FileRead(int processId, int descriptor, byte[] destination, int length);
        int FileWrite(int processId, int descriptor, byte[] source, int length,
            int operation);
        int FileClose(int processId, int descriptor);
        int FileCreate(int processId, byte[] path, int length);
        int FileDelete(int processId, byte[] path, int length);
    }
    public class NativeUserResult {
        private int status;
        private int exitCode;
        private long faultAddress;
        private long faultError;
        public NativeUserResult(int inputStatus, int inputExitCode,
            long inputFaultAddress, long inputFaultError) {
            status = inputStatus; exitCode = inputExitCode;
            faultAddress = inputFaultAddress; faultError = inputFaultError;
        }
        public int Status() { return status; }
        public int ExitCode() { return exitCode; }
        public long FaultAddress() { return faultAddress; }
        public long FaultError() { return faultError; }
        public int UserFaultCode() {
            if (status == -14) { return UserFault.MemoryAccess(); }
            if (status == -13) { return UserFault.InvalidInstruction(); }
            if (status == -8) { return UserFault.Arithmetic(); }
            if (status == -110) { return UserFault.InstructionLimit(); }
            if (status == -125) { return UserFault.Terminated(); }
            return UserFault.InvalidImage();
        }
        public UserProgramResult ProgramResult(int processId) {
            if (status == 0) {
                return new UserProgramResult(processId, UserProgramState.Exited(),
                    exitCode, UserFault.None(), 0);
            }
            return new UserProgramResult(processId, UserProgramState.Faulted(),
                -1, UserFaultCode(), 0);
        }
        public int ShellStatus() {
            if (status == 0) { return exitCode; }
            return -100 - UserFaultCode();
        }
    }

    // One native thread owns its address space and saved CPU frame until it
    // exits, faults, reaches its time limit, or is terminated. A finished
    // result remains available to its parent until wait/reap.
    public class NativeThreadState {
        public static int Runnable() { return 1; }
        public static int Running() { return 2; }
        public static int Exited() { return 3; }
        public static int Faulted() { return 4; }
        public static int Terminated() { return 5; }
    }
    public class NativeUserTask {
        private int pid;
        private NativeUserPageTables pages;
        private long context;
        private long argument;
        private int slices;
        private int calls;
        private int state;
        private NativeUserResult result;
        public NativeUserTask(int inputPid, NativeUserPageTables inputPages,
            long inputContext, long inputArgument) {
            pid = inputPid; pages = inputPages; context = inputContext;
            argument = inputArgument; slices = 0; calls = 0;
            state = NativeThreadState.Runnable();
            result = null;
        }
        public int Pid() { return pid; }
        public long Root() { return pages.Root(); }
        public long Base() { return pages.Base(); }
        public long Context() { return context; }
        public long Argument() { return argument; }
        public int State() { return state; }
        public bool Complete() { return state >= NativeThreadState.Exited(); }
        public NativeUserResult Result() { return result; }
        public int Slices() { return slices; }
        public int Calls() { return calls; }
        public void MarkRunning() { state = NativeThreadState.Running(); }
        public void MarkRunnable() { state = NativeThreadState.Runnable(); }
        public void Called() { calls = calls + 1; }
        public long Register(int offset) {
            return System.Kernel.Memory.Read64(context + offset);
        }
        public void Return(long value) {
            System.Kernel.Memory.Write64(context, value);
        }
        public bool CanCopyFrom(long address, int length) {
            return pages.CanCopyFrom(address, length);
        }
        public bool CanCopyTo(long address, int length) {
            return pages.CanCopyTo(address, length);
        }
        public bool CopyFromUser(long address, byte[] destination, int length) {
            return pages.CopyFromUser(address, destination, length);
        }
        public bool CopyToUser(long address, byte[] source, int length) {
            return pages.CopyToUser(address, source, length);
        }
        public void Yield() {
            slices = slices + 1; state = NativeThreadState.Runnable();
        }
        public void Finish(NativeUserResult inputResult) {
            result = inputResult; state = NativeThreadState.Faulted();
            if (result.Status() == 0) { state = NativeThreadState.Exited(); }
            if (result.Status() == -125) { state = NativeThreadState.Terminated(); }
        }
        public bool Release(long bootInfo) {
            bool released = pages.Release();
            if (context != 0 && !PhysicalPages.Free(bootInfo, context)) {
                released = false;
            }
            context = 0;
            return released;
        }
    }

    // This is the first hardware-enforced execution path. Its ring-0 shim is
    // generated from native_runtime.S and is mapped read-only executable.
    // The normal AUEX scheduler and VFS remain available around a native fault.
    public class NativeUserRuntime {
        private long bootInfo;
        private long codeFrame;
        private long codeAddress;
        private long tssFrame;
        private bool ready;
        private int failureCode;
        private int lastRunStep;
        private int lastStatus;
        private int lastRunPid;
        private NativeUserTask[] tasks;
        private int nextTaskSlot;
        private INativeUserServices services;

        private static long U32() { long n = 65536; return n * n; }
        private static long Gate(int vector, long bootInfo) {
            return bootInfo + 4096 + vector * 16;
        }
        private static long GateTarget(long gate) {
            return System.Kernel.Memory.Read16(gate) +
                System.Kernel.Memory.Read16(gate + 6) * 65536 +
                System.Kernel.Memory.Read32(gate + 8) * U32();
        }
        private static void WriteGate(long gate, long target, int access) {
            System.Kernel.Memory.Write16(gate, target % 65536);
            System.Kernel.Memory.Write16(gate + 2, 8);
            System.Kernel.Memory.Write8(gate + 4, 0);
            System.Kernel.Memory.Write8(gate + 5, access);
            System.Kernel.Memory.Write16(gate + 6, (target / 65536) % 65536);
            System.Kernel.Memory.Write32(gate + 8, target / U32());
            System.Kernel.Memory.Write32(gate + 12, 0);
        }
        private static void WriteUserDescriptor(long address, int access) {
            System.Kernel.Memory.Write8(address, 255);
            System.Kernel.Memory.Write8(address + 1, 255);
            System.Kernel.Memory.Write8(address + 2, 0);
            System.Kernel.Memory.Write8(address + 3, 0);
            System.Kernel.Memory.Write8(address + 4, 0);
            System.Kernel.Memory.Write8(address + 5, access);
            int flags = 175;
            if (access == 242) { flags = 207; }
            System.Kernel.Memory.Write8(address + 6, flags);
            System.Kernel.Memory.Write8(address + 7, 0);
        }
        private static void WriteTssDescriptor(long address, long tss) {
            System.Kernel.Memory.Write16(address, 103);
            System.Kernel.Memory.Write16(address + 2, tss % 65536);
            System.Kernel.Memory.Write8(address + 4, (tss / 65536) % 256);
            System.Kernel.Memory.Write8(address + 5, 137);
            System.Kernel.Memory.Write8(address + 6, 0);
            System.Kernel.Memory.Write8(address + 7, (tss / 16777216) % 256);
            System.Kernel.Memory.Write32(address + 8, tss / U32());
            System.Kernel.Memory.Write32(address + 12, 0);
        }

        public NativeUserRuntime(long inputBootInfo) {
            bootInfo = inputBootInfo; codeFrame = 0; codeAddress = 0;
            tssFrame = 0; failureCode = 1; lastRunStep = 0;
            lastStatus = -100; lastRunPid = 0;
            tasks = new NativeUserTask[16]; nextTaskSlot = 0;
            services = null;
            ready = Initialize();
        }
        public void BindServices(INativeUserServices inputServices) {
            services = inputServices;
        }
        public bool IsReady() { return ready; }
        public int FailureCode() { return failureCode; }
        public int LastRunStep() { return lastRunStep; }
        public int LastStatus() { return lastStatus; }
        public int LastRunPid() { return lastRunPid; }

        private bool Initialize() {
            if (bootInfo < 4096 || bootInfo % 4096 != 0) { return false; }
            byte[] blob = NativeRuntimeBlob.Bytes();
            if (blob.Length < 32 || blob.Length > 4096) { return false; }
            codeFrame = PhysicalPages.AllocateZeroed(bootInfo);
            tssFrame = PhysicalPages.AllocateZeroed(bootInfo);
            failureCode = 2;
            if (codeFrame == 0 || tssFrame == 0) { return false; }
            int i = 0;
            while (i < blob.Length) {
                System.Kernel.Memory.Write8(codeFrame + i, blob[i]); i = i + 1;
            }
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.BootInfoPointerOffset(), bootInfo);
            long oldPageFault = GateTarget(Gate(14, bootInfo));
            long oldGeneralProtection = GateTarget(Gate(13, bootInfo));
            long oldInvalidOpcode = GateTarget(Gate(6, bootInfo));
            long oldDivideError = GateTarget(Gate(0, bootInfo));
            long oldTimer = GateTarget(Gate(48, bootInfo));
            long oldInt80 = GateTarget(Gate(128, bootInfo));
            failureCode = 3;
            if (oldPageFault < 4096 || oldGeneralProtection < 4096 ||
                oldInvalidOpcode < 4096 || oldDivideError < 4096 ||
                oldTimer < 4096 || oldInt80 < 4096) { return false; }
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.OriginalPageFaultOffset(), oldPageFault);
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.OriginalGeneralProtectionOffset(),
                oldGeneralProtection);
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.OriginalInvalidOpcodeOffset(),
                oldInvalidOpcode);
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.OriginalDivideErrorOffset(),
                oldDivideError);
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.OriginalTimerOffset(), oldTimer);
            System.Kernel.Memory.Write64(codeFrame +
                NativeRuntimeBlob.OriginalInt80Offset(), oldInt80);
            codeAddress = KernelAddressSpace.FindUnmappedRange(bootInfo, 1);
            failureCode = 4;
            if (codeAddress == 0 || !KernelAddressSpace.MapTrustedCodePage(
                bootInfo, codeAddress, codeFrame) ||
                !KernelAddressSpace.IsExecutable(bootInfo, codeAddress)) {
                return false;
            }
            System.Kernel.Cpu.DisableInterrupts();
            WriteUserDescriptor(bootInfo + 536, 250);
            WriteUserDescriptor(bootInfo + 544, 242);
            WriteTssDescriptor(bootInfo + 552, tssFrame);
            System.Kernel.Memory.Write16(tssFrame + 102, 104);
            System.Kernel.Memory.Write64(bootInfo + 3576, tssFrame);
            System.Kernel.Memory.Write64(bootInfo + 3536, 0);
            failureCode = 5;
            if (System.Kernel.Cpu.CallKernel(codeAddress +
                NativeRuntimeBlob.SetupOffset(), bootInfo) != 0) {
                System.Kernel.Cpu.EnableInterrupts(); return false;
            }
            WriteGate(Gate(14, bootInfo), codeAddress +
                NativeRuntimeBlob.PageFaultOffset(), 142);
            WriteGate(Gate(13, bootInfo), codeAddress +
                NativeRuntimeBlob.GeneralProtectionOffset(), 142);
            WriteGate(Gate(6, bootInfo), codeAddress +
                NativeRuntimeBlob.InvalidOpcodeOffset(), 142);
            WriteGate(Gate(0, bootInfo), codeAddress +
                NativeRuntimeBlob.DivideErrorOffset(), 142);
            WriteGate(Gate(48, bootInfo), codeAddress +
                NativeRuntimeBlob.TimerOffset(), 142);
            WriteGate(Gate(128, bootInfo), codeAddress +
                NativeRuntimeBlob.Int80Offset(), 238);
            System.Kernel.Cpu.EnableInterrupts();
            failureCode = 0;
            return true;
        }

        public NativeUserResult Run(byte[] code, int length, long argument,
            int processId) {
            return RunCore(code, length, null, 0, argument, processId);
        }
        public NativeUserResult RunImage(byte[] code, byte[] startup,
            int processId) {
            if (code == null || startup == null) {
                return new NativeUserResult(-4, -1, 0, 0);
            }
            return RunCore(code, code.Length, startup, startup.Length, 0,
                processId);
        }
        private int SlotOf(int processId) {
            int i = 0;
            while (i < tasks.Length) {
                if (tasks[i] != null && tasks[i].Pid() == processId) { return i; }
                i = i + 1;
            }
            return -1;
        }
        public bool HasTask(int processId) { return SlotOf(processId) >= 0; }
        public int TaskSlices(int processId) {
            int slot = SlotOf(processId);
            if (slot < 0) { return -1; }
            return tasks[slot].Slices();
        }
        public bool IsComplete(int processId) {
            int slot = SlotOf(processId);
            return slot >= 0 && tasks[slot].Complete();
        }
        public NativeUserResult Result(int processId) {
            int slot = SlotOf(processId);
            if (slot < 0 || !tasks[slot].Complete()) { return null; }
            return tasks[slot].Result();
        }
        public NativeUserResult Reap(int processId) {
            int slot = SlotOf(processId);
            if (slot < 0 || !tasks[slot].Complete()) { return null; }
            NativeUserResult result = tasks[slot].Result();
            tasks[slot] = null;
            return result;
        }
        public bool SpawnImage(byte[] code, byte[] startup, int processId) {
            if (code == null || startup == null) { return false; }
            return SpawnCore(code, code.Length, startup, startup.Length, 0,
                processId);
        }
        private bool SpawnCore(byte[] code, int length,
            byte[] startup, int startupLength, long argument, int processId) {
            lastRunStep = 1; lastStatus = -4;
            if (!ready || processId < 1 || code == null || length < 1 || length > 4096 ||
                length > code.Length || startupLength < 0 || startupLength > 4096 ||
                (startup != null && startupLength > startup.Length) ||
                System.Kernel.Memory.Read64(bootInfo + 3536) != 0 ||
                SlotOf(processId) >= 0) { return false; }
            int slot = 0;
            while (slot < tasks.Length && tasks[slot] != null) { slot = slot + 1; }
            if (slot == tasks.Length) { return false; }
            NativeUserPageTables pages = new NativeUserPageTables(bootInfo);
            lastRunStep = 2;
            if (!pages.IsValid()) { return false; }
            lastRunStep = 3;
            bool mapped = pages.MapCode(1, code, length);
            // The syscall ABI accepts reads from page 2 for every native
            // process. Map it even when no startup record was supplied.
            if (mapped && startup == null) {
                mapped = pages.MapData(2, new byte[0], 0);
            }
            if (mapped && startup != null) {
                mapped = pages.MapData(2, startup, startupLength);
            }
            if (mapped) { mapped = pages.MapStack(4); }
            if (!mapped || !pages.IsGuardPage(3) ||
                !pages.IsGuardPage(5) || !pages.KernelMappingsSupervisorOnly()) {
                pages.Release(); return false;
            }
            long context = PhysicalPages.AllocateZeroed(bootInfo);
            if (context == 0) {
                pages.Release(); return false;
            }
            if (startup != null) { argument = pages.Base() + 8192; }
            System.Kernel.Memory.Write64(context + 48, argument);
            System.Kernel.Memory.Write64(context + 120, pages.Base() + 4096);
            System.Kernel.Memory.Write64(context + 128, 27);
            System.Kernel.Memory.Write64(context + 136, 514);
            System.Kernel.Memory.Write64(context + 144, pages.Base() + 5 * 4096);
            System.Kernel.Memory.Write64(context + 152, 35);
            tasks[slot] = new NativeUserTask(processId, pages, context, argument);
            return true;
        }
        private long Dispatch(NativeUserTask task) {
            long number = task.Register(0);
            long first = task.Register(48);
            long second = task.Register(40);
            long third = task.Register(24);
            long fourth = task.Register(16);
            if (services == null) { return -38; }
            if (number == 5) {
                if (first < 1 || first > 255) { return -22; }
                return services.ChannelAccept(task.Pid(), (int)first);
            }
            if (number == 6) {
                if (first < 1 || first > 2147483647 || fourth < 1 ||
                    fourth > 255 || third < 0 || third > 256) { return -22; }
                byte[] payload = new byte[(int)third];
                if (!task.CopyFromUser(second, payload, (int)third)) { return -14; }
                return services.ChannelSend(task.Pid(), (int)first,
                    (int)fourth, payload, (int)third);
            }
            if (number == 7) {
                if (first < 1 || first > 2147483647 || third < 0 ||
                    third > 256) { return -22; }
                if (!task.CanCopyTo(second, (int)third)) { return -14; }
                byte[] payload = new byte[(int)third];
                int count = services.ChannelReceive(task.Pid(), (int)first,
                    payload);
                if (count < 0) { return count; }
                if (!task.CopyToUser(second, payload, count)) { return -14; }
                return count;
            }
            if (number == 8) {
                if (first < 1 || first > 2147483647) { return -22; }
                int queued = services.ChannelQueuedFor(task.Pid(), (int)first);
                if (queued < 0) { return queued; }
                if (queued == 0) { return -11; }
                return 0;
            }
            if (number == 9) {
                if (first < 1 || first > 2147483647) { return -22; }
                return services.ChannelClose(task.Pid(), (int)first);
            }
            if (number == 10) {
                if (first < 1 || first > 2147483647) { return -22; }
                return services.ChannelPeer(task.Pid(), (int)first);
            }
            if (number == 11 || number == 15 || number == 16) {
                if (second < 1 || second > 255 ||
                    (number == 11 && third != 0 && third != 1)) { return -22; }
                byte[] path = new byte[(int)second];
                if (!task.CopyFromUser(first, path, (int)second)) { return -14; }
                if (number == 11) {
                    return services.FileOpen(task.Pid(), path, (int)second, (int)third);
                }
                if (number == 15) {
                    return services.FileCreate(task.Pid(), path, (int)second);
                }
                return services.FileDelete(task.Pid(), path, (int)second);
            }
            if (number == 12) {
                if (first < 3 || first > 15 || third < 0 || third > 256) { return -22; }
                if (!task.CanCopyTo(second, (int)third)) { return -14; }
                byte[] payload = new byte[(int)third];
                int count = services.FileRead(task.Pid(), (int)first,
                    payload, (int)third);
                if (count < 0) { return count; }
                if (!task.CopyToUser(second, payload, count)) { return -14; }
                return count;
            }
            if (number == 13) {
                if (first < 3 || first > 15 || third < 0 || third > 256 ||
                    (fourth != 1 && fourth != 2)) { return -22; }
                byte[] payload = new byte[(int)third];
                if (!task.CopyFromUser(second, payload, (int)third)) { return -14; }
                return services.FileWrite(task.Pid(), (int)first,
                    payload, (int)third, (int)fourth);
            }
            if (number == 14) {
                if (first < 3 || first > 15) { return -22; }
                return services.FileClose(task.Pid(), (int)first);
            }
            return -38;
        }
        // One timer-bounded slice. A waiting parent or the AUEX scheduler may
        // call this repeatedly; each runnable native child receives a turn.
        public int RunRound() {
            int visited = 0;
            while (visited < tasks.Length) {
                int slot = (nextTaskSlot + visited) % tasks.Length;
                NativeUserTask task = tasks[slot];
                if (task != null && !task.Complete()) {
                    lastRunPid = task.Pid();
                    task.MarkRunning();
                    nextTaskSlot = (slot + 1) % tasks.Length;
                    System.Kernel.Memory.Write64(bootInfo + 3544, task.Root());
                    System.Kernel.Memory.Write64(bootInfo + 3552, task.Base() + 4096);
                    System.Kernel.Memory.Write64(bootInfo + 3560,
                        task.Base() + 5 * 4096);
                    System.Kernel.Memory.Write64(bootInfo + 3568, task.Argument());
                    System.Kernel.Memory.Write64(bootInfo + 3624, task.Pid());
                    System.Kernel.Memory.Write64(bootInfo + 3640, task.Context());
                    System.Kernel.Memory.Write64(bootInfo + 3584, -1);
                    System.Kernel.Memory.Write64(bootInfo + 3592, 0);
                    System.Kernel.Memory.Write64(bootInfo + 3600, 0);
                    long status = System.Kernel.Cpu.CallKernel(codeAddress +
                        NativeRuntimeBlob.EnterOffset(), bootInfo);
                    lastRunStep = 4; lastStatus = (int)status;
                    if (status == 2) {
                        task.Called();
                        if (task.Calls() <= 4096) {
                            task.Return(Dispatch(task));
                            task.MarkRunnable();
                            System.Kernel.Memory.Write64(bootInfo + 3640, 0);
                            return 1;
                        }
                        status = -110;
                    }
                    if (status == 1) {
                        task.Yield();
                        if (task.Slices() <= 16) {
                            System.Kernel.Memory.Write64(bootInfo + 3640, 0);
                            return 1;
                        }
                        status = -110;
                    }
                    long exitCode = System.Kernel.Memory.Read64(bootInfo + 3584);
                    long faultAddress = System.Kernel.Memory.Read64(bootInfo + 3592);
                    long faultError = System.Kernel.Memory.Read64(bootInfo + 3600);
                    bool released = task.Release(bootInfo);
                    System.Kernel.Memory.Write64(bootInfo + 3640, 0);
                    if (!released || System.Kernel.Memory.Read64(bootInfo + 3536) != 0) {
                        status = -4; exitCode = -1;
                    }
                    task.Finish(new NativeUserResult((int)status,
                        (int)exitCode, faultAddress, faultError));
                    lastRunStep = 5; lastStatus = (int)status;
                    return 1;
                }
                visited = visited + 1;
            }
            return 0;
        }
        public bool Terminate(int processId) {
            int slot = SlotOf(processId);
            if (slot < 0 || tasks[slot].Complete() ||
                System.Kernel.Memory.Read64(bootInfo + 3536) != 0) { return false; }
            bool released = tasks[slot].Release(bootInfo);
            System.Kernel.Memory.Write64(bootInfo + 3640, 0);
            int status = -125;
            if (!released) { status = -4; }
            tasks[slot].Finish(new NativeUserResult(status, -1, 0, 0));
            return released;
        }
        public NativeUserResult Wait(int processId) {
            int slot = SlotOf(processId);
            if (slot < 0) { return new NativeUserResult(-4, -1, 0, 0); }
            while (!tasks[slot].Complete()) {
                if (RunRound() == 0) { return new NativeUserResult(-4, -1, 0, 0); }
            }
            return Reap(processId);
        }
        private NativeUserResult RunCore(byte[] code, int length,
            byte[] startup, int startupLength, long argument, int processId) {
            if (!SpawnCore(code, length, startup, startupLength, argument,
                processId)) { return new NativeUserResult(-4, -1, 0, 0); }
            return Wait(processId);
        }

        // The second image deliberately dereferences the supervisor-only
        // KernelBootInfo address. The first establishes a working exit syscall.
        public bool Probe(UserProcessTable processes, int parentPid,
            int cleanPid, int faultPid, int privilegePid,
            int spinPid, int secondPid) {
            if (processes == null || parentPid < 1 || cleanPid < 1 ||
                faultPid < 1 || privilegePid < 1 || spinPid < 1 || secondPid < 1 ||
                cleanPid == faultPid || cleanPid == privilegePid ||
                faultPid == privilegePid || spinPid == secondPid) { return false; }
            failureCode = 6;
            if (!processes.Start(cleanPid, parentPid)) { return false; }
            byte[] exits = new byte[18];
            exits[0] = 184; exits[1] = 2; exits[5] = 205; exits[6] = 128;
            exits[7] = 137; exits[8] = 199;
            exits[9] = 184; exits[10] = 1;
            exits[14] = 205; exits[15] = 128;
            exits[16] = 15; exits[17] = 11;
            NativeUserResult clean = Run(exits, 18, 0, cleanPid);
            if (clean.Status() == 0) {
                processes.Finish(new UserProgramResult(cleanPid,
                    UserProgramState.Exited(), clean.ExitCode(), UserFault.None(), 0));
            } else {
                processes.Finish(new UserProgramResult(cleanPid,
                    UserProgramState.Faulted(), -1, UserFault.MemoryAccess(), 0));
            }
            if (clean.Status() != 0) { return false; }
            failureCode = 7;
            if (clean.ExitCode() != cleanPid) { return false; }
            if (!processes.Start(faultPid, parentPid)) { return false; }
            byte[] faults = new byte[18];
            faults[0] = 72; faults[1] = 139; faults[2] = 7;
            faults[3] = 184; faults[4] = 1;
            faults[8] = 191; faults[9] = 99;
            faults[13] = 205; faults[14] = 128;
            faults[15] = 15; faults[16] = 11;
            NativeUserResult denied = Run(faults, 17, bootInfo, faultPid);
            if (denied.Status() == -14) {
                processes.Finish(new UserProgramResult(faultPid,
                    UserProgramState.Faulted(), -1, UserFault.MemoryAccess(), 0));
            } else {
                processes.Finish(new UserProgramResult(faultPid,
                    UserProgramState.Faulted(), -1, UserFault.InvalidImage(), 0));
            }
            failureCode = 8;
            if (denied.Status() != -14) { return false; }
            failureCode = 9;
            if (denied.FaultAddress() != bootInfo ||
                (denied.FaultError() / 4) % 2 == 0) { return false; }
            byte[] writes = new byte[3];
            writes[0] = 198; writes[1] = 7; writes[2] = 90;
            NativeUserResult writeDenied = Run(writes, 3, bootInfo, faultPid);
            if (writeDenied.Status() != -14 ||
                writeDenied.FaultAddress() != bootInfo ||
                (writeDenied.FaultError() / 2) % 2 == 0 ||
                (writeDenied.FaultError() / 4) % 2 == 0) { return false; }
            if (!processes.Start(privilegePid, parentPid)) { return false; }
            byte[] privileged = new byte[2];
            privileged[0] = 250; // cli: ring 3 cannot change interrupt state.
            privileged[1] = 244; // hlt if the privilege check ever failed.
            NativeUserResult rejected = Run(privileged, 2, 0, privilegePid);
            processes.Finish(new UserProgramResult(privilegePid,
                UserProgramState.Faulted(), -1,
                UserFault.InvalidInstruction(), 0));
            if (rejected.Status() != -13) { return false; }
            UserProcessRecord parent = processes.Find(parentPid);
            UserProcessRecord cleanChild = processes.Find(cleanPid);
            UserProcessRecord faultChild = processes.Find(faultPid);
            UserProcessRecord privilegeChild = processes.Find(privilegePid);
            if (parent == null || cleanChild == null || faultChild == null ||
                privilegeChild == null ||
                parent.State() != UserProgramState.Running() ||
                cleanChild.State() != UserProgramState.Exited() ||
                cleanChild.ExitCode() != cleanPid ||
                faultChild.State() != UserProgramState.Faulted() ||
                faultChild.Fault() != UserFault.MemoryAccess() ||
                privilegeChild.State() != UserProgramState.Faulted() ||
                privilegeChild.Fault() != UserFault.InvalidInstruction()) {
                return false;
            }
            failureCode = 10;
            if (!processes.Start(spinPid, parentPid) ||
                !processes.Start(secondPid, parentPid)) { return false; }
            byte[] spin = new byte[2]; spin[0] = 235; spin[1] = 254;
            if (!SpawnCore(spin, 2, null, 0, 0, spinPid) ||
                !SpawnCore(exits, 18, null, 0, 0, secondPid)) { return false; }
            nextTaskSlot = SlotOf(spinPid);
            if (RunRound() != 1 || IsComplete(spinPid) ||
                TaskSlices(spinPid) < 1) { return false; }
            failureCode = 11;
            if (RunRound() != 1 || !IsComplete(secondPid)) { return false; }
            NativeUserResult second = Reap(secondPid);
            if (second == null || second.Status() != 0 ||
                second.ExitCode() != secondPid ||
                !processes.Finish(second.ProgramResult(secondPid))) { return false; }
            failureCode = 12;
            if (!Terminate(spinPid)) { return false; }
            NativeUserResult stopped = Reap(spinPid);
            if (stopped == null || stopped.Status() != -125 ||
                !processes.Finish(stopped.ProgramResult(spinPid)) ||
                processes.Find(secondPid).State() != UserProgramState.Exited() ||
                processes.Find(spinPid).Fault() != UserFault.Terminated()) {
                return false;
            }
            processes.ReapChild(parentPid, cleanPid);
            processes.ReapChild(parentPid, faultPid);
            processes.ReapChild(parentPid, privilegePid);
            processes.ReapChild(parentPid, spinPid);
            processes.ReapChild(parentPid, secondPid);
            failureCode = 0;
            return true;
        }
    }
}
