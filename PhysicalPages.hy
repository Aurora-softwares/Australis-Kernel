// Single-CPU page allocator controls over the descriptor range published by
// KernelBootInfo. The compiler runtime consumes the same cursor for objects,
// arrays, and strings, so a shell command can reclaim a known transient tail
// only after every reference into that tail has gone out of scope.
public class PhysicalPages {
    private static long PageSize() { return 4096; }
    private static long TransientFloorOffset() { return 1152; }
    private static long MemoryErrorOffset() { return 1160; }
    // A freed page stores its successor in word zero. These fields live in
    // KernelBootInfo after the serial diagnostics and before the RX ring.
    private static long FreeHeadOffset() { return 1184; }
    private static long FreeCountOffset() { return 1192; }
    // Set by KernelMain before its first allocation. Earlier boot pages and
    // the allocator metadata page are never owned by PhysicalPages callers.
    private static long AllocationFloorOffset() { return 3608; }

    private static bool ValidRange(long next, long limit) {
        return next >= PageSize() && next % PageSize() == 0 && limit >= next &&
            limit % PageSize() == 0;
    }

    private static void RecordError(long bootInfo, int error) {
        if (bootInfo >= PageSize()) { System.Kernel.Memory.Write32(bootInfo + MemoryErrorOffset(), error); }
    }

    private static bool ValidFreeLink(long link, long floor, long next, long limit) {
        return link == 0 || (link >= floor && link < next && link < limit && link % PageSize() == 0);
    }

