// A ring-3 address space owns one lower-half PML4 slot. All
// copied kernel entries retain supervisor-only flags; user code/data/stack
// pages and their page tables are owned and released together.
public class NativeUserPageTables {
    private long bootInfo;
    private long root;
    private long pdpt;
    private long directory;
    private long leaves;
    private long userBase;
    private long[] frames;
    private int count;
    private bool valid;

    private static long PageSize() { return 4096; }
    private static long SlotStride() {
        long stride = 1073741824;
        int i = 0;
        while (i < 9) { stride = stride + stride; i = i + 1; }
        return stride;
    }
    private static bool Present(long entry) { return entry % 2 != 0; }
    private static long WithoutNoExecute(long entry) {
        if (entry < 0) { return entry - System.Kernel.Memory.NoExecute(); }
        return entry;
    }
    private static bool User(long entry) {
        return (WithoutNoExecute(entry) / 4) % 2 != 0;
    }

    public NativeUserPageTables(long inputBootInfo) {
        bootInfo = inputBootInfo; root = 0; pdpt = 0; directory = 0;
        leaves = 0; userBase = 0;
        frames = new long[16]; count = 0;
        valid = Initialize();
        if (!valid) { Release(); }
    }
    private bool Initialize() {
        if (bootInfo < PageSize() || bootInfo % PageSize() != 0) { return false; }
        long kernelRoot = System.Kernel.Memory.Read64(bootInfo + 64);
        if (kernelRoot < PageSize() || kernelRoot % PageSize() != 0) { return false; }
        int chosen = -1; int i = 0;
        while (i < 256) {
            long entry = System.Kernel.Memory.Read64(kernelRoot + i * 8);
            if (i >= 2 && chosen < 0 && !Present(entry)) { chosen = i; }
            i = i + 1;
        }
        if (chosen < 0) { return false; }
        root = PhysicalPages.AllocateZeroed(bootInfo);
        if (root == 0) { return false; }
        i = 0;
        while (i < 512) {
            long entry = System.Kernel.Memory.Read64(kernelRoot + i * 8);
            // Firmware mappings may carry U/S at upper levels. Clearing it in
            // the private PML4 blocks ring-3 access without changing the
            // kernel's shared lower-level tables.
            if (Present(entry) && User(entry)) { entry = entry - 4; }
            System.Kernel.Memory.Write64(root + i * 8, entry);
            i = i + 1;
        }
        pdpt = PhysicalPages.AllocateZeroed(bootInfo);
        directory = PhysicalPages.AllocateZeroed(bootInfo);
        leaves = PhysicalPages.AllocateZeroed(bootInfo);
        if (pdpt == 0 || directory == 0 || leaves == 0) { return false; }
        System.Kernel.Memory.Write64(root + chosen * 8, pdpt + 7);
        System.Kernel.Memory.Write64(pdpt, directory + 7);
        System.Kernel.Memory.Write64(directory, leaves + 7);
        int slotIndex = 0;
        while (slotIndex < chosen) {
            userBase = userBase + SlotStride();
            slotIndex = slotIndex + 1;
        }
        return true;
    }
    public bool IsValid() { return valid; }
    public long Root() { return root; }
    public long Base() { return userBase; }

    // Copy through the owned physical frame after checking the complete user
    // range. No caller-provided virtual address is dereferenced in kernel CR3.
    public bool CanCopyFrom(long address, int length) {
        if (length == 0) { return true; }
        if (!valid || length < 0 || length > 256 || address < userBase) { return false; }
        long relative = address - userBase;
        if (relative >= 5 * 4096) { return false; }
        int page = (int)(relative / 4096);
        int offset = (int)(relative % 4096);
        if (page != 1 && page != 2 && page != 4) { return false; }
        return length <= 4096 - offset &&
            IsUserPage(page, page != 1, page == 1);
    }
    public bool CanCopyTo(long address, int length) {
        if (length == 0) { return true; }
        if (!valid || length < 0 || length > 256 || address < userBase) { return false; }
        long relative = address - userBase;
        if (relative >= 5 * 4096) { return false; }
        int page = (int)(relative / 4096);
        int offset = (int)(relative % 4096);
        if (page != 2 && page != 4) { return false; }
        return length <= 4096 - offset && IsUserPage(page, true, false);
    }
    public bool CopyFromUser(long address, byte[] destination, int length) {
        if (destination == null || length < 0 || length > destination.Length ||
            !CanCopyFrom(address, length)) { return false; }
        if (length == 0) { return true; }
        long relative = address - userBase;
        int page = (int)(relative / 4096);
        long entry = WithoutNoExecute(System.Kernel.Memory.Read64(leaves + page * 8));
        long frame = entry - entry % 4096;
        int offset = (int)(relative % 4096);
        int i = 0;
        while (i < length) {
            destination[i] = (byte)System.Kernel.Memory.Read8(frame + offset + i);
            i = i + 1;
        }
        return true;
    }
    public bool CopyToUser(long address, byte[] source, int length) {
        if (source == null || length < 0 || length > source.Length ||
            !CanCopyTo(address, length)) { return false; }
        if (length == 0) { return true; }
        long relative = address - userBase;
        int page = (int)(relative / 4096);
        long entry = WithoutNoExecute(System.Kernel.Memory.Read64(leaves + page * 8));
        long frame = entry - entry % 4096;
        int offset = (int)(relative % 4096);
        int i = 0;
        while (i < length) {
            System.Kernel.Memory.Write8(frame + offset + i, source[i]);
            i = i + 1;
        }
        return true;
    }

