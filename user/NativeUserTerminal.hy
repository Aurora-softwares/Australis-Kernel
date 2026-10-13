using Australis.Kernel.Console;
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
            while (input.IsReady()) {
                int value = events.Poll();
                if (value >= 0 && value <= 255) { return value; }
                if (value == ConsoleKey.InputLost()) { return -1; }
                if (usb != null) { usb.Pump(); }
                decoder.Pump();
                value = events.Poll();
                if (value >= 0 && value <= 255) { return value; }
                if (value == ConsoleKey.InputLost()) { return -1; }
                if (input.CanHalt()) { System.Kernel.Cpu.Halt(); }
                else { System.Kernel.Cpu.Pause(); }
            }
            return -1;
        }

        public bool WriteByte(int value) {
            return output != null && output.WriteByte(value);
        }
    }

    public class NativeUserFiles : IUserFiles {
        private VfsNamespace mounts;
        private VfsFileHandle[] handles;
        public NativeUserFiles(VfsNamespace inputMounts) {
            mounts = inputMounts; handles = new VfsFileHandle[16];
        }
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
            if (append) { return handles[descriptor].Append(bytes); }
            return handles[descriptor].Replace(bytes);
        }
        public int Truncate(int descriptor, long length) {
            if (descriptor < 3 || descriptor >= handles.Length || handles[descriptor] == null) {
                return VfsStatus.InvalidArgument();
            }
            return handles[descriptor].Truncate(length);
        }
        public int Create(byte[] path, int count, byte[] contents) {
            string text = Path(path, count);
            if (mounts == null || text == null || contents == null) {
                return VfsStatus.InvalidArgument();
            }
            return mounts.CreateFile(text, contents);
        }
        public int Delete(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return VfsStatus.InvalidArgument(); }
            return mounts.DeleteFile(text);
        }
        public int Mkdir(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return VfsStatus.InvalidArgument(); }
            return mounts.Mkdir(text);
        }
        public int Rmdir(byte[] path, int count) {
            string text = Path(path, count);
            if (mounts == null || text == null) { return VfsStatus.InvalidArgument(); }
            return mounts.Rmdir(text);
        }
        public int Rename(byte[] source, int sourceCount, byte[] destination,
            int destinationCount) {
            string first = Path(source, sourceCount);
            string second = Path(destination, destinationCount);
            if (mounts == null || first == null || second == null) {
                return VfsStatus.InvalidArgument();
            }
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
        private int nextChildPid;
        private int activeChildDepth;
        public NativeUserProgramHost(VfsNamespace inputMounts, IUserTerminal inputTerminal) {
            Initialize(inputMounts, inputTerminal, 0);
        }
        public NativeUserProgramHost(VfsNamespace inputMounts, IUserTerminal inputTerminal,
            long bootInfo) {
            Initialize(inputMounts, inputTerminal, bootInfo);
        }
        private void Initialize(VfsNamespace inputMounts, IUserTerminal inputTerminal,
            long inputBootInfo) {
            mounts = inputMounts; terminal = inputTerminal;
            bootInfo = inputBootInfo; systemInformation = new int[55];
            files = new NativeUserFiles(mounts);
            nextChildPid = 2; activeChildDepth = 0;
            host = new UserProgramHost(terminal, files, systemInformation, this, 1);
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
        public int RunChild(byte[] path) {
            if (path == null || path.Length < 1 || path.Length > 255 ||
                path[0] != 47 || activeChildDepth >= 8 ||
                nextChildPid >= 2147483647) { return -1; }
            string name = System.Kernel.String.FromBytes(path, path.Length);
            UserExecutable executable = Load(name);
            if (executable == null) { return -1; }
            int[] childInformation = new int[systemInformation.Length];
            int index = 0;
            while (index < childInformation.Length) {
                childInformation[index] = systemInformation[index];
                index = index + 1;
            }
            NativeUserFiles childFiles = new NativeUserFiles(mounts);
            int childPid = nextChildPid;
            nextChildPid = nextChildPid + 1;
            activeChildDepth = activeChildDepth + 1;
            UserProgramResult result = new UserProgramHost(terminal, childFiles,
                childInformation, this, childPid).Run(executable);
            activeChildDepth = activeChildDepth - 1;
            if (result.State() == UserProgramState.Exited()) {
                return result.ExitCode();
            }
            return -100 - result.Fault();
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
            if (nextChildPid <= host.NextPid()) {
                nextChildPid = host.NextPid() + 1;
            }
            return host.Run(executable, arguments);
        }
    }
}
