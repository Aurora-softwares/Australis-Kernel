namespace Australis.Kernel.Storage {
    public class GptDiskStatus {
        public static int Ok() { return 0; }
        public static int InvalidDevice() { return 1; }
        public static int InvalidProtectiveMbr() { return 2; }
        public static int InvalidGpt() { return 3; }
        public static int IoFailure() { return 4; }
        public static int InvalidIndex() { return 5; }
    }

    // Reads and checks either GPT copy directly from a block device. The
    // complete entry-array CRC is streamed one sector at a time, so table size
    // does not dictate a fixed boot-time DMA or heap allocation.
    public class GptDisk {
        private BlockDevice device;
        private byte[] header;
        private long entriesLba;
        private long entryCount;
        private int entrySize;
        private long firstUsable;
        private long lastUsable;
        private bool backup;
        private int lastStatus;

        public GptDisk() { Reset(); }

        private void Reset() {
            device = null; header = null; entriesLba = 0; entryCount = 0;
            entrySize = 0; firstUsable = 0; lastUsable = 0;
            backup = false; lastStatus = GptDiskStatus.InvalidDevice();
        }

        public bool IsOpen() { return device != null; }
        public bool UsingBackup() { return backup; }
        public long EntryCount() { return entryCount; }
        public int LastStatus() { return lastStatus; }

        private bool OpenHeader(BlockDevice input, long headerLba, long otherLba, bool isBackup) {
            int sectorSize = input.SectorSize();
            byte[] candidate = new byte[sectorSize];
            if (input.Read(headerLba, 1, candidate) != BlockStatus.Ok()) {
                lastStatus = GptDiskStatus.IoFailure(); return false;
            }
            if (!Gpt.IsValidHeaderAt(candidate, headerLba, otherLba)) {
                lastStatus = GptDiskStatus.InvalidGpt(); return false;
            }
            long usableFirst = PartitionBytes.Read64(candidate, 40);
            long usableLast = PartitionBytes.Read64(candidate, 48);
            long tableLba = PartitionBytes.Read64(candidate, 72);
            long count = PartitionBytes.Read32(candidate, 80);
            long size = PartitionBytes.Read32(candidate, 84);
            long diskLast = input.SectorCount() - 1;
            if (usableFirst < 2 || usableLast >= diskLast || size < 128 || size > 4096 ||
                size % 8 != 0 || tableLba < 2 || tableLba >= input.SectorCount()) {
                lastStatus = GptDiskStatus.InvalidGpt(); return false;
            }
            // Count is an unsigned 32-bit field and size is now bounded to
            // 4096, so their product fits signed 64-bit arithmetic.
            long tableBytes = count * size;
            long tableSectors = tableBytes / sectorSize;
            if (tableBytes % sectorSize != 0) { tableSectors = tableSectors + 1; }
            if (tableSectors < 1 || tableSectors > input.SectorCount() - tableLba ||
                (headerLba >= tableLba && headerLba - tableLba < tableSectors) ||
                (otherLba >= tableLba && otherLba - tableLba < tableSectors) ||
                (tableLba <= usableLast && tableLba + tableSectors - 1 >= usableFirst)) {
                lastStatus = GptDiskStatus.InvalidGpt(); return false;
            }

            long crc = PartitionBytes.MaxU32State();
            byte[] sector = new byte[sectorSize];
            long remaining = tableBytes;
            long lba = tableLba;
            while (remaining > 0) {
                if (input.Read(lba, 1, sector) != BlockStatus.Ok()) {
                    lastStatus = GptDiskStatus.IoFailure(); return false;
                }
                int countBytes = sectorSize;
                if (remaining < sectorSize) { countBytes = (int)remaining; }
                crc = PartitionBytes.UpdateCrc32(crc, sector, 0, countBytes);
                if (crc < 0) { lastStatus = GptDiskStatus.InvalidGpt(); return false; }
                remaining = remaining - countBytes;
                lba = lba + 1;
            }
            if (PartitionBytes.FinishCrc32(crc) != PartitionBytes.Read32(candidate, 88)) {
                lastStatus = GptDiskStatus.InvalidGpt(); return false;
            }

            device = input; header = candidate; entriesLba = tableLba;
            entryCount = count; entrySize = (int)size;
            firstUsable = usableFirst; lastUsable = usableLast;
            backup = isBackup; lastStatus = GptDiskStatus.Ok();
            return true;
        }

        public int Open(BlockDevice input) {
            Reset();
            if (input == null || (input.SectorSize() != 512 && input.SectorSize() != 1024 &&
                input.SectorSize() != 2048 && input.SectorSize() != 4096) || input.SectorCount() < 6) {
                lastStatus = GptDiskStatus.InvalidDevice(); return lastStatus;
            }
            byte[] mbr = new byte[input.SectorSize()];
            if (input.Read(0, 1, mbr) != BlockStatus.Ok()) {
                lastStatus = GptDiskStatus.IoFailure(); return lastStatus;
            }
            if (!Mbr.IsProtective(mbr)) {
                lastStatus = GptDiskStatus.InvalidProtectiveMbr(); return lastStatus;
            }
            long diskLast = input.SectorCount() - 1;
            if (OpenHeader(input, 1, diskLast, false)) { return lastStatus; }
            int primaryStatus = lastStatus;
            if (OpenHeader(input, diskLast, 1, true)) { return lastStatus; }
            if (primaryStatus == GptDiskStatus.IoFailure()) { lastStatus = primaryStatus; }
            return lastStatus;
        }

        public Partition Entry(long index) {
            Partition absent = new Partition(false, true, 0, 0, 0);
            if (device == null || index < 0 || index >= entryCount) {
                lastStatus = GptDiskStatus.InvalidIndex(); return absent;
            }
            int sectorSize = device.SectorSize();
            long byteOffset = index * entrySize;
            long sectorOffset = byteOffset / sectorSize;
            int inSector = (int)(byteOffset % sectorSize);
            int sectors = 1;
            if (inSector + entrySize > sectorSize) { sectors = 2; }
            byte[] bytes = new byte[sectors * sectorSize];
            if (device.Read(entriesLba + sectorOffset, sectors, bytes) != BlockStatus.Ok()) {
                lastStatus = GptDiskStatus.IoFailure(); return absent;
            }
            int i = 0; bool empty = true;
            while (i < 16) { if (bytes[inSector + i] != 0) { empty = false; } i = i + 1; }
            if (empty) { lastStatus = GptDiskStatus.Ok(); return absent; }
            long first = PartitionBytes.Read64(bytes, inSector + 32);
            long last = PartitionBytes.Read64(bytes, inSector + 40);
            if (first < firstUsable || first > last || last > lastUsable) {
                lastStatus = GptDiskStatus.InvalidGpt(); return absent;
            }
            lastStatus = GptDiskStatus.Ok();
            return new Partition(true, true, bytes[inSector], first, last - first + 1);
        }

        public Partition FirstPresent() {
            long index = 0;
            while (index < entryCount) {
                Partition entry = Entry(index);
                if (lastStatus != GptDiskStatus.Ok()) { return new Partition(false, true, 0, 0, 0); }
                if (entry.Present()) { return entry; }
                index = index + 1;
            }
            return new Partition(false, true, 0, 0, 0);
        }

        // Compare the complete GPT type GUID. Partition.Type() retains only
        // its first byte for compatibility with older callers; using that
        // alone could select an unrelated filesystem partition.
        public Partition FirstWithTypeGuid(byte[] typeGuid) {
            Partition absent = new Partition(false, true, 0, 0, 0);
            if (device == null || typeGuid == null || typeGuid.Length != 16) {
                lastStatus = GptDiskStatus.InvalidDevice(); return absent;
            }
            int sectorSize = device.SectorSize();
            long index = 0;
            while (index < entryCount) {
                Partition candidate = Entry(index);
                if (lastStatus != GptDiskStatus.Ok()) { return absent; }
                if (candidate.Present() && candidate.Type() == typeGuid[0]) {
                    long byteOffset = index * entrySize;
                    long sectorOffset = byteOffset / sectorSize;
                    int inSector = (int)(byteOffset % sectorSize);
                    int sectors = 1;
                    if (inSector + 16 > sectorSize) { sectors = 2; }
                    byte[] bytes = new byte[sectors * sectorSize];
                    if (device.Read(entriesLba + sectorOffset, sectors, bytes) != BlockStatus.Ok()) {
                        lastStatus = GptDiskStatus.IoFailure(); return absent;
                    }
                    int position = 0;
                    while (position < 16 && bytes[inSector + position] == typeGuid[position]) {
                        position = position + 1;
                    }
                    if (position == 16) { lastStatus = GptDiskStatus.Ok(); return candidate; }
                }
                index = index + 1;
            }
            lastStatus = GptDiskStatus.Ok();
            return absent;
        }
    }
}
