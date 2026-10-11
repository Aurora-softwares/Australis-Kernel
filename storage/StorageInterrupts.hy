// PCI configuration mechanism #1 is available on the q35 bootstrap path.
// Program one MSI or MSI-X message for the BSP local APIC, vector 0x31.
public class StorageInterrupts {
    private static long U32() { long n = 65536; return n * n; }

    private static long ConfigAddress(int bdf, int offset) {
        long address = 1073741824;
        address = address * 2;
        return address + bdf * 256 + offset / 4 * 4;
    }

    private static long Read(int bdf, int offset) {
        System.Kernel.Port.Write32(3320, ConfigAddress(bdf, offset));
        return System.Kernel.Port.Read32(3324);
    }

    private static void Write(int bdf, int offset, long value) {
        System.Kernel.Port.Write32(3320, ConfigAddress(bdf, offset));
        System.Kernel.Port.Write32(3324, value);
    }

    private static long Bar(int bdf, int index) {
        if (index < 0 || index > 5) { return 0; }
        long low = Read(bdf, 16 + index * 4);
        if (low % 2 != 0) { return 0; }
        long barBase = low - low % 16;
        if ((low / 2) % 4 == 2 && index < 5) {
            barBase = barBase + Read(bdf, 20 + index * 4) * U32();
        }
        return barBase;
    }

    private static bool EnableMsi(int bdf, int capability) {
        long header = Read(bdf, capability);
        long control = header / 65536;
        bool wide = (control / 128) % 2 != 0;
        Write(bdf, capability + 4, 4276092928); // 0xfee00000, BSP APIC ID 0
        int dataOffset = capability + 8;
        if (wide) { Write(bdf, capability + 8, 0); dataOffset = capability + 12; }
        Write(bdf, dataOffset, 49);
        control = control - (control / 16 % 8) * 16; // one vector
        if (control % 2 == 0) { control = control + 1; }
        Write(bdf, capability, header % 65536 + control * 65536);
        return (Read(bdf, capability) / 65536) % 2 != 0;
    }

    private static bool EnableMsix(long bootInfo, int bdf, int capability, long mappedBar) {
        long tableInfo = Read(bdf, capability + 4);
        int barIndex = (int)(tableInfo % 8);
        long tableOffset = tableInfo - barIndex;
        long barBase = Bar(bdf, barIndex);
        if (barBase == 0) { return false; }
        long entry = 0;
        long primary = Bar(bdf, 0);
        if (barIndex == 0 && barBase == primary && tableOffset + 16 <= 65536) {
            entry = mappedBar + tableOffset;
        } else {
            long physicalPage = barBase + tableOffset;
            long offsetInPage = physicalPage % 4096;
            physicalPage = physicalPage - offsetInPage;
            if (offsetInPage > 4080) { return false; }
            long virtualPage = KernelAddressSpace.FindUnmappedRange(bootInfo, 1);
            if (virtualPage == 0 || !KernelAddressSpace.MapPage(bootInfo, virtualPage,
                physicalPage, KernelAddressSpace.DeviceReadWrite())) { return false; }
            entry = virtualPage + offsetInPage;
            System.Kernel.Memory.Write64(bootInfo + 1248, virtualPage);
        }
        System.Kernel.Memory.Write32(entry + 12, 1); // mask entry during setup
        System.Kernel.Memory.Write32(entry, 4276092928);
        System.Kernel.Memory.Write32(entry + 4, 0);
        System.Kernel.Memory.Write32(entry + 8, 49);
        System.Kernel.Memory.Write32(entry + 12, 0);
        long header = Read(bdf, capability);
        long control = header / 65536;
        if ((control / 16384) % 2 != 0) { control = control - 16384; }
        if ((control / 32768) % 2 == 0) { control = control + 32768; }
        Write(bdf, capability, header % 65536 + control * 65536);
        return (Read(bdf, capability) / 2147483648) % 2 != 0;
    }

    public static bool Configure(long bootInfo, int kind) {
        if (bootInfo < 4096 || (kind != 1 && kind != 2)) { return false; }
        int bdf = System.Kernel.Memory.Read32(bootInfo + 216);
        long mappedBar = System.Kernel.Memory.Read64(bootInfo + 248);
        if (kind == 2) {
            bdf = System.Kernel.Memory.Read32(bootInfo + 220);
            mappedBar = System.Kernel.Memory.Read64(bootInfo + 256);
        }
        if (bdf < 0 || bdf > 65535 || mappedBar == 0) {
            System.Kernel.Memory.Write32(bootInfo + 1236, 101); return false;
        }
        long statusCommand = Read(bdf, 4);
        if ((statusCommand / 1048576) % 2 == 0) {
            System.Kernel.Memory.Write32(bootInfo + 1236, 102); return false;
        } // status.capabilities
        int pointer = (int)(Read(bdf, 52) % 256);
        int msi = 0; int msix = 0; int visited = 0;
        while (pointer >= 64 && pointer < 256 && visited < 48) {
            long cap = Read(bdf, pointer);
            int id = (int)(cap % 256);
            if (id == 5) { msi = pointer; }
            if (id == 17) { msix = pointer; }
            pointer = (int)(cap / 256 % 256);
            visited = visited + 1;
        }
        bool enabled = false;
        int mode = 0;
        if (msix != 0) { enabled = EnableMsix(bootInfo, bdf, msix, mappedBar); if (enabled) { mode = 2; } }
        if (!enabled && msi != 0) { enabled = EnableMsi(bdf, msi); if (enabled) { mode = 1; } }
        if (!enabled) {
            System.Kernel.Memory.Write32(bootInfo + 1236, 103);
            System.Kernel.Memory.Write32(bootInfo + 1240, msi);
            System.Kernel.Memory.Write32(bootInfo + 1244, msix);
            return false;
        }
        System.Kernel.Memory.Write32(bootInfo + 1244, mode);
        System.Kernel.Memory.Write32(bootInfo + 1232, kind);
        return true;
    }
}
