using Australis.Kernel.Pci;

namespace Australis.Kernel.Usb {
    // Configure one xHCI message on the BSP local APIC. The generic vector
    // handler only acknowledges IMAN and records a deferred event; event-ring
    // and port processing stays in normal kernel context.
    public class XhciInterrupts {
        private static long U32() { long n = 65536; return n * n; }

        private static long Bar(IPciConfigAccess pci, int bdf, int index) {
            if (index < 0 || index > 5) { return 0; }
            long low = pci.Read32(bdf, 16 + index * 4);
            if (low % 2 != 0) { return 0; }
            long value = low - low % 16;
            if ((low / 2) % 4 == 2 && index < 5) {
                value = value + pci.Read32(bdf, 20 + index * 4) * U32();
            }
            return value;
        }

        private static bool EnableMsi(IPciConfigAccess pci, int bdf, int capability) {
            long header = pci.Read32(bdf, capability);
            long control = header / 65536;
            bool wide = (control / 128) % 2 != 0;
            pci.Write32(bdf, capability + 4, 4276092928); // 0xfee00000
            int dataOffset = capability + 8;
            if (wide) { pci.Write32(bdf, capability + 8, 0); dataOffset = capability + 12; }
            pci.Write32(bdf, dataOffset, 50);
            control = control - (control / 16 % 8) * 16;
            if (control % 2 == 0) { control = control + 1; }
            pci.Write32(bdf, capability, header % 65536 + control * 65536);
            return (pci.Read32(bdf, capability) / 65536) % 2 != 0;
        }

        private static bool EnableMsix(IPciConfigAccess pci, int bdf, int capability,
            long mappedBar, long mappedLength) {
            long table = pci.Read32(bdf, capability + 4);
            int barIndex = (int)(table % 8);
            long offset = table - barIndex;
            long primary = Bar(pci, bdf, 0);
            if (barIndex != 0 || Bar(pci, bdf, barIndex) != primary || offset < 0 ||
                offset + 16 > mappedLength) { return false; }
            long entry = mappedBar + offset;
            System.Kernel.Memory.Write32(entry + 12, 1);
            System.Kernel.Memory.Write32(entry, 4276092928);
            System.Kernel.Memory.Write32(entry + 4, 0);
            System.Kernel.Memory.Write32(entry + 8, 50);
            System.Kernel.Memory.Write32(entry + 12, 0);
            long header = pci.Read32(bdf, capability);
            long control = header / 65536;
            if ((control / 16384) % 2 != 0) { control = control - 16384; }
            if ((control / 32768) % 2 == 0) { control = control + 32768; }
            pci.Write32(bdf, capability, header % 65536 + control * 65536);
            return (pci.Read32(bdf, capability) / 2147483648) % 2 != 0;
        }

        public static int Configure(int bdf, long mappedBar, long mappedLength) {
            if (bdf < 0 || bdf > 65535 || mappedBar < 4096 || mappedLength < 4096) { return 0; }
            NativePciConfigAccess pci = new NativePciConfigAccess();
            long command = pci.Read32(bdf, 4);
            long low = command % 65536;
            if ((low / 2) % 2 == 0) { low = low + 2; }
            if ((low / 4) % 2 == 0) { low = low + 4; }
            pci.Write32(bdf, 4, low + command / 65536 * 65536);
            if ((pci.Read32(bdf, 4) / 1048576) % 2 == 0) {
                System.Kernel.Managed.Release(pci); return 0;
            }
            int pointer = (int)(pci.Read32(bdf, 52) % 256);
            int msi = 0; int msix = 0; int visited = 0;
            while (pointer >= 64 && pointer < 256 && visited < 48) {
                long cap = pci.Read32(bdf, pointer);
                int id = (int)(cap % 256);
                if (id == 5) { msi = pointer; }
                if (id == 17) { msix = pointer; }
                pointer = (int)(cap / 256 % 256);
                visited = visited + 1;
            }
            int result = 0;
            if (msix != 0 && EnableMsix(pci, bdf, msix, mappedBar, mappedLength)) { result = 2; }
            if (result == 0 && msi != 0 && EnableMsi(pci, bdf, msi)) { result = 1; }
            System.Kernel.Managed.Release(pci);
            return result;
        }
    }
}
