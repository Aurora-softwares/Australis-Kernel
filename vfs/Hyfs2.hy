using Australis.Kernel.Storage;

namespace Australis.Kernel.Vfs {
    // HyFS v2 reader and transactional writer. The boot image stays read-only;
    // the separately typed raw data partition opts into writable mounting.
    public class Hyfs2 : IWritableFileSystem {
        private BlockDevice device;
        private Partition partition;
        private byte[] table;
        private int entryCount;
        private long tableFirst;
        private int tableBlocks;
        private long generation;
        private long blockCount;
        private int lastStatus;
        private int activeSlot;
        private Hyfs2 previous;
        private bool writable;

        public Hyfs2() {
            device = null; partition = null; table = null; entryCount = 0;
            tableFirst = 0; tableBlocks = 0; generation = 0; blockCount = 0;
            lastStatus = VfsStatus.NotMounted();
            activeSlot = -1; previous = null; writable = false;
        }

        private void Reset() {
            device = null; partition = null; table = null; entryCount = 0;
            tableFirst = 0; tableBlocks = 0; generation = 0; blockCount = 0;
            lastStatus = VfsStatus.NotMounted();
            activeSlot = -1; previous = null; writable = false;
        }

        public int LastStatus() { return lastStatus; }
        public long Generation() { return generation; }
        public bool IsMounted() { return device != null; }
        private int Offset(int index) { return index * 128; }
        private long Id(int index) { return PartitionBytes.Read32(table, Offset(index)); }
        private long Parent(int index) { return PartitionBytes.Read32(table, Offset(index) + 4); }
        private int Kind(int index) { return table[Offset(index) + 8]; }
        private int NameLength(int index) { return table[Offset(index) + 9]; }
        private long FirstBlock(int index) { return PartitionBytes.Read64(table, Offset(index) + 12); }
        private long Length(int index) { return PartitionBytes.Read64(table, Offset(index) + 20); }
        private long DataCrc(int index) { return PartitionBytes.Read32(table, Offset(index) + 28); }
        private int Flags(int index) { return table[Offset(index) + 10] + table[Offset(index) + 11] * 256; }
        private long Created(int index) { return PartitionBytes.Read64(table, Offset(index) + 32); }
        private long Modified(int index) { return PartitionBytes.Read64(table, Offset(index) + 40); }
        private long Attributes(int index) { return PartitionBytes.Read32(table, Offset(index) + 48); }

        private static bool Zero(byte[] bytes, int start, int length) {
            int index = 0;
            while (index < length) {
                if (bytes[start + index] != 0) { return false; }
                index = index + 1;
            }
            return true;
        }

        private static bool Magic(byte[] bytes) {
            return bytes[0] == 72 && bytes[1] == 89 && bytes[2] == 70 &&
                bytes[3] == 83 && bytes[4] == 13 && bytes[5] == 10 &&
                bytes[6] == 26 && bytes[7] == 10;
        }

        private int FindId(long id) {
            int index = 0;
            while (index < entryCount) {
                if (Id(index) == id) { return index; }
                index = index + 1;
            }
            return -1;
        }

        private bool SameName(int left, int right) {
            int length = NameLength(left);
            if (length != NameLength(right)) { return false; }
            int index = 0;
            while (index < length) {
                if (table[Offset(left) + 64 + index] != table[Offset(right) + 64 + index]) {
                    return false;
                }
                index = index + 1;
            }
            return true;
        }

        private bool ValidEntry(int index) {
            int offset = Offset(index);
            long id = Id(index);
            long parent = Parent(index);
            int kind = Kind(index);
            int nameLength = NameLength(index);
            int flags = Flags(index);
            long first = FirstBlock(index);
            long length = Length(index);
            long crc = DataCrc(index);
            long created = Created(index);
            long modified = Modified(index);
            if (id < 1 || kind < 1 || kind > 2 || flags > 3 ||
                first < 0 || length < 0 || created < 0 || modified < 0 ||
                Attributes(index) != 0 || !Zero(table, offset + 52, 12) ||
                nameLength > 63 || !Zero(table, offset + 64 + nameLength, 64 - nameLength)) {
                return false;
            }
            if ((flags % 2 == 0 && created != 0) ||
                ((flags / 2) % 2 == 0 && modified != 0)) { return false; }
            if (index == 0) {
                if (id != 1 || parent != 0 || kind != 2 || nameLength != 0) { return false; }
            } else {
                if (nameLength < 1 || parent == 0 || id <= Id(index - 1)) { return false; }
                int byteIndex = 0;
                while (byteIndex < nameLength) {
                    int value = table[offset + 64 + byteIndex];
                    if (value < 33 || value > 126 || value == 47) { return false; }
                    byteIndex = byteIndex + 1;
                }
                if (table[offset + 64] == 46 &&
                    (nameLength == 1 || (nameLength == 2 && table[offset + 65] == 46))) {
                    return false;
                }
                int parentIndex = FindId(parent);
                if (parentIndex < 0 || Kind(parentIndex) != 2) { return false; }
                int previous = 1;
                while (previous < index) {
                    if (Parent(previous) == parent && SameName(previous, index)) { return false; }
                    previous = previous + 1;
                }
                long ancestor = parent;
                int hops = 0;
                while (ancestor != 1) {
                    if (ancestor == id || hops >= entryCount) { return false; }
                    int ancestorIndex = FindId(ancestor);
                    if (ancestorIndex < 0 || Kind(ancestorIndex) != 2) { return false; }
                    ancestor = Parent(ancestorIndex);
                    hops = hops + 1;
                }
            }

            if (kind == 2) { return first == 0 && length == 0 && crc == 0; }
            if (length == 0) { return first == 0 && crc == 0; }
            long blocks = length / 512;
            if (length % 512 != 0) { blocks = blocks + 1; }
            if (first < 2 || first >= blockCount || blocks > blockCount - first ||
                (first < tableFirst + tableBlocks && tableFirst < first + blocks)) {
                return false;
            }
            int previousFile = 1;
            while (previousFile < index) {
                if (Kind(previousFile) == 1 && Length(previousFile) > 0) {
                    long otherFirst = FirstBlock(previousFile);
                    long otherBlocks = Length(previousFile) / 512;
                    if (Length(previousFile) % 512 != 0) { otherBlocks = otherBlocks + 1; }
                    if (first < otherFirst + otherBlocks && otherFirst < first + blocks) {
                        return false;
                    }
                }
                previousFile = previousFile + 1;
            }
            return true;
        }

