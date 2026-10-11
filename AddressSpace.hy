// Four-level kernel mappings owned after handoff. The API creates only 4 KiB
// leaves and rejects bootstrap large leaves, so it never changes the mapping
// policy the bootloader established for firmware-visible memory.
public class KernelAddressSpace {
    private static long PageSize() { return 4096; }
    private static long EntriesPerTable() { return 512; }
    private static long Gigabyte() { return 1073741824; }
    private static long Pml4Stride() { return Gigabyte() * EntriesPerTable(); }
    private static long DynamicBaseOffset() { return 1216; }

    private static bool PageAligned(long value) {
        return value >= PageSize() && value % PageSize() == 0;
    }

    private static bool Present(long entry) { return entry % 2 != 0; }
    private static long NoExecuteBit() { return System.Kernel.Memory.NoExecute(); }
    private static long WithoutNoExecute(long entry) {
        if (entry < 0) { return entry - NoExecuteBit(); }
        return entry;
    }
    private static bool Large(long entry) { return (WithoutNoExecute(entry) / 128) % 2 != 0; }
    private static long Frame(long entry) {
        entry = WithoutNoExecute(entry);
        return (entry / PageSize()) * PageSize();
    }
    public static long ReadOnly() { return 1; }
    public static long ReadWrite() { return 3; }
    public static long DeviceReadWrite() { return 27; } // present, writable, PWT, PCD

    private static long Index(long address, long shift) {
        return (address / shift) % EntriesPerTable();
    }

    private static bool ValidPage(long address) {
        return address >= PageSize() && address % PageSize() == 0;
    }

    private static bool ValidFlags(long flags) {
        return flags == ReadOnly() || flags == ReadWrite() || flags == DeviceReadWrite();
    }

    private static bool Empty(long table) {
        long index = 0;
        while (index < EntriesPerTable()) {
            if (Present(System.Kernel.Memory.Read64(table + index * 8))) { return false; }
            index = index + 1;
        }
        return true;
    }

    // The dynamic hierarchy is rooted in one initially-empty PML4 slot. This
    // keeps its table-page lifetime separate from the cloned boot hierarchy.
    private static bool ClaimDynamicBase(long bootInfo, long root, long virtualPage) {
        long dynamicBase = System.Kernel.Memory.Read64(bootInfo + DynamicBaseOffset());
        long candidate = (virtualPage / Pml4Stride()) * Pml4Stride();
        if (dynamicBase != 0) { return dynamicBase == candidate; }
        long slot = root + Index(virtualPage, Pml4Stride()) * 8;
        if (Present(System.Kernel.Memory.Read64(slot))) { return false; }
        System.Kernel.Memory.Write64(bootInfo + DynamicBaseOffset(), candidate);
        return true;
    }

    private static long EnsureChild(long bootInfo, long table, long index) {
        long slot = table + index * 8;
        long entry = System.Kernel.Memory.Read64(slot);
        if (Present(entry)) {
            if (Large(entry) || !ValidPage(Frame(entry))) { return 0; }
            return Frame(entry);
        }
        long child = PhysicalPages.AllocateZeroed(bootInfo);
        if (child == 0) { return 0; }
        System.Kernel.Memory.Write64(slot, child + ReadWrite());
        return child;
    }

    // The bootstrap preserves identity mappings. This walk only asks whether
    // the hierarchy translates an address; it never dereferences that address.
    public static bool IsMapped(long root, long address) {
        if (!PageAligned(root) || address < 0) { return false; }
        long entry = System.Kernel.Memory.Read64(root + Index(address, Pml4Stride()) * 8);
        if (!Present(entry) || Large(entry)) { return false; }
        long pdpt = Frame(entry);
        if (!PageAligned(pdpt)) { return false; }
        entry = System.Kernel.Memory.Read64(pdpt + Index(address, Gigabyte()) * 8);
        if (!Present(entry)) { return false; }
        if (Large(entry)) { return true; }
        long pd = Frame(entry);
        if (!PageAligned(pd)) { return false; }
        entry = System.Kernel.Memory.Read64(pd + Index(address, 2097152) * 8);
        if (!Present(entry)) { return false; }
        if (Large(entry)) { return true; }
        long pt = Frame(entry);
        if (!PageAligned(pt)) { return false; }
        entry = System.Kernel.Memory.Read64(pt + Index(address, PageSize()) * 8);
        return Present(entry);
    }

