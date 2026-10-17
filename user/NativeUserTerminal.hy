using Australis.Kernel.Console;
using Australis.Kernel.Time;
using Australis.Kernel.Usb;
using Australis.Kernel.Vfs;

namespace Australis.User {
    // The live adapter consumes the same decoded event queue as the shell.
    // Controller work and ANSI decoding happen here in normal context; COM1
    // and xHCI handlers only acknowledge hardware and enqueue bounded input.
    public class NativeUserTerminal : IUserTerminal {
        private IConsoleInput input;
        private ConsoleWriter output;
        private ConsoleEventQueue events;
        private SerialKeyDecoder decoder;
        private NativeXhci usb;

        public NativeUserTerminal(IConsoleInput inputSource, ConsoleWriter outputWriter,
            ConsoleEventQueue inputEvents, SerialKeyDecoder inputDecoder, NativeXhci inputUsb) {
            input = inputSource; output = outputWriter; events = inputEvents;
            decoder = inputDecoder; usb = inputUsb;
        }

        public int ReadByte() {
            if (input == null || output == null || events == null || decoder == null) { return -1; }
            if (!input.IsReady()) { return -1; }
            int value = events.Poll();
            if (value >= 0 && value <= ConsoleKey.Delete()) { return value; }
            if (value == ConsoleKey.InputLost()) { return -1; }
            if (usb != null) { usb.Pump(); }
            decoder.Pump();
            value = events.Poll();
            if (value >= 0 && value <= ConsoleKey.Delete()) { return value; }
            if (value == ConsoleKey.InputLost()) { return -1; }
            System.Kernel.Cpu.Pause();
            return -3; // No input yet; let the scheduler run another process.
        }

        public bool WriteByte(int value) {
            return output != null && output.WriteByte(value);
        }
    }