        private int VerifyFile(int index, long requestedOffset, byte[] result) {
            long length = Length(index);
            if (length == 0) { return VfsStatus.Ok(); }
            byte[] sector = new byte[512];
            long crc = PartitionBytes.MaxU32State();
            long scanned = 0;
            long block = 0;
            long requestedEnd = requestedOffset + result.Length;
            while (scanned < length) {
                if (device.Read(partition.FirstLba() + FirstBlock(index) + block, 1, sector) !=
                    BlockStatus.Ok()) { return VfsStatus.IoFailure(); }
                int valid = 512;
                if (length - scanned < 512) { valid = (int)(length - scanned); }
                crc = PartitionBytes.UpdateCrc32(crc, sector, 0, valid);
                if (crc < 0) { return VfsStatus.Corrupt(); }
                long from = requestedOffset;
                if (from < scanned) { from = scanned; }
                long to = requestedEnd;
                if (to > scanned + valid) { to = scanned + valid; }
                long position = from;
                while (position < to) {
                    result[(int)(position - requestedOffset)] = sector[(int)(position - scanned)];
                    position = position + 1;
                }
                scanned = scanned + valid;
                block = block + 1;
            }
            if (PartitionBytes.FinishCrc32(crc) != DataCrc(index)) { return VfsStatus.Corrupt(); }
            return VfsStatus.Ok();
        }

        private bool LoadCandidate(BlockDevice inputDevice, Partition inputPartition, int slot) {
            byte[] header = new byte[512];
            if (inputDevice.Read(inputPartition.FirstLba() + slot, 1, header) != BlockStatus.Ok()) {
                lastStatus = VfsStatus.IoFailure(); return false;
            }
            if (!Magic(header) || PartitionBytes.Read32(header, 8) != 2 ||
                PartitionBytes.Read32(header, 12) != 512 ||
                PartitionBytes.Read64(header, 16) != inputPartition.BlockCount() ||
                PartitionBytes.Crc32(header, 0, 56, 52, 4) != PartitionBytes.Read32(header, 52) ||
                !Zero(header, 56, 456)) { return false; }
            long inputGeneration = PartitionBytes.Read64(header, 24);
            long inputTableFirst = PartitionBytes.Read64(header, 32);
            long inputTableBlocks = PartitionBytes.Read32(header, 40);
            long inputEntryCount = PartitionBytes.Read32(header, 44);
            if (inputGeneration < 1 || inputTableFirst < 2 || inputTableBlocks < 1 ||
                inputTableBlocks > 128 || inputTableFirst >= inputPartition.BlockCount() ||
                inputTableBlocks > inputPartition.BlockCount() - inputTableFirst ||
                inputTableBlocks * 512 > 65536 ||
                inputEntryCount < 1 || inputEntryCount > inputTableBlocks * 4 ||
                (inputEntryCount * 128 + 511) / 512 != inputTableBlocks) { return false; }
            byte[] inputTable = new byte[(int)inputTableBlocks * 512];
            if (inputDevice.Read(inputPartition.FirstLba() + inputTableFirst,
                (int)inputTableBlocks, inputTable) != BlockStatus.Ok()) {
                lastStatus = VfsStatus.IoFailure(); return false;
            }
            if (PartitionBytes.Crc32(inputTable, 0, inputTable.Length, 0, 0) !=
                PartitionBytes.Read32(header, 48) ||
                !Zero(inputTable, (int)inputEntryCount * 128,
                    inputTable.Length - (int)inputEntryCount * 128)) { return false; }

            device = inputDevice; partition = inputPartition; table = inputTable;
            entryCount = (int)inputEntryCount; tableFirst = inputTableFirst;
            tableBlocks = (int)inputTableBlocks; generation = inputGeneration;
            blockCount = inputPartition.BlockCount();
            int index = 0;
            while (index < entryCount) {
                if (!ValidEntry(index)) { return false; }
                if (Kind(index) == 1 && Length(index) > 0 &&
                    VerifyFile(index, 0, new byte[0]) != VfsStatus.Ok()) { return false; }
                index = index + 1;
            }
            lastStatus = VfsStatus.Ok();
            return true;
        }