    private bool Map(int page, byte[] source, int length, bool writable) {
        if (!valid || page < 1 || page >= 512 || source == null ||
            length < 0 || length > 4096 || length > source.Length ||
            count >= frames.Length || Present(System.Kernel.Memory.Read64(leaves + page * 8))) {
            return false;
        }
        long frame = PhysicalPages.AllocateZeroed(bootInfo);
        if (frame == 0) { return false; }
        int i = 0;
        while (i < length) {
            System.Kernel.Memory.Write8(frame + i, source[i]); i = i + 1;
        }
        long entry = frame + 5; // present and user, read-only executable
        if (writable) {
            entry = frame + 7 + System.Kernel.Memory.NoExecute();
        }
        System.Kernel.Memory.Write64(leaves + page * 8, entry);
        frames[count] = frame; count = count + 1;
        return true;
    }
    public bool MapCode(int page, byte[] source, int length) {
        return page == 1 && Map(page, source, length, false);
    }
    public bool MapData(int page, byte[] source, int length) {
        return page == 2 && Map(page, source, length, true);
    }
    public bool MapStack(int page) {
        return page == 4 && Map(page, new byte[0], 0, true);
    }
    public bool IsUserPage(int page, bool writable, bool executable) {
        if (!valid || page < 0 || page >= 512) { return false; }
        long entry = System.Kernel.Memory.Read64(leaves + page * 8);
        if (!Present(entry) || !User(entry)) { return false; }
        if (((WithoutNoExecute(entry) / 2) % 2 != 0) != writable) {
            return false;
        }
        return (entry >= 0) == executable;
    }
    public bool IsGuardPage(int page) {
        return valid && page >= 0 && page < 512 &&
            !Present(System.Kernel.Memory.Read64(leaves + page * 8));
    }
    public bool KernelMappingsSupervisorOnly() {
        if (!valid) { return false; }
        int userSlot = (int)(userBase / SlotStride());
        int i = 0;
        while (i < 512) {
            long entry = System.Kernel.Memory.Read64(root + i * 8);
            if (i == userSlot) {
                if (!Present(entry) || !User(entry)) { return false; }
            } else if (Present(entry) && User(entry)) {
                return false;
            }
            i = i + 1;
        }
        return true;
    }
    public bool Release() {
        bool result = true; int i = 0;
        while (i < count) {
            if (frames[i] != 0 && !PhysicalPages.Free(bootInfo, frames[i])) {
                result = false;
            }
            frames[i] = 0; i = i + 1;
        }
        count = 0;
        if (leaves != 0 && !PhysicalPages.Free(bootInfo, leaves)) { result = false; }
        if (directory != 0 && !PhysicalPages.Free(bootInfo, directory)) {
            result = false;
        }
        if (pdpt != 0 && !PhysicalPages.Free(bootInfo, pdpt)) { result = false; }
        if (root != 0 && !PhysicalPages.Free(bootInfo, root)) { result = false; }
        leaves = 0; directory = 0; pdpt = 0; root = 0; valid = false;
        return result;
    }

    public static bool Probe(long bootInfo) {
        NativeUserPageTables pages = new NativeUserPageTables(bootInfo);
        if (!pages.IsValid()) { return false; }
        byte[] code = new byte[2]; code[0] = 144; code[1] = 195;
        int failed = 0;
        if (!pages.MapCode(1, code, 2)) { failed = 1; }
        if (failed == 0 && !pages.MapData(2, new byte[0], 0)) { failed = 2; }
        if (failed == 0 && !pages.MapStack(4)) { failed = 3; }
        if (failed == 0 && pages.Base() < 4096) { failed = 9; }
        if (failed == 0 && pages.Base() < SlotStride() + SlotStride()) { failed = 9; }
        if (failed == 0 && !pages.IsUserPage(1, false, true)) { failed = 4; }
        if (failed == 0 && !pages.IsUserPage(2, true, false)) { failed = 5; }
        if (failed == 0 && !pages.IsUserPage(4, true, false)) { failed = 6; }
        if (failed == 0 && !pages.IsGuardPage(3)) { failed = 7; }
        if (failed == 0 && !pages.IsGuardPage(5)) { failed = 10; }
        if (failed == 0 && !pages.KernelMappingsSupervisorOnly()) {
            failed = 11;
        }
        if (failed == 0 && KernelAddressSpace.IsMapped(pages.Root(), 0)) {
            failed = 8;
        }
        bool released = pages.Release();
        return released && failed == 0;
    }
}