    public class NativeUserFiles : IUserFiles {
        private VfsNamespace mounts;
        private VfsFileHandle[] handles;
        private NativeUserProgramHost owner;
        public NativeUserFiles(VfsNamespace inputMounts) {
            mounts = inputMounts; handles = new VfsFileHandle[16]; owner = null;
        }
        public NativeUserFiles(VfsNamespace inputMounts, NativeUserProgramHost inputOwner) {
            mounts = inputMounts; handles = new VfsFileHandle[16]; owner = inputOwner;
        }
        private void MarkMutation() { if (owner != null) { owner.RecordMutation(); } }
        private int Place(VfsFileHandle handle) {
            if (handle == null) { return -VfsStatus.Corrupt(); }
            if (!handle.IsOpen()) { return -handle.Status(); }
            int descriptor = 3;
            while (descriptor < handles.Length && handles[descriptor] != null) {
                descriptor = descriptor + 1;
            }
            if (descriptor == handles.Length) { handle.Close(); return -VfsStatus.NoSpace(); }
            handles[descriptor] = handle; return descriptor;
        }
        private string Path(byte[] path, int count) {
            if (path == null || count < 1 || count > 255 || count > path.Length) {
                return null;
            }
            return System.Kernel.String.FromBytes(path, count);
        }
        public int Open(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return -VfsStatus.InvalidArgument(); }
            return Place(mounts.Open(text));
        }
        public int OpenWrite(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return -VfsStatus.InvalidArgument(); }
            MarkMutation();
            return Place(mounts.OpenWrite(text));
        }
        public int Read(int descriptor, byte[] destination, int capacity) {
            if (descriptor < 3 || descriptor >= handles.Length || handles[descriptor] == null ||
                destination == null || capacity < 0 || capacity > destination.Length) {
                return -VfsStatus.InvalidArgument();
            }
            VfsFileHandle handle = handles[descriptor];
            if (!handle.IsOpen()) { return -VfsStatus.NotMounted(); }
            int count = capacity;
            if (handle.Remaining() < count) { count = (int)handle.Remaining(); }
            if (count == 0) { return 0; }
            byte[] bytes = new byte[count];
            int status = handle.Read(bytes);
            if (status != VfsStatus.Ok()) { return -status; }
            int i = 0;
            while (i < count) { destination[i] = bytes[i]; i = i + 1; }
            return count;
        }
        public int Write(int descriptor, byte[] source, int count, bool append) {
            if (descriptor < 3 || descriptor >= handles.Length || handles[descriptor] == null ||
                source == null || count < 0 || count > source.Length) {
                return VfsStatus.InvalidArgument();
            }
            byte[] bytes = new byte[count];
            int i = 0;
            while (i < count) { bytes[i] = source[i]; i = i + 1; }
            MarkMutation();
            if (append) { return handles[descriptor].Append(bytes); }
            return handles[descriptor].Replace(bytes);
        }
        public int Truncate(int descriptor, long length) {
            if (descriptor < 3 || descriptor >= handles.Length || handles[descriptor] == null) {
                return VfsStatus.InvalidArgument();
            }
            MarkMutation();
            return handles[descriptor].Truncate(length);
        }
        public int Create(byte[] path, int count, byte[] contents) {
            string text = Path(path, count);
            if (mounts == null || text == null || contents == null) {
                return VfsStatus.InvalidArgument();
            }
            MarkMutation();
            return mounts.CreateFile(text, contents);
        }
        public int Delete(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return VfsStatus.InvalidArgument(); }
            MarkMutation();
            return mounts.DeleteFile(text);
        }
        public int Mkdir(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return VfsStatus.InvalidArgument(); }
            MarkMutation();
            return mounts.Mkdir(text);
        }
        public int Rmdir(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return VfsStatus.InvalidArgument(); }
            MarkMutation();
            return mounts.Rmdir(text);
        }
        public int Rename(byte[] source, int sourceCount, byte[] destination,
            int destinationCount) {
            string first = Path(source, sourceCount);
            string second = Path(destination, destinationCount);
            if (mounts == null || first == null || second == null) {
                return VfsStatus.InvalidArgument();
            }
            MarkMutation();
            return mounts.Rename(first, second);
        }
        public UserFileInfo Stat(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) {
                return new UserFileInfo(VfsStatus.InvalidArgument(), 0, 0, 0, 0, 0, 0, 0);
            }
            VfsFileInfo info = mounts.Stat(text);
            int flags = 0;
            if (info.HasCreationTime()) { flags = flags + 1; }
            if (info.HasModificationTime()) { flags = flags + 2; }
            return new UserFileInfo(info.Status(), info.Kind(), info.ByteLength(),
                info.ObjectId(), info.CreatedUnixSeconds(), info.ModifiedUnixSeconds(),
                flags, info.Attributes());
        }
        public UserDirectoryInfo DirectoryCount(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) {
                return new UserDirectoryInfo(VfsStatus.InvalidArgument(), 0);
            }
            VfsDirectoryResult info = mounts.DirectoryInfo(text);
            return new UserDirectoryInfo(info.Status(), info.Count());
        }
        public int DirectoryName(byte[] path, int count, int index, byte[] destination) {
            string text = Path(path, count);
            if (mounts == null || text == null || destination == null) {
                return -VfsStatus.InvalidArgument();
            }
            return mounts.ReadDirectoryName(text, index, destination);
        }
        public bool Close(int descriptor) {
            if (descriptor < 3 || descriptor >= handles.Length || handles[descriptor] == null) {
                return false;
            }
            handles[descriptor].Close(); handles[descriptor] = null; return true;
        }
        public void CloseAll() {
            int descriptor = 3;
            while (descriptor < handles.Length) {
                if (handles[descriptor] != null) {
                    handles[descriptor].Close(); handles[descriptor] = null;
                }
                descriptor = descriptor + 1;
            }
        }
        public int ActiveCount() {
            int count = 0; int descriptor = 3;
            while (descriptor < handles.Length) {
                if (handles[descriptor] != null) { count = count + 1; }
                descriptor = descriptor + 1;
            }
            return count;
        }
    }

    public class NativeUserProgramHost : IUserChildLauncher {
        private VfsNamespace mounts;
        private IUserTerminal terminal;
        private UserProgramHost host;
        private NativeUserFiles files;
        private long bootInfo;
        private int[] systemInformation;
        private int activeChildDepth;
        private int[] activePids;
        private UserProcessTable processTable;
        private UserChannelTable channels;
        private UserCapabilityPolicy capabilityPolicy;
        private NativeUserRuntime nativeRuntime;
        private int shellPid;
        private int mutationSequence;
        private int commandMutation;
        private bool commandMarked;
        private long commandPhysicalNext;
        private long commandPhysicalLast;
        private long commandHeapNext;
        private long commandHeapEnd;
        private long commandFreeHead;
        private long commandFreeCount;
        private long commandMappingBase;
        public NativeUserProgramHost(VfsNamespace inputMounts, IUserTerminal inputTerminal) {
            Initialize(inputMounts, inputTerminal, 0, null);
        }
        public NativeUserProgramHost(VfsNamespace inputMounts, IUserTerminal inputTerminal,
            long bootInfo) {
            Initialize(inputMounts, inputTerminal, bootInfo, null);
        }
        public NativeUserProgramHost(VfsNamespace inputMounts, IUserTerminal inputTerminal,
            long bootInfo, NativeUserRuntime inputNativeRuntime) {
            Initialize(inputMounts, inputTerminal, bootInfo, inputNativeRuntime);
        }
        private void Initialize(VfsNamespace inputMounts, IUserTerminal inputTerminal,
            long inputBootInfo, NativeUserRuntime inputNativeRuntime) {
            mounts = inputMounts; terminal = inputTerminal;
            bootInfo = inputBootInfo; systemInformation = new int[55];
            nativeRuntime = inputNativeRuntime;
            files = new NativeUserFiles(mounts, this);
            activeChildDepth = 0;
            activePids = new int[9]; processTable = new UserProcessTable();
            channels = new UserChannelTable(processTable);
            capabilityPolicy = LoadCapabilityPolicy();
            shellPid = 0; mutationSequence = 0; commandMarked = false;
            host = new UserProgramHost(terminal, files, systemInformation, this, 1);
        }
        public void RecordMutation() {
            if (mutationSequence < 2147483647) { mutationSequence = mutationSequence + 1; }
            else { mutationSequence = 1; }
        }
        // The prompt's next read is the first point where the preceding
        // command's managed objects are no longer reachable by the shell.
        public void BeforeTerminalInput(int processId) {
            if (processId != shellPid || shellPid == 0 || !commandMarked ||
                bootInfo < 4096) { return; }
            commandMarked = false;
            if (mutationSequence != commandMutation || files.ActiveCount() != 0 ||
                System.Kernel.Memory.Read64(bootInfo + 1184) != commandFreeHead ||
                System.Kernel.Memory.Read64(bootInfo + 1192) != commandFreeCount ||
                System.Kernel.Memory.Read64(bootInfo + 1216) != commandMappingBase ||
                System.Kernel.Memory.Read64(bootInfo + 88) != commandHeapNext ||
                System.Kernel.Memory.Read64(bootInfo + 96) != commandHeapEnd) {
                System.Kernel.Memory.Write64(bootInfo + 1208, 0);
                return;
            }
            if (PhysicalPages.RewindTransient(bootInfo, commandPhysicalNext)) {
                System.Kernel.Memory.Write64(bootInfo + 72, commandPhysicalLast);
            } else {
                System.Kernel.Memory.Write64(bootInfo + 1208, 0);
            }
        }
        public void AfterTerminalInput(int processId) {
            if (shellPid == 0 || bootInfo < 4096) { return; }
            if (processId != shellPid) {
                // An editor or another child may retain terminal state, so
                // its parent command cannot be rolled back as read-only.
                if (commandMarked) { RecordMutation(); }
                return;
            }
            commandPhysicalNext = PhysicalPages.MarkTransient(bootInfo);
            commandPhysicalLast = System.Kernel.Memory.Read64(bootInfo + 72);
            commandHeapNext = System.Kernel.Memory.Read64(bootInfo + 88);
            commandHeapEnd = System.Kernel.Memory.Read64(bootInfo + 96);
            commandFreeHead = System.Kernel.Memory.Read64(bootInfo + 1184);
            commandFreeCount = System.Kernel.Memory.Read64(bootInfo + 1192);
            commandMappingBase = System.Kernel.Memory.Read64(bootInfo + 1216);
            commandMutation = mutationSequence;
            commandMarked = commandPhysicalNext != 0;
        }
        private int Count(long value) {
            if (value < 0) { return 0; }
            if (value > 2147483647) { return 2147483647; }
            return (int)value;
        }
        private void RefreshSystemInformation() {
            if (bootInfo < 4096) { return; }
            systemInformation[16] = System.Kernel.Memory.Read32(bootInfo + 4);
            systemInformation[17] = System.Kernel.Memory.Read32(bootInfo + 3472);
            systemInformation[18] = System.Kernel.Memory.Read32(bootInfo + 36);
            systemInformation[19] = System.Kernel.Memory.Read32(bootInfo + 200);
            systemInformation[20] = System.Kernel.Memory.Read32(bootInfo + 192);
            systemInformation[21] = System.Kernel.Memory.Read32(bootInfo + 304);
            systemInformation[22] = System.Kernel.Memory.Read32(bootInfo + 1072);
            systemInformation[23] = System.Kernel.Memory.Read32(bootInfo + 128);
            systemInformation[24] = System.Kernel.Memory.Read32(bootInfo + 132);
            systemInformation[25] = System.Kernel.Memory.Read32(bootInfo + 2352);
            systemInformation[32] = 4096;
            long next = System.Kernel.Memory.Read64(bootInfo + 40);
            long limit = System.Kernel.Memory.Read64(bootInfo + 48);
            long fresh = 0;
            if (limit > next) { fresh = (limit - next) / 4096; }
            long recycled = System.Kernel.Memory.Read64(bootInfo + 1192);
            systemInformation[33] = Count(fresh);
            systemInformation[34] = Count(recycled);
            systemInformation[35] = Count(fresh + recycled);
            long heapBase = System.Kernel.Memory.Read64(bootInfo + 80);
            long heapNext = System.Kernel.Memory.Read64(bootInfo + 88);
            long heapEnd = System.Kernel.Memory.Read64(bootInfo + 96);
            long committed = 0;
            if (heapEnd > heapBase) { committed = (heapEnd - heapBase) / 4096; }
            systemInformation[36] = Count(committed);
            long used = 0;
            if (heapNext > heapBase) { used = heapNext - heapBase; }
            systemInformation[37] = Count(used);
            systemInformation[38] = System.Kernel.Memory.Read32(bootInfo + 1160);
            systemInformation[39] = System.Kernel.Memory.Read32(bootInfo + 1164);
            systemInformation[40] = 0;
            systemInformation[41] = System.Kernel.Memory.Read32(bootInfo + 3464);
            systemInformation[42] = System.Kernel.Memory.Read32(bootInfo + 2576);
            systemInformation[43] = System.Kernel.Memory.Read32(bootInfo + 2580);
            systemInformation[44] = System.Kernel.Memory.Read32(bootInfo + 2584);
            systemInformation[45] = System.Kernel.Memory.Read32(bootInfo + 2588);
            systemInformation[48] = System.Kernel.Memory.Read32(bootInfo + 1140);
            systemInformation[49] = System.Kernel.Memory.Read32(bootInfo + 1232);
            systemInformation[50] = System.Kernel.Memory.Read32(bootInfo + 1244);
            systemInformation[51] = System.Kernel.Memory.Read32(bootInfo + 2384);
            systemInformation[52] = System.Kernel.Memory.Read32(bootInfo + 2472);
            systemInformation[53] = System.Kernel.Memory.Read32(bootInfo + 2356);
            systemInformation[54] = System.Kernel.Memory.Read32(bootInfo + 2388);
        }
        public int ActiveDescriptors() { return files.ActiveCount(); }
        public UserProcessTable Processes() { return processTable; }
        public UserChannelTable Channels() { return channels; }
        public int RunChild(byte[] path, UserArguments arguments) {
            byte[] root = new byte[1]; root[0] = 47;
            return RunChildWithContext(activePids[activeChildDepth], path, arguments,
                new UserArguments(new byte[0], new int[0], new int[0], 0), root);
        }
        public int RunChildWithContext(int parentPid, byte[] path, UserArguments arguments,
            UserArguments environment, byte[] workingDirectory) {
            if (parentPid < 1 || path == null || path.Length < 1 || path.Length > 255 ||
                path[0] != 47 || activeChildDepth >= 8 ||
                host.NextPid() >= 2147483647 || arguments == null ||
                !arguments.IsValid() || environment == null ||
                !environment.IsValid()) { return -4; }
            UserProcessStart start = new UserProcessStart(arguments, environment,
                workingDirectory, 0, 1, 2);
            if (!start.IsValid()) { return -4; }
            string name = System.Kernel.String.FromBytes(path, path.Length);
            VfsFileInfo info = mounts.Stat(name);
            if (info.Status() == VfsStatus.NotFound()) { return -1; }
            if (info.Status() != VfsStatus.Ok()) { return -4; }
            if (info.Kind() != 1) { return -3; }
            byte[] nativeCode = LoadNative(name);
            if (nativeCode != null) {
                byte[] nativeStart = start.BuildNativeRecord();
                if (nativeRuntime == null || !nativeRuntime.IsReady() ||
                    nativeStart == null) {
                    return -4;
                }
                int nativePid = host.ReservePid();
                if (nativePid < 1 || !processTable.Start(nativePid, parentPid,
                    capabilityPolicy.Grant(name))) { return -4; }
                NativeUserResult completed = nativeRuntime.RunImage(nativeCode,
                    nativeStart, nativePid);
                int state = UserProgramState.Faulted();
                int fault = UserFault.InvalidImage();
                if (completed.Status() == 0) {
                    state = UserProgramState.Exited(); fault = UserFault.None();
                } else if (completed.Status() == -14) {
                    fault = UserFault.MemoryAccess();
                } else if (completed.Status() == -13) {
                    fault = UserFault.InvalidInstruction();
                }
                processTable.Finish(new UserProgramResult(nativePid, state,
                    completed.ExitCode(), fault, 0));
                channels.CloseForProcess(nativePid);
                if (state == UserProgramState.Exited()) { return completed.ExitCode(); }
                return -100 - fault;
            }
            UserExecutable executable = Load(name);
            if (executable == null) { return -2; }
            int[] childInformation = new int[systemInformation.Length];
            int index = 0;
            while (index < childInformation.Length) {
                childInformation[index] = systemInformation[index];
                index = index + 1;
            }
            NativeUserFiles childFiles = new NativeUserFiles(mounts, this);
            int childPid = host.NextPid();
            if (!processTable.Start(childPid, parentPid,
                capabilityPolicy.Grant(name))) { return -4; }
            int spawned = host.SpawnRunnable(executable, start, childFiles,
                childInformation);
            if (spawned != childPid || !host.Block(parentPid)) {
                if (spawned == childPid) { host.Wait(childPid); }
                processTable.Finish(new UserProgramResult(childPid,
                    UserProgramState.Faulted(), -1, UserFault.InvalidImage(), 0));
                return -4;
            }
            processTable.WaitForChild(parentPid, childPid);
            activeChildDepth = activeChildDepth + 1;
            activePids[activeChildDepth] = childPid;
            bool enteredShell = false;
            if (shellPid == 0 && name == "/System/Core/CommandShell.exec") {
                shellPid = childPid; enteredShell = true;
            }
            UserProgramResult result = host.Wait(childPid);
            channels.CloseForProcess(childPid);
            processTable.Finish(result);
            if (enteredShell) {
                shellPid = 0; commandMarked = false;
                if (bootInfo >= 4096) { System.Kernel.Memory.Write64(bootInfo + 1208, 0); }
            }
            activePids[activeChildDepth] = 0;
            activeChildDepth = activeChildDepth - 1;
            host.Unblock(parentPid);
            processTable.Resume(parentPid);
            if (result.State() == UserProgramState.Exited()) {
                return result.ExitCode();
            }
            return -100 - result.Fault();
        }
        public int SpawnChildWithContext(int parentPid, byte[] path,
            UserArguments arguments, UserArguments environment,
            byte[] workingDirectory) {
            if (parentPid < 1 || path == null || path.Length < 1 ||
                path.Length > 255 || path[0] != 47 ||
                host.NextPid() >= 2147483647 || arguments == null ||
                !arguments.IsValid() || environment == null ||
                !environment.IsValid()) { return -4; }
            UserProcessStart start = new UserProcessStart(arguments, environment,
                workingDirectory, 0, 1, 2);
            if (!start.IsValid()) { return -4; }
            string name = System.Kernel.String.FromBytes(path, path.Length);
            VfsFileInfo info = mounts.Stat(name);
            if (info.Status() == VfsStatus.NotFound()) { return -1; }
            if (info.Status() != VfsStatus.Ok()) { return -4; }
            if (info.Kind() != 1) { return -3; }
            UserExecutable executable = Load(name);
            if (executable == null) { return -2; }
            int[] childInformation = new int[systemInformation.Length];
            int index = 0;
            while (index < childInformation.Length) {
                childInformation[index] = systemInformation[index];
                index = index + 1;
            }
            int childPid = host.NextPid();
            if (!processTable.Start(childPid, parentPid,
                capabilityPolicy.Grant(name))) { return -4; }
            NativeUserFiles childFiles = new NativeUserFiles(mounts, this);
            int spawned = host.SpawnRunnable(executable, start, childFiles,
                childInformation);
            if (spawned != childPid) {
                processTable.Finish(new UserProgramResult(childPid,
                    UserProgramState.Faulted(), -1, UserFault.InvalidImage(), 0));
                return -4;
            }
            if (shellPid == 0 && name == "/System/Core/CommandShell.exec") {
                shellPid = childPid;
            }
            return childPid;
        }
        public int WaitChild(int parentPid, int childPid) {
            UserProcessRecord child = processTable.Find(childPid);
            if (child == null || child.ParentPid() != parentPid ||
                !processTable.WaitForChild(parentPid, childPid) ||
                !host.Block(parentPid)) { return -4; }
            UserProgramResult result = host.Wait(childPid);
            host.Unblock(parentPid);
            processTable.Resume(parentPid);
            if (result.State() == UserProgramState.Exited()) {
                return result.ExitCode();
            }
            return -100 - result.Fault();
        }
        public int WaitReadyChild(int parentPid, int childPid, int maxRounds) {
            UserProcessRecord child = processTable.Find(childPid);
            if (child == null || child.ParentPid() != parentPid ||
                maxRounds < 1 || maxRounds > 100000 ||
                !processTable.WaitForChild(parentPid, childPid) ||
                !host.Block(parentPid)) { return -4; }
            int result = host.WaitReady(childPid, maxRounds);
            host.Unblock(parentPid);
            processTable.Resume(parentPid);
            return result;
        }
        public int MarkReady(int processId) { return host.MarkReady(processId); }
        public int TerminateChild(int parentPid, int childPid) {
            UserProcessRecord child = processTable.Find(childPid);
            if (child == null || child.ParentPid() != parentPid) { return -4; }
            return host.Terminate(childPid);
        }
        public int SleepProcess(int processId, int milliseconds) {
            return host.Sleep(processId, milliseconds);
        }
        public int ChannelOpen(int processId, int childPid, int version) {
            return channels.Open(processId, childPid, version);
        }
        public int ChannelAccept(int processId, int version) {
            return channels.Accept(processId, version);
        }
        public int ChannelSend(int processId, int handle, int version,
            byte[] source, int length) {
            return channels.Send(handle, processId, version, source, length);
        }
        public int ChannelReceive(int processId, int handle, byte[] destination) {
            return channels.Receive(handle, processId, destination);
        }
        public int ChannelWait(int processId, int handle, int maxRounds) {
            int queued = channels.QueuedFor(handle, processId);
            if (queued < 0) { return queued; }
            if (queued > 0) { return 0; }
            if (!host.Block(processId)) { return -4; }
            int rounds = 0;
            while (rounds < maxRounds) {
                host.RunRound();
                queued = channels.QueuedFor(handle, processId);
                if (queued != 0) { break; }
                rounds = rounds + 1;
            }
            host.Unblock(processId);
            if (queued < 0) { return queued; }
            if (queued > 0) { return 0; }
            return -2;
        }
        public int ChannelPeer(int processId, int handle) {
            return channels.Peer(handle, processId);
        }
        public int ChannelClose(int processId, int handle) {
            if (channels.Close(handle, processId)) { return 0; }
            return -2;
        }
        public long ClockNow() { return KernelClock.Now(); }
        public long ClockDeadlineAfter(int milliseconds) {
            if (bootInfo < 4096) { return 0; }
            return KernelClock.DeadlineAfter(bootInfo, milliseconds);
        }
        public void ProcessExited(UserProgramResult result) {
            if (result == null) { return; }
            if (result.Pid() == shellPid) {
                shellPid = 0; commandMarked = false;
                if (bootInfo >= 4096) { System.Kernel.Memory.Write64(bootInfo + 1208, 0); }
            }
            channels.CloseForProcess(result.Pid());
            processTable.Finish(result);
            int childPid = processTable.FirstChild(result.Pid());
            while (childPid > 0) {
                UserProcessRecord child = processTable.Find(childPid);
                if (child != null && (child.State() == UserProgramState.Running() ||
                    child.State() == 4)) { host.Terminate(childPid); }
                host.Wait(childPid);
                processTable.Clear(childPid);
                childPid = processTable.FirstChild(result.Pid());
            }
        }
        // AUN1 is an intentionally small native image. Only the read-only
        // system bin directory can supply it until native preemption lands.
        private byte[] LoadNative(string path) {
            string prefix = "/System/Bin/";
            if (mounts == null || path == null || path.Length <= prefix.Length) {
                return null;
            }
            int i = 0;
            while (i < prefix.Length) {
                if (System.Kernel.String.ByteAt(path, i) !=
                    System.Kernel.String.ByteAt(prefix, i)) { return null; }
                i = i + 1;
            }
            VfsFileInfo info = mounts.Stat(path);
            if (!info.Exists() || info.Kind() != 1 ||
                info.ByteLength() < 9 || info.ByteLength() > 4112) { return null; }
            VfsFileHandle handle = mounts.Open(path);
            if (handle == null || !handle.IsOpen()) { return null; }
            byte[] header = new byte[8];
            if (handle.Read(header) != VfsStatus.Ok()) {
                handle.Close(); return null;
            }
            if (header[0] != 65 || header[1] != 85 || header[2] != 78 ||
                header[3] != 49 || header[7] != 0 ||
                (header[6] != 0 && header[6] != 2)) {
                handle.Close(); return null;
            }
            int headerLength = 8;
            if (header[6] == 2) {
                byte[] extension = new byte[8];
                if (handle.Read(extension) != VfsStatus.Ok()) {
                    handle.Close(); return null;
                }
                int reserved = 0;
                while (reserved < extension.Length) {
                    if (extension[reserved] != 0) { handle.Close(); return null; }
                    reserved = reserved + 1;
                }
                headerLength = 16;
            }
            int length = header[4] + header[5] * 256;
            if (length < 1 || length > 4096 || info.ByteLength() != length + headerLength) {
                handle.Close(); return null;
            }
            byte[] code = new byte[length];
            int status = handle.Read(code);
            handle.Close();
            if (status != VfsStatus.Ok()) { return null; }
            return code;
        }
        private UserExecutable Load(string path) {
            if (mounts == null || path == null) { return null; }
            VfsFileInfo info = mounts.Stat(path);
            if (!info.Exists() || info.ByteLength() < 32 || info.ByteLength() > 131104) { return null; }
            VfsFileHandle handle = mounts.Open(path);
            if (handle == null || !handle.IsOpen()) { return null; }
            byte[] image = new byte[(int)info.ByteLength()];
            if (handle.Read(image) != VfsStatus.Ok()) { handle.Close(); return null; }
            handle.Close();
            UserExecutable executable = new UserExecutable(image);
            if (!executable.IsValid()) { return null; }
            return executable;
        }
        private UserCapabilityPolicy LoadCapabilityPolicy() {
            string path = "/System/Config/capabilities.manifest";
            if (mounts == null) { return new UserCapabilityPolicy(new byte[0]); }
            VfsFileInfo info = mounts.Stat(path);
            if (!info.Exists() || info.Kind() != 1 || info.ByteLength() < 10 ||
                info.ByteLength() > 4096) {
                return new UserCapabilityPolicy(new byte[0]);
            }
            VfsFileHandle handle = mounts.Open(path);
            if (handle == null || !handle.IsOpen()) {
                return new UserCapabilityPolicy(new byte[0]);
            }
            byte[] image = new byte[(int)info.ByteLength()];
            int status = handle.Read(image);
            handle.Close();
            if (status != VfsStatus.Ok()) {
                return new UserCapabilityPolicy(new byte[0]);
            }
            return new UserCapabilityPolicy(image);
        }
        public UserProgramResult Run(string path) {
            return Run(path, new UserArguments(new byte[0], new int[0],
                new int[0], 0));
        }
        public UserProgramResult Run(string path, UserArguments arguments) {
            UserExecutable executable = Load(path);
            if (executable == null) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            RefreshSystemInformation();
            bool enteredShell = false;
            if (shellPid == 0 && path == "/System/Core/CommandShell.exec") {
                shellPid = host.NextPid(); enteredShell = true;
            }
            int pid = host.NextPid();
            if (!processTable.Start(pid, 0, capabilityPolicy.Grant(path))) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            activePids[0] = pid;
            UserProgramResult result = null;
            if (path == "/System/Core/System.exec" && nativeRuntime != null) {
                int started = host.SpawnForeground(executable,
                    new UserProcessStart(arguments));
                if (started != pid) {
                    processTable.Clear(pid); activePids[0] = 0;
                    return new UserProgramResult(UserProgramState.Faulted(), -1,
                        UserFault.InvalidImage(), 0);
                }
                int cleanPid = host.ReservePid();
                int faultPid = host.ReservePid();
                int privilegePid = host.ReservePid();
                bool isolated = nativeRuntime.IsReady() &&
                    nativeRuntime.Probe(processTable, pid, cleanPid,
                        faultPid, privilegePid);
                string marker = "native-user: isolation passed\n";
                if (!isolated) { marker = "native-user: isolation failed\n"; }
                int i = 0;
                while (i < marker.Length) {
                    terminal.WriteByte(System.Kernel.String.ByteAt(marker, i));
                    i = i + 1;
                }
                if (!isolated) {
                    terminal.WriteByte(48 + nativeRuntime.FailureCode());
                    terminal.WriteByte(48 + nativeRuntime.LastRunStep());
                    int diagnostic = nativeRuntime.LastStatus();
                    if (diagnostic < 0) {
                        terminal.WriteByte(45); diagnostic = -diagnostic;
                    }
                    if (diagnostic >= 100) { terminal.WriteByte(48 + diagnostic / 100); }
                    if (diagnostic >= 10) {
                        terminal.WriteByte(48 + (diagnostic / 10) % 10);
                    }
                    terminal.WriteByte(48 + diagnostic % 10);
                    terminal.WriteByte(10);
                }
                if (!isolated) {
                    UserProgramResult failed = new UserProgramResult(
                        UserProgramState.Faulted(), -1, UserFault.InvalidImage(), 0);
                    host.Terminate(pid); host.Wait(pid);
                    processTable.Clear(pid); activePids[0] = 0;
                    return failed;
                }
                result = host.Wait(pid);
            } else {
                result = host.Run(executable, arguments);
            }
            channels.CloseForProcess(pid);
            processTable.Finish(result);
            activePids[0] = 0;
            if (enteredShell) {
                shellPid = 0; commandMarked = false;
                if (bootInfo >= 4096) { System.Kernel.Memory.Write64(bootInfo + 1208, 0); }
            }
            return result;
        }
    }
}