        public int Mount(BlockDevice inputDevice, Partition inputPartition) {
            Reset();
            if (inputDevice == null || inputPartition == null || !inputPartition.Present() ||
                inputDevice.SectorSize() != 512 || inputPartition.BlockCount() < 8 ||
                inputPartition.FirstLba() < 0 ||
                inputPartition.FirstLba() >= inputDevice.SectorCount() ||
                inputPartition.BlockCount() > inputDevice.SectorCount() -
                    inputPartition.FirstLba()) {
                lastStatus = VfsStatus.InvalidArgument(); return lastStatus;
            }
            Hyfs2 first = new Hyfs2();
            Hyfs2 second = new Hyfs2();
            bool firstValid = first.LoadCandidate(inputDevice, inputPartition, 0);
            bool secondValid = second.LoadCandidate(inputDevice, inputPartition, 1);
            Hyfs2 chosen = null;
            if (firstValid) { chosen = first; }
            if (secondValid && (chosen == null || second.generation > chosen.generation)) {
                chosen = second;
            }
            if (chosen == null) {
                if (first.lastStatus == VfsStatus.IoFailure() ||
                    second.lastStatus == VfsStatus.IoFailure()) { lastStatus = VfsStatus.IoFailure(); }
                else { lastStatus = VfsStatus.MountFailed(); }
                return lastStatus;
            }
            device = chosen.device; partition = chosen.partition; table = chosen.table;
            entryCount = chosen.entryCount; tableFirst = chosen.tableFirst;
            tableBlocks = chosen.tableBlocks; generation = chosen.generation;
            blockCount = chosen.blockCount; lastStatus = VfsStatus.Ok();
            activeSlot = 0;
            if (chosen == second) { activeSlot = 1; }
            if (activeSlot == 0 && secondValid) { previous = second; }
            if (activeSlot == 1 && firstValid) { previous = first; }
            return lastStatus;
        }

        // Only trusted kernel callers select a writable mount. Regular mounts
        // continue to use Mount() and cannot modify their backing volume.
        public int MountWritable(BlockDevice inputDevice, Partition inputPartition) {
            int status = Mount(inputDevice, inputPartition);
            if (status == VfsStatus.Ok()) {
                // A volume with object IDs greater than its generation cannot
                // prove the next ID will never reuse a deleted high ID.
                long limit = 2147483647;
                limit = limit * 65536 * 65536 + 4294967295;
                if (generation >= limit || Id(entryCount - 1) > generation + 1) {
                    return Result(VfsStatus.ReadOnly());
                }
                if (previous == null) {
                    // A newly formatted volume has only one valid slot. If
                    // the other slot is damaged, replace it with a copy of
                    // the selected snapshot before allocating any blocks.
                    int inactive = 1 - activeSlot;
                    byte[] oldHeader = new byte[512];
                    if (device.Read(partition.FirstLba() + inactive, 1,
                        oldHeader) != BlockStatus.Ok()) {
                        return Result(VfsStatus.IoFailure());
                    }
                    byte[] mirror = Superblock(generation, tableFirst,
                        tableBlocks, entryCount, table);
                    if (device.Write(partition.FirstLba() + inactive, 1,
                        mirror) != BlockStatus.Ok() ||
                        device.Flush() != BlockStatus.Ok()) {
                        Reset(); return Result(VfsStatus.IoFailure());
                    }
                    Hyfs2 oldSnapshot = new Hyfs2();
                    oldSnapshot.table = table;
                    oldSnapshot.entryCount = entryCount;
                    oldSnapshot.tableFirst = tableFirst;
                    oldSnapshot.tableBlocks = tableBlocks;
                    previous = oldSnapshot;
                }
                writable = true;
            }
            return status;
        }

        public bool IsWritable() { return IsMounted() && writable; }

        private bool NameMatches(int index, string path, int start, int length) {
            if (NameLength(index) != length) { return false; }
            int byteIndex = 0;
            while (byteIndex < length) {
                if (table[Offset(index) + 64 + byteIndex] !=
                    Hyfs.PathByteAt(path, start + byteIndex)) { return false; }
                byteIndex = byteIndex + 1;
            }
            return true;
        }

