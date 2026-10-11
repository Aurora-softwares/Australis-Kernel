using Australis.Kernel.Storage;

namespace Australis.User {
    // Terminal syscalls use this byte contract on both the hosted tests and
    // the live kernel. ReadByte is called only from scheduler context; an IRQ
    // handler may fill a device queue, but it never executes a user program.
    public interface IUserTerminal {
        int ReadByte();
        bool WriteByte(int value);
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
        public static int IoFailure() { return 6; }
        public static int Corrupt() { return 7; }
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

        public static long CodeBase() { return 4194304; }
        public static long DataBase() { return 5242880; }

        public UserAddressSpace(UserExecutable executable) {
            code = new byte[executable.Code().Length];
            data = new byte[executable.DataCapacity()];
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
            if (count < 0 || address < DataBase()) { return false; }
            long offset = address - DataBase();
            return offset <= data.Length && count <= data.Length - offset;
        }
        public bool CanWrite(long address, int count) { return CanRead(address, count); }
        public int ReadByte(long address) {
            if (!CanRead(address, 1)) { return -1; }
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
            while (i < count) { destination[i] = data[offset + i]; i = i + 1; }
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

    public class UserSystemCalls {
        private IUserTerminal terminal;
        private IUserFiles files;
        private int lastFileStatus;

        public UserSystemCalls(IUserTerminal inputTerminal, IUserFiles inputFiles) {
            terminal = inputTerminal;
            files = inputFiles;
            lastFileStatus = UserFileStatus.Ok();
        }

        public int LastFileStatus() { return lastFileStatus; }

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
            if (files == null || path == null || selector < 0 || selector > 6) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            UserFileInfo info = files.Stat(path, count);
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
            if (files == null || path == null) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            UserDirectoryInfo result = files.DirectoryCount(path, count);
            if (result == null) { lastFileStatus = UserFileStatus.Corrupt(); return -1; }
            lastFileStatus = result.Status();
            if (lastFileStatus != UserFileStatus.Ok()) { return -1; }
            return result.Count();
        }

        public int DirectoryName(UserAddressSpace memory, long pathAddress,
            int pathCount, long index, long destination) {
            byte[] path = Path(memory, pathAddress, pathCount);
            if (files == null || path == null || index < 0 || index > 2147483647 ||
                !memory.CanWrite(destination, 64)) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            byte[] name = new byte[64];
            int length = files.DirectoryName(path, pathCount, (int)index, name);
            if (length < 0) { lastFileStatus = -length; return -1; }
            if (length > 63 || !memory.CopyIn(destination, name, length)) {
                lastFileStatus = UserFileStatus.Corrupt(); return -1;
            }
            lastFileStatus = UserFileStatus.Ok(); return length;
        }

        public int OpenChecked(UserAddressSpace memory, long address, int count,
            bool write) {
            byte[] path = Path(memory, address, count);
            if (files == null || path == null) {
                lastFileStatus = UserFileStatus.InvalidArgument(); return -1;
            }
            int descriptor = -1;
            if (write) { descriptor = files.OpenWrite(path, count); }
            else { descriptor = files.Open(path, count); }
            if (descriptor < 3) {
                lastFileStatus = -descriptor;
                if (lastFileStatus == 0) { lastFileStatus = UserFileStatus.Corrupt(); }
                return -1;
            }
            lastFileStatus = UserFileStatus.Ok(); return descriptor;
        }

        public int ReadChecked(int descriptor, UserAddressSpace memory,
            long address, int capacity) {
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
            lastFileStatus = UserFileStatus.Ok(); return length;
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
            if (terminal == null || memory == null || capacity < 1 ||
                !memory.CanWrite(address, capacity)) { return -1; }
            int length = 0;
            while (true) {
                int value = terminal.ReadByte();
                if (value < 0) { return -1; }
                if (value == 3) { return -2; }
                if (value == 10 || value == 13) {
                    terminal.WriteByte(13); terminal.WriteByte(10); return length;
                }
                if (value == 8 || value == 127) {
                    if (length > 0) {
                        length = length - 1;
                        terminal.WriteByte(8); terminal.WriteByte(32); terminal.WriteByte(8);
                    }
                } else if (value >= 32 && value <= 126 && length < capacity) {
                    if (!memory.WriteByte(address + length, value)) { return -1; }
                    length = length + 1; terminal.WriteByte(value);
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
        private long[] values;
        private int valueCount;
        private long[] locals;

        public UserProcess(UserExecutable executable, UserSystemCalls systemCalls) {
            calls = systemCalls; instructionPointer = 0; fault = UserFault.InvalidImage();
            exitCode = -1; accumulator = 0; openDescriptor = -1; instructions = 0;
            values = new long[256]; valueCount = 0; locals = new long[256];
            if (executable == null || !executable.IsValid() || calls == null) {
                memory = null; state = UserProgramState.Faulted(); return;
            }
            memory = new UserAddressSpace(executable);
            instructionPointer = executable.Entry(); state = UserProgramState.Running();
            fault = UserFault.None();
        }

        public int State() { return state; }
        public int Fault() { return fault; }
        public int ExitCode() { return exitCode; }
        public int Accumulator() { return accumulator; }
        public long Instructions() { return instructions; }
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
                if (accumulator < 0) { Fail(UserFault.SystemCall()); }
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
            Fail(UserFault.InvalidInstruction());
        }
    }

    public class UserProgramResult {
        private int state;
        private int exitCode;
        private int fault;
        private long instructions;
        public UserProgramResult(int inputState, int inputExit, int inputFault, long inputInstructions) {
            state = inputState; exitCode = inputExit; fault = inputFault; instructions = inputInstructions;
        }
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
                process.Instructions() < instructionLimit) {
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
        public UserProgramHost(IUserTerminal inputTerminal, IUserFiles inputFiles) {
            terminal = inputTerminal; files = inputFiles;
        }

        public UserProgramResult Run(UserExecutable executable) {
            if (executable == null) {
                return new UserProgramResult(UserProgramState.Faulted(), -1,
                    UserFault.InvalidImage(), 0);
            }
            UserSystemCalls calls = new UserSystemCalls(terminal, files);
            UserProcess process = new UserProcess(executable, calls);
            return new UserScheduler().Run(process);
        }
    }
}
