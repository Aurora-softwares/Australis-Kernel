namespace Australis.Kernel.Storage {
    // Synchronous block I/O contract shared by AHCI, NVMe and USB storage.
    // A failed write may have changed part of the media; only a successful
    // Flush can establish durability for callers that need it.
    public interface IBlockTransport {
        int SectorSize();
        long SectorCount();
        bool Read(long lba, int sectors, byte[] destination);
        bool Write(long lba, int sectors, byte[] source);
        bool Flush();
    }

    public class BlockStatus {
        public static int Ok() { return 0; }
        public static int Unavailable() { return 1; }
        public static int InvalidArgument() { return 2; }
        public static int OutOfRange() { return 3; }
        public static int IoFailure() { return 4; }
    }

    public class BlockGeometry {
        private int sectorSize;
        private long sectorCount;

        public BlockGeometry(int inputSectorSize, long inputSectorCount) {
            sectorSize = inputSectorSize;
            sectorCount = inputSectorCount;
        }

        public int SectorSize() { return sectorSize; }
        public long SectorCount() { return sectorCount; }

        // Storage transports use power-of-two logical sectors. Restricting the
        // bootstrap contract to 512 through 4096 bytes prevents byte-count
        // overflow and keeps the page-backed DMA path naturally aligned.
        public bool IsValid() {
            if (sectorCount <= 0 || sectorSize < 512 || sectorSize > 4096) { return false; }
            return sectorSize == 512 || sectorSize == 1024 || sectorSize == 2048 || sectorSize == 4096;
        }
    }

    public class BlockDevice {
        private IBlockTransport transport;
        private BlockGeometry geometry;
        private int lastStatus;

        public BlockDevice(IBlockTransport inputTransport) {
            transport = inputTransport;
            geometry = new BlockGeometry(0, 0);
            lastStatus = BlockStatus.Unavailable();
            if (transport != null) {
                geometry = new BlockGeometry(transport.SectorSize(), transport.SectorCount());
                if (!geometry.IsValid()) { lastStatus = BlockStatus.InvalidArgument(); }
            }
        }

        public int SectorSize() { return geometry.SectorSize(); }
        public long SectorCount() { return geometry.SectorCount(); }
        public int LastStatus() { return lastStatus; }

        // A request either transfers every requested sector or reports failure.
        // The subtraction form is deliberate: `lba + sectors` could overflow a
        // signed 64-bit value before the capacity comparison.
        public int Read(long lba, int sectors, byte[] destination) {
            if (transport == null) { lastStatus = BlockStatus.Unavailable(); return lastStatus; }
            if (!geometry.IsValid() || lba < 0 || sectors < 1 || destination == null) {
                lastStatus = BlockStatus.InvalidArgument(); return lastStatus;
            }
            if (lba >= geometry.SectorCount() || sectors > geometry.SectorCount() - lba) {
                lastStatus = BlockStatus.OutOfRange(); return lastStatus;
            }
            if (sectors > destination.Length / geometry.SectorSize()) {
                lastStatus = BlockStatus.InvalidArgument(); return lastStatus;
            }
            // A controller may DMA some sectors before reporting an error.
            // Stage the complete transfer so failure never exposes partial
            // data to filesystem parsers or their callers.
            int byteCount = sectors * geometry.SectorSize();
            byte[] staged = new byte[byteCount];
            if (!transport.Read(lba, sectors, staged)) {
                lastStatus = BlockStatus.IoFailure(); return lastStatus;
            }
            int i = 0;
            while (i < byteCount) {
                destination[i] = staged[i];
                i = i + 1;
            }
            lastStatus = BlockStatus.Ok();
            return lastStatus;
        }

        public int Write(long lba, int sectors, byte[] source) {
            if (transport == null) { lastStatus = BlockStatus.Unavailable(); return lastStatus; }
            if (!geometry.IsValid() || lba < 0 || sectors < 1 || source == null) {
                lastStatus = BlockStatus.InvalidArgument(); return lastStatus;
            }
            if (lba >= geometry.SectorCount() || sectors > geometry.SectorCount() - lba) {
                lastStatus = BlockStatus.OutOfRange(); return lastStatus;
            }
            if (sectors > source.Length / geometry.SectorSize()) {
                lastStatus = BlockStatus.InvalidArgument(); return lastStatus;
            }
            int byteCount = sectors * geometry.SectorSize();
            byte[] staged = new byte[byteCount];
            int i = 0;
            while (i < byteCount) { staged[i] = source[i]; i = i + 1; }
            if (!transport.Write(lba, sectors, staged)) {
                lastStatus = BlockStatus.IoFailure(); return lastStatus;
            }
            lastStatus = BlockStatus.Ok();
            return lastStatus;
        }

        public int Flush() {
            if (transport == null) { lastStatus = BlockStatus.Unavailable(); return lastStatus; }
            if (!geometry.IsValid()) { lastStatus = BlockStatus.InvalidArgument(); return lastStatus; }
            if (!transport.Flush()) { lastStatus = BlockStatus.IoFailure(); return lastStatus; }
            lastStatus = BlockStatus.Ok();
            return lastStatus;
        }
    }
}
