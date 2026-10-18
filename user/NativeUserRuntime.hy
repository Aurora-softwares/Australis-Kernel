namespace Australis.User {
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
            lastStatus = -100;
            ready = Initialize();
        }
        public bool IsReady() { return ready; }
        public int FailureCode() { return failureCode; }
        public int LastRunStep() { return lastRunStep; }
        public int LastStatus() { return lastStatus; }

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
            long oldInt80 = GateTarget(Gate(128, bootInfo));
            failureCode = 3;
            if (oldPageFault < 4096 || oldGeneralProtection < 4096 ||
                oldInvalidOpcode < 4096 || oldDivideError < 4096 ||
                oldInt80 < 4096) { return false; }
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
        private NativeUserResult RunCore(byte[] code, int length,
            byte[] startup, int startupLength, long argument, int processId) {
            lastRunStep = 1; lastStatus = -4;
            if (!ready || processId < 1 || code == null || length < 1 || length > 4096 ||
                length > code.Length || startupLength < 0 || startupLength > 4096 ||
                (startup != null && startupLength > startup.Length) ||
                System.Kernel.Memory.Read64(bootInfo + 3536) != 0) {
                return new NativeUserResult(-4, -1, 0, 0);
            }
            NativeUserPageTables pages = new NativeUserPageTables(bootInfo);
            lastRunStep = 2;
            if (!pages.IsValid()) { return new NativeUserResult(-4, -1, 0, 0); }
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
                pages.Release(); return new NativeUserResult(-4, -1, 0, 0);
            }
            System.Kernel.Memory.Write64(bootInfo + 3544, pages.Root());
            System.Kernel.Memory.Write64(bootInfo + 3552, pages.Base() + 4096);
            System.Kernel.Memory.Write64(bootInfo + 3560, pages.Base() + 5 * 4096);
            if (startup != null) { argument = pages.Base() + 8192; }
            System.Kernel.Memory.Write64(bootInfo + 3568, argument);
            System.Kernel.Memory.Write64(bootInfo + 3624, processId);
            System.Kernel.Memory.Write64(bootInfo + 3584, -1);
            System.Kernel.Memory.Write64(bootInfo + 3592, 0);
            System.Kernel.Memory.Write64(bootInfo + 3600, 0);
            long status = System.Kernel.Cpu.CallKernel(codeAddress +
                NativeRuntimeBlob.EnterOffset(), bootInfo);
            lastRunStep = 4; lastStatus = (int)status;
            long exitCode = System.Kernel.Memory.Read64(bootInfo + 3584);
            long faultAddress = System.Kernel.Memory.Read64(bootInfo + 3592);
            long faultError = System.Kernel.Memory.Read64(bootInfo + 3600);
            bool released = pages.Release();
            if (!released || System.Kernel.Memory.Read64(bootInfo + 3536) != 0) {
                lastStatus = -4;
                return new NativeUserResult(-4, -1, faultAddress, faultError);
            }
            lastRunStep = 5;
            return new NativeUserResult((int)status, (int)exitCode,
                faultAddress, faultError);
        }

        // The second image deliberately dereferences the supervisor-only
        // KernelBootInfo address. The first establishes a working exit syscall.
        public bool Probe(UserProcessTable processes, int parentPid,
            int cleanPid, int faultPid, int privilegePid) {
            if (processes == null || parentPid < 1 || cleanPid < 1 ||
                faultPid < 1 || privilegePid < 1 || cleanPid == faultPid ||
                cleanPid == privilegePid || faultPid == privilegePid) { return false; }
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
            failureCode = 0;
            return true;
        }
    }
}
