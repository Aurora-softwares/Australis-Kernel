namespace Australis.Kernel.Storage {
    public class Partition {
        private bool present;
        private bool gpt;
        private int type;
        private long firstLba;
        private long blockCount;

        public Partition(bool inputPresent, bool inputGpt, int inputType, long inputFirstLba, long inputBlockCount) {
            present = inputPresent; gpt = inputGpt; type = inputType;
            firstLba = inputFirstLba; blockCount = inputBlockCount;
        }
        public bool Present() { return present; }
        public bool IsGpt() { return gpt; }
        public int Type() { return type; }
        public long FirstLba() { return firstLba; }
        public long BlockCount() { return blockCount; }
    }

    public class PartitionBytes {
        public static long Read32(byte[] bytes, int offset) {
            long b0 = bytes[offset]; long b1 = bytes[offset + 1];
            long b2 = bytes[offset + 2]; long b3 = bytes[offset + 3];
            return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
        }

        public static long Read64(byte[] bytes, int offset) {
            long result = 0; long multiplier = 1; int i = 0;
            while (i < 8) {
                long value = bytes[offset + i];
                result = result + value * multiplier;
                if (i < 7) { multiplier = multiplier * 256; }
                i = i + 1;
            }
            return result;
        }

        // Hydrogen has no bitwise integer operators yet. This is the exact
        // unsigned 32-bit XOR used by GPT's IEEE CRC-32 calculation.
        private static long Xor32(long left, long right) {
            long result = 0; long place = 1; int bit = 0;
            while (bit < 32) {
                if (left % 2 != right % 2) { result = result + place; }
                left = left / 2; right = right / 2;
                if (bit < 31) { place = place * 2; }
                bit = bit + 1;
            }
            return result;
        }

        private static long MaxU32() { long high = 2147483647; return high * 2 + 1; }
        private static long CrcPolynomial() { long high = 60856; return high * 65536 + 33568; } // 0xedb88320

        // The raw CRC state can be carried across bounded block reads. The
        // caller starts with MaxU32State() and complements only after the last
        // byte. This avoids assembling an entire file in memory for its CRC.
        public static long MaxU32State() { return MaxU32(); }
        public static long FinishCrc32(long state) { return Xor32(state, MaxU32()); }

        public static long UpdateCrc32(long state, byte[] bytes, int offset, int length) {
            if (bytes == null || offset < 0 || length < 0 || offset > bytes.Length ||
                length > bytes.Length - offset || state < 0 || state > MaxU32()) { return -1; }
            int i = 0;
            while (i < length) {
                state = Xor32(state, bytes[offset + i]);
                int bit = 0;
                while (bit < 8) {
                    bool lowBit = state % 2 != 0;
                    state = state / 2;
                    if (lowBit) { state = Xor32(state, CrcPolynomial()); }
                    bit = bit + 1;
                }
                i = i + 1;
            }
            return state;
        }

        // Calculate standard reflected CRC-32. `zeroOffset` and `zeroLength`
        // let GPT verify a header without allocating a mutable copy.
        public static long Crc32(byte[] bytes, int offset, int length, int zeroOffset, int zeroLength) {
            if (offset < 0 || length < 0 || offset > bytes.Length || length > bytes.Length - offset ||
                zeroOffset < 0 || zeroLength < 0) { return -1; }
            long crc = MaxU32();
            int i = 0;
            while (i < length) {
                long value = bytes[offset + i];
                if (i >= zeroOffset && i < zeroOffset + zeroLength) { value = 0; }
                crc = Xor32(crc, value);
                int bit = 0;
                while (bit < 8) {
                    bool lowBit = crc % 2 != 0;
                    crc = crc / 2;
                    if (lowBit) { crc = Xor32(crc, CrcPolynomial()); }
                    bit = bit + 1;
                }
                i = i + 1;
            }
            return FinishCrc32(crc);
        }
    }

    public class Mbr {
        private static int EntryOffset(int index) { return 446 + index * 16; }
        public static bool IsValid(byte[] sector) { return sector.Length >= 512 && sector[510] == 85 && sector[511] == 170; }
        public static bool IsProtective(byte[] sector) {
            return IsValid(sector) && sector[450] == 238 && PartitionBytes.Read32(sector, 454) == 1;
        }
        public static Partition Entry(byte[] sector, int index) {
            if (!IsValid(sector) || index < 0 || index > 3) { return new Partition(false, false, 0, 0, 0); }
            int offset = EntryOffset(index);
            int type = sector[offset + 4];
            long first = PartitionBytes.Read32(sector, offset + 8);
            long count = PartitionBytes.Read32(sector, offset + 12);
            if (type == 0 || count == 0) { return new Partition(false, false, type, 0, 0); }
            return new Partition(true, false, type, first, count);
        }
    }

    public class Gpt {
        private static bool IsSignature(byte[] header) {
            return header[0] == 69 && header[1] == 70 && header[2] == 73 && header[3] == 32 &&
                header[4] == 80 && header[5] == 65 && header[6] == 82 && header[7] == 84;
        }
        private static bool IsZeroGuid(byte[] entries, int offset) {
            int i = 0; while (i < 16) { if (entries[offset + i] != 0) { return false; } i = i + 1; }
            return true;
        }

        // Header CRC is mandatory. The accepted revision is GPT 1.0, whose
        // documented 92-byte header is extensible only within the supplied
        // logical sector.
        public static bool IsValidHeader(byte[] header) {
            if (header.Length < 92 || !IsSignature(header) || PartitionBytes.Read32(header, 8) != 65536) { return false; }
            int headerSize = (int)PartitionBytes.Read32(header, 12);
            if (headerSize < 92 || headerSize > header.Length) { return false; }
            if (PartitionBytes.Crc32(header, 0, headerSize, 16, 4) != PartitionBytes.Read32(header, 16)) { return false; }
            long current = PartitionBytes.Read64(header, 24);
            long backup = PartitionBytes.Read64(header, 32);
            long firstUsable = PartitionBytes.Read64(header, 40);
            long lastUsable = PartitionBytes.Read64(header, 48);
            long entriesLba = PartitionBytes.Read64(header, 72);
            long entryCount = PartitionBytes.Read32(header, 80);
            long entrySize = PartitionBytes.Read32(header, 84);
            return current == 1 && backup > current && firstUsable <= lastUsable && entriesLba >= 2 &&
                entryCount > 0 && entrySize >= 128 && entrySize % 8 == 0;
        }

        public static bool IsValidHeaderAt(byte[] header, long expectedLba, long otherLba) {
            if (header == null || header.Length < 92 || !IsSignature(header) ||
                PartitionBytes.Read32(header, 8) != 65536 || PartitionBytes.Read32(header, 20) != 0) { return false; }
            int headerSize = (int)PartitionBytes.Read32(header, 12);
            if (headerSize < 92 || headerSize > header.Length ||
                PartitionBytes.Crc32(header, 0, headerSize, 16, 4) != PartitionBytes.Read32(header, 16)) { return false; }
            long firstUsable = PartitionBytes.Read64(header, 40);
            long lastUsable = PartitionBytes.Read64(header, 48);
            return PartitionBytes.Read64(header, 24) == expectedLba &&
                PartitionBytes.Read64(header, 32) == otherLba &&
                firstUsable > 1 && firstUsable <= lastUsable &&
                PartitionBytes.Read32(header, 80) > 0;
        }

        public static bool ValidateEntries(byte[] header, byte[] entries, int entryBytes) {
            if (!IsValidHeader(header) || entryBytes < 0 || entryBytes > entries.Length) { return false; }
            long count = PartitionBytes.Read32(header, 80);
            long size = PartitionBytes.Read32(header, 84);
            if (count > entryBytes / size) { return false; }
            long expectedCrc = PartitionBytes.Read32(header, 88);
            return PartitionBytes.Crc32(entries, 0, (int)(count * size), entryBytes, 0) == expectedCrc;
        }

        public static Partition Entry(byte[] header, byte[] entries, int entryBytes, int index) {
            if (!ValidateEntries(header, entries, entryBytes) || index < 0 || index >= PartitionBytes.Read32(header, 80)) {
                return new Partition(false, true, 0, 0, 0);
            }
            int entrySize = (int)PartitionBytes.Read32(header, 84);
            int offset = index * entrySize;
            if (IsZeroGuid(entries, offset)) { return new Partition(false, true, 0, 0, 0); }
            long first = PartitionBytes.Read64(entries, offset + 32);
            long last = PartitionBytes.Read64(entries, offset + 40);
            long firstUsable = PartitionBytes.Read64(header, 40);
            long lastUsable = PartitionBytes.Read64(header, 48);
            if (first < firstUsable || first > last || last > lastUsable) { return new Partition(false, true, 0, 0, 0); }
            return new Partition(true, true, entries[offset], first, last - first + 1);
        }
    }
}
