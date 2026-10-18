using Australis.Kernel.Storage;

namespace Australis.User {
    // Terminal syscalls use this byte contract on both the hosted tests and
    // the live kernel. ReadByte returns -3 while input is pending and -1 on
    // end of input. It runs only in scheduler context; IRQ handlers enqueue.
    public interface IUserTerminal {
        int ReadByte();
        bool WriteByte(int value);
    }

    // A foreground child runs with its own address space and descriptors.
    // Negative results describe launch or process faults; nonnegative values
    // are the child's exit status.
    public interface IUserChildLauncher {
        int RunChild(byte[] path, UserArguments arguments);
        int RunChildWithContext(int parentPid, byte[] path, UserArguments arguments,
            UserArguments environment, byte[] workingDirectory);
        int SpawnChildWithContext(int parentPid, byte[] path,
            UserArguments arguments, UserArguments environment,
            byte[] workingDirectory);
        int WaitChild(int parentPid, int childPid);
        int WaitReadyChild(int parentPid, int childPid, int maxRounds);
        int TerminateChild(int parentPid, int childPid);
        int SleepProcess(int processId, int milliseconds);
        int ChannelOpen(int processId, int childPid, int version);
        int ChannelAccept(int processId, int version);
        int ChannelSend(int processId, int handle, int version,
            byte[] source, int length);
        int ChannelReceive(int processId, int handle, byte[] destination);
        int ChannelWait(int processId, int handle, int maxRounds);
        int ChannelPeer(int processId, int handle);
        int ChannelClose(int processId, int handle);
        long ClockNow();
        long ClockDeadlineAfter(int milliseconds);
        int MarkReady(int processId);
        int RunNativeRound();
        void ProcessExited(UserProgramResult result);
        void BeforeTerminalInput(int processId);
        void AfterTerminalInput(int processId);
    }

    // Descriptors 0, 1, and 2 are owned by UserSystemCalls. Filesystem
    // implementations provide checked read and write descriptors from 3.
    public interface IUserFiles {
        int Open(byte[] path, int count);
        int Read(int descriptor, byte[] destination, int capacity);
        int OpenWrite(byte[] path, int count);
        int Write(int descriptor, byte[] source, int count, bool append);
        int Truncate(int descriptor, long length);
        int Create(byte[] path, int count, byte[] contents);
        int Delete(byte[] path, int count);
        int Mkdir(byte[] path, int count);
        int Rmdir(byte[] path, int count);
        int Rename(byte[] source, int sourceCount, byte[] destination, int destinationCount);
        UserFileInfo Stat(byte[] path, int count);
        UserDirectoryInfo DirectoryCount(byte[] path, int count);
        int DirectoryName(byte[] path, int count, int index, byte[] destination);
        bool Close(int descriptor);
        void CloseAll();
    }

    public class UserFileInfo {
        private int status;
        private int kind;
        private long length;
        private long objectId;
        private long created;
        private long modified;
        private int timeFlags;
        private long attributes;
        public UserFileInfo(int inputStatus, int inputKind, long inputLength,
            long inputId, long inputCreated, long inputModified,
            int inputFlags, long inputAttributes) {
            status = inputStatus; kind = inputKind; length = inputLength;
            objectId = inputId; created = inputCreated; modified = inputModified;
            timeFlags = inputFlags; attributes = inputAttributes;
        }
        public int Status() { return status; }
        public int Kind() { return kind; }
        public long Length() { return length; }
        public long ObjectId() { return objectId; }
        public long Created() { return created; }
        public long Modified() { return modified; }
        public int TimeFlags() { return timeFlags; }
        public long Attributes() { return attributes; }
    }

    public class UserDirectoryInfo {
        private int status;
        private int count;
        public UserDirectoryInfo(int inputStatus, int inputCount) {
            status = inputStatus; count = inputCount;
        }
        public int Status() { return status; }
        public int Count() { return count; }
    }

    public class UserFileStatus {
        public static int Ok() { return 0; }
        public static int InvalidArgument() { return 1; }
        public static int NotFound() { return 4; }
        public static int EndOfFile() { return 5; }
        public static int IoFailure() { return 6; }
        public static int Corrupt() { return 7; }
    }

    // Stable result states for new user APIs. Existing VFS status values are
    // retained where they already match the user file API.
    public class UserSyscallStatus {
        public static int Success() { return 0; }
        public static int InvalidArgument() { return 1; }
        public static int NotFound() { return 4; }
        public static int EndOfFile() { return 5; }
        public static int IoError() { return 6; }
        public static int Permission() { return 8; }
        public static int Retry() { return 14; }
    }

    public class UserSyscallResult {
        private int status;
        private long value;
        public UserSyscallResult(int inputStatus, long inputValue) {
            status = inputStatus; value = inputValue;
        }
        public int Status() { return status; }
        public long Value() { return value; }
    }

    public class UserProgramState {
        public static int Running() { return 1; }
        public static int Exited() { return 2; }
        public static int Faulted() { return 3; }
    }

    public class UserFault {
        public static int None() { return 0; }
        public static int InvalidImage() { return 1; }
        public static int InvalidInstruction() { return 2; }
        public static int MemoryAccess() { return 3; }
        public static int SystemCall() { return 4; }
        public static int InstructionLimit() { return 5; }
        public static int Arithmetic() { return 6; }
        public static int Terminated() { return 7; }
    }

    // AUEX v1 is a compact, deterministic bytecode image. It intentionally
    // has no instruction that can address physical memory. Code is read-only,
    // data is a separate bounded region, and every syscall copies through the
    // checked UserAddressSpace API.
    public class UserExecutable {
        private bool valid;
        private int status;
        private byte[] code;
        private byte[] initialData;
        private int dataCapacity;
        private int entry;

        public UserExecutable(byte[] image) {
            valid = false; status = UserFault.InvalidImage();
            code = new byte[0]; initialData = new byte[0]; dataCapacity = 0; entry = 0;
            if (image == null || image.Length < 32 || image[0] != 65 || image[1] != 85 ||
                image[2] != 69 || image[3] != 88 || image[4] != 1 || image[5] != 32 ||
                image[6] != 0 || image[7] != 0) { return; }
            long codeLengthLong = PartitionBytes.Read32(image, 8);
            long dataLengthLong = PartitionBytes.Read32(image, 12);
            long capacityLong = PartitionBytes.Read32(image, 16);
            long entryLong = PartitionBytes.Read32(image, 20);
            if (codeLengthLong < 1 || codeLengthLong > 65536 || dataLengthLong < 0 ||
                dataLengthLong > 65536 || capacityLong < dataLengthLong || capacityLong > 65536 ||
                entryLong < 0 || entryLong >= codeLengthLong ||
                codeLengthLong + dataLengthLong != image.Length - 32) { return; }
            int codeLength = (int)codeLengthLong;
            int dataLength = (int)dataLengthLong;
            if (PartitionBytes.Crc32(image, 32, codeLength, codeLength, 0) !=
                    PartitionBytes.Read32(image, 24) ||
                PartitionBytes.Crc32(image, 32 + codeLength, dataLength, dataLength, 0) !=
                    PartitionBytes.Read32(image, 28)) { return; }
            code = new byte[codeLength];
            initialData = new byte[dataLength];
            int i = 0;
            while (i < codeLength) { code[i] = image[32 + i]; i = i + 1; }
            i = 0;
            while (i < dataLength) { initialData[i] = image[32 + codeLength + i]; i = i + 1; }
            dataCapacity = (int)capacityLong;
            entry = (int)entryLong;
            valid = true; status = UserFault.None();
        }

        public bool IsValid() { return valid; }
        public int Status() { return status; }
        public byte[] Code() { return code; }
        public byte[] InitialData() { return initialData; }
        public int DataCapacity() { return dataCapacity; }
        public int Entry() { return entry; }
    }

    public class UserAddressSpace {
        private byte[] code;
        private byte[] data;
        private byte[] startRecord;
        private int startLength;

        public static long CodeBase() { return 4194304; }
        public static long DataBase() { return 5242880; }
        public static long StartBase() { return 6291456; }

        public UserAddressSpace(UserExecutable executable) {
            code = new byte[executable.Code().Length];
            data = new byte[executable.DataCapacity()];
            startRecord = new byte[2048]; startLength = 0;
            int i = 0;
            while (i < code.Length) { code[i] = executable.Code()[i]; i = i + 1; }
            i = 0;
            while (i < executable.InitialData().Length) {
                data[i] = executable.InitialData()[i]; i = i + 1;
            }
        }

        public int CodeLength() { return code.Length; }
        public int DataLength() { return data.Length; }
        public int ReadCode(int offset) {
            if (offset < 0 || offset >= code.Length) { return -1; }
            return code[offset];
        }
        public bool CanRead(long address, int count) {
            if (count < 0) { return false; }
            if (address >= StartBase()) {
                long recordOffset = address - StartBase();
                return recordOffset <= startLength && count <= startLength - recordOffset;
            }
            if (address < DataBase()) { return false; }
            long offset = address - DataBase();
            return offset <= data.Length && count <= data.Length - offset;
        }
        public bool CanWrite(long address, int count) {
            if (count < 0 || address < DataBase() || address >= StartBase()) { return false; }
            long offset = address - DataBase();
            return offset <= data.Length && count <= data.Length - offset;
        }
        public bool InstallStartRecord(byte[] source, int count) {
            if (source == null || count < 40 || count > startRecord.Length ||
                count > source.Length || startLength != 0) { return false; }
            int i = 0;
            while (i < count) { startRecord[i] = source[i]; i = i + 1; }
            startLength = count; return true;
        }
        public int StartLength() { return startLength; }
        public int ReadByte(long address) {
            if (!CanRead(address, 1)) { return -1; }
            if (address >= StartBase()) {
                return startRecord[(int)(address - StartBase())];
            }
            return data[(int)(address - DataBase())];
        }
        public bool WriteByte(long address, int value) {
            if (value < 0 || value > 255 || !CanWrite(address, 1)) { return false; }
            data[(int)(address - DataBase())] = (byte)value;
            return true;
        }
        public bool CopyOut(long address, byte[] destination, int count) {
            if (destination == null || count < 0 || count > destination.Length ||
                !CanRead(address, count)) { return false; }
            int offset = (int)(address - DataBase());
            int i = 0;
            if (address >= StartBase()) {
                offset = (int)(address - StartBase());
                while (i < count) { destination[i] = startRecord[offset + i]; i = i + 1; }
            } else {
                while (i < count) { destination[i] = data[offset + i]; i = i + 1; }
            }
            return true;
        }
        public bool CopyIn(long address, byte[] source, int count) {
            if (source == null || count < 0 || count > source.Length ||
                !CanWrite(address, count)) { return false; }
            int offset = (int)(address - DataBase());
            int i = 0;
            while (i < count) { data[offset + i] = source[i]; i = i + 1; }
            return true;
        }
    }

    // Checked argument bytes are owned by the process for its entire run.
    // The VM sees bounded string handles rather than kernel pointers.
    public class UserArguments {
        private byte[] bytes;
        private int[] starts;
        private int[] lengths;
        private int count;
        private bool valid;
        private UserAddressSpace memory;
        private long[] addresses;

