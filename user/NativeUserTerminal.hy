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
    }

    public class NativeUserProgramHost {
        private VfsNamespace mounts;
        private IUserTerminal terminal;
        public NativeUserProgramHost(VfsNamespace inputMounts, IUserTerminal inputTerminal) {
            mounts = inputMounts; terminal = inputTerminal;
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
            UserExecutable executable = Load(path);
            if (executable == null) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            NativeUserFiles files = new NativeUserFiles(mounts);
            return new UserProgramHost(terminal, files).Run(executable);
        }
    }
}
