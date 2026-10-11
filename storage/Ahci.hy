namespace Australis.Kernel.Storage {
    // Register and DMA boundary used by the AHCI protocol code. The hardware
    // implementation must map the HBA BAR uncached and pass physical DMA
    // addresses below the controller's advertised address-width limit.
    public interface IAhciRegisters {
        long Read32(int offset);
        void Write32(int offset, long value);
        void Pause();
    }

    public class Ahci {
        public static long MaxU32() {
            long max = 2147483647;
            return max * 2 + 1;
        }

        private static long MaxLba48() {
            long value = 65535;
            int i = 0;
            while (i < 2) { value = value * 65536 + 65535; i = i + 1; }
            return value;
        }

        private static void Write32(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 4) { bytes[offset + i] = (byte)(value % 256); value = value / 256; i = i + 1; }
        }

        private static void Write64(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 8) { bytes[offset + i] = (byte)(value % 256); value = value / 256; i = i + 1; }
        }

        private static long Read16(byte[] bytes, int offset) {
            return bytes[offset] + bytes[offset + 1] * 256;
        }

        public static bool SupportsLba48(byte[] identify) {
            if (identify.Length < 168) { return false; }
            // Word 83, bit 10. The high byte contains bits 8..15, so bit 10
            // is the value 4 and can be checked without a signed bit-mask.
            return (identify[167] / 4) % 2 != 0;
        }

        // PxSSTS: DET=3 and IPM=1 are the AHCI definition of an active SATA
        // link. SATAPI, port multipliers, and enclosure-management ports stay
        // out of the bootstrap disk path until their distinct protocols exist.
        public static bool IsActiveSata(long signature, long sataStatus) {
            return signature == 257 && sataStatus % 16 == 3 && (sataStatus / 256) % 16 == 1;
        }

        // Return the lowest implemented active SATA port, or -1. The HBA port
        // register bank starts at 0x100 and each port occupies 0x80 bytes.
        public static int FindActiveSataPort(IAhciRegisters registers) {
            long implemented = registers.Read32(12);
            int port = 0;
            long mask = 1;
            while (port < 32) {
                if ((implemented / mask) % 2 != 0) {
                    int portBase = 256 + port * 128;
                    if (IsActiveSata(registers.Read32(portBase + 36), registers.Read32(portBase + 40))) { return port; }
                }
                port = port + 1;
                mask = mask * 2;
            }
            return -1;
        }

        // Stop the command and receive engines before changing CLB/FB. Polling
        // is intentionally bounded; a wedged controller is a failed device,
        // never a reason for the kernel to spin forever during boot.
        public static bool StopCommandEngine(IAhciRegisters registers, int port, int maximumPolls) {
            if (port < 0 || port > 31 || maximumPolls < 1) { return false; }
            int command = 256 + port * 128 + 24;
            long value = registers.Read32(command);
            value = value - value % 2;
            if ((value / 16) % 2 != 0) { value = value - 16; }
            registers.Write32(command, value);
            int attempt = 0;
            while (attempt < maximumPolls) {
                value = registers.Read32(command);
                if ((value / 16384) % 2 == 0 && (value / 32768) % 2 == 0) { return true; }
                registers.Pause();
                attempt = attempt + 1;
            }
            return false;
        }

        public static bool StartCommandEngine(IAhciRegisters registers, int port, int maximumPolls) {
            if (port < 0 || port > 31 || maximumPolls < 1) { return false; }
            int command = 256 + port * 128 + 24;
            int attempt = 0;
            while (attempt < maximumPolls && (registers.Read32(command) / 16384) % 2 != 0) {
                registers.Pause();
                attempt = attempt + 1;
            }
            if (attempt == maximumPolls) { return false; }
            long value = registers.Read32(command);
            if ((value / 16) % 2 == 0) { value = value + 16; }
            if (value % 2 == 0) { value = value + 1; }
            registers.Write32(command, value);
            return true;
        }

        // Build command slot zero for ATA IDENTIFY DEVICE (0xEC). The PRDT has
        // one 512-byte entry, so a transport can issue it after installing the
        // 1 KiB command-list and 256-byte received-FIS buffers for the port.
        public static bool BuildIdentify(byte[] header, byte[] table, long commandTablePhysical, long dataPhysical) {
            if (header.Length < 32 || table.Length < 144 || commandTablePhysical < 0 || dataPhysical < 0) { return false; }
            int i = 0;
            while (i < 32) { header[i] = 0; i = i + 1; }
            i = 0; while (i < 144) { table[i] = 0; i = i + 1; }
            header[0] = 5; // CFL: 5 DWORD register H2D FIS
            header[2] = 1; // PRDTL: one entry
            Write64(header, 8, commandTablePhysical);
            table[0] = 39; table[1] = 128; table[2] = 236; // FIS_REG_H2D, C, IDENTIFY
            Write64(table, 128, dataPhysical);
            table[140] = 255; table[141] = 1; table[142] = 0; table[143] = 128; // IOC | (512 - 1)
            return true;
        }

        // One ATA READ DMA EXT (0x25) command. It supports the full nonzero
        // 48-bit LBA and issues no more than 65535 logical sectors per command;
        // larger VFS reads are split by the block scheduler.
        public static bool BuildReadDmaExt(byte[] header, byte[] table, long commandTablePhysical,
            long dataPhysical, long lba, int sectors, int sectorSize) {
            if (header.Length < 32 || table.Length < 144 || commandTablePhysical < 0 || dataPhysical < 0 ||
                lba < 0 || lba > MaxLba48() || sectors < 1 || sectors > 65535 ||
                (sectorSize != 512 && sectorSize != 1024 && sectorSize != 2048 && sectorSize != 4096)) { return false; }
            long byteCount = sectors * sectorSize;
            if (byteCount > 4194304) { return false; } // one AHCI PRDT entry encodes at most 4 MiB
            int i = 0;
            while (i < 32) { header[i] = 0; i = i + 1; }
            i = 0; while (i < 144) { table[i] = 0; i = i + 1; }
            header[0] = 5; header[2] = 1; Write64(header, 8, commandTablePhysical);
            table[0] = 39; table[1] = 128; table[2] = 37; // READ DMA EXT
            table[7] = 64; // device register: select LBA addressing
            long remainingLba = lba;
            table[4] = (byte)(remainingLba % 256); remainingLba = remainingLba / 256;
            table[5] = (byte)(remainingLba % 256); remainingLba = remainingLba / 256;
            table[6] = (byte)(remainingLba % 256); remainingLba = remainingLba / 256;
            table[8] = (byte)(remainingLba % 256); remainingLba = remainingLba / 256;
            table[9] = (byte)(remainingLba % 256); remainingLba = remainingLba / 256;
            table[10] = (byte)(remainingLba % 256);
            table[12] = (byte)(sectors % 256);
            table[13] = (byte)(sectors / 256);
            Write64(table, 128, dataPhysical);
            byteCount = byteCount - 1;
            table[140] = (byte)(byteCount % 256);
            table[141] = (byte)((byteCount / 256) % 256);
            table[142] = (byte)((byteCount / 65536) % 256);
            table[143] = 128; // IOC
            return true;
        }

        public static bool BuildWriteDmaExt(byte[] header, byte[] table,
            long commandTablePhysical, long dataPhysical, long lba, int sectors,
            int sectorSize) {
            if (!BuildReadDmaExt(header, table, commandTablePhysical, dataPhysical,
                lba, sectors, sectorSize)) { return false; }
            header[0] = 69; // W=1, CFL=5
            table[2] = 53; // ATA WRITE DMA EXT
            return true;
        }

        public static bool BuildFlushCacheExt(byte[] header, byte[] table,
            long commandTablePhysical) {
            if (header == null || table == null || header.Length < 32 ||
                table.Length < 144 || commandTablePhysical < 0) { return false; }
            int i = 0;
            while (i < 32) { header[i] = 0; i = i + 1; }
            i = 0;
            while (i < 144) { table[i] = 0; i = i + 1; }
            header[0] = 5; // No PRDT entry
            Write64(header, 8, commandTablePhysical);
            table[0] = 39; table[1] = 128; table[2] = 234; // FLUSH CACHE EXT
            table[7] = 64;
            return true;
        }

        // Logical-sector count from ATA IDENTIFY words. LBA48 is required for
        // modern disks; an LBA28 fallback exists for older SATA disks. The
        // bootstrap accepts 512-byte logical sectors only because ATA words do
        // not carry a universally safe physical-sector interpretation.
        public static long IdentifySectorCount(byte[] identify) {
            if (identify.Length < 512) { return 0; }
            if ((identify[167] / 4) % 2 != 0) {
                long byte200 = identify[200]; long byte201 = identify[201];
                long byte202 = identify[202]; long byte203 = identify[203];
                long byte204 = identify[204]; long byte205 = identify[205];
                long byte206 = identify[206]; long byte207 = identify[207];
                long low = byte200 + byte201 * 256 + (byte202 + byte203 * 256) * 65536;
                long high = byte204 + byte205 * 256 + (byte206 + byte207 * 256) * 65536;
                long value = low + high * 65536 * 65536;
                if (value > 0) { return value; }
            }
            long byte120 = identify[120]; long byte121 = identify[121];
            long byte122 = identify[122]; long byte123 = identify[123];
            return byte120 + byte121 * 256 + (byte122 + byte123 * 256) * 65536;
        }
    }
}