        public UserArguments(byte[] source, int[] offsets, int[] sizes, int number) {
            bytes = source; starts = offsets; lengths = sizes; count = number;
            memory = null; addresses = null;
            valid = source != null && offsets != null && sizes != null &&
                number >= 0 && number <= 16 && number <= offsets.Length &&
                number <= sizes.Length && source.Length <= 2048;
            if (!valid) { return; }
            int i = 0;
            while (i < number) {
                int start = offsets[i]; int size = sizes[i];
                if (start < 0 || size < 0 || size > 255 ||
                    start > source.Length || size > source.Length - start) {
                    valid = false; return;
                }
                int previous = 0;
                while (previous < i) {
                    if (size > 0 && sizes[previous] > 0 &&
                        start < offsets[previous] + sizes[previous] &&
                        offsets[previous] < start + size) {
                        valid = false; return;
                    }
                    previous = previous + 1;
                }
                int j = 0;
                while (j < size) {
                    if (source[start + j] == 0) { valid = false; return; }
                    j = j + 1;
                }
                i = i + 1;
            }
        }
        public UserArguments(UserAddressSpace inputMemory, long[] inputAddresses,
            int[] inputLengths, int number) {
            bytes = null; starts = null; memory = inputMemory;
            addresses = inputAddresses; lengths = inputLengths; count = number;
            valid = memory != null && addresses != null && lengths != null &&
                number >= 0 && number <= 16 && number <= addresses.Length &&
                number <= lengths.Length;
            if (!valid) { return; }
            int i = 0;
            while (i < number) {
                if (lengths[i] < 0 || lengths[i] > 255 ||
                    addresses[i] < UserAddressSpace.StartBase() ||
                    !memory.CanRead(addresses[i], lengths[i] + 1) ||
                    memory.ReadByte(addresses[i] + lengths[i]) != 0) {
                    valid = false; return;
                }
                int previous = 0;
                while (previous < i) {
                    if (addresses[i] < addresses[previous] + lengths[previous] + 1 &&
                        addresses[previous] < addresses[i] + lengths[i] + 1) {
                        valid = false; return;
                    }
                    previous = previous + 1;
                }
                int j = 0;
                while (j < lengths[i]) {
                    if (memory.ReadByte(addresses[i] + j) == 0) {
                        valid = false; return;
                    }
                    j = j + 1;
                }
                i = i + 1;
            }
        }
        public bool IsValid() { return valid; }
        public int Count() { return count; }
        public int Length(int index) {
            if (!valid || index < 0 || index >= count) { return -1; }
            return lengths[index];
        }
        public int ByteAt(int index, int offset) {
            if (!valid || index < 0 || index >= count || offset < 0 ||
                offset > lengths[index]) { return -1; }
            if (offset == lengths[index]) { return 0; }
            if (memory != null) { return memory.ReadByte(addresses[index] + offset); }
            return bytes[starts[index] + offset];
        }
    }

    // Version 1 start record lives in a read-only user region. All offsets in
    // its argument and environment tables are checked before the VM starts.
    public class UserProcessStart {
        private UserArguments arguments;
        private UserArguments environment;
        private byte[] workingDirectory;
        private int standardInput;
        private int standardOutput;
        private int standardError;
        private bool valid;