    public static bool Validate(long bootInfo) {
        if (!PageAligned(bootInfo)) { return false; }
        long root = System.Kernel.Memory.Read64(bootInfo + 64);
        if (!PageAligned(root)) { return false; }
        // A present large leaf at any stage would map page zero. A normal PTE
        // is permitted only when its present bit is clear.
        if (IsMapped(root, 0)) { return false; }
        return IsMapped(root, bootInfo);
    }

    // Returns a canonical lower-half PML4 slot which the bootstrap did not
    // populate. Keeping dynamic mappings in a vacant slot avoids modifying
    // firmware and identity-map hierarchy owned before handoff.
    public static long FindUnmappedPml4Base(long bootInfo) {
        if (!ValidPage(bootInfo)) { return 0; }
        long root = System.Kernel.Memory.Read64(bootInfo + 64);
        if (!ValidPage(root)) { return 0; }
        long index = 1;
        while (index < 256) {
            if (!Present(System.Kernel.Memory.Read64(root + index * 8))) { return index * Pml4Stride(); }
            index = index + 1;
        }
        return 0;
    }

    // Finds contiguous free pages inside the one kernel-owned dynamic PML4
    // slot. This lets independent MMIO owners coexist without expanding the
    // mutable part of the bootstrap hierarchy.
    public static long FindUnmappedRange(long bootInfo, int pages) {
        if (!ValidPage(bootInfo) || pages < 1 || pages > 16384) { return 0; }
        long dynamicBase = System.Kernel.Memory.Read64(bootInfo + DynamicBaseOffset());
        if (dynamicBase == 0) { dynamicBase = FindUnmappedPml4Base(bootInfo); }
        if (dynamicBase == 0) { return 0; }
        int first = 0;
        while (first <= 16384 - pages) {
            int free = 0;
            while (free < pages && Translate(bootInfo, dynamicBase + (first + free) * PageSize()) == 0) {
                free = free + 1;
            }
            if (free == pages) { return dynamicBase + first * PageSize(); }
            first = first + free + 1;
        }
        return 0;
    }

    // Maps an unmapped kernel virtual page to a caller-owned physical frame or
    // MMIO page. Unmap releases page tables, never the mapped frame itself.
    public static bool MapPage(long bootInfo, long virtualPage, long physicalPage, long flags) {
        if (!ValidPage(bootInfo) || !ValidPage(virtualPage) || !ValidPage(physicalPage) || !ValidFlags(flags)) {
            return false;
        }
        long root = System.Kernel.Memory.Read64(bootInfo + 64);
        if (!ValidPage(root)) { return false; }
        if (!ClaimDynamicBase(bootInfo, root, virtualPage)) { return false; }
        long pdpt = EnsureChild(bootInfo, root, Index(virtualPage, Pml4Stride()));
        if (pdpt == 0) { return false; }
        long pd = EnsureChild(bootInfo, pdpt, Index(virtualPage, Gigabyte()));
        if (pd == 0) { return false; }
        long pt = EnsureChild(bootInfo, pd, Index(virtualPage, 2097152));
        if (pt == 0) { return false; }
        long slot = pt + Index(virtualPage, PageSize()) * 8;
        if (Present(System.Kernel.Memory.Read64(slot))) { return false; }
        // Dynamic kernel data mappings are always NX. Code loading needs a
        // separate executable mapping path with a stronger provenance check.
        System.Kernel.Memory.Write64(slot, physicalPage + flags + NoExecuteBit());
        System.Kernel.Cpu.InvalidatePage(virtualPage);
        return true;
    }

