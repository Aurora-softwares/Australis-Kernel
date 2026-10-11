using Australis.Kernel.Storage;

namespace Australis.Kernel.Vfs {
    // HyFS v1 is the bootstrap filesystem for Australis. It intentionally has
    // a narrow surface: a single flat directory of regular files, no writes,
    // and byte-exact ASCII file names. Every on-disk extent is checked against
    // the partition before I/O, and file reads verify the complete data CRC.
    //
    // Superblock (logical block 0, little-endian):
    //   0..7   "HYFS\r\n\x1a\n"
    //   8      version (1)
    //   12     logical block size (must equal the transport sector size)
    //   16     filesystem block count (must equal the partition block count)
    //   24     directory first block
    //   32     directory block count
    //   36     directory entry count
    //   40     CRC-32 of the complete directory allocation
    //   44     CRC-32 of bytes 0..47 with this field zeroed
    //   48..   reserved and zero
    //
    // Directory entries are fixed 64-byte records:
    //   0 name byte count, 1 kind (1 = regular file), 2..3 flags (zero),
    //   4 first data block, 12 byte length, 20 CRC-32 of complete file data,
    //   24..55 ASCII name bytes, 56..63 reserved and zero.
    public class Hyfs : IFileSystem {
        private BlockDevice device;
        private Partition partition;
        private byte[] directory;
        private int sectorSize;
        private long blockCount;
        private long directoryFirstBlock;
        private int directoryBlockCount;
        private int entryCount;
        private int lastStatus;

        private static int Version() { return 1; }
        private static int EntrySize() { return 64; }
        private static int MaxDirectoryBytes() { return 65536; }

        public Hyfs() { Reset(); }

        public int LastStatus() { return lastStatus; }
        public bool IsMounted() { return device != null; }

        public int DirectorySlotCount() {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return -1; }
            lastStatus = VfsStatus.Ok();
            return entryCount;
        }

