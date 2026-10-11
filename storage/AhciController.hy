namespace Australis.Kernel.Storage {
    // Four page-aligned DMA buffers: command list, received FIS, command
    // table, and one 4 KiB transfer page. Register offsets are from ABAR.
    public interface IAhciControllerIo {
        long Read32(int offset);
        void Write32(int offset, long value);
        long PhysicalPage(int index);
        void WriteDma(int page, int offset, byte[] source, int count);
        void ReadDma(int page, int offset, byte[] destination, int count);
        void Pause();
        long Deadline(int milliseconds);
        bool Expired(long deadline);
        long CompletionEpoch(); // -1 selects polling for host-only transports
        void ReportFailure(int cause, int state);
    }

    public class AhciController : IBlockTransport {
        private static long U32Base() { long high = 65536; return high * high; }
        private static long HighBit() { long high = 65536; return high * 32768; }
        private IAhciControllerIo io;
        private int maximumPolls;
        private int port;
        private int sectorSize;
        private long sectorCount;
        private bool ready;
        private int lastError;
        private int recoveryState;
        private int retries;

        public AhciController(IAhciControllerIo inputIo, int inputMaximumPolls) {
            io = inputIo; maximumPolls = inputMaximumPolls;
            port = -1; sectorSize = 0; sectorCount = 0; ready = false;
            lastError = 0;
            recoveryState = 0; retries = 0;
        }

        private int PortBase() { return 256 + port * 128; }

        private void WriteAddress(int lowOffset, long address) {
            io.Write32(PortBase() + lowOffset, address % U32Base());
            io.Write32(PortBase() + lowOffset + 4, address / U32Base());
        }

        private bool WaitCommandReady() {
            long deadline = io.Deadline(maximumPolls);
            while (!io.Expired(deadline)) {
                long taskFile = io.Read32(PortBase() + 32);
                if (taskFile % 256 / 8 % 2 == 0 && taskFile % 256 / 128 == 0) { return true; }
                io.Pause();
            }
            return false;
        }

        private bool Issue(byte[] header, byte[] table, int expectedBytes) {
            lastError = 0;
            if (!WaitCommandReady()) { lastError = 1; return false; }
            io.WriteDma(0, 0, header, 32);
            io.WriteDma(2, 0, table, 144);
            io.Write32(PortBase() + 16, U32Base() - 1); // clear PxIS
            io.Write32(PortBase() + 48, U32Base() - 1); // clear PxSERR
            long epoch = io.CompletionEpoch();
            io.Write32(PortBase() + 56, 1); // slot zero
            long deadline = io.Deadline(maximumPolls);
            while (!io.Expired(deadline)) {
                long interruptStatus = io.Read32(PortBase() + 16);
                long taskFile = io.Read32(PortBase() + 32);
                if ((interruptStatus / 1073741824) % 2 != 0 || taskFile % 2 != 0 ||
                    (taskFile / 32) % 2 != 0) { lastError = 2; Acknowledge(interruptStatus); return false; }
                if (epoch >= 0 && io.CompletionEpoch() == epoch) {
                    io.Pause(); continue;
                }
                if (io.Read32(PortBase() + 56) % 2 == 0) {
                    // AHCI updates PRDBC in the command header. A command may
                    // complete without transferring every requested byte.
                    io.ReadDma(0, 0, header, 32);
                    long b0 = header[4]; long b1 = header[5];
                    long b2 = header[6]; long b3 = header[7];
                    long transferred = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
                    if (transferred != expectedBytes) { lastError = 3; Acknowledge(interruptStatus); return false; }
                    bool good =
                        (io.Read32(PortBase() + 16) / 1073741824) % 2 == 0 &&
                        io.Read32(PortBase() + 32) % 2 == 0;
                    if (!good) { lastError = 4; }
                    Acknowledge(interruptStatus);
                    return good;
                }
                io.Pause();
            }
            lastError = 5; return false;
        }

        private void Acknowledge(long status) {
            if (status != 0) { io.Write32(PortBase() + 16, status); }
            long mask = 1;
            int bit = 0;
            while (bit < port) { mask = mask * 2; bit = bit + 1; }
            io.Write32(8, mask); // HBA.IS is write-one-to-clear
        }

        public bool Initialize() {
            ready = false; port = -1; sectorSize = 0; sectorCount = 0;
            lastError = 0;
            if (io == null || maximumPolls < 1) { return false; }
            long capabilities = io.Read32(0);
            long[] pages = new long[4];
            int page = 0;
            while (page < 4) {
                pages[page] = io.PhysicalPage(page);
                if (pages[page] < 4096 || pages[page] % 4096 != 0 ||
                    ((capabilities / HighBit()) % 2 == 0 && pages[page] >= U32Base())) { return false; }
                int previous = 0;
                while (previous < page) {
                    if (pages[previous] == pages[page]) { return false; }
                    previous = previous + 1;
                }
                page = page + 1;
            }
            byte[] zero = new byte[4096];
            page = 0;
            while (page < 4) { io.WriteDma(page, 0, zero, 4096); page = page + 1; }
            long globalControl = io.Read32(4);
            if ((globalControl / HighBit()) % 2 == 0) { io.Write32(4, globalControl + HighBit()); }
            long implemented = io.Read32(12);
            int candidate = 0;
            long mask = 1;
            while (candidate < 32) {
                if ((implemented / mask) % 2 != 0) {
                    int portOffset = 256 + candidate * 128;
                    if (Ahci.IsActiveSata(io.Read32(portOffset + 36), io.Read32(portOffset + 40))) {
                        port = candidate; break;
                    }
                }
                candidate = candidate + 1; mask = mask * 2;
            }
            if (port < 0 || !StopEngine()) { return false; }
            WriteAddress(0, pages[0]);
            WriteAddress(8, pages[1]);
            if (!StartEngine()) { return false; }
            // GHC.IE and the selected port's completion/error sources.
            io.Write32(PortBase() + 20, 2109735039);
            long enabled = io.Read32(4);
            if ((enabled / 2) % 2 == 0) { io.Write32(4, enabled + 2); }

            byte[] header = new byte[32];
            byte[] table = new byte[144];
            if (!Ahci.BuildIdentify(header, table, pages[2], pages[3]) || !Issue(header, table, 512)) { return false; }
            byte[] identify = new byte[512];
            io.ReadDma(3, 0, identify, 512);
            if (!Ahci.SupportsLba48(identify)) { return false; }
            sectorCount = Ahci.IdentifySectorCount(identify);
            if (sectorCount < 1) { return false; }
            sectorSize = 512; ready = true;
            return true;
        }

        private bool StopEngine() {
            int commandOffset = PortBase() + 24;
            long command = io.Read32(commandOffset);
            if (command % 2 != 0) { command = command - 1; }
            if ((command / 16) % 2 != 0) { command = command - 16; }
            io.Write32(commandOffset, command);
            long deadline = io.Deadline(maximumPolls);
            while (!io.Expired(deadline)) {
                command = io.Read32(commandOffset);
                if ((command / 16384) % 2 == 0 && (command / 32768) % 2 == 0) { return true; }
                io.Pause();
            }
            return false;
        }

        private bool StartEngine() {
            int commandOffset = PortBase() + 24;
            long deadline = io.Deadline(maximumPolls);
            while (!io.Expired(deadline) && (io.Read32(commandOffset) / 16384) % 2 != 0) {
                io.Pause();
            }
            if (io.Expired(deadline)) { return false; }
            long command = io.Read32(commandOffset);
            if ((command / 16) % 2 == 0) { command = command + 16; }
            if (command % 2 == 0) { command = command + 1; }
            io.Write32(commandOffset, command);
            return true;
        }

        public int SectorSize() { return sectorSize; }
        public long SectorCount() { return sectorCount; }
        public int LastError() { return lastError; }
        public int RecoveryState() { return recoveryState; }
        public int RetryCount() { return retries; }
        public bool Flush() {
            if (!ready) { return false; }
            byte[] header = new byte[32]; byte[] table = new byte[144];
            if (!Ahci.BuildFlushCacheExt(header, table, io.PhysicalPage(2)) ||
                !Issue(header, table, 0)) {
                recoveryState = 4; io.ReportFailure(lastError, recoveryState);
                ready = false; return false;
            }
            return true;
        }

        public bool Write(long lba, int sectors, byte[] source) {
            if (!ready || source == null || lba < 0 || sectors < 1 ||
                lba >= sectorCount || sectors > sectorCount - lba ||
                sectors > source.Length / sectorSize) { return false; }
            byte[] transfer = new byte[4096];
            int remaining = sectors;
            int copied = 0;
            while (remaining > 0) {
                int blocks = 4096 / sectorSize;
                if (blocks > remaining) { blocks = remaining; }
                int count = blocks * sectorSize;
                int index = 0;
                while (index < count) {
                    transfer[index] = source[copied + index]; index = index + 1;
                }
                io.WriteDma(3, 0, transfer, count);
                byte[] header = new byte[32]; byte[] table = new byte[144];
                if (!Ahci.BuildWriteDmaExt(header, table, io.PhysicalPage(2),
                    io.PhysicalPage(3), lba, blocks, sectorSize) ||
                    !Issue(header, table, count)) {
                    recoveryState = 4; io.ReportFailure(lastError, recoveryState);
                    ready = false; return false;
                }
                copied = copied + count;
                lba = lba + blocks; remaining = remaining - blocks;
            }
            return true;
        }

        private bool ReadOnce(long lba, int sectors, byte[] destination) {
            if (!ready || destination == null || lba < 0 || sectors < 1 ||
                lba >= sectorCount || sectors > sectorCount - lba ||
                sectors > destination.Length / sectorSize) { return false; }
            byte[] staged = new byte[sectors * sectorSize];
            byte[] transfer = new byte[4096];
            int remaining = sectors;
            int copied = 0;
            while (remaining > 0) {
                int blocks = 4096 / sectorSize;
                if (blocks > remaining) { blocks = remaining; }
                byte[] header = new byte[32];
                byte[] table = new byte[144];
                if (!Ahci.BuildReadDmaExt(header, table, io.PhysicalPage(2), io.PhysicalPage(3),
                    lba, blocks, sectorSize) || !Issue(header, table, blocks * sectorSize)) {
                    if (lastError == 0) { lastError = 6; }
                    ready = false; return false;
                }
                io.ReadDma(3, 0, transfer, blocks * sectorSize);
                int i = 0;
                while (i < blocks * sectorSize) { staged[copied + i] = transfer[i]; i = i + 1; }
                copied = copied + blocks * sectorSize;
                lba = lba + blocks; remaining = remaining - blocks;
            }
            int i = 0;
            while (i < copied) { destination[i] = staged[i]; i = i + 1; }
            return true;
        }

        // One failed command gets one complete controller reinitialization and
        // retry. A second failure leaves the device unavailable to callers.
        public bool Read(long lba, int sectors, byte[] destination) {
            if (destination == null || lba < 0 || sectors < 1 ||
                (ready && (lba >= sectorCount || sectors > sectorCount - lba ||
                sectors > destination.Length / sectorSize))) { return false; }
            if (ReadOnce(lba, sectors, destination)) {
                recoveryState = 0; io.ReportFailure(0, 0); return true;
            }
            int cause = lastError;
            recoveryState = 2;
            if (cause == 1 || cause == 5) { recoveryState = 1; } // timeout or fatal/short transfer
            io.ReportFailure(cause, recoveryState);
            recoveryState = 3; retries = retries + 1; io.ReportFailure(cause, recoveryState);
            if (!Initialize()) { recoveryState = 4; io.ReportFailure(cause, recoveryState); return false; }
            if (ReadOnce(lba, sectors, destination)) {
                recoveryState = 0; io.ReportFailure(0, 0); return true;
            }
            recoveryState = 4; io.ReportFailure(lastError, recoveryState);
            return false;
        }
    }
}
