namespace Australis.Kernel.Pci {
    public class NativePciConfigAccess : IPciConfigAccess {
        private long Address(int bdf, int offset) {
            long enabled = 1073741824; enabled = enabled * 2;
            return enabled + bdf * 256 + offset / 4 * 4;
        }
        public long Read32(int bdf, int offset) {
            System.Kernel.Port.Write32(3320, Address(bdf, offset)); return System.Kernel.Port.Read32(3324);
        }
        public void Write32(int bdf, int offset, long value) {
            System.Kernel.Port.Write32(3320, Address(bdf, offset)); System.Kernel.Port.Write32(3324, value);
        }
    }
}
