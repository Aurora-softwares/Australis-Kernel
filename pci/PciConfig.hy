namespace Australis.Kernel.Pci {
    public interface IPciConfigAccess {
        long Read32(int bdf, int offset);
        void Write32(int bdf, int offset, long value);
    }

    public class PciBarInfo {
        private long address;
        private long size;
        private bool memory;
        private bool wide;
        public PciBarInfo(long inputAddress, long inputSize, bool inputMemory, bool inputWide) {
            address = inputAddress; size = inputSize; memory = inputMemory; wide = inputWide;
        }
        public long Address() { return address; }
        public long Size() { return size; }
        public bool IsMemory() { return memory; }
        public bool Is64Bit() { return wide; }
        public bool IsValid() { return memory && address >= 4096 && size >= 4096 && size % 4096 == 0; }
    }

    public class PciBars {
        private static long U32() { long n = 65536; return n * n; }
        public static PciBarInfo Probe(IPciConfigAccess config, int bdf, int index) {
            if (config == null || bdf < 0 || bdf > 65535 || index < 0 || index > 5) {
                return new PciBarInfo(0, 0, false, false);
            }
            int offset = 16 + index * 4;
            long originalLow = config.Read32(bdf, offset);
            if (originalLow % 2 != 0) { return new PciBarInfo(0, 0, false, false); }
            bool wide = (originalLow / 2) % 4 == 2;
            if (wide && index == 5) { return new PciBarInfo(0, 0, false, true); }
            long originalHigh = 0;
            if (wide) { originalHigh = config.Read32(bdf, offset + 4); }
            long command = config.Read32(bdf, 4);
            long disabled = command - command % 4;
            config.Write32(bdf, 4, disabled);
            config.Write32(bdf, offset, U32() - 1);
            if (wide) { config.Write32(bdf, offset + 4, U32() - 1); }
            long maskLow = config.Read32(bdf, offset);
            long maskHigh = 0;
            if (wide) { maskHigh = config.Read32(bdf, offset + 4); }
            config.Write32(bdf, offset, originalLow);
            if (wide) { config.Write32(bdf, offset + 4, originalHigh); }
            config.Write32(bdf, 4, command);
            long address = originalLow - originalLow % 16;
            long lowMask = maskLow - maskLow % 16;
            long size = 0;
            if (wide) {
                // The virtual mapping remains in the lower canonical half, but
                // page-table leaves may target controller MMIO above 4 GiB.
                address = address + originalHigh * U32();
                if (maskHigh != U32() - 1) {
                    return new PciBarInfo(0, 0, true, true);
                }
            }
            if (lowMask != 0) { size = U32() - lowMask; }
            return new PciBarInfo(address, size, true, wide);
        }
    }
}