        public int CopyDirectoryEntryName(int index, byte[] destination) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return -1; }
            if (index < 0 || index >= entryCount || destination == null) {
                lastStatus = VfsStatus.InvalidArgument(); return -1;
            }
            int offset = index * EntrySize();
            if (directory[offset + 1] != 1) { lastStatus = VfsStatus.Ok(); return 0; }
            int length = directory[offset];
            if (destination.Length < length) { lastStatus = VfsStatus.InvalidArgument(); return -1; }
            int i = 0;
            while (i < length) {
                destination[i] = directory[offset + 24 + i];
                i = i + 1;
            }
            lastStatus = VfsStatus.Ok();
            return length;
        }

        public int DirectorySlotCountAt(string path) {
            if (path == "/") { return DirectorySlotCount(); }
            lastStatus = VfsStatus.NotFound(); return -1;
        }

        public int CopyDirectoryEntryNameAt(string path, int index, byte[] destination) {
            if (path == "/") { return CopyDirectoryEntryName(index, destination); }
            lastStatus = VfsStatus.NotFound(); return -1;
        }

        private void Reset() {
            device = null;
            partition = null;
            directory = null;
            sectorSize = 0;
            blockCount = 0;
            directoryFirstBlock = 0;
            directoryBlockCount = 0;
            entryCount = 0;
            lastStatus = VfsStatus.NotMounted();
        }

        private static long Read16(byte[] bytes, int offset) {
            return bytes[offset] + bytes[offset + 1] * 256;
        }

        private static bool IsMagic(byte[] bytes) {
            return bytes.Length >= 8 && bytes[0] == 72 && bytes[1] == 89 &&
                bytes[2] == 70 && bytes[3] == 83 && bytes[4] == 13 &&
                bytes[5] == 10 && bytes[6] == 26 && bytes[7] == 10;
        }

        private static bool IsPrintableNameByte(int value) {
            return value >= 33 && value <= 126 && value != 47;
        }

        private static bool IsZeroRange(byte[] bytes, int offset, int length) {
            int i = 0;
            while (i < length) {
                if (bytes[offset + i] != 0) { return false; }
                i = i + 1;
            }
            return true;
        }

        private static bool IsEmptyEntry(byte[] bytes, int offset) {
            return IsZeroRange(bytes, offset, EntrySize());
        }

        // Read a path byte without allocating a one-character string. Live
        // user file calls may traverse many paths before the command ends.
        public static int PathByteAt(string path, int index) {
            if (path == null || index < 0 || index >= path.Length) { return -1; }
            int value = System.Kernel.String.ByteAt(path, index);
            if (value < 33 || value > 126) { return -1; }
            return value;
        }

        public static int PathByte(string value) {
            if (value == "!") { return 33; } if (value == "\"") { return 34; }
            if (value == "#") { return 35; } if (value == "$") { return 36; }
            if (value == "%") { return 37; } if (value == "&") { return 38; }
            if (value == "'") { return 39; } if (value == "(") { return 40; }
            if (value == ")") { return 41; } if (value == "*") { return 42; }
            if (value == "+") { return 43; } if (value == ",") { return 44; }
            if (value == "-") { return 45; } if (value == ".") { return 46; }
            if (value == "0") { return 48; } if (value == "1") { return 49; }
            if (value == "2") { return 50; } if (value == "3") { return 51; }
            if (value == "4") { return 52; } if (value == "5") { return 53; }
            if (value == "6") { return 54; } if (value == "7") { return 55; }
            if (value == "8") { return 56; } if (value == "9") { return 57; }
            if (value == ":") { return 58; } if (value == ";") { return 59; }
            if (value == "<") { return 60; } if (value == "=") { return 61; }
            if (value == ">") { return 62; } if (value == "?") { return 63; }
            if (value == "@") { return 64; }
            if (value == "A") { return 65; } if (value == "B") { return 66; }
            if (value == "C") { return 67; } if (value == "D") { return 68; }
            if (value == "E") { return 69; } if (value == "F") { return 70; }
            if (value == "G") { return 71; } if (value == "H") { return 72; }
            if (value == "I") { return 73; } if (value == "J") { return 74; }
            if (value == "K") { return 75; } if (value == "L") { return 76; }
            if (value == "M") { return 77; } if (value == "N") { return 78; }
            if (value == "O") { return 79; } if (value == "P") { return 80; }
            if (value == "Q") { return 81; } if (value == "R") { return 82; }
            if (value == "S") { return 83; } if (value == "T") { return 84; }
            if (value == "U") { return 85; } if (value == "V") { return 86; }
            if (value == "W") { return 87; } if (value == "X") { return 88; }
            if (value == "Y") { return 89; } if (value == "Z") { return 90; }
            if (value == "[") { return 91; } if (value == "\\") { return 92; }
            if (value == "]") { return 93; } if (value == "^") { return 94; }
            if (value == "_") { return 95; } if (value == "`") { return 96; }
            if (value == "a") { return 97; } if (value == "b") { return 98; }
            if (value == "c") { return 99; } if (value == "d") { return 100; }
            if (value == "e") { return 101; } if (value == "f") { return 102; }
            if (value == "g") { return 103; } if (value == "h") { return 104; }
            if (value == "i") { return 105; } if (value == "j") { return 106; }
            if (value == "k") { return 107; } if (value == "l") { return 108; }
            if (value == "m") { return 109; } if (value == "n") { return 110; }
            if (value == "o") { return 111; } if (value == "p") { return 112; }
            if (value == "q") { return 113; } if (value == "r") { return 114; }
            if (value == "s") { return 115; } if (value == "t") { return 116; }
            if (value == "u") { return 117; } if (value == "v") { return 118; }
            if (value == "w") { return 119; } if (value == "x") { return 120; }
            if (value == "y") { return 121; } if (value == "z") { return 122; }
            if (value == "{") { return 123; } if (value == "|") { return 124; }
            if (value == "}") { return 125; } if (value == "~") { return 126; }
            return -1;
        }

        private bool IsPathValid(string path) {
            if (path == null || path.Length < 2 || path.Length > 33 ||
                PathByteAt(path, 0) != 47) { return false; }
            int i = 1;
            while (i < path.Length) {
                if (PathByteAt(path, i) < 0) { return false; }
                i = i + 1;
            }
            return true;
        }

        private bool NamesEqual(int leftOffset, int rightOffset) {
            int leftLength = directory[leftOffset];
            if (leftLength != directory[rightOffset]) { return false; }
            int i = 0;
            while (i < leftLength) {
                if (directory[leftOffset + 24 + i] != directory[rightOffset + 24 + i]) { return false; }
                i = i + 1;
            }
            return true;
        }

        private bool EntryMatchesPath(int entryOffset, string path) {
            int nameLength = directory[entryOffset];
            if (path.Length != nameLength + 1) { return false; }
            int i = 0;
            while (i < nameLength) {
                if (directory[entryOffset + 24 + i] != PathByteAt(path, i + 1)) { return false; }
                i = i + 1;
            }
            return true;
        }

        private int FindEntry(string path) {
            if (!IsPathValid(path)) { return -2; }
            int index = 0;
            while (index < entryCount) {
                int offset = index * EntrySize();
                if (directory[offset + 1] == 1 && EntryMatchesPath(offset, path)) { return index; }
                index = index + 1;
            }
            return -1;
        }

        private bool IsValidEntry(int index, long dataStartBlock) {
            int offset = index * EntrySize();
            int nameLength = directory[offset];
            int kind = directory[offset + 1];
            if (kind == 0) { return IsEmptyEntry(directory, offset); }
            if (kind != 1 || nameLength < 1 || nameLength > 32 || Read16(directory, offset + 2) != 0 ||
                !IsZeroRange(directory, offset + 24 + nameLength, 32 - nameLength) ||
                !IsZeroRange(directory, offset + 56, 8)) { return false; }

            int c = 0;
            while (c < nameLength) {
                if (!IsPrintableNameByte(directory[offset + 24 + c])) { return false; }
                c = c + 1;
            }
            if (directory[offset + 24] == 46 &&
                (nameLength == 1 || (nameLength == 2 && directory[offset + 25] == 46))) { return false; }

            long firstBlock = PartitionBytes.Read64(directory, offset + 4);
            long byteLength = PartitionBytes.Read64(directory, offset + 12);
            long dataCrc = PartitionBytes.Read32(directory, offset + 20);
            if (byteLength < 0) { return false; }

            // An empty file still occupies a name in the flat directory.
            int previous = 0;
            while (previous < index) {
                int previousOffset = previous * EntrySize();
                if (directory[previousOffset + 1] == 1 && NamesEqual(offset, previousOffset)) { return false; }
                previous = previous + 1;
            }
            if (byteLength == 0) { return firstBlock == 0 && dataCrc == 0; }

            long blocks = byteLength / sectorSize;
            if (byteLength % sectorSize != 0) { blocks = blocks + 1; }
            if (firstBlock < dataStartBlock || firstBlock >= blockCount || blocks > blockCount - firstBlock) { return false; }

            previous = 0;
            while (previous < index) {
                int previousOffset = previous * EntrySize();
                if (directory[previousOffset + 1] == 1) {
                    long previousLength = PartitionBytes.Read64(directory, previousOffset + 12);
                    if (previousLength > 0) {
                        long previousFirst = PartitionBytes.Read64(directory, previousOffset + 4);
                        long previousBlocks = previousLength / sectorSize;
                        if (previousLength % sectorSize != 0) { previousBlocks = previousBlocks + 1; }
                        // Extents are canonical and exclusive in HyFS v1.
                        // Every endpoint was bounds-checked before this test,
                        // so each addition is safe and remains in the volume.
                        if (firstBlock < previousFirst + previousBlocks && previousFirst < firstBlock + blocks) { return false; }
                    }
                }
                previous = previous + 1;
            }
            return true;
        }

        public int Mount(BlockDevice inputDevice, Partition inputPartition) {
            Reset();
            if (inputDevice == null || inputPartition == null || !inputPartition.Present() ||
                inputPartition.FirstLba() < 0 || inputPartition.BlockCount() < 3 ||
                inputPartition.FirstLba() >= inputDevice.SectorCount() ||
                inputPartition.BlockCount() > inputDevice.SectorCount() - inputPartition.FirstLba()) {
                lastStatus = VfsStatus.InvalidArgument();
                return lastStatus;
            }

            int inputSectorSize = inputDevice.SectorSize();
            if (inputSectorSize < 512 || inputSectorSize > 4096) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            byte[] superblock = new byte[inputSectorSize];
            if (inputDevice.Read(inputPartition.FirstLba(), 1, superblock) != BlockStatus.Ok()) {
                lastStatus = VfsStatus.IoFailure();
                return lastStatus;
            }

            if (!IsMagic(superblock) || PartitionBytes.Read32(superblock, 8) != Version() ||
                PartitionBytes.Read32(superblock, 12) != inputSectorSize ||
                PartitionBytes.Read64(superblock, 16) != inputPartition.BlockCount() ||
                PartitionBytes.Crc32(superblock, 0, 48, 44, 4) != PartitionBytes.Read32(superblock, 44) ||
                !IsZeroRange(superblock, 48, inputSectorSize - 48)) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            long inputDirectoryFirst = PartitionBytes.Read64(superblock, 24);
            long inputDirectoryBlocksLong = PartitionBytes.Read32(superblock, 32);
            long inputEntryCountLong = PartitionBytes.Read32(superblock, 36);
            if (inputDirectoryFirst < 1 || inputDirectoryBlocksLong < 1 || inputDirectoryBlocksLong > 128 ||
                inputDirectoryFirst >= inputPartition.BlockCount() ||
                inputDirectoryBlocksLong > inputPartition.BlockCount() - inputDirectoryFirst ||
                inputDirectoryBlocksLong > MaxDirectoryBytes() / inputSectorSize) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            int inputDirectoryBlocks = (int)inputDirectoryBlocksLong;
            int directoryBytes = inputDirectoryBlocks * inputSectorSize;
            if (inputEntryCountLong > directoryBytes / EntrySize()) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            byte[] inputDirectory = new byte[directoryBytes];
            long directoryLba = inputPartition.FirstLba() + inputDirectoryFirst;
            if (inputDevice.Read(directoryLba, inputDirectoryBlocks, inputDirectory) != BlockStatus.Ok()) {
                lastStatus = VfsStatus.IoFailure();
                return lastStatus;
            }
            if (PartitionBytes.Crc32(inputDirectory, 0, directoryBytes, directoryBytes, 0) != PartitionBytes.Read32(superblock, 40)) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            int inputEntryCount = (int)inputEntryCountLong;
            if (!IsZeroRange(inputDirectory, inputEntryCount * EntrySize(), directoryBytes - inputEntryCount * EntrySize())) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            device = inputDevice;
            partition = inputPartition;
            directory = inputDirectory;
            sectorSize = inputSectorSize;
            blockCount = inputPartition.BlockCount();
            directoryFirstBlock = inputDirectoryFirst;
            directoryBlockCount = inputDirectoryBlocks;
            entryCount = inputEntryCount;
            long dataStartBlock = directoryFirstBlock + directoryBlockCount;
            int index = 0;
            while (index < entryCount) {
                if (!IsValidEntry(index, dataStartBlock)) {
                    Reset();
                    lastStatus = VfsStatus.MountFailed();
                    return lastStatus;
                }
                index = index + 1;
            }

            lastStatus = VfsStatus.Ok();
            return lastStatus;
        }

        public bool Exists(string path) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return false; }
            int index = FindEntry(path);
            if (index == -2) { lastStatus = VfsStatus.InvalidArgument(); return false; }
            if (index < 0) { lastStatus = VfsStatus.NotFound(); return false; }
            lastStatus = VfsStatus.Ok();
            return true;
        }

        public VfsFileInfo Stat(string path) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return new VfsFileInfo(lastStatus, 0); }
            int index = FindEntry(path);
            if (index == -2) { lastStatus = VfsStatus.InvalidArgument(); return new VfsFileInfo(lastStatus, 0); }
            if (index < 0) { lastStatus = VfsStatus.NotFound(); return new VfsFileInfo(lastStatus, 0); }
            lastStatus = VfsStatus.Ok();
            return new VfsFileInfo(lastStatus, PartitionBytes.Read64(directory, index * EntrySize() + 12));
        }

        private int ReadVerifiedEntry(int index, long requestedOffset, byte[] output) {
            int entryOffset = index * EntrySize();
            long byteLength = PartitionBytes.Read64(directory, entryOffset + 12);
            long expectedCrc = PartitionBytes.Read32(directory, entryOffset + 20);
            if (byteLength == 0) {
                if (expectedCrc != 0) { return VfsStatus.Corrupt(); }
                return VfsStatus.Ok();
            }

            long firstBlock = PartitionBytes.Read64(directory, entryOffset + 4);
            byte[] sector = new byte[sectorSize];
            long crc = PartitionBytes.MaxU32State();
            long scanned = 0;
            long block = 0;
            long requestedEnd = requestedOffset + output.Length;
            while (scanned < byteLength) {
                if (device.Read(partition.FirstLba() + firstBlock + block, 1, sector) != BlockStatus.Ok()) { return VfsStatus.IoFailure(); }
                int validBytes = sectorSize;
                if (byteLength - scanned < validBytes) { validBytes = (int)(byteLength - scanned); }
                crc = PartitionBytes.UpdateCrc32(crc, sector, 0, validBytes);
                if (crc < 0) { return VfsStatus.Corrupt(); }
                long copyStart = requestedOffset;
                if (copyStart < scanned) { copyStart = scanned; }
                long copyEnd = requestedEnd;
                if (copyEnd > scanned + validBytes) { copyEnd = scanned + validBytes; }
                long position = copyStart;
                while (position < copyEnd) {
                    output[(int)(position - requestedOffset)] = sector[(int)(position - scanned)];
                    position = position + 1;
                }
                scanned = scanned + validBytes;
                block = block + 1;
            }
            if (PartitionBytes.FinishCrc32(crc) != expectedCrc) { return VfsStatus.Corrupt(); }
            return VfsStatus.Ok();
        }

        public int ReadFile(string path, long offset, byte[] destination) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return lastStatus; }
            if (destination == null || offset < 0) { lastStatus = VfsStatus.InvalidArgument(); return lastStatus; }
            int index = FindEntry(path);
            if (index == -2) { lastStatus = VfsStatus.InvalidArgument(); return lastStatus; }
            if (index < 0) { lastStatus = VfsStatus.NotFound(); return lastStatus; }

            long byteLength = PartitionBytes.Read64(directory, index * EntrySize() + 12);
            if (offset > byteLength || destination.Length > byteLength - offset) {
                lastStatus = VfsStatus.EndOfFile();
                return lastStatus;
            }

            // Keep caller memory untouched until all sectors and the complete
            // file CRC pass. Memory usage is proportional to the requested
            // slice rather than the size of the file on disk.
            byte[] verifiedBytes = new byte[destination.Length];
            int result = ReadVerifiedEntry(index, offset, verifiedBytes);
            if (result != VfsStatus.Ok()) { lastStatus = result; return lastStatus; }
            int i = 0;
            while (i < destination.Length) {
                destination[i] = verifiedBytes[i];
                i = i + 1;
            }
            lastStatus = VfsStatus.Ok();
            return lastStatus;
        }
    }
}