        private int FindPath(string path) {
            if (path == null || path.Length < 1 || path.Length > 255 ||
                Hyfs.PathByteAt(path, 0) != 47) {
                return -2;
            }
            if (path.Length == 1) { return 0; }
            long parent = 1;
            int cursor = 1;
            int found = -1;
            while (cursor < path.Length) {
                int start = cursor;
                while (cursor < path.Length && Hyfs.PathByteAt(path, cursor) != 47) {
                    if (Hyfs.PathByteAt(path, cursor) < 0) { return -2; }
                    cursor = cursor + 1;
                }
                int length = cursor - start;
                if (length < 1 || length > 63) { return -2; }
                found = -1;
                int index = 1;
                while (index < entryCount) {
                    if (Parent(index) == parent && NameMatches(index, path, start, length)) {
                        found = index; break;
                    }
                    index = index + 1;
                }
                if (found < 0) { return -1; }
                if (cursor < path.Length) {
                    if (Kind(found) != 2) { return -2; }
                    cursor = cursor + 1;
                    if (cursor >= path.Length) { return found; }
                }
                parent = Id(found);
            }
            return found;
        }

        public bool Exists(string path) { return Stat(path).Exists(); }

        public VfsFileInfo Stat(string path) {
            if (!IsMounted()) {
                lastStatus = VfsStatus.NotMounted(); return new VfsFileInfo(lastStatus, 0);
            }
            int index = FindPath(path);
            if (index < 0) {
                if (index == -2) { lastStatus = VfsStatus.InvalidArgument(); }
                else { lastStatus = VfsStatus.NotFound(); }
                return new VfsFileInfo(lastStatus, 0);
            }
            VfsFileInfo result = new VfsFileInfo(VfsStatus.Ok(), Length(index));
            result.SetMetadata(Kind(index), Id(index), Created(index), Modified(index),
                Flags(index), Attributes(index));
            lastStatus = VfsStatus.Ok();
            return result;
        }