    public static bool IsExecutable(long bootInfo, long virtualPage) {
        if (!ValidPage(bootInfo) || !ValidPage(virtualPage)) { return false; }
        long root = System.Kernel.Memory.Read64(bootInfo + 64);
        if (!ValidPage(root)) { return false; }
        long dynamicBase = System.Kernel.Memory.Read64(bootInfo + DynamicBaseOffset());
        if (dynamicBase == 0 || dynamicBase != (virtualPage / Pml4Stride()) * Pml4Stride()) { return false; }
        long entry = System.Kernel.Memory.Read64(root + Index(virtualPage, Pml4Stride()) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return false; }
        long pdpt = Frame(entry);
        entry = System.Kernel.Memory.Read64(pdpt + Index(virtualPage, Gigabyte()) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return false; }
        long pd = Frame(entry);
        entry = System.Kernel.Memory.Read64(pd + Index(virtualPage, 2097152) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return false; }
        long pt = Frame(entry);
        entry = System.Kernel.Memory.Read64(pt + Index(virtualPage, PageSize()) * 8);
        return Present(entry) && entry >= 0;
    }

    public static long Translate(long bootInfo, long virtualPage) {
        if (!ValidPage(bootInfo) || !ValidPage(virtualPage)) { return 0; }
        long root = System.Kernel.Memory.Read64(bootInfo + 64);
        if (!ValidPage(root)) { return 0; }
        long entry = System.Kernel.Memory.Read64(root + Index(virtualPage, Pml4Stride()) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return 0; }
        long pdpt = Frame(entry);
        entry = System.Kernel.Memory.Read64(pdpt + Index(virtualPage, Gigabyte()) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return 0; }
        long pd = Frame(entry);
        entry = System.Kernel.Memory.Read64(pd + Index(virtualPage, 2097152) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return 0; }
        long pt = Frame(entry);
        entry = System.Kernel.Memory.Read64(pt + Index(virtualPage, PageSize()) * 8);
        if (!Present(entry)) { return 0; }
        return Frame(entry);
    }

    public static bool UnmapPage(long bootInfo, long virtualPage) {
        if (!ValidPage(bootInfo) || !ValidPage(virtualPage)) { return false; }
        long root = System.Kernel.Memory.Read64(bootInfo + 64);
        if (!ValidPage(root)) { return false; }
        long dynamicBase = System.Kernel.Memory.Read64(bootInfo + DynamicBaseOffset());
        if (dynamicBase == 0 || dynamicBase != (virtualPage / Pml4Stride()) * Pml4Stride()) { return false; }
        long entry = System.Kernel.Memory.Read64(root + Index(virtualPage, Pml4Stride()) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return false; }
        long pdpt = Frame(entry);
        entry = System.Kernel.Memory.Read64(pdpt + Index(virtualPage, Gigabyte()) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return false; }
        long pd = Frame(entry);
        entry = System.Kernel.Memory.Read64(pd + Index(virtualPage, 2097152) * 8);
        if (!Present(entry) || Large(entry) || !ValidPage(Frame(entry))) { return false; }
        long pt = Frame(entry);
        long slot = pt + Index(virtualPage, PageSize()) * 8;
        if (!Present(System.Kernel.Memory.Read64(slot))) { return false; }
        System.Kernel.Memory.Write64(slot, 0);
        System.Kernel.Cpu.InvalidatePage(virtualPage);
        if (Empty(pt)) {
            System.Kernel.Memory.Write64(pd + Index(virtualPage, 2097152) * 8, 0);
            if (!PhysicalPages.Free(bootInfo, pt)) { return false; }
            if (Empty(pd)) {
                System.Kernel.Memory.Write64(pdpt + Index(virtualPage, Gigabyte()) * 8, 0);
                if (!PhysicalPages.Free(bootInfo, pd)) { return false; }
                if (Empty(pdpt)) {
                    System.Kernel.Memory.Write64(root + Index(virtualPage, Pml4Stride()) * 8, 0);
                    if (!PhysicalPages.Free(bootInfo, pdpt)) { return false; }
                    System.Kernel.Memory.Write64(bootInfo + DynamicBaseOffset(), 0);
                }
            }
        }
        return true;
    }
}