        public UserProcessStart(UserArguments inputArguments) {
            byte[] root = new byte[1]; root[0] = 47;
            Initialize(inputArguments,
                new UserArguments(new byte[0], new int[0], new int[0], 0),
                root, 0, 1, 2);
        }
        public UserProcessStart(UserArguments inputArguments,
            UserArguments inputEnvironment, byte[] inputDirectory,
            int stdin, int stdout, int stderr) {
            Initialize(inputArguments, inputEnvironment, inputDirectory,
                stdin, stdout, stderr);
        }
        private void Initialize(UserArguments inputArguments,
            UserArguments inputEnvironment, byte[] inputDirectory,
            int stdin, int stdout, int stderr) {
            arguments = inputArguments; environment = inputEnvironment;
            workingDirectory = inputDirectory;
            standardInput = stdin; standardOutput = stdout; standardError = stderr;
            valid = arguments != null && arguments.IsValid() &&
                environment != null && environment.IsValid() &&
                workingDirectory != null && workingDirectory.Length > 0 &&
                workingDirectory.Length <= 255 && workingDirectory[0] == 47 &&
                stdin == 0 && stdout == 1 && stderr == 2;
            if (!valid) { return; }
            int i = 0;
            while (i < workingDirectory.Length) {
                if (workingDirectory[i] == 0) { valid = false; return; }
                i = i + 1;
            }
        }
        public bool IsValid() { return valid; }
        public UserArguments Environment() { return environment; }
        public byte[] WorkingDirectory() { return workingDirectory; }
        public static int Version() { return 1; }
        private void Write32(byte[] record, int offset, long value) {
            int i = 0;
            while (i < 4) {
                record[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        // Native AUSP v2 keeps the v1 field layout but stores offsets from
        // RDI rather than 32-bit virtual addresses. Strings remain NUL ended.
        public byte[] BuildNativeRecord() {
            if (!valid) { return null; }
            byte[] record = new byte[2048];
            record[0] = 65; record[1] = 85; record[2] = 83; record[3] = 80;
            Write32(record, 4, 2);
            Write32(record, 12, arguments.Count());
            Write32(record, 16, environment.Count());
            Write32(record, 28, standardInput);
            Write32(record, 32, standardOutput);
            Write32(record, 36, standardError);
            int cursor = 320; int i = 0;
            while (i < arguments.Count()) {
                int length = arguments.Length(i);
                if (length < 0 || cursor + length + 1 > record.Length) { return null; }
                Write32(record, 64 + i * 8, cursor);
                Write32(record, 68 + i * 8, length);
                int j = 0;
                while (j < length) {
                    int value = arguments.ByteAt(i, j);
                    if (value < 1 || value > 255) { return null; }
                    record[cursor] = (byte)value; cursor = cursor + 1; j = j + 1;
                }
                cursor = cursor + 1; i = i + 1;
            }
            i = 0;
            while (i < environment.Count()) {
                int length = environment.Length(i);
                if (length < 0 || cursor + length + 1 > record.Length) { return null; }
                Write32(record, 192 + i * 8, cursor);
                Write32(record, 196 + i * 8, length);
                int j = 0;
                while (j < length) {
                    int value = environment.ByteAt(i, j);
                    if (value < 1 || value > 255) { return null; }
                    record[cursor] = (byte)value; cursor = cursor + 1; j = j + 1;
                }
                cursor = cursor + 1; i = i + 1;
            }
            if (cursor + workingDirectory.Length + 1 > record.Length) { return null; }
            Write32(record, 20, cursor);
            Write32(record, 24, workingDirectory.Length);
            i = 0;
            while (i < workingDirectory.Length) {
                record[cursor] = workingDirectory[i]; cursor = cursor + 1; i = i + 1;
            }
            cursor = cursor + 1;
            Write32(record, 8, cursor);
            byte[] result = new byte[cursor];
            i = 0;
            while (i < cursor) { result[i] = record[i]; i = i + 1; }
            return result;
        }
        public UserArguments CopyTo(UserAddressSpace memory) {
            if (!valid || memory == null) { return null; }
            byte[] record = new byte[2048];
            record[0] = 65; record[1] = 85; record[2] = 83; record[3] = 80;
            Write32(record, 4, Version());
            Write32(record, 12, arguments.Count());
            Write32(record, 16, environment.Count());
            Write32(record, 28, standardInput);
            Write32(record, 32, standardOutput);
            Write32(record, 36, standardError);
            long[] argumentAddresses = new long[arguments.Count()];
            int[] argumentLengths = new int[arguments.Count()];
            long[] environmentAddresses = new long[environment.Count()];
            int[] environmentLengths = new int[environment.Count()];
            int cursor = 320; int i = 0;
            while (i < arguments.Count()) {
                int length = arguments.Length(i);
                if (length < 0 || cursor + length + 1 > record.Length) { return null; }
                long address = UserAddressSpace.StartBase() + cursor;
                argumentAddresses[i] = address; argumentLengths[i] = length;
                Write32(record, 64 + i * 8, address);
                Write32(record, 68 + i * 8, length);
                int j = 0;
                while (j < length) {
                    int value = arguments.ByteAt(i, j);
                    if (value < 1 || value > 255) { return null; }
                    record[cursor] = (byte)value; cursor = cursor + 1; j = j + 1;
                }
                cursor = cursor + 1; i = i + 1;
            }
            i = 0;
            while (i < environment.Count()) {
                int length = environment.Length(i);
                if (length < 0 || cursor + length + 1 > record.Length) { return null; }
                environmentAddresses[i] = UserAddressSpace.StartBase() + cursor;
                environmentLengths[i] = length;
                Write32(record, 192 + i * 8, environmentAddresses[i]);
                Write32(record, 196 + i * 8, length);
                int j = 0;
                while (j < length) {
                    int value = environment.ByteAt(i, j);
                    if (value < 1 || value > 255) { return null; }
                    record[cursor] = (byte)value; cursor = cursor + 1; j = j + 1;
                }
                cursor = cursor + 1; i = i + 1;
            }
            if (cursor + workingDirectory.Length + 1 > record.Length) { return null; }
            Write32(record, 20, UserAddressSpace.StartBase() + cursor);
            Write32(record, 24, workingDirectory.Length);
            i = 0;
            while (i < workingDirectory.Length) {
                record[cursor] = workingDirectory[i]; cursor = cursor + 1; i = i + 1;
            }
            cursor = cursor + 1;
            Write32(record, 8, cursor);
            if (!memory.InstallStartRecord(record, cursor)) { return null; }
            UserArguments copied = new UserArguments(memory, argumentAddresses,
                argumentLengths, arguments.Count());
            UserArguments copiedEnvironment = new UserArguments(memory,
                environmentAddresses, environmentLengths, environment.Count());
            if (!copied.IsValid() || !copiedEnvironment.IsValid()) { return null; }
            return copied;
        }
    }

    public class UserSystemCalls {
        private IUserTerminal terminal;
        private IUserFiles files;
        private int processId;
        private int[] systemInformation;
        private IUserChildLauncher childLauncher;
        private UserProcessStart processStart;
        private bool terminalEndOfInput;
        private bool terminalReadActive;
        private long terminalReadAddress;
        private int terminalReadCapacity;
        private int terminalReadLength;
        private int lastFileStatus;
        private long lastResultAddress;
        private int lastResultLength;

        public UserSystemCalls(IUserTerminal inputTerminal, IUserFiles inputFiles) {
            Initialize(inputTerminal, inputFiles, 0, null);
        }
        public UserSystemCalls(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int inputProcessId) {
            Initialize(inputTerminal, inputFiles, inputProcessId, null);
        }
        public UserSystemCalls(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int inputProcessId, int[] inputSystemInformation) {
            Initialize(inputTerminal, inputFiles, inputProcessId, inputSystemInformation);
        }
        public UserSystemCalls(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int inputProcessId, int[] inputSystemInformation,
            IUserChildLauncher inputChildLauncher) {
            Initialize(inputTerminal, inputFiles, inputProcessId, inputSystemInformation);
            childLauncher = inputChildLauncher;
        }
        private void Initialize(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int inputProcessId, int[] inputSystemInformation) {
            terminal = inputTerminal;
            files = inputFiles;
            processId = inputProcessId;
            systemInformation = inputSystemInformation;
            childLauncher = null;
            processStart = null; terminalEndOfInput = false;
            terminalReadActive = false; terminalReadLength = 0;
            lastFileStatus = UserFileStatus.Ok();
            lastResultAddress = 0; lastResultLength = 0;
        }

        public int LastFileStatus() { return lastFileStatus; }
        public void SetProcessStart(UserProcessStart start) { processStart = start; }
        public bool TerminalEndOfInput() { return terminalEndOfInput; }
        public int RunChild(byte[] path, UserArguments arguments) {
            if (childLauncher == null || path == null || path.Length < 1 ||
                path.Length > 255 || path[0] != 47 || arguments == null ||
                !arguments.IsValid()) { return -1; }
            if (processStart == null) { return childLauncher.RunChild(path, arguments); }
            return childLauncher.RunChildWithContext(processId, path, arguments,
                processStart.Environment(), processStart.WorkingDirectory());
        }
        public int RunChildWithContext(byte[] path, UserArguments arguments,
            UserArguments environment, byte[] workingDirectory) {
            if (childLauncher == null || path == null || path.Length < 1 ||
                path.Length > 255 || path[0] != 47 || arguments == null ||
                !arguments.IsValid() || environment == null ||
                !environment.IsValid() || workingDirectory == null) { return -1; }
            return childLauncher.RunChildWithContext(processId, path, arguments,
                environment, workingDirectory);
        }
        public int SpawnChild(byte[] path) {
            if (childLauncher == null || processStart == null || path == null ||
                path.Length < 1 || path.Length > 255 || path[0] != 47) { return -4; }
            return childLauncher.SpawnChildWithContext(processId, path,
                new UserArguments(new byte[0], new int[0], new int[0], 0),
                processStart.Environment(), processStart.WorkingDirectory());
        }
        public int WaitChild(int childPid) {
            if (childLauncher == null || childPid < 1 || childPid == processId) {
                return -4;
            }
            return childLauncher.WaitChild(processId, childPid);
        }
        public int WaitReadyChild(int childPid, int maxRounds) {
            if (childLauncher == null || childPid < 1 || childPid == processId ||
                maxRounds < 1 || maxRounds > 100000) { return -4; }
            return childLauncher.WaitReadyChild(processId, childPid, maxRounds);
        }
        public int MarkReady() {
            if (childLauncher == null || processId < 1) { return -4; }
            return childLauncher.MarkReady(processId);
        }
        public int TerminateChild(int childPid) {
            if (childLauncher == null || childPid < 1 || childPid == processId) {
                return -4;
            }
            return childLauncher.TerminateChild(processId, childPid);
        }
        public int Sleep(int milliseconds) {
            if (childLauncher == null || milliseconds < 1 ||
                milliseconds > 60000) { return -4; }
            return childLauncher.SleepProcess(processId, milliseconds);
        }
        public int ChannelOpen(int childPid, int version) {
            if (childLauncher == null || childPid < 1 || version < 1 || version > 255) {
                return -4;
            }
            return childLauncher.ChannelOpen(processId, childPid, version);
        }
        public int ChannelAccept(int version) {
            if (childLauncher == null || version < 1 || version > 255) { return -4; }
            return childLauncher.ChannelAccept(processId, version);
        }
        public int ChannelSend(int handle, int version, byte[] source, int length) {
            if (childLauncher == null || handle < 1 || version < 1 ||
                version > 255 || source == null || length < 0 ||
                length > 256 || length > source.Length) { return -4; }
            return childLauncher.ChannelSend(processId, handle, version, source,
                length);
        }
        public int ChannelReceive(int handle, byte[] destination) {
            if (childLauncher == null || handle < 1 || destination == null ||
                destination.Length > 256) { return -4; }
            return childLauncher.ChannelReceive(processId, handle, destination);
        }
        public int ChannelWait(int handle, int maxRounds) {
            if (childLauncher == null || handle < 1 || maxRounds < 1 ||
                maxRounds > 100000) { return -4; }
            return childLauncher.ChannelWait(processId, handle, maxRounds);
        }
        public int ChannelPeer(int handle) {
            if (childLauncher == null || handle < 1) { return -4; }
            return childLauncher.ChannelPeer(processId, handle);
        }
        public int ChannelClose(int handle) {
            if (childLauncher == null || handle < 1) { return -4; }
            return childLauncher.ChannelClose(processId, handle);
        }
        public int FileApiVersion() { return 1; }
        public UserSyscallResult SystemInformation(int selector) {
            if (selector == 0) { return new UserSyscallResult(UserSyscallStatus.Success(), 4); }
            if (selector == 1) {
                return new UserSyscallResult(UserSyscallStatus.Success(), UserProcessStart.Version());
            }
            if (selector == 2) { return new UserSyscallResult(UserSyscallStatus.Success(), 16); }
            if (selector == 3) { return new UserSyscallResult(UserSyscallStatus.Success(), processId); }
            bool supported = (selector >= 16 && selector <= 25) ||
                (selector >= 32 && selector <= 45) ||
                (selector >= 48 && selector <= 54);
            if (!supported || systemInformation == null ||
                selector >= systemInformation.Length) {
                return new UserSyscallResult(UserSyscallStatus.InvalidArgument(), -1);
            }
            return new UserSyscallResult(UserSyscallStatus.Success(),
                systemInformation[selector]);
        }
        public UserSyscallResult OpenResult(UserAddressSpace memory, long address,
            int count, bool write) {
            int descriptor = OpenChecked(memory, address, count, write);
            if (descriptor < 3) { return new UserSyscallResult(lastFileStatus, -1); }
            return new UserSyscallResult(UserSyscallStatus.Success(), descriptor);
        }
        public UserSyscallResult ReadResult(int descriptor, UserAddressSpace memory,
            long address, int count) {
            int received = ReadChecked(descriptor, memory, address, count);
            if (received < 0) { return new UserSyscallResult(lastFileStatus, -1); }
            if (received == 0) {
                return new UserSyscallResult(UserSyscallStatus.EndOfFile(), 0);
            }
            return new UserSyscallResult(UserSyscallStatus.Success(), received);
        }

        private byte[] Path(UserAddressSpace memory, long address, int count) {
            if (memory == null || count < 1 || count > 255 ||
                !memory.CanRead(address, count)) { return null; }
            byte[] path = new byte[count];
            if (!memory.CopyOut(address, path, count)) { return null; }
            return path;
        }

        private byte[] Payload(UserAddressSpace memory, long address, int count) {
            if (memory == null || count < 0 || count > 65536 ||
                !memory.CanRead(address, count)) { return null; }
            byte[] bytes = new byte[count];
            if (!memory.CopyOut(address, bytes, count)) { return null; }
            return bytes;
        }

        public long StatField(UserAddressSpace memory, long address, int count,
            int selector) {
            byte[] path = Path(memory, address, count);
            return StatField(path, selector);
        }

        public long StatField(byte[] path, int selector) {
            if (files == null || path == null || path.Length < 1 ||
                path.Length > 255 || selector < 0 || selector > 6) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            UserFileInfo info = files.Stat(path, path.Length);
            if (info == null) { lastFileStatus = UserFileStatus.Corrupt(); return -1; }
            lastFileStatus = info.Status();
            if (lastFileStatus != UserFileStatus.Ok()) { return -1; }
            if (selector == 0) { return info.Kind(); }
            if (selector == 1) { return info.Length(); }
            if (selector == 2) { return info.ObjectId(); }
            if (selector == 3) { return info.Created(); }
            if (selector == 4) { return info.Modified(); }
            if (selector == 5) { return info.TimeFlags(); }
            return info.Attributes();
        }

        public int DirectoryCount(UserAddressSpace memory, long address, int count) {
            byte[] path = Path(memory, address, count);
            return DirectoryCount(path);
        }

        public int DirectoryCount(byte[] path) {
            if (files == null || path == null || path.Length < 1 || path.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            UserDirectoryInfo result = files.DirectoryCount(path, path.Length);
            if (result == null) { lastFileStatus = UserFileStatus.Corrupt(); return -1; }
            lastFileStatus = result.Status();
            if (lastFileStatus != UserFileStatus.Ok()) { return -1; }
            return result.Count();
        }

        public int DirectoryName(UserAddressSpace memory, long pathAddress,
            int pathCount, long index, long destination) {
            byte[] path = Path(memory, pathAddress, pathCount);
            return DirectoryName(path, index, memory, destination);
        }

        public int DirectoryName(byte[] path, long index,
            UserAddressSpace memory, long destination) {
            lastResultLength = 0;
            if (files == null || path == null || path.Length < 1 ||
                path.Length > 255 || index < 0 || index > 2147483647 ||
                memory == null ||
                !memory.CanWrite(destination, 64)) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            byte[] name = new byte[64];
            int length = files.DirectoryName(path, path.Length, (int)index, name);
            if (length < 0) { lastFileStatus = -length; return -1; }
            if (length > 63 || !memory.CopyIn(destination, name, length)) {
                lastFileStatus = UserFileStatus.Corrupt(); return -1;
            }
            lastResultAddress = destination; lastResultLength = length;
            lastFileStatus = UserFileStatus.Ok(); return length;
        }

        public int OpenChecked(UserAddressSpace memory, long address, int count,
            bool write) {
            byte[] path = Path(memory, address, count);
            return OpenChecked(path, write);
        }

        public int OpenChecked(byte[] path, bool write) {
            if (files == null || path == null || path.Length < 1 || path.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            int descriptor = -1;
            if (write) { descriptor = files.OpenWrite(path, path.Length); }
            else { descriptor = files.Open(path, path.Length); }
            if (descriptor < 3) {
                lastFileStatus = -descriptor;
                if (lastFileStatus == 0) { lastFileStatus = UserFileStatus.Corrupt(); }
                return -1;
            }
            lastFileStatus = UserFileStatus.Ok(); return descriptor;
        }

        public int ReadChecked(int descriptor, UserAddressSpace memory,
            long address, int capacity) {
            lastResultLength = 0;
            if (files == null || memory == null || capacity < 0 ||
                capacity > 65536 || !memory.CanWrite(address, capacity)) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            byte[] bytes = new byte[capacity];
            int length = files.Read(descriptor, bytes, capacity);
            if (length < 0) { lastFileStatus = -length; return -1; }
            if (length > capacity || !memory.CopyIn(address, bytes, length)) {
                lastFileStatus = UserFileStatus.Corrupt(); return -1;
            }
            lastResultAddress = address; lastResultLength = length;
            lastFileStatus = UserFileStatus.Ok(); return length;
        }

        // The portable text API owns its result. Keep the AUEX v1 string limit
        // explicit and check for one extra byte so a large file is never cut off.
        public byte[] ReadAllText(byte[] path) {
            if (files == null || path == null || path.Length < 1 || path.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return null;
            }
            int descriptor = OpenChecked(path, false);
            if (descriptor < 3) { return null; }
            byte[] chunk = new byte[256];
            byte[] contents = new byte[255];
            int length = 0;
            int failure = UserFileStatus.Ok();
            bool done = false;
            while (!done && length <= 255) {
                int requested = 256 - length;
                int count = files.Read(descriptor, chunk, requested);
                if (count < 0) { failure = 0 - count; done = true; }
                else if (count > requested) { failure = UserFileStatus.Corrupt(); done = true; }
                else if (count == 0) { done = true; }
                else {
                    int i = 0;
                    while (i < count) {
                        if (chunk[i] == 0) { failure = UserFileStatus.InvalidArgument(); }
                        if (length + i < 255) { contents[length + i] = chunk[i]; }
                        i = i + 1;
                    }
                    length = length + count;
                    if (failure != UserFileStatus.Ok()) { done = true; }
                }
            }
            if (length > 255 && failure == UserFileStatus.Ok()) {
                failure = UserFileStatus.InvalidArgument();
            }
            if (!files.Close(descriptor) && failure == UserFileStatus.Ok()) {
                failure = UserFileStatus.IoFailure();
            }
            lastFileStatus = failure;
            if (failure != UserFileStatus.Ok()) { return null; }
            byte[] result = new byte[length];
            int position = 0;
            while (position < length) {
                result[position] = contents[position]; position = position + 1;
            }
            return result;
        }

        public int WriteAllText(byte[] path, byte[] contents) {
            if (files == null || path == null || path.Length < 1 || path.Length > 255 ||
                contents == null || contents.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            int descriptor = files.OpenWrite(path, path.Length);
            if (descriptor < 3) {
                lastFileStatus = 0 - descriptor;
                if (lastFileStatus != UserFileStatus.NotFound()) { return lastFileStatus; }
                lastFileStatus = files.Create(path, path.Length, contents);
                return lastFileStatus;
            }
            lastFileStatus = files.Truncate(descriptor, 0);
            if (lastFileStatus == UserFileStatus.Ok() && contents.Length > 0) {
                lastFileStatus = files.Write(descriptor, contents, contents.Length, false);
            }
            if (!files.Close(descriptor) && lastFileStatus == UserFileStatus.Ok()) {
                lastFileStatus = UserFileStatus.IoFailure();
            }
            return lastFileStatus;
        }

        public long ResultField(UserAddressSpace memory, long offset, int width) {
            if (memory == null || offset < 0 || width < 1 || width > 4 ||
                offset > lastResultLength || width > lastResultLength - offset ||
                !memory.CanRead(lastResultAddress + offset, width)) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            long result = 0;
            long scale = 1;
            int index = 0;
            while (index < width) {
                long byteValue = memory.ReadByte(lastResultAddress + offset + index);
                result = result + byteValue * scale;
                scale = scale * 256;
                index = index + 1;
            }
            lastFileStatus = UserFileStatus.Ok(); return result;
        }

        public int WriteOpen(int descriptor, UserAddressSpace memory,
            long address, int count, bool append) {
            byte[] bytes = Payload(memory, address, count);
            if (files == null || bytes == null) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = files.Write(descriptor, bytes, count, append);
            return lastFileStatus;
        }

        public int TruncateOpen(int descriptor, long length) {
            if (files == null || length < 0) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = files.Truncate(descriptor, length); return lastFileStatus;
        }

        public int Create(UserAddressSpace memory, long pathAddress, int pathCount,
            long dataAddress, int dataCount) {
            byte[] path = Path(memory, pathAddress, pathCount);
            byte[] bytes = Payload(memory, dataAddress, dataCount);
            if (files == null || path == null || bytes == null) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = files.Create(path, pathCount, bytes); return lastFileStatus;
        }

        public int CreateDynamic(byte[] path, byte[] contents) {
            if (files == null || path == null || path.Length < 1 ||
                path.Length > 255 || contents == null || contents.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = files.Create(path, path.Length, contents);
            return lastFileStatus;
        }

        public int MutateDynamic(byte[] path, int operation) {
            if (files == null || path == null || path.Length < 1 ||
                path.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            if (operation == 0) { lastFileStatus = files.Delete(path, path.Length); }
            else if (operation == 1) { lastFileStatus = files.Mkdir(path, path.Length); }
            else if (operation == 2) { lastFileStatus = files.Rmdir(path, path.Length); }
            else { lastFileStatus = UserFileStatus.InvalidArgument(); }
            return lastFileStatus;
        }

        public int RenameDynamic(byte[] source, byte[] destination) {
            if (files == null || source == null || destination == null ||
                source.Length < 1 || destination.Length < 1 ||
                source.Length > 255 || destination.Length > 255) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = files.Rename(source, source.Length, destination,
                destination.Length);
            return lastFileStatus;
        }

        public int MutatePath(UserAddressSpace memory, long address, int count,
            int operation) {
            byte[] path = Path(memory, address, count);
            if (files == null || path == null) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            if (operation == 0) { lastFileStatus = files.Delete(path, count); }
            else if (operation == 1) { lastFileStatus = files.Mkdir(path, count); }
            else if (operation == 2) { lastFileStatus = files.Rmdir(path, count); }
            else { lastFileStatus = UserFileStatus.InvalidArgument(); }
            return lastFileStatus;
        }

        public int Rename(UserAddressSpace memory, long sourceAddress,
            int sourceCount, long destinationAddress, int destinationCount) {
            byte[] source = Path(memory, sourceAddress, sourceCount);
            byte[] destination = Path(memory, destinationAddress, destinationCount);
            if (files == null || source == null || destination == null) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = files.Rename(source, sourceCount, destination,
                destinationCount);
            return lastFileStatus;
        }

        public int CloseChecked(int descriptor) {
            if (files == null || descriptor < 3 || !files.Close(descriptor)) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return lastFileStatus;
            }
            lastFileStatus = UserFileStatus.Ok(); return lastFileStatus;
        }

        public int Write(int descriptor, UserAddressSpace memory, long address, int count) {
            if ((descriptor != 1 && descriptor != 2) || terminal == null || memory == null ||
                count < 0 || !memory.CanRead(address, count)) { return -1; }
            int i = 0;
            while (i < count) {
                int value = memory.ReadByte(address + i);
                if (value < 0 || !terminal.WriteByte(value)) { return -1; }
                i = i + 1;
            }
            return count;
        }

        public bool WriteTextByte(int value) {
            return terminal != null && value >= 0 && value <= 255 &&
                terminal.WriteByte(value);
        }

        // Raw, decoded input lets a foreground TUI own its editing and echo.
        // Navigation keys use 256..262; EOF is returned as -1.
        public int ReadKey() {
            if (terminal == null) { return -1; }
            if (childLauncher != null) { childLauncher.BeforeTerminalInput(processId); }
            int key = terminal.ReadByte();
            if (key == -3) { return -3; }
            if (childLauncher != null) { childLauncher.AfterTerminalInput(processId); }
            terminalEndOfInput = key < 0 || key == 4;
            if (terminalEndOfInput) { return -1; }
            return key;
        }

        public bool MoveCursor(int row, int column) {
            if (terminal == null || row < 1 || row > 200 ||
                column < 1 || column > 200) { return false; }
            return WriteTextByte(27) && WriteTextByte(91) &&
                WriteValue(row, 0) && WriteTextByte(59) &&
                WriteValue(column, 0) && WriteTextByte(72);
        }

        // Formats scalar values without allocating a temporary string, so a
        // user loop that prints values cannot consume kernel heap pages.
        public bool WriteValue(long value, int format) {
            if (terminal == null || format < 0 || format > 3) { return false; }
            bool boolValue = format >= 2; bool newline = format % 2 == 1;
            if (boolValue) {
                if (value == 0) {
                    if (!terminal.WriteByte(102) || !terminal.WriteByte(97) ||
                        !terminal.WriteByte(108) || !terminal.WriteByte(115) ||
                        !terminal.WriteByte(101)) { return false; }
                } else {
                    if (!terminal.WriteByte(116) || !terminal.WriteByte(114) ||
                        !terminal.WriteByte(117) || !terminal.WriteByte(101)) { return false; }
                }
            } else if (value == 0) {
                if (!terminal.WriteByte(48)) { return false; }
            } else {
                if (value < 0) { if (!terminal.WriteByte(45)) { return false; } }
                long divisor = 1;
                if (value < 0) {
                    while (value / divisor <= -10) { divisor = divisor * 10; }
                } else {
                    while (value / divisor >= 10) { divisor = divisor * 10; }
                }
                while (divisor > 0) {
                    long digit = (value / divisor) % 10;
                    if (digit < 0) { digit = 0 - digit; }
                    if (!terminal.WriteByte(48 + (int)digit)) { return false; }
                    divisor = divisor / 10;
                }
            }
            if (newline) {
                if (!terminal.WriteByte(13) || !terminal.WriteByte(10)) { return false; }
            }
            return true;
        }

        // fd 0 is a canonical terminal stream. Backspace editing and echo are
        // part of the terminal syscall, so every user program sees the same
        // behavior regardless of whether bytes came from COM1 or USB HID.
        public int ReadTerminal(UserAddressSpace memory, long address, int capacity) {
            if (!terminalReadActive && childLauncher != null) {
                childLauncher.BeforeTerminalInput(processId);
            }
            int result = ReadTerminalCore(memory, address, capacity);
            if (result != -3 && childLauncher != null) {
                childLauncher.AfterTerminalInput(processId);
            }
            return result;
        }
        private int ReadTerminalCore(UserAddressSpace memory, long address, int capacity) {
            if (terminal == null || memory == null || capacity < 1 ||
                !memory.CanWrite(address, capacity)) { return -1; }
            if (terminalReadActive && (terminalReadAddress != address ||
                terminalReadCapacity != capacity)) { return -1; }
            if (!terminalReadActive) {
                terminalReadActive = true; terminalReadAddress = address;
                terminalReadCapacity = capacity; terminalReadLength = 0;
                terminalEndOfInput = false;
            }
            while (true) {
                int value = terminal.ReadByte();
                if (value == -3) { return -3; }
                if (value < 0 || (value == 4 && terminalReadLength == 0)) {
                    terminalEndOfInput = true; terminalReadActive = false;
                    return terminalReadLength;
                }
                if (value == 3) { terminalReadActive = false; return -2; }
                if (value == 10 || value == 13) {
                    terminal.WriteByte(13); terminal.WriteByte(10);
                    terminalReadActive = false; return terminalReadLength;
                }
                if (value == 8 || value == 127) {
                    if (terminalReadLength > 0) {
                        terminalReadLength = terminalReadLength - 1;
                        terminal.WriteByte(8); terminal.WriteByte(32); terminal.WriteByte(8);
                    }
                } else if (value >= 32 && value <= 126 && terminalReadLength < capacity) {
                    if (!memory.WriteByte(address + terminalReadLength, value)) { return -1; }
                    terminalReadLength = terminalReadLength + 1; terminal.WriteByte(value);
                } else if (value >= 32 && value <= 126) {
                    terminal.WriteByte(7);
                }
            }
            return -1;
        }

        public int Open(UserAddressSpace memory, long address, int count) {
            if (memory == null || count < 1 || count > 255 || !memory.CanRead(address, count)) {
                return -1;
            }
            byte[] bytes = new byte[count];
            if (!memory.CopyOut(address, bytes, count)) { return -1; }
            if (files == null) { return -1; }
            return files.Open(bytes, count);
        }
        public int ReadFile(int descriptor, UserAddressSpace memory, long address, int capacity) {
            if (files == null || memory == null || capacity < 0 ||
                !memory.CanWrite(address, capacity)) { return -1; }
            byte[] bytes = new byte[capacity];
            int count = files.Read(descriptor, bytes, capacity);
            if (count < 0 || count > capacity || !memory.CopyIn(address, bytes, count)) { return -1; }
            return count;
        }
        public bool Close(int descriptor) { return files != null && files.Close(descriptor); }
        public void CloseAll() { if (files != null) { files.CloseAll(); } }
    }

    public class UserProcess {
        private UserAddressSpace memory;
        private UserSystemCalls calls;
        private int instructionPointer;
        private int state;
        private int fault;
        private int exitCode;
        private int accumulator;
        private int openDescriptor;
        private long instructions;
        private long lastTerminalInputInstruction;
        private long[] values;
        private int valueCount;
        private long[] locals;
        private long[] savedLocals;
        private int[] returnPointers;
        private int[] returnValueDepths;
        private int callDepth;
        private UserArguments arguments;
        private UserProcessStart startRecord;
        private long staticDataEnd;
        private long heapBase;
        private long heapTop;
        private long[] arrayAddresses;
        private int[] arrayLengths;
        private int arrayCount;

        public UserProcess(UserExecutable executable, UserSystemCalls systemCalls) {
            Initialize(executable, systemCalls,
                new UserProcessStart(new UserArguments(new byte[0], new int[0],
                    new int[0], 0)));
        }

        public UserProcess(UserExecutable executable, UserSystemCalls systemCalls,
            UserArguments inputArguments) {
            Initialize(executable, systemCalls, new UserProcessStart(inputArguments));
        }
        public UserProcess(UserExecutable executable, UserSystemCalls systemCalls,
            UserProcessStart start) {
            Initialize(executable, systemCalls, start);
        }

        private void Initialize(UserExecutable executable, UserSystemCalls systemCalls,
            UserProcessStart start) {
            calls = systemCalls; instructionPointer = 0; fault = UserFault.InvalidImage();
            exitCode = -1; accumulator = 0; openDescriptor = -1; instructions = 0;
            lastTerminalInputInstruction = 0;
            values = new long[256]; valueCount = 0; locals = new long[256];
            savedLocals = new long[16 * 256];
            returnPointers = new int[16]; returnValueDepths = new int[16]; callDepth = 0;
            arguments = null;
            startRecord = start;
            arrayAddresses = new long[32]; arrayLengths = new int[32]; arrayCount = 0;
            if (executable == null || !executable.IsValid() || calls == null ||
                start == null || !start.IsValid()) {
                memory = null; state = UserProgramState.Faulted(); return;
            }
            memory = new UserAddressSpace(executable);
            arguments = start.CopyTo(memory);
            if (arguments == null || !arguments.IsValid()) {
                memory = null; state = UserProgramState.Faulted(); return;
            }
            staticDataEnd = UserAddressSpace.DataBase() + executable.InitialData().Length;
            calls.SetProcessStart(start);
            heapBase = 0; heapTop = 0;
            instructionPointer = executable.Entry(); state = UserProgramState.Running();
            fault = UserFault.None();
        }

        public int State() { return state; }
        public int Fault() { return fault; }
        public int ExitCode() { return exitCode; }
        public int Accumulator() { return accumulator; }
        public long Instructions() { return instructions; }
        public long InstructionsSinceTerminalInput() {
            return instructions - lastTerminalInputInstruction;
        }
        public UserAddressSpace AddressSpace() { return memory; }
        public void Abort(int cause) {
            if (state == UserProgramState.Running()) { Fail(cause); }
        }

        private void Fail(int cause) {
            fault = cause; state = UserProgramState.Faulted(); calls.CloseAll();
        }
        private int NextByte() {
            if (memory == null) { return -1; }
            int value = memory.ReadCode(instructionPointer);
            if (value >= 0) { instructionPointer = instructionPointer + 1; }
            return value;
        }
        private long Next32() {
            int b0 = NextByte(); int b1 = NextByte(); int b2 = NextByte(); int b3 = NextByte();
            if (b0 < 0 || b1 < 0 || b2 < 0 || b3 < 0) { return -1; }
            return b0 + b1 * 256 + b2 * 65536 + (long)b3 * 16777216;
        }
        private bool PushValue(long value) {
            if (valueCount >= values.Length) { Fail(UserFault.InvalidInstruction()); return false; }
            values[valueCount] = value; valueCount = valueCount + 1; return true;
        }

        private int TextByte(long handle, int offset) {
            if (offset < 0 || offset > 255) { return -1; }
            if (handle < 0) {
                if (handle < -16) { return -1; }
                long index = 0 - handle - 1;
                if (index < 0 || index >= arguments.Count()) { return -1; }
                return arguments.ByteAt((int)index, offset);
            }
            return memory.ReadByte(handle + offset);
        }

        private byte[] TextPath(long handle) {
            int length = 0;
            while (length <= 255) {
                int value = TextByte(handle, length);
                if (value < 0) { return null; }
                if (value == 0) {
                    if (length == 0) { return new byte[0]; }
                    byte[] path = new byte[length];
                    int position = 0;
                    while (position < length) {
                        path[position] = (byte)TextByte(handle, position);
                        position = position + 1;
                    }
                    return path;
                }
                length = length + 1;
            }
            return null;
        }
        private int ArrayIndex(long handle) {
            int i = 0;
            while (i < arrayCount) {
                if (arrayAddresses[i] == handle) { return i; }
                i = i + 1;
            }
            return -1;
        }

        // Execute at most one bytecode operation. Returning to the scheduler
        // after each operation bounds latency and gives explicit yield points.
        public void Step() {
            if (state != UserProgramState.Running()) { return; }
            int opcode = NextByte();
            if (opcode < 0) { Fail(UserFault.InvalidInstruction()); return; }
            instructions = instructions + 1;
            if (opcode == 1) {
                int code = NextByte();
                if (code < 0) { Fail(UserFault.InvalidInstruction()); return; }
                exitCode = code; state = UserProgramState.Exited(); calls.CloseAll(); return;
            }
            if (opcode == 2) {
                long address = Next32(); long count = Next32();
                if (address < 0 || count < 0 || count > 65536 ||
                    calls.Write(1, memory, address, (int)count) < 0) {
                    Fail(UserFault.SystemCall());
                }
                return;
            }
            if (opcode == 3) {
                long address = Next32(); long capacity = Next32();
                if (address < 0 || capacity < 1 || capacity > 65536) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                accumulator = calls.ReadTerminal(memory, address, (int)capacity);
                if (accumulator == -3) {
                    instructionPointer = instructionPointer - 9;
                    lastTerminalInputInstruction = instructions; return;
                }
                if (accumulator < 0) { Fail(UserFault.SystemCall()); }
                else { lastTerminalInputInstruction = instructions; }
                return;
            }
            if (opcode == 4) {
                long address = Next32();
                if (address < 0 || accumulator < 0 ||
                    calls.Write(1, memory, address, accumulator) < 0) {
                    Fail(UserFault.SystemCall());
                }
                return;
            }
            if (opcode == 5) {
                long address = Next32(); long count = Next32();
                if (address < 0 || count < 1 || count > 255) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                openDescriptor = calls.Open(memory, address, (int)count);
                if (openDescriptor < 0) { Fail(UserFault.SystemCall()); }
                return;
            }
            if (opcode == 6) {
                long address = Next32(); long capacity = Next32();
                if (address < 0 || capacity < 0 || capacity > 65536 || openDescriptor < 3) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                accumulator = calls.ReadFile(openDescriptor, memory, address, (int)capacity);
                if (accumulator < 0) { Fail(UserFault.SystemCall()); }
                return;
            }
            if (opcode == 7) {
                if (openDescriptor < 3 || !calls.Close(openDescriptor)) {
                    Fail(UserFault.SystemCall()); return;
                }
                openDescriptor = -1; return;
            }
            if (opcode == 8) {
                long address = Next32(); int value = NextByte();
                if (address < 0 || value < 0 || !memory.WriteByte(address, value)) {
                    Fail(UserFault.MemoryAccess());
                }
                return;
            }
            if (opcode == 9) { return; }
            if (opcode == 10) {
                long target = Next32();
                if (target < 0 || target >= memory.CodeLength()) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                instructionPointer = (int)target; return;
            }
            if (opcode == 11) {
                long raw = Next32();
                if (raw < 0) { Fail(UserFault.InvalidInstruction()); return; }
                long sign = 65536; sign = sign * 32768;
                if (raw >= sign) { raw = raw - sign * 2; }
                PushValue(raw); return;
            }
            if (opcode == 12) {
                int slot = NextByte();
                if (slot < 0 || slot >= locals.Length) { Fail(UserFault.InvalidInstruction()); return; }
                PushValue(locals[slot]); return;
            }
            if (opcode == 13) {
                int slot2 = NextByte();
                if (slot2 < 0 || slot2 >= locals.Length || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                locals[slot2] = values[valueCount - 1]; return;
            }
            if (opcode == 14) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                valueCount = valueCount - 1; return;
            }
            if (opcode >= 15 && opcode <= 19) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long right = values[valueCount - 1]; long left = values[valueCount - 2];
                valueCount = valueCount - 2; long result = 0;
                if (opcode == 15) { result = left + right; }
                else if (opcode == 16) { result = left - right; }
                else if (opcode == 17) { result = left * right; }
                else if (right == 0) { Fail(UserFault.Arithmetic()); return; }
                else if (opcode == 18) { result = left / right; }
                else { result = left % right; }
                PushValue(result); return;
            }
            if (opcode == 20) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                values[valueCount - 1] = 0 - values[valueCount - 1]; return;
            }
            if (opcode >= 21 && opcode <= 26) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long right2 = values[valueCount - 1]; long left2 = values[valueCount - 2];
                valueCount = valueCount - 2; bool comparison = false;
                if (opcode == 21) { comparison = left2 == right2; }
                else if (opcode == 22) { comparison = left2 != right2; }
                else if (opcode == 23) { comparison = left2 < right2; }
                else if (opcode == 24) { comparison = left2 <= right2; }
                else if (opcode == 25) { comparison = left2 > right2; }
                else { comparison = left2 >= right2; }
                if (comparison) { PushValue(1); } else { PushValue(0); }
                return;
            }
            if (opcode == 27) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                if (values[valueCount - 1] == 0) { values[valueCount - 1] = 1; }
                else { values[valueCount - 1] = 0; }
                return;
            }
            if (opcode == 28) {
                long target2 = Next32();
                if (target2 < 0 || target2 >= memory.CodeLength() || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long condition = values[valueCount - 1]; valueCount = valueCount - 1;
                if (condition == 0) { instructionPointer = (int)target2; }
                return;
            }
            if (opcode == 29) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long returned = values[valueCount - 1]; valueCount = valueCount - 1;
                returned = returned % 256; if (returned < 0) { returned = returned + 256; }
                exitCode = (int)returned; state = UserProgramState.Exited(); calls.CloseAll(); return;
            }
            if (opcode == 32) {
                int format = NextByte();
                if (format < 0 || format > 3 || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long printable = values[valueCount - 1]; valueCount = valueCount - 1;
                if (!calls.WriteValue(printable, format)) { Fail(UserFault.SystemCall()); }
                return;
            }
            if (opcode == 33) {
                int field = NextByte(); long pathAddress = Next32(); long pathCount = Next32();
                if (field < 0 || field > 6 || pathAddress < 0 ||
                    pathCount < 1 || pathCount > 255) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                PushValue(calls.StatField(memory, pathAddress, (int)pathCount, field));
                return;
            }
            if (opcode == 34) {
                long pathAddress2 = Next32(); long pathCount2 = Next32();
                if (pathAddress2 < 0 || pathCount2 < 1 || pathCount2 > 255) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                PushValue(calls.DirectoryCount(memory, pathAddress2, (int)pathCount2));
                return;
            }
            if (opcode == 35) {
                long pathAddress3 = Next32(); long pathCount3 = Next32();
                long nameAddress = Next32();
                if (pathAddress3 < 0 || pathCount3 < 1 || pathCount3 > 255 ||
                    nameAddress < 0 || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long nameIndex = values[valueCount - 1]; valueCount = valueCount - 1;
                accumulator = calls.DirectoryName(memory, pathAddress3,
                    (int)pathCount3, nameIndex, nameAddress);
                PushValue(accumulator); return;
            }
            if (opcode == 36) {
                long createPath = Next32(); long createPathCount = Next32();
                long createData = Next32(); long createDataCount = Next32();
                if (createPath < 0 || createPathCount < 1 || createPathCount > 255 ||
                    createData < 0 || createDataCount < 0 || createDataCount > 65536) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                PushValue(calls.Create(memory, createPath, (int)createPathCount,
                    createData, (int)createDataCount)); return;
            }
            if (opcode == 37) {
                int writeMode = NextByte(); long openPath = Next32();
                long openCount = Next32();
                if (writeMode < 0 || writeMode > 1 || openPath < 0 ||
                    openCount < 1 || openCount > 255) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                int opened = calls.OpenChecked(memory, openPath, (int)openCount,
                    writeMode == 1);
                if (opened >= 3) {
                    if (openDescriptor >= 3) { calls.CloseChecked(openDescriptor); }
                    openDescriptor = opened; PushValue(0);
                } else { PushValue(calls.LastFileStatus()); }
                return;
            }
            if (opcode == 38) {
                int appendMode = NextByte(); long writeAddress = Next32();
                long writeCount = Next32();
                if (appendMode < 0 || appendMode > 1 || writeAddress < 0 ||
                    writeCount < 0 || writeCount > 65536) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                PushValue(calls.WriteOpen(openDescriptor, memory, writeAddress,
                    (int)writeCount, appendMode == 1)); return;
            }
            if (opcode == 39) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long newLength = values[valueCount - 1]; valueCount = valueCount - 1;
                PushValue(calls.TruncateOpen(openDescriptor, newLength)); return;
            }
            if (opcode == 40) {
                int pathAction = NextByte(); long actionPath = Next32();
                long actionCount = Next32();
                if (pathAction < 0 || pathAction > 2 || actionPath < 0 ||
                    actionCount < 1 || actionCount > 255) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                PushValue(calls.MutatePath(memory, actionPath, (int)actionCount,
                    pathAction)); return;
            }
            if (opcode == 41) {
                long firstPath = Next32(); long firstCount = Next32();
                long secondPath = Next32(); long secondCount = Next32();
                if (firstPath < 0 || secondPath < 0 || firstCount < 1 ||
                    secondCount < 1 || firstCount > 255 || secondCount > 255) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                PushValue(calls.Rename(memory, firstPath, (int)firstCount,
                    secondPath, (int)secondCount)); return;
            }
            if (opcode == 42) { PushValue(calls.LastFileStatus()); return; }
            if (opcode == 43) {
                int closeStatus = calls.CloseChecked(openDescriptor);
                if (closeStatus == UserFileStatus.Ok()) { openDescriptor = -1; }
                PushValue(closeStatus); return;
            }
            if (opcode == 44) {
                long readAddress = Next32(); long readCount = Next32();
                if (readAddress < 0 || readCount < 0 || readCount > 65536) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                accumulator = calls.ReadChecked(openDescriptor, memory,
                    readAddress, (int)readCount);
                PushValue(accumulator); return;
            }
            if (opcode == 45) { PushValue(arguments.Count()); return; }
            if (opcode == 46) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long index = values[valueCount - 1]; valueCount = valueCount - 1;
                if (index < 0 || index >= arguments.Count()) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                PushValue(0 - index - 1); return;
            }
            if (opcode == 47) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long rightText = values[valueCount - 1];
                long leftText = values[valueCount - 2];
                valueCount = valueCount - 2;
                int position = 0;
                while (position <= 255) {
                    int leftByte = TextByte(leftText, position);
                    int rightByte = TextByte(rightText, position);
                    if (leftByte < 0 || rightByte < 0) {
                        Fail(UserFault.MemoryAccess()); return;
                    }
                    if (leftByte != rightByte) { PushValue(0); return; }
                    if (leftByte == 0) { PushValue(1); return; }
                    position = position + 1;
                }
                Fail(UserFault.MemoryAccess()); return;
            }
            if (opcode == 48) {
                int newline = NextByte();
                if (newline < 0 || newline > 1 || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long textHandle = values[valueCount - 1]; valueCount = valueCount - 1;
                int position2 = 0;
                while (position2 <= 255) {
                    int value = TextByte(textHandle, position2);
                    if (value < 0) { Fail(UserFault.MemoryAccess()); return; }
                    if (value == 0) { break; }
                    if (!calls.WriteTextByte(value)) { Fail(UserFault.SystemCall()); return; }
                    position2 = position2 + 1;
                }
                if (position2 > 255) { Fail(UserFault.MemoryAccess()); return; }
                if (newline == 1 && (!calls.WriteTextByte(13) || !calls.WriteTextByte(10))) {
                    Fail(UserFault.SystemCall());
                }
                return;
            }
            if (opcode == 49) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long textHandle2 = values[valueCount - 1]; valueCount = valueCount - 1;
                int size = 0;
                while (size <= 255) {
                    int value2 = TextByte(textHandle2, size);
                    if (value2 < 0) { Fail(UserFault.MemoryAccess()); return; }
                    if (value2 == 0) { PushValue(size); return; }
                    size = size + 1;
                }
                Fail(UserFault.MemoryAccess()); return;
            }
            if (opcode == 50 || opcode == 51 || opcode == 52) {
                int option = -1;
                if (opcode != 52) { option = NextByte(); }
                if (valueCount < 1 || (opcode == 50 && (option < 0 || option > 1)) ||
                    (opcode == 51 && (option < 0 || option > 6))) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long handle = values[valueCount - 1]; valueCount = valueCount - 1;
                byte[] dynamicPath = TextPath(handle);
                if (dynamicPath == null) { Fail(UserFault.MemoryAccess()); return; }
                if (opcode == 51) {
                    PushValue(calls.StatField(dynamicPath, option)); return;
                }
                if (opcode == 52) {
                    PushValue(calls.DirectoryCount(dynamicPath)); return;
                }
                int dynamicOpened = calls.OpenChecked(dynamicPath, option == 1);
                if (dynamicOpened >= 3) {
                    if (openDescriptor >= 3) { calls.CloseChecked(openDescriptor); }
                    openDescriptor = dynamicOpened; PushValue(0);
                } else { PushValue(calls.LastFileStatus()); }
                return;
            }
            if (opcode == 53) {
                int width = NextByte();
                if ((width != 1 && width != 4) || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long offset = values[valueCount - 1]; valueCount = valueCount - 1;
                PushValue(calls.ResultField(memory, offset, width)); return;
            }
            if (opcode == 54) { PushValue(calls.FileApiVersion()); return; }
            if (opcode == 56) {
                long requestedHeapBase = Next32();
                if (requestedHeapBase < staticDataEnd ||
                    !memory.CanWrite(requestedHeapBase, 0) || valueCount < 1 ||
                    (heapBase != 0 && heapBase != requestedHeapBase)) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                if (heapBase == 0) {
                    heapBase = requestedHeapBase; heapTop = heapBase;
                }
                long pathHandle = values[valueCount - 1]; valueCount = valueCount - 1;
                byte[] textPath = TextPath(pathHandle);
                if (textPath == null) { Fail(UserFault.MemoryAccess()); return; }
                byte[] contents = calls.ReadAllText(textPath);
                if (contents == null) { Fail(UserFault.SystemCall()); return; }
                if (!memory.CanWrite(heapTop, contents.Length + 1) ||
                    !memory.CopyIn(heapTop, contents, contents.Length) ||
                    !memory.WriteByte(heapTop + contents.Length, 0)) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                long resultAddress = heapTop;
                heapTop = heapTop + contents.Length + 1;
                PushValue(resultAddress); return;
            }
            if (opcode == 57) {
                long requestedHeapBase2 = Next32();
                if (requestedHeapBase2 < staticDataEnd ||
                    !memory.CanWrite(requestedHeapBase2, 0) ||
                    (heapBase != 0 && heapBase != requestedHeapBase2)) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                if (heapBase == 0) {
                    heapBase = requestedHeapBase2; heapTop = heapBase;
                }
                if (!memory.CanWrite(heapTop, 256)) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                int lineLength = calls.ReadTerminal(memory, heapTop, 255);
                if (lineLength == -3) {
                    instructionPointer = instructionPointer - 5;
                    lastTerminalInputInstruction = instructions; return;
                }
                if (lineLength < 0) { Fail(UserFault.SystemCall()); return; }
                lastTerminalInputInstruction = instructions;
                if (!memory.WriteByte(heapTop + lineLength, 0)) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                long lineAddress = heapTop;
                heapTop = heapTop + lineLength + 1;
                PushValue(lineAddress); return;
            }
            if (opcode == 58) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long contentsHandle = values[valueCount - 1];
                long outputPathHandle = values[valueCount - 2];
                valueCount = valueCount - 2;
                byte[] outputPath = TextPath(outputPathHandle);
                byte[] outputContents = TextPath(contentsHandle);
                if (outputPath == null || outputContents == null) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                if (calls.WriteAllText(outputPath, outputContents) != UserFileStatus.Ok()) {
                    Fail(UserFault.SystemCall());
                }
                return;
            }
            if (opcode == 59) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long numberHandle = values[valueCount - 1]; valueCount = valueCount - 1;
                int numberPosition = 0; bool negative = false;
                int firstNumberByte = TextByte(numberHandle, numberPosition);
                if (firstNumberByte == 45) {
                    negative = true; numberPosition = numberPosition + 1;
                }
                long number = 0; int digits = 0;
                long numberLimit = 2147483647;
                if (negative) { numberLimit = 2147483648; }
                bool numberDone = false;
                while (!numberDone && numberPosition <= 255) {
                    int numberByte = TextByte(numberHandle, numberPosition);
                    if (numberByte == 0) { numberDone = true; }
                    else if (numberByte < 48 || numberByte > 57 ||
                        number > (numberLimit - (numberByte - 48)) / 10) {
                        Fail(UserFault.Arithmetic()); return;
                    } else {
                        number = number * 10 + numberByte - 48;
                        digits = digits + 1; numberPosition = numberPosition + 1;
                    }
                }
                if (!numberDone || digits == 0) { Fail(UserFault.Arithmetic()); return; }
                if (negative) { number = 0 - number; }
                PushValue(number); return;
            }
            if (opcode == 55) {
                long nameAddress2 = Next32();
                if (nameAddress2 < 0 || valueCount < 2) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long nameIndex2 = values[valueCount - 1];
                long directoryHandle = values[valueCount - 2];
                valueCount = valueCount - 2;
                byte[] directoryPath = TextPath(directoryHandle);
                if (directoryPath == null) { Fail(UserFault.MemoryAccess()); return; }
                accumulator = calls.DirectoryName(directoryPath, nameIndex2,
                    memory, nameAddress2);
                PushValue(accumulator); return;
            }
            if (opcode == 60) {
                long target3 = Next32(); int argumentCount = NextByte();
                if (target3 < 0 || target3 >= memory.CodeLength() ||
                    argumentCount < 0 || argumentCount > valueCount ||
                    callDepth >= returnPointers.Length) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                int firstArgument = valueCount - argumentCount;
                int saved = 0;
                while (saved < locals.Length) {
                    savedLocals[callDepth * 256 + saved] = locals[saved];
                    locals[saved] = 0; saved = saved + 1;
                }
                returnPointers[callDepth] = instructionPointer;
                returnValueDepths[callDepth] = firstArgument;
                callDepth = callDepth + 1;
                int argument = 0;
                while (argument < argumentCount) {
                    locals[argument] = values[firstArgument + argument];
                    argument = argument + 1;
                }
                valueCount = firstArgument;
                instructionPointer = (int)target3; return;
            }
            if (opcode == 61 || opcode == 62) {
                if (callDepth < 1 || (opcode == 61 && valueCount < 1)) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long returned = 0;
                if (opcode == 61) { returned = values[valueCount - 1]; }
                callDepth = callDepth - 1;
                int restored = 0;
                while (restored < locals.Length) {
                    locals[restored] = savedLocals[callDepth * 256 + restored];
                    restored = restored + 1;
                }
                instructionPointer = returnPointers[callDepth];
                valueCount = returnValueDepths[callDepth];
                if (opcode == 61) { PushValue(returned); }
                return;
            }
            if (opcode == 63) {
                int selector = NextByte();
                if (selector < 0) { Fail(UserFault.InvalidInstruction()); return; }
                UserSyscallResult information = calls.SystemInformation(selector);
                if (information.Status() == UserSyscallStatus.Success()) {
                    PushValue(information.Value());
                } else { PushValue(0 - information.Status()); }
                return;
            }
            if (opcode == 64) {
                long requestedBase = Next32();
                if (requestedBase < staticDataEnd || !memory.CanWrite(requestedBase, 0) ||
                    valueCount < 1 || arrayCount >= arrayAddresses.Length ||
                    (heapBase != 0 && heapBase != requestedBase)) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                if (heapBase == 0) { heapBase = requestedBase; heapTop = heapBase; }
                long length = values[valueCount - 1]; valueCount = valueCount - 1;
                if (length < 0 || length > 4096) { Fail(UserFault.MemoryAccess()); return; }
                int allocation = (int)length;
                if (allocation == 0) { allocation = 1; }
                if (!memory.CanWrite(heapTop, allocation)) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                arrayAddresses[arrayCount] = heapTop;
                arrayLengths[arrayCount] = (int)length;
                arrayCount = arrayCount + 1;
                long arrayAddress = heapTop; heapTop = heapTop + allocation;
                PushValue(arrayAddress); return;
            }
            if (opcode == 65 || opcode == 66 || opcode == 67) {
                int required = 1;
                if (opcode == 66) { required = 2; }
                if (opcode == 67) { required = 3; }
                if (valueCount < required) { Fail(UserFault.InvalidInstruction()); return; }
                long handle = values[valueCount - required];
                int array = ArrayIndex(handle);
                if (array < 0) { Fail(UserFault.MemoryAccess()); return; }
                if (opcode == 65) {
                    values[valueCount - 1] = arrayLengths[array]; return;
                }
                long index = values[valueCount - required + 1];
                if (index < 0 || index >= arrayLengths[array]) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                valueCount = valueCount - required;
                if (opcode == 66) {
                    PushValue(memory.ReadByte(handle + index)); return;
                }
                long byteValue = values[valueCount + 2];
                if (byteValue < 0 || byteValue > 255 ||
                    !memory.WriteByte(handle + index, (int)byteValue)) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                PushValue(byteValue); return;
            }
            if (opcode == 68) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long childPathHandle = values[valueCount - 1];
                valueCount = valueCount - 1;
                byte[] childPath = TextPath(childPathHandle);
                if (childPath == null) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(calls.RunChild(childPath,
                    new UserArguments(new byte[0], new int[0], new int[0], 0))); return;
            }
            if (opcode == 69) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long childHandle = values[valueCount - 2];
                long argumentHandle = values[valueCount - 1];
                valueCount = valueCount - 2;
                byte[] executablePath = TextPath(childHandle);
                int argumentArray = ArrayIndex(argumentHandle);
                if (executablePath == null || argumentArray < 0 ||
                    arrayLengths[argumentArray] > 256) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                int length = arrayLengths[argumentArray];
                if (length < 1) { PushValue(-1); return; }
                int count = memory.ReadByte(argumentHandle);
                if (count < 0 || count > 16) { PushValue(-1); return; }
                byte[] encoded = new byte[length];
                int[] starts = new int[16]; int[] sizes = new int[16];
                int index = 0; int cursor = 1;
                while (index < count) {
                    starts[index] = cursor;
                    while (cursor < length && memory.ReadByte(argumentHandle + cursor) != 0) {
                        encoded[cursor] = (byte)memory.ReadByte(argumentHandle + cursor);
                        cursor = cursor + 1;
                    }
                    if (cursor == length) { PushValue(-1); return; }
                    sizes[index] = cursor - starts[index];
                    index = index + 1; cursor = cursor + 1;
                }
                PushValue(calls.RunChild(executablePath,
                    new UserArguments(encoded, starts, sizes, count))); return;
            }
            if (opcode == 83) {
                if (valueCount < 3) { Fail(UserFault.InvalidInstruction()); return; }
                long childHandle = values[valueCount - 3];
                long argumentHandle = values[valueCount - 2];
                long contextHandle = values[valueCount - 1];
                valueCount = valueCount - 3;
                byte[] executablePath = TextPath(childHandle);
                int argumentArray = ArrayIndex(argumentHandle);
                int contextArray = ArrayIndex(contextHandle);
                if (executablePath == null || argumentArray < 0 ||
                    contextArray < 0 || arrayLengths[argumentArray] > 256 ||
                    arrayLengths[contextArray] > 2048 ||
                    arrayLengths[contextArray] < 4) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                int argumentLength = arrayLengths[argumentArray];
                int argumentCount = memory.ReadByte(argumentHandle);
                if (argumentCount < 0 || argumentCount > 16) {
                    PushValue(-4); return;
                }
                byte[] argumentBytes = new byte[argumentLength];
                int[] argumentStarts = new int[16]; int[] argumentSizes = new int[16];
                int argumentCursor = 1; int argumentIndex = 0;
                while (argumentIndex < argumentCount) {
                    argumentStarts[argumentIndex] = argumentCursor;
                    while (argumentCursor < argumentLength &&
                        memory.ReadByte(argumentHandle + argumentCursor) != 0) {
                        argumentBytes[argumentCursor] =
                            (byte)memory.ReadByte(argumentHandle + argumentCursor);
                        argumentCursor = argumentCursor + 1;
                    }
                    if (argumentCursor >= argumentLength) {
                        PushValue(-4); return;
                    }
                    argumentSizes[argumentIndex] = argumentCursor - argumentStarts[argumentIndex];
                    argumentIndex = argumentIndex + 1; argumentCursor = argumentCursor + 1;
                }
                int environmentCount = memory.ReadByte(contextHandle);
                int directoryLength = memory.ReadByte(contextHandle + 1);
                int contextLength = arrayLengths[contextArray];
                if (environmentCount < 0 || environmentCount > 16 ||
                    directoryLength < 1 || directoryLength > 255 ||
                    directoryLength + 2 > contextLength ||
                    memory.ReadByte(contextHandle + 2) != 47) {
                    PushValue(-4); return;
                }
                byte[] directory = new byte[directoryLength]; int c = 0;
                while (c < directoryLength) {
                    int value = memory.ReadByte(contextHandle + 2 + c);
                    if (value < 1) {
                        PushValue(-4); return;
                    }
                    directory[c] = (byte)value; c = c + 1;
                }
                byte[] environmentBytes = new byte[contextLength];
                int[] environmentStarts = new int[16];
                int[] environmentSizes = new int[16];
                int cursor = directoryLength + 2; int entry = 0;
                while (entry < environmentCount) {
                    environmentStarts[entry] = cursor;
                    while (cursor < contextLength &&
                        memory.ReadByte(contextHandle + cursor) != 0) {
                        environmentBytes[cursor] = (byte)memory.ReadByte(contextHandle + cursor);
                        cursor = cursor + 1;
                    }
                    if (cursor >= contextLength ||
                        cursor - environmentStarts[entry] > 255) {
                        PushValue(-4); return;
                    }
                    environmentSizes[entry] = cursor - environmentStarts[entry];
                    entry = entry + 1; cursor = cursor + 1;
                }
                int childResult = calls.RunChildWithContext(executablePath,
                    new UserArguments(argumentBytes, argumentStarts, argumentSizes,
                        argumentCount),
                    new UserArguments(environmentBytes, environmentStarts,
                        environmentSizes, environmentCount), directory);
                PushValue(childResult); return;
            }
            if (opcode == 84) {
                PushValue(startRecord.Environment().Count()); return;
            }
            if (opcode == 85) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long index = values[valueCount - 1]; valueCount = valueCount - 1;
                if (index < 0 || index >= startRecord.Environment().Count()) {
                    PushValue(0); return;
                }
                long table = UserAddressSpace.StartBase() + 192 + index * 8;
                long pointer = memory.ReadByte(table) + memory.ReadByte(table + 1) * 256 +
                    memory.ReadByte(table + 2) * 65536 +
                    (long)memory.ReadByte(table + 3) * 16777216;
                PushValue(pointer); return;
            }
            if (opcode == 86) {
                long table2 = UserAddressSpace.StartBase() + 20;
                long pointer2 = memory.ReadByte(table2) + memory.ReadByte(table2 + 1) * 256 +
                    memory.ReadByte(table2 + 2) * 65536 +
                    (long)memory.ReadByte(table2 + 3) * 16777216;
                PushValue(pointer2); return;
            }
            if (opcode == 87) {
                if (calls.TerminalEndOfInput()) { PushValue(1); }
                else { PushValue(0); }
                return;
            }
            if (opcode == 88) {
                int key = calls.ReadKey();
                if (key == -3) {
                    instructionPointer = instructionPointer - 1;
                    lastTerminalInputInstruction = instructions; return;
                }
                lastTerminalInputInstruction = instructions;
                PushValue(key); return;
            }
            if (opcode == 89) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long row = values[valueCount - 2];
                long column = values[valueCount - 1]; valueCount = valueCount - 2;
                if (row < 1 || row > 200 || column < 1 || column > 200 ||
                    !calls.MoveCursor((int)row, (int)column)) {
                    Fail(UserFault.SystemCall());
                }
                return;
            }
            if (opcode == 90) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long buffer = values[valueCount - 1]; valueCount = valueCount - 1;
                int array = ArrayIndex(buffer);
                if (array < 0 || arrayLengths[array] > 4096) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                int i = 0;
                while (i < arrayLengths[array]) {
                    int value = memory.ReadByte(buffer + i);
                    if (value < 0 || !calls.WriteTextByte(value)) {
                        Fail(UserFault.SystemCall()); return;
                    }
                    i = i + 1;
                }
                return;
            }
            if (opcode == 91) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long childPathHandle = values[valueCount - 1];
                valueCount = valueCount - 1;
                byte[] childPath = TextPath(childPathHandle);
                if (childPath == null) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(calls.SpawnChild(childPath)); return;
            }
            if (opcode == 92) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long childPid = values[valueCount - 1];
                valueCount = valueCount - 1;
                if (childPid < 1 || childPid > 2147483647) {
                    PushValue(-4); return;
                }
                PushValue(calls.WaitChild((int)childPid)); return;
            }
            if (opcode == 93) {
                PushValue(calls.MarkReady()); return;
            }
            if (opcode == 94) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long childPid = values[valueCount - 2];
                long maxRounds = values[valueCount - 1];
                valueCount = valueCount - 2;
                if (childPid < 1 || childPid > 2147483647 ||
                    maxRounds < 1 || maxRounds > 100000) { PushValue(-4); return; }
                PushValue(calls.WaitReadyChild((int)childPid, (int)maxRounds)); return;
            }
            if (opcode == 95) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long childPid = values[valueCount - 1]; valueCount = valueCount - 1;
                if (childPid < 1 || childPid > 2147483647) { PushValue(-4); return; }
                PushValue(calls.TerminateChild((int)childPid)); return;
            }
            if (opcode == 96) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long milliseconds = values[valueCount - 1]; valueCount = valueCount - 1;
                if (milliseconds < 1 || milliseconds > 60000) {
                    PushValue(-4); return;
                }
                PushValue(calls.Sleep((int)milliseconds)); return;
            }
            if (opcode == 97) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long peer = values[valueCount - 2];
                long version = values[valueCount - 1]; valueCount = valueCount - 2;
                if (peer < 1 || peer > 2147483647 || version < 1 || version > 255) {
                    PushValue(-4); return;
                }
                PushValue(calls.ChannelOpen((int)peer, (int)version)); return;
            }
            if (opcode == 98) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long version = values[valueCount - 1]; valueCount = valueCount - 1;
                if (version < 1 || version > 255) { PushValue(-4); return; }
                PushValue(calls.ChannelAccept((int)version)); return;
            }
            if (opcode == 99) {
                if (valueCount < 3) { Fail(UserFault.InvalidInstruction()); return; }
                long handle = values[valueCount - 3];
                long version = values[valueCount - 2];
                long address = values[valueCount - 1]; valueCount = valueCount - 3;
                int array = ArrayIndex(address);
                if (handle < 1 || handle > 2147483647 || version < 1 ||
                    version > 255 || array < 0 || arrayLengths[array] > 256) {
                    PushValue(-4); return;
                }
                int count = arrayLengths[array]; byte[] payload = new byte[count];
                int i = 0;
                while (i < count) {
                    int value = memory.ReadByte(address + i);
                    if (value < 0) { Fail(UserFault.MemoryAccess()); return; }
                    payload[i] = (byte)value; i = i + 1;
                }
                PushValue(calls.ChannelSend((int)handle, (int)version,
                    payload, count)); return;
            }
            if (opcode == 100) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long handle = values[valueCount - 2];
                long address = values[valueCount - 1]; valueCount = valueCount - 2;
                int array = ArrayIndex(address);
                if (handle < 1 || handle > 2147483647 || array < 0 ||
                    arrayLengths[array] > 256) { PushValue(-4); return; }
                byte[] payload = new byte[arrayLengths[array]];
                int result = calls.ChannelReceive((int)handle, payload);
                if (result > 0) {
                    int i = 0;
                    while (i < result) {
                        if (!memory.WriteByte(address + i, payload[i])) {
                            Fail(UserFault.MemoryAccess()); return;
                        }
                        i = i + 1;
                    }
                }
                PushValue(result); return;
            }
            if (opcode == 101) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long handle = values[valueCount - 2];
                long rounds = values[valueCount - 1]; valueCount = valueCount - 2;
                if (handle < 1 || handle > 2147483647 || rounds < 1 ||
                    rounds > 100000) { PushValue(-4); return; }
                PushValue(calls.ChannelWait((int)handle, (int)rounds)); return;
            }
            if (opcode == 102 || opcode == 103) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long handle = values[valueCount - 1]; valueCount = valueCount - 1;
                if (handle < 1 || handle > 2147483647) { PushValue(-4); return; }
                if (opcode == 102) { PushValue(calls.ChannelPeer((int)handle)); }
                else { PushValue(calls.ChannelClose((int)handle)); }
                return;
            }
            if (opcode == 70) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long offset = values[valueCount - 1];
                long handle = values[valueCount - 2];
                valueCount = valueCount - 2;
                if (offset < 0 || offset > 255) { Fail(UserFault.MemoryAccess()); return; }
                int value = TextByte(handle, (int)offset);
                if (value < 0) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(value); return;
            }
            if (opcode == 71) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long length = values[valueCount - 1];
                long handle = values[valueCount - 2];
                valueCount = valueCount - 2;
                int array = ArrayIndex(handle);
                if (array < 0 || length < 0 || length > 255 ||
                    length >= arrayLengths[array] ||
                    !memory.WriteByte(handle + length, 0)) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                PushValue(handle); return;
            }
            if (opcode == 72) {
                if (!calls.WriteTextByte(27) || !calls.WriteTextByte(91) ||
                    !calls.WriteTextByte(50) || !calls.WriteTextByte(74) ||
                    !calls.WriteTextByte(27) || !calls.WriteTextByte(91) ||
                    !calls.WriteTextByte(72)) { Fail(UserFault.SystemCall()); }
                return;
            }
            if (opcode == 73 || opcode == 74) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long pathHandle = values[valueCount - 1]; valueCount = valueCount - 1;
                byte[] path = TextPath(pathHandle);
                if (path == null) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(calls.OpenChecked(path, opcode == 74)); return;
            }
            if (opcode == 75 || opcode == 76) {
                if (valueCount < 3) { Fail(UserFault.InvalidInstruction()); return; }
                long descriptor = values[valueCount - 3];
                long buffer = values[valueCount - 2];
                long length = values[valueCount - 1];
                valueCount = valueCount - 3;
                int array = ArrayIndex(buffer);
                if (descriptor < 3 || descriptor > 18 || array < 0 || length < 0 ||
                    length > arrayLengths[array] || length > 4096) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                if (opcode == 75) {
                    PushValue(calls.ReadChecked((int)descriptor, memory, buffer,
                        (int)length));
                } else {
                    PushValue(calls.WriteOpen((int)descriptor, memory, buffer,
                        (int)length, true));
                }
                return;
            }
            if (opcode == 77) {
                if (valueCount < 1) { Fail(UserFault.InvalidInstruction()); return; }
                long descriptor2 = values[valueCount - 1]; valueCount = valueCount - 1;
                if (descriptor2 < 3 || descriptor2 > 18) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                PushValue(calls.CloseChecked((int)descriptor2)); return;
            }
            if (opcode == 78) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long descriptor3 = values[valueCount - 2];
                long size = values[valueCount - 1]; valueCount = valueCount - 2;
                if (descriptor3 < 3 || descriptor3 > 18 || size < 0) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                PushValue(calls.TruncateOpen((int)descriptor3, size)); return;
            }
            if (opcode == 79) {
                if (valueCount < 3) { Fail(UserFault.InvalidInstruction()); return; }
                long pathHandle2 = values[valueCount - 3];
                long index2 = values[valueCount - 2];
                long output = values[valueCount - 1]; valueCount = valueCount - 3;
                byte[] path2 = TextPath(pathHandle2);
                int outputArray = ArrayIndex(output);
                if (path2 == null || outputArray < 0 ||
                    arrayLengths[outputArray] < 64) {
                    Fail(UserFault.MemoryAccess()); return;
                }
                int nameLength = calls.DirectoryName(path2, index2, memory, output);
                if (nameLength >= 0 && nameLength < 64) {
                    memory.WriteByte(output + nameLength, 0);
                }
                PushValue(nameLength); return;
            }
            if (opcode == 80) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long createPath = values[valueCount - 2];
                long createData = values[valueCount - 1]; valueCount = valueCount - 2;
                byte[] path3 = TextPath(createPath);
                byte[] data = TextPath(createData);
                if (path3 == null || data == null) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(calls.CreateDynamic(path3, data)); return;
            }
            if (opcode == 81) {
                int action = NextByte();
                if (action < 0 || action > 2 || valueCount < 1) {
                    Fail(UserFault.InvalidInstruction()); return;
                }
                long mutatePath = values[valueCount - 1]; valueCount = valueCount - 1;
                byte[] path4 = TextPath(mutatePath);
                if (path4 == null) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(calls.MutateDynamic(path4, action)); return;
            }
            if (opcode == 82) {
                if (valueCount < 2) { Fail(UserFault.InvalidInstruction()); return; }
                long fromHandle = values[valueCount - 2];
                long toHandle = values[valueCount - 1]; valueCount = valueCount - 2;
                byte[] from = TextPath(fromHandle); byte[] to = TextPath(toHandle);
                if (from == null || to == null) { Fail(UserFault.MemoryAccess()); return; }
                PushValue(calls.RenameDynamic(from, to)); return;
            }
            Fail(UserFault.InvalidInstruction());
        }
    }

    public class UserProgramResult {
        private int pid;
        private int state;
        private int exitCode;
        private int fault;
        private long instructions;
        public UserProgramResult(int inputState, int inputExit, int inputFault, long inputInstructions) {
            Initialize(0, inputState, inputExit, inputFault, inputInstructions);
        }
        public UserProgramResult(int inputPid, int inputState, int inputExit,
            int inputFault, long inputInstructions) {
            Initialize(inputPid, inputState, inputExit, inputFault, inputInstructions);
        }
        private void Initialize(int inputPid, int inputState, int inputExit,
            int inputFault, long inputInstructions) {
            pid = inputPid; state = inputState; exitCode = inputExit;
            fault = inputFault; instructions = inputInstructions;
        }
        public int Pid() { return pid; }
        public int State() { return state; }
        public int ExitCode() { return exitCode; }
        public int Fault() { return fault; }
        public long Instructions() { return instructions; }
    }

    public class UserScheduler {
        private int quantum;
        private long instructionLimit;
        public UserScheduler() { quantum = 32; instructionLimit = 100000; }

        public UserProgramResult Run(UserProcess process) {
            if (process == null) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            while (process.State() == UserProgramState.Running() &&
                process.InstructionsSinceTerminalInput() < instructionLimit) {
                int used = 0;
                while (used < quantum && process.State() == UserProgramState.Running()) {
                    process.Step(); used = used + 1;
                }
            }
            if (process.State() == UserProgramState.Running()) {
                process.Abort(UserFault.InstructionLimit());
            }
            return new UserProgramResult(process.State(), process.ExitCode(),
                process.Fault(), process.Instructions());
        }
    }

    public class UserProgramHost {
        private IUserTerminal terminal;
        private IUserFiles files;
        private int[] systemInformation;
        private IUserChildLauncher childLauncher;
        private int nextPid;
        private int[] pids;
        private UserProcess[] processes;
        private IUserFiles[] processFiles;
        private UserProgramResult[] results;
        private bool[] blocked;
        private bool[] ready;
        private long[] wakeDeadlines;
        private long roundClock;
        private int nextSlot;
        public UserProgramHost(IUserTerminal inputTerminal, IUserFiles inputFiles) {
            Initialize(inputTerminal, inputFiles, null);
        }
        public UserProgramHost(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int[] inputSystemInformation) {
            Initialize(inputTerminal, inputFiles, inputSystemInformation);
        }
        public UserProgramHost(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int[] inputSystemInformation, IUserChildLauncher inputChildLauncher,
            int firstPid) {
            Initialize(inputTerminal, inputFiles, inputSystemInformation);
            childLauncher = inputChildLauncher;
            nextPid = firstPid;
        }
        private void Initialize(IUserTerminal inputTerminal, IUserFiles inputFiles,
            int[] inputSystemInformation) {
            terminal = inputTerminal; files = inputFiles;
            systemInformation = inputSystemInformation;
            childLauncher = null;
            nextPid = 1; nextSlot = 0;
            pids = new int[16]; processes = new UserProcess[16];
            processFiles = new IUserFiles[16]; results = new UserProgramResult[16];
            blocked = new bool[16];
            ready = new bool[16];
            wakeDeadlines = new long[16]; roundClock = 0;
        }

        public UserProgramResult Run(UserExecutable executable) {
            return Run(executable,
                new UserArguments(new byte[0], new int[0], new int[0], 0));
        }
        public int NextPid() { return nextPid; }
        // Native processes share the PID sequence even when they do not use
        // the AUEX instruction scheduler.
        public int ReservePid() {
            if (nextPid < 1 || nextPid >= 2147483647) { return -1; }
            int reserved = nextPid; nextPid = nextPid + 1;
            return reserved;
        }

        public UserProgramResult Run(UserExecutable executable, UserArguments arguments) {
            return Run(executable, new UserProcessStart(arguments));
        }
        public UserProgramResult Run(UserExecutable executable, UserProcessStart start) {
            int pid = SpawnForeground(executable, start);
            if (pid < 1) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            return Wait(pid);
        }
        public int SpawnForeground(UserExecutable executable, UserProcessStart start) {
            int i = 0;
            while (i < pids.Length) {
                if (pids[i] != 0) { return -1; }
                i = i + 1;
            }
            return SpawnRunnable(executable, start, files);
        }
        public int SpawnRunnable(UserExecutable executable, UserProcessStart start,
            IUserFiles isolatedFiles) {
            return SpawnRunnable(executable, start, isolatedFiles, systemInformation);
        }
        public int SpawnRunnable(UserExecutable executable, UserProcessStart start,
            IUserFiles isolatedFiles, int[] processInformation) {
            if (isolatedFiles == null || executable == null || !executable.IsValid() ||
                start == null || !start.IsValid() || nextPid < 1 ||
                nextPid >= 2147483647) { return -1; }
            int slot = 0;
            while (slot < pids.Length && pids[slot] != 0) { slot = slot + 1; }
            if (slot == pids.Length) { return -1; }
            UserSystemCalls calls = new UserSystemCalls(terminal, isolatedFiles, nextPid,
                processInformation, childLauncher);
            UserProcess process = new UserProcess(executable, calls, start);
            if (process.State() == UserProgramState.Faulted()) { return -1; }
            processes[slot] = process; processFiles[slot] = isolatedFiles;
            pids[slot] = nextPid; results[slot] = null;
            blocked[slot] = false;
            ready[slot] = false;
            wakeDeadlines[slot] = 0;
            nextPid = nextPid + 1;
            if (processInformation != null && processInformation.Length >= 46) {
                processInformation[40] = pids[slot];
            }
            return pids[slot];
        }
        public bool Block(int pid) {
            int i = 0;
            while (i < pids.Length) {
                if (pids[i] == pid && processes[i] != null) {
                    blocked[i] = true; return true;
                }
                i = i + 1;
            }
            return false;
        }
        public int MarkReady(int pid) {
            int i = 0;
            while (i < pids.Length) {
                if (pids[i] == pid && processes[i] != null) {
                    ready[i] = true; return 0;
                }
                i = i + 1;
            }
            return -4;
        }
        public int Terminate(int pid) {
            int slot = 0;
            while (slot < pids.Length && pids[slot] != pid) { slot = slot + 1; }
            if (pid < 1 || slot == pids.Length || processes[slot] == null) { return -4; }
            UserProcess process = processes[slot];
            process.Abort(UserFault.Terminated());
            results[slot] = new UserProgramResult(pid, process.State(),
                process.ExitCode(), process.Fault(), process.Instructions());
            if (processFiles[slot] != null) { processFiles[slot].CloseAll(); }
            processFiles[slot] = null; processes[slot] = null;
            wakeDeadlines[slot] = 0;
            if (childLauncher != null) { childLauncher.ProcessExited(results[slot]); }
            return 0;
        }
        public int Sleep(int pid, int milliseconds) {
            if (pid < 1 || milliseconds < 1 || milliseconds > 60000) { return -4; }
            int slot = 0;
            while (slot < pids.Length && pids[slot] != pid) { slot = slot + 1; }
            if (slot == pids.Length || processes[slot] == null) { return -4; }
            long deadline = roundClock + milliseconds;
            if (childLauncher != null) {
                deadline = childLauncher.ClockDeadlineAfter(milliseconds);
            }
            if (deadline <= 0) { return -4; }
            wakeDeadlines[slot] = deadline; blocked[slot] = true;
            return 0;
        }
        public int WaitReady(int pid, int maxRounds) {
            int slot = 0;
            while (slot < pids.Length && pids[slot] != pid) { slot = slot + 1; }
            if (pid < 1 || slot == pids.Length || maxRounds < 1 ||
                maxRounds > 100000) { return -4; }
            int round = 0;
            while (round < maxRounds && !ready[slot] && results[slot] == null) {
                if (RunRound() == 0) { break; }
                round = round + 1;
            }
            if (ready[slot]) { return 0; }
            if (results[slot] != null) { return -1; }
            return -2;
        }
        public void Unblock(int pid) {
            int i = 0;
            while (i < pids.Length) {
                if (pids[i] == pid) { blocked[i] = false; return; }
                i = i + 1;
            }
        }
        public long Instructions(int pid) {
            int i = 0;
            while (i < pids.Length) {
                if (pids[i] == pid && processes[i] != null) {
                    return processes[i].Instructions();
                }
                if (pids[i] == pid && results[i] != null) {
                    return results[i].Instructions();
                }
                i = i + 1;
            }
            return -1;
        }
        // One bounded quantum per runnable process; a caller may step or wait.
        public int RunRound() {
            if (roundClock < 2147483647) { roundClock = roundClock + 1; }
            long now = roundClock;
            if (childLauncher != null) { now = childLauncher.ClockNow(); }
            int visited = 0; int ran = 0; int sleepers = 0;
            while (visited < processes.Length) {
                int slot = (nextSlot + visited) % processes.Length;
                UserProcess process = processes[slot];
                if (process != null && wakeDeadlines[slot] > 0) {
                    if (now >= wakeDeadlines[slot]) {
                        wakeDeadlines[slot] = 0; blocked[slot] = false;
                    } else { sleepers = sleepers + 1; }
                }
                if (process != null && !blocked[slot]) {
                    int used = 0;
                    while (used < 32 && !blocked[slot] &&
                        process.State() == UserProgramState.Running()) {
                        process.Step(); used = used + 1;
                    }
                    if (process.State() == UserProgramState.Running() &&
                        process.InstructionsSinceTerminalInput() >= 100000) {
                        process.Abort(UserFault.InstructionLimit());
                    }
                    if (process.State() != UserProgramState.Running()) {
                        results[slot] = new UserProgramResult(pids[slot], process.State(),
                            process.ExitCode(), process.Fault(), process.Instructions());
                        if (processFiles[slot] != null) { processFiles[slot].CloseAll(); }
                        processFiles[slot] = null; processes[slot] = null;
                        wakeDeadlines[slot] = 0;
                        if (childLauncher != null) {
                            childLauncher.ProcessExited(results[slot]);
                        }
                    }
                    ran = ran + 1;
                }
                visited = visited + 1;
            }
            nextSlot = (nextSlot + 1) % processes.Length;
            if (childLauncher != null) { ran = ran + childLauncher.RunNativeRound(); }
            if (ran == 0 && sleepers > 0) { return 1; }
            return ran;
        }
        public UserProgramResult Wait(int pid) {
            int slot = 0;
            while (slot < pids.Length && pids[slot] != pid) { slot = slot + 1; }
            if (pid < 1 || slot == pids.Length) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            while (results[slot] == null) {
                if (RunRound() == 0) {
                    return new UserProgramResult(UserProgramState.Faulted(), -1,
                        UserFault.InvalidImage(), 0);
                }
            }
            UserProgramResult finished = results[slot];
            if (systemInformation != null && systemInformation.Length >= 46 &&
                systemInformation[40] == pid) {
                systemInformation[40] = 0;
            }
            pids[slot] = 0; results[slot] = null;
            blocked[slot] = false;
            ready[slot] = false;
            wakeDeadlines[slot] = 0;
            return finished;
        }
    }
}