    public static bool Initialize(long bootInfo) {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return false; }
        long next = System.Kernel.Memory.Read64(bootInfo + 40);
        long limit = System.Kernel.Memory.Read64(bootInfo + 48);
        if (!ValidRange(next, limit) ||
            System.Kernel.Memory.Read64(bootInfo + FreeHeadOffset()) != 0 ||
            System.Kernel.Memory.Read64(bootInfo + FreeCountOffset()) != 0 ||
            System.Kernel.Memory.Read64(bootInfo + AllocationFloorOffset()) != 0) { return false; }
        System.Kernel.Memory.Write64(bootInfo + AllocationFloorOffset(), next);
        return true;
    }

    private static void Zero(long page) {
        long offset = 0;
        while (offset < PageSize()) {
            System.Kernel.Memory.Write64(page + offset, 0);
            offset = offset + 8;
        }
    }

    public static long AllocateZeroed(long bootInfo) {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return 0; }
        long next = System.Kernel.Memory.Read64(bootInfo + 40);
        long limit = System.Kernel.Memory.Read64(bootInfo + 48);
        long floor = System.Kernel.Memory.Read64(bootInfo + AllocationFloorOffset());
        long freeHead = System.Kernel.Memory.Read64(bootInfo + FreeHeadOffset());
        long freeCount = System.Kernel.Memory.Read64(bootInfo + FreeCountOffset());
        if (!ValidRange(next, limit) || floor < PageSize() || floor > next ||
            floor % PageSize() != 0 || freeCount < 0 ||
            freeCount > (next - floor) / PageSize() ||
            (freeHead == 0 && freeCount != 0) ||
            (freeHead != 0 && freeCount == 0) ||
            !ValidFreeLink(freeHead, floor, next, limit)) {
            RecordError(bootInfo, 1);
            return 0;
        }
        long page = next;
        if (freeHead != 0) {
            long link = System.Kernel.Memory.Read64(freeHead);
            if (!ValidFreeLink(link, floor, next, limit)) {
                RecordError(bootInfo, 5);
                return 0;
            }
            page = freeHead;
            System.Kernel.Memory.Write64(bootInfo + FreeHeadOffset(), link);
            System.Kernel.Memory.Write64(bootInfo + FreeCountOffset(), freeCount - 1);
        } else {
            if (limit - next < PageSize()) { RecordError(bootInfo, 1); return 0; }
            System.Kernel.Memory.Write64(bootInfo + 40, next + PageSize());
        }
        Zero(page);
        System.Kernel.Memory.Write64(bootInfo + 72, page);
        RecordError(bootInfo, 0);
        return page;
    }

    // Return one page obtained from AllocateZeroed. Ownership remains with the
    // caller until this method succeeds. The bounded scan rejects double frees
    // and corrupted successor links before they can poison future allocations.
    public static bool Free(long bootInfo, long page) {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return false; }
        long next = System.Kernel.Memory.Read64(bootInfo + 40);
        long limit = System.Kernel.Memory.Read64(bootInfo + 48);
        long floor = System.Kernel.Memory.Read64(bootInfo + AllocationFloorOffset());
        long head = System.Kernel.Memory.Read64(bootInfo + FreeHeadOffset());
        long count = System.Kernel.Memory.Read64(bootInfo + FreeCountOffset());
        if (!ValidRange(next, limit) || floor < PageSize() || floor > next ||
            floor % PageSize() != 0 || page < floor || page >= next || page >= limit ||
            page % PageSize() != 0 || count < 0 || count >= (next - floor) / PageSize() ||
            (head == 0 && count != 0) || (head != 0 && count == 0) ||
            !ValidFreeLink(head, floor, next, limit)) {
            RecordError(bootInfo, 6); return false;
        }
        long cursor = head;
        long visited = 0;
        long maximum = (next - floor) / PageSize();
        while (cursor != 0 && visited < maximum) {
            if (cursor == page) { RecordError(bootInfo, 7); return false; }
            long link = System.Kernel.Memory.Read64(cursor);
            if (!ValidFreeLink(link, floor, next, limit)) { RecordError(bootInfo, 8); return false; }
            cursor = link; visited = visited + 1;
        }
        if (cursor != 0 || visited != count) { RecordError(bootInfo, 8); return false; }
        Zero(page);
        System.Kernel.Memory.Write64(page, head);
        System.Kernel.Memory.Write64(bootInfo + FreeHeadOffset(), page);
        System.Kernel.Memory.Write64(bootInfo + FreeCountOffset(), count + 1);
        RecordError(bootInfo, 0);
        return true;
    }

    // Call only after all kernel objects which must survive shell commands
    // have been constructed. The floor prevents a bad rewind from releasing
    // the VFS, controller, console, or runtime state below it.
    public static bool BeginTransientRegion(long bootInfo) {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return false; }
        long next = System.Kernel.Memory.Read64(bootInfo + 40);
        long limit = System.Kernel.Memory.Read64(bootInfo + 48);
        if (!ValidRange(next, limit)) { RecordError(bootInfo, 2); return false; }
        System.Kernel.Memory.Write64(bootInfo + TransientFloorOffset(), next);
        System.Kernel.Memory.Write64(bootInfo + 1208, 0);
        RecordError(bootInfo, 0);
        return true;
    }

    public static long MarkTransient(long bootInfo) {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return 0; }
        long floor = System.Kernel.Memory.Read64(bootInfo + TransientFloorOffset());
        long next = System.Kernel.Memory.Read64(bootInfo + 40);
        long limit = System.Kernel.Memory.Read64(bootInfo + 48);
        if (!ValidRange(next, limit) || floor < PageSize() || floor % PageSize() != 0 || floor > next) {
            RecordError(bootInfo, 3); return 0;
        }
        System.Kernel.Memory.Write64(bootInfo + 1208, next);
        return next;
    }

    public static bool RewindTransient(long bootInfo, long marker) {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return false; }
        long floor = System.Kernel.Memory.Read64(bootInfo + TransientFloorOffset());
        long next = System.Kernel.Memory.Read64(bootInfo + 40);
        long limit = System.Kernel.Memory.Read64(bootInfo + 48);
        if (!ValidRange(next, limit) || floor < PageSize() || floor % PageSize() != 0 ||
            marker < floor || marker > next || marker % PageSize() != 0 ||
            marker != System.Kernel.Memory.Read64(bootInfo + 1208)) {
            RecordError(bootInfo, 4); return false;
        }
        // Rewinding over a free-list node would leave that node available to
        // the allocator after the cursor starts using the same page again.
        long allocationFloor = System.Kernel.Memory.Read64(bootInfo + AllocationFloorOffset());
        long count = System.Kernel.Memory.Read64(bootInfo + FreeCountOffset());
        long cursor = System.Kernel.Memory.Read64(bootInfo + FreeHeadOffset());
        if (allocationFloor < PageSize() || allocationFloor > marker ||
            count < 0 || count > (next - allocationFloor) / PageSize() ||
            (cursor == 0 && count != 0) || (cursor != 0 && count == 0)) {
            RecordError(bootInfo, 8); return false;
        }
        long visited = 0;
        while (cursor != 0 && visited < count) {
            if (!ValidFreeLink(cursor, allocationFloor, next, limit) || cursor >= marker) {
                RecordError(bootInfo, 8); return false;
            }
            cursor = System.Kernel.Memory.Read64(cursor);
            visited = visited + 1;
        }
        if (cursor != 0 || visited != count) { RecordError(bootInfo, 8); return false; }
        System.Kernel.Memory.Write64(bootInfo + 40, marker);
        System.Kernel.Memory.Write64(bootInfo + 1208, 0);
        return true;
    }
}