        public int ReadFile(string path, long offset, byte[] destination) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return lastStatus; }
            if (offset < 0 || destination == null) {
                lastStatus = VfsStatus.InvalidArgument(); return lastStatus;
            }
            int index = FindPath(path);
            if (index < 0) {
                if (index == -2) { lastStatus = VfsStatus.InvalidArgument(); }
                else { lastStatus = VfsStatus.NotFound(); }
                return lastStatus;
            }
            if (Kind(index) != 1) {
                lastStatus = VfsStatus.InvalidArgument(); return lastStatus;
            }
            long length = Length(index);
            if (offset > length || destination.Length > length - offset) {
                lastStatus = VfsStatus.EndOfFile(); return lastStatus;
            }
            byte[] staged = new byte[destination.Length];
            int result = VerifyFile(index, offset, staged);
            if (result != VfsStatus.Ok()) { lastStatus = result; return lastStatus; }
            int byteIndex = 0;
            while (byteIndex < destination.Length) {
                destination[byteIndex] = staged[byteIndex]; byteIndex = byteIndex + 1;
            }
            lastStatus = VfsStatus.Ok();
            return lastStatus;
        }

        public int DirectorySlotCount() {
            return DirectorySlotCountAt("/");
        }

        public int DirectorySlotCountAt(string path) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return -1; }
            int directory = FindPath(path);
            if (directory < 0 || Kind(directory) != 2) {
                lastStatus = VfsStatus.InvalidArgument(); return -1;
            }
            long parentId = Id(directory);
            int count = 0;
            int index = 1;
            while (index < entryCount) {
                if (Parent(index) == parentId) { count = count + 1; }
                index = index + 1;
            }
            lastStatus = VfsStatus.Ok();
            return count;
        }

        public int CopyDirectoryEntryName(int slot, byte[] destination) {
            return CopyDirectoryEntryNameAt("/", slot, destination);
        }

        public int CopyDirectoryEntryNameAt(string path, int slot, byte[] destination) {
            if (!IsMounted()) { lastStatus = VfsStatus.NotMounted(); return -1; }
            if (slot < 0 || destination == null) {
                lastStatus = VfsStatus.InvalidArgument(); return -1;
            }
            int directory = FindPath(path);
            if (directory < 0 || Kind(directory) != 2) {
                lastStatus = VfsStatus.InvalidArgument(); return -1;
            }
            long parentId = Id(directory);
            int index = 1;
            int seen = 0;
            while (index < entryCount) {
                if (Parent(index) == parentId) {
                    if (seen == slot) {
                        int length = NameLength(index);
                        if (length > destination.Length) {
                            lastStatus = VfsStatus.InvalidArgument(); return -1;
                        }
                        int byteIndex = 0;
                        while (byteIndex < length) {
                            destination[byteIndex] = table[Offset(index) + 64 + byteIndex];
                            byteIndex = byteIndex + 1;
                        }
                        lastStatus = VfsStatus.Ok();
                        return length;
                    }
                    seen = seen + 1;
                }
                index = index + 1;
            }
            lastStatus = VfsStatus.InvalidArgument();
            return -1;
        }

        private static void Put32(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 4) {
                bytes[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }

        private static void Put64(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 8) {
                bytes[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }

        private int Result(int status) { lastStatus = status; return status; }

        private int CheckWritable() {
            if (!IsMounted()) { return Result(VfsStatus.NotMounted()); }
            if (!writable) { return Result(VfsStatus.ReadOnly()); }
            return VfsStatus.Ok();
        }

        private static bool Intersects(long first, long count, long other, long otherCount) {
            return count > 0 && otherCount > 0 && first < other + otherCount &&
                other < first + count;
        }

        private bool SnapshotUses(Hyfs2 snapshot, long first, long count) {
            if (snapshot == null) { return false; }
            if (Intersects(first, count, snapshot.tableFirst, snapshot.tableBlocks)) { return true; }
            int index = 1;
            while (index < snapshot.entryCount) {
                if (snapshot.Kind(index) == 1 && snapshot.Length(index) > 0) {
                    long length = snapshot.Length(index);
                    long blocks = length / 512;
                    if (length % 512 != 0) { blocks = blocks + 1; }
                    if (Intersects(first, count, snapshot.FirstBlock(index), blocks)) { return true; }
                }
                index = index + 1;
            }
            return false;
        }

        // Both valid generations remain protected until their superblock is
        // replaced. Otherwise a crash could destroy the fallback snapshot.
        private long Allocate(int count, long extraFirst, int extraCount) {
            if (count < 1 || count > blockCount - 2) { return -1; }
            long first = 2;
            while (first <= blockCount - count) {
                if (!SnapshotUses(this, first, count) &&
                    !SnapshotUses(previous, first, count) &&
                    !Intersects(first, count, extraFirst, extraCount)) { return first; }
                first = first + 1;
            }
            return -1;
        }

        private byte[] CopyTable(int count) {
            byte[] proposed = new byte[((count + 3) / 4) * 512];
            int length = entryCount * 128;
            if (length > proposed.Length) { length = proposed.Length; }
            int i = 0;
            while (i < length) { proposed[i] = table[i]; i = i + 1; }
            return proposed;
        }

        private bool ValidProposed(byte[] proposed, int count, long first, int blocks) {
            byte[] savedTable = table;
            int savedCount = entryCount;
            long savedFirst = tableFirst;
            int savedBlocks = tableBlocks;
            table = proposed; entryCount = count; tableFirst = first; tableBlocks = blocks;
            bool valid = true;
            int index = 0;
            while (index < count) {
                if (!ValidEntry(index)) { valid = false; break; }
                index = index + 1;
            }
            table = savedTable; entryCount = savedCount;
            tableFirst = savedFirst; tableBlocks = savedBlocks;
            return valid;
        }

        // Copy an old file prefix, then inserted bytes, then zero extension.
        // Every changed file gets a new contiguous extent and exact-byte CRC.
        private long WriteData(int oldIndex, long copyLength, byte[] insert,
            long length, long first) {
            long crc = PartitionBytes.MaxU32State();
            long block = 0;
            long position = 0;
            while (position < length) {
                byte[] sector = new byte[512];
                if (position < copyLength) {
                    if (device.Read(partition.FirstLba() + FirstBlock(oldIndex) + block,
                        1, sector) != BlockStatus.Ok()) { return -1; }
                }
                int valid = 512;
                if (length - position < 512) { valid = (int)(length - position); }
                int i = 0;
                while (i < valid) {
                    long at = position + i;
                    if (at >= copyLength && at - copyLength < insert.Length) {
                        sector[i] = insert[(int)(at - copyLength)];
                    } else if (at >= copyLength) { sector[i] = 0; }
                    i = i + 1;
                }
                while (i < 512) { sector[i] = 0; i = i + 1; }
                crc = PartitionBytes.UpdateCrc32(crc, sector, 0, valid);
                if (crc < 0 || device.Write(partition.FirstLba() + first + block,
                    1, sector) != BlockStatus.Ok()) { return -1; }
                position = position + valid;
                block = block + 1;
            }
            return PartitionBytes.FinishCrc32(crc);
        }

        private byte[] Superblock(long nextGeneration, long first, int blocks,
            int count, byte[] proposed) {
            byte[] header = new byte[512];
            header[0] = 72; header[1] = 89; header[2] = 70; header[3] = 83;
            header[4] = 13; header[5] = 10; header[6] = 26; header[7] = 10;
            Put32(header, 8, 2); Put32(header, 12, 512);
            Put64(header, 16, blockCount); Put64(header, 24, nextGeneration);
            Put64(header, 32, first); Put32(header, 40, blocks);
            Put32(header, 44, count);
            Put32(header, 48, PartitionBytes.Crc32(proposed, 0, proposed.Length, 0, 0));
            Put32(header, 52, PartitionBytes.Crc32(header, 0, 56, 52, 4));
            return header;
        }

        private int Commit(byte[] proposed, int count, int changedIndex,
            int oldIndex, long copyLength, byte[] insert, long length) {
            long limit = 2147483647;
            limit = limit * 65536 * 65536 + 4294967295;
            if (generation >= limit || count < 1 || count > 512) {
                return Result(VfsStatus.NoSpace());
            }
            int newTableBlocks = (count + 3) / 4;
            long dataCount = length / 512;
            if (length % 512 != 0) { dataCount = dataCount + 1; }
            if (dataCount > blockCount - 2 || dataCount > 2147483647) {
                return Result(VfsStatus.NoSpace());
            }
            long dataFirst = 0;
            if (changedIndex >= 0 && dataCount > 0) {
                dataFirst = Allocate((int)dataCount, 0, 0);
                if (dataFirst < 0) { return Result(VfsStatus.NoSpace()); }
            }
            long newTableFirst = Allocate(newTableBlocks, dataFirst, (int)dataCount);
            if (newTableFirst < 0) { return Result(VfsStatus.NoSpace()); }
            if (copyLength > 0) {
                int checked = VerifyFile(oldIndex, 0, new byte[0]);
                if (checked == VfsStatus.IoFailure()) {
                    Reset(); return Result(checked);
                }
                if (checked != VfsStatus.Ok()) { return Result(checked); }
            }
            if (changedIndex >= 0) {
                long crc = 0;
                if (dataCount > 0) {
                    crc = WriteData(oldIndex, copyLength, insert, length, dataFirst);
                    if (crc < 0) { Reset(); return Result(VfsStatus.IoFailure()); }
                }
                int offset = changedIndex * 128;
                Put64(proposed, offset + 12, dataFirst);
                Put64(proposed, offset + 20, length);
                Put32(proposed, offset + 28, crc);
            }
            if (!ValidProposed(proposed, count, newTableFirst, newTableBlocks)) {
                return Result(VfsStatus.Corrupt());
            }
            if (device.Flush() != BlockStatus.Ok() ||
                device.Write(partition.FirstLba() + newTableFirst,
                    newTableBlocks, proposed) != BlockStatus.Ok() ||
                device.Flush() != BlockStatus.Ok()) {
                Reset(); return Result(VfsStatus.IoFailure());
            }
            int nextSlot = 1 - activeSlot;
            byte[] header = Superblock(generation + 1, newTableFirst,
                newTableBlocks, count, proposed);
            if (device.Write(partition.FirstLba() + nextSlot, 1, header) !=
                BlockStatus.Ok() || device.Flush() != BlockStatus.Ok()) {
                Reset(); return Result(VfsStatus.IoFailure());
            }
            Hyfs2 oldSnapshot = new Hyfs2();
            oldSnapshot.table = table; oldSnapshot.entryCount = entryCount;
            oldSnapshot.tableFirst = tableFirst; oldSnapshot.tableBlocks = tableBlocks;
            previous = oldSnapshot;
            table = proposed; entryCount = count; tableFirst = newTableFirst;
            tableBlocks = newTableBlocks; generation = generation + 1;
            activeSlot = nextSlot;
            return Result(VfsStatus.Ok());
        }

        // Name byte zero holds the length; bytes 1..63 hold printable ASCII.
        // A negative return distinguishes malformed paths from missing parents.
        private int ParentFor(string path, bool directory, byte[] name) {
            if (path == null || path.Length < 2 || path.Length > 255 ||
                Hyfs.PathByteAt(path, 0) != 47 || name == null ||
                name.Length < 64) { return -2; }
            int end = path.Length;
            if (directory) {
                while (end > 1 && Hyfs.PathByteAt(path, end - 1) == 47) {
                    end = end - 1;
                }
            } else if (Hyfs.PathByteAt(path, end - 1) == 47) { return -2; }
            int slash = end - 1;
            while (slash >= 0 && Hyfs.PathByteAt(path, slash) != 47) {
                slash = slash - 1;
            }
            int length = end - slash - 1;
            if (slash < 0 || length < 1 || length > 63) { return -2; }
            if (length == 1 && Hyfs.PathByteAt(path, slash + 1) == 46) {
                return -2;
            }
            if (length == 2 && Hyfs.PathByteAt(path, slash + 1) == 46 &&
                Hyfs.PathByteAt(path, slash + 2) == 46) { return -2; }
            name[0] = (byte)length;
            int i = 0;
            while (i < length) {
                int value = Hyfs.PathByteAt(path, slash + 1 + i);
                if (value < 33 || value > 126 || value == 47) { return -2; }
                name[i + 1] = (byte)value;
                i = i + 1;
            }
            int parent = 0;
            int cursor = 1;
            while (cursor < slash) {
                int start = cursor;
                while (cursor < slash && Hyfs.PathByteAt(path, cursor) != 47) {
                    if (Hyfs.PathByteAt(path, cursor) < 0) { return -2; }
                    cursor = cursor + 1;
                }
                int componentLength = cursor - start;
                if (componentLength < 1 || componentLength > 63) { return -2; }
                int found = -1;
                int entry = 1;
                while (entry < entryCount) {
                    if (Parent(entry) == Id(parent) &&
                        NameMatches(entry, path, start, componentLength)) {
                        found = entry; break;
                    }
                    entry = entry + 1;
                }
                if (found < 0) { return -1; }
                if (Kind(found) != 2) { return -2; }
                parent = found;
                cursor = cursor + 1;
            }
            return parent;
        }

        private int FindChild(long parentId, byte[] name) {
            int index = 1;
            while (index < entryCount) {
                if (Parent(index) == parentId && NameLength(index) == name[0]) {
                    bool same = true;
                    int i = 0;
                    while (i < name[0]) {
                        if (table[Offset(index) + 64 + i] != name[i + 1]) {
                            same = false; break;
                        }
                        i = i + 1;
                    }
                    if (same) { return index; }
                }
                index = index + 1;
            }
            return -1;
        }

        private long NextId() {
            long max = 65535;
            max = max * 65536 + 65535;
            if (generation >= max) { return -1; }
            long next = Id(entryCount - 1) + 1;
            if (next <= generation) { next = generation + 1; }
            if (next > max) { return -1; }
            return next;
        }

        private static void SetName(byte[] proposed, int offset, byte[] name) {
            proposed[offset + 9] = name[0];
            int i = 0;
            while (i < 64) {
                proposed[offset + 64 + i] = 0;
                i = i + 1;
            }
            i = 0;
            while (i < name[0]) {
                proposed[offset + 64 + i] = name[i + 1];
                i = i + 1;
            }
        }

        private static void NewRecord(byte[] proposed, int index, long id,
            long parentId, int kind, byte[] name) {
            int offset = index * 128;
            Put32(proposed, offset, id); Put32(proposed, offset + 4, parentId);
            proposed[offset + 8] = (byte)kind;
            SetName(proposed, offset, name);
        }

        private int ParentError(int parent) {
            if (parent == -1) { return Result(VfsStatus.NotFound()); }
            return Result(VfsStatus.InvalidArgument());
        }

        private byte[] Without(int removed) {
            int count = entryCount - 1;
            byte[] proposed = new byte[((count + 3) / 4) * 512];
            int source = 0;
            int target = 0;
            while (source < entryCount) {
                if (source != removed) {
                    int i = 0;
                    while (i < 128) {
                        proposed[target * 128 + i] = table[source * 128 + i];
                        i = i + 1;
                    }
                    target = target + 1;
                }
                source = source + 1;
            }
            return proposed;
        }

        public int CreateFile(string path, byte[] contents) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            if (contents == null) { return Result(VfsStatus.InvalidArgument()); }
            byte[] name = new byte[64];
            int parent = ParentFor(path, false, name);
            if (parent < 0) { return ParentError(parent); }
            if (FindChild(Id(parent), name) >= 0) { return Result(VfsStatus.AlreadyExists()); }
            if (entryCount >= 512) { return Result(VfsStatus.NoSpace()); }
            long id = NextId();
            if (id < 0) { return Result(VfsStatus.NoSpace()); }
            byte[] proposed = CopyTable(entryCount + 1);
            NewRecord(proposed, entryCount, id, Id(parent), 1, name);
            return Commit(proposed, entryCount + 1, entryCount, -1, 0,
                contents, contents.Length);
        }

        private int FileIndex(string path) {
            int index = FindPath(path);
            if (index == -1) { return -1; }
            if (index < 0 || Kind(index) != 1) { return -2; }
            return index;
        }

        private int FileError(int index) {
            if (index == -1) { return Result(VfsStatus.NotFound()); }
            return Result(VfsStatus.InvalidArgument());
        }

        // No clock source is assumed by the filesystem. A mutation clears a
        // preexisting modification timestamp rather than preserving a stale one.
        private void ClearModified(byte[] proposed, int index) {
            int offset = index * 128;
            proposed[offset + 10] = (byte)(Flags(index) % 2);
            proposed[offset + 11] = 0;
            Put64(proposed, offset + 40, 0);
        }

        public int ReplaceFile(string path, byte[] contents) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            if (contents == null) { return Result(VfsStatus.InvalidArgument()); }
            int index = FileIndex(path);
            if (index < 0) { return FileError(index); }
            byte[] proposed = CopyTable(entryCount);
            ClearModified(proposed, index);
            return Commit(proposed, entryCount, index, -1, 0,
                contents, contents.Length);
        }

        public int AppendFile(string path, byte[] suffix) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            if (suffix == null) { return Result(VfsStatus.InvalidArgument()); }
            int index = FileIndex(path);
            if (index < 0) { return FileError(index); }
            if (suffix.Length == 0) { return Result(VfsStatus.Ok()); }
            long original = Length(index);
            long length = original + suffix.Length;
            if (length < original) { return Result(VfsStatus.NoSpace()); }
            byte[] proposed = CopyTable(entryCount);
            ClearModified(proposed, index);
            return Commit(proposed, entryCount, index, index, original,
                suffix, length);
        }

        public int TruncateFile(string path, long length) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            if (length < 0) { return Result(VfsStatus.InvalidArgument()); }
            int index = FileIndex(path);
            if (index < 0) { return FileError(index); }
            if (length == Length(index)) { return Result(VfsStatus.Ok()); }
            long copyLength = Length(index);
            if (length < copyLength) { copyLength = length; }
            byte[] proposed = CopyTable(entryCount);
            ClearModified(proposed, index);
            return Commit(proposed, entryCount, index, index, copyLength,
                new byte[0], length);
        }

        public int DeleteFile(string path) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            int index = FileIndex(path);
            if (index < 0) { return FileError(index); }
            return Commit(Without(index), entryCount - 1, -1, -1, 0,
                new byte[0], 0);
        }

        public int Mkdir(string path) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            byte[] name = new byte[64];
            int parent = ParentFor(path, true, name);
            if (parent < 0) { return ParentError(parent); }
            if (FindChild(Id(parent), name) >= 0) { return Result(VfsStatus.AlreadyExists()); }
            if (entryCount >= 512) { return Result(VfsStatus.NoSpace()); }
            long id = NextId();
            if (id < 0) { return Result(VfsStatus.NoSpace()); }
            byte[] proposed = CopyTable(entryCount + 1);
            NewRecord(proposed, entryCount, id, Id(parent), 2, name);
            return Commit(proposed, entryCount + 1, -1, -1, 0,
                new byte[0], 0);
        }

        public int Rmdir(string path) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            int index = FindPath(path);
            if (index == -1) { return Result(VfsStatus.NotFound()); }
            if (index <= 0 || Kind(index) != 2) {
                return Result(VfsStatus.InvalidArgument());
            }
            int child = 1;
            while (child < entryCount) {
                if (Parent(child) == Id(index)) { return Result(VfsStatus.NotEmpty()); }
                child = child + 1;
            }
            return Commit(Without(index), entryCount - 1, -1, -1, 0,
                new byte[0], 0);
        }

        public int Rename(string source, string destination) {
            if (CheckWritable() != VfsStatus.Ok()) { return lastStatus; }
            int index = FindPath(source);
            if (index == -1) { return Result(VfsStatus.NotFound()); }
            if (index <= 0) { return Result(VfsStatus.InvalidArgument()); }
            byte[] name = new byte[64];
            int parent = ParentFor(destination, Kind(index) == 2, name);
            if (parent < 0) { return ParentError(parent); }
            if (FindChild(Id(parent), name) >= 0) { return Result(VfsStatus.AlreadyExists()); }
            long ancestor = Id(parent);
            while (ancestor != 1) {
                if (ancestor == Id(index)) { return Result(VfsStatus.InvalidArgument()); }
                int ancestorIndex = FindId(ancestor);
                if (ancestorIndex < 0) { return Result(VfsStatus.Corrupt()); }
                ancestor = Parent(ancestorIndex);
            }
            if (Id(parent) == Id(index)) { return Result(VfsStatus.InvalidArgument()); }
            byte[] proposed = CopyTable(entryCount);
            Put32(proposed, index * 128 + 4, Id(parent));
            SetName(proposed, index * 128, name);
            return Commit(proposed, entryCount, -1, -1, 0,
                new byte[0], 0);
        }
    }

    // Keep existing v1 boot and removable images readable while v2 rolls out.
    public class HyfsAuto : IFileSystem {
        private IFileSystem mounted;
        public HyfsAuto() { mounted = null; }
        public int Mount(BlockDevice device, Partition partition) {
            mounted = null;
            Hyfs2 newer = new Hyfs2();
            if (newer.Mount(device, partition) == VfsStatus.Ok()) {
                mounted = newer; return VfsStatus.Ok();
            }
            Hyfs older = new Hyfs();
            if (older.Mount(device, partition) == VfsStatus.Ok()) {
                mounted = older; return VfsStatus.Ok();
            }
            return VfsStatus.MountFailed();
        }
        public bool Exists(string path) { return mounted != null && mounted.Exists(path); }
        public VfsFileInfo Stat(string path) {
            if (mounted == null) { return new VfsFileInfo(VfsStatus.NotMounted(), 0); }
            return mounted.Stat(path);
        }
        public int ReadFile(string path, long offset, byte[] destination) {
            if (mounted == null) { return VfsStatus.NotMounted(); }
            return mounted.ReadFile(path, offset, destination);
        }
        public int DirectorySlotCount() {
            if (mounted == null) { return -1; }
            return mounted.DirectorySlotCount();
        }
        public int CopyDirectoryEntryName(int index, byte[] destination) {
            if (mounted == null) { return -1; }
            return mounted.CopyDirectoryEntryName(index, destination);
        }
        public int DirectorySlotCountAt(string path) {
            if (mounted == null) { return -1; }
            return mounted.DirectorySlotCountAt(path);
        }
        public int CopyDirectoryEntryNameAt(string path, int index, byte[] destination) {
            if (mounted == null) { return -1; }
            return mounted.CopyDirectoryEntryNameAt(path, index, destination);
        }
    }
}
