public class MmioRegion {
    private long bootInfo;
    private long virtualBase;
    private long physicalBase;
    private long byteLength;
    private int pageCount;
    private bool mapped;

    public MmioRegion(long inputBootInfo, long inputVirtualBase, long inputPhysicalBase,
        long inputByteLength, int inputPageCount) {
        bootInfo = inputBootInfo; virtualBase = inputVirtualBase; physicalBase = inputPhysicalBase;
        byteLength = inputByteLength; pageCount = inputPageCount; mapped = true;
    }
    public long Address() { return virtualBase; }
    public long PhysicalAddress() { return physicalBase; }
    public long ByteLength() { return byteLength; }
    public int PageCount() { return pageCount; }
    public bool IsMapped() { return mapped; }
    public bool Release() {
        if (!mapped) { return false; }
        int page = pageCount - 1;
        bool ok = true;
        while (page >= 0) {
            if (!KernelAddressSpace.UnmapPage(bootInfo, virtualBase + page * 4096)) { ok = false; }
            page = page - 1;
        }
        if (ok) { mapped = false; virtualBase = 0; }
        return ok;
    }
}

public class MmioMapper {
    public static MmioRegion Map(long bootInfo, long physicalAddress, long byteLength) {
        if (bootInfo < 4096 || physicalAddress < 4096 || byteLength < 1) { return null; }
        long offset = physicalAddress % 4096;
        long physicalPage = physicalAddress - offset;
        long covered = byteLength + offset;
        int pages = (int)((covered + 4095) / 4096);
        if (pages < 1 || pages > 16384) { return null; }
        long virtualPage = KernelAddressSpace.FindUnmappedRange(bootInfo, pages);
        if (virtualPage == 0) { return null; }
        int mapped = 0;
        while (mapped < pages && KernelAddressSpace.MapPage(bootInfo, virtualPage + mapped * 4096,
            physicalPage + mapped * 4096, KernelAddressSpace.DeviceReadWrite())) { mapped = mapped + 1; }
        if (mapped != pages) {
            mapped = mapped - 1;
            while (mapped >= 0) { KernelAddressSpace.UnmapPage(bootInfo, virtualPage + mapped * 4096); mapped = mapped - 1; }
            return null;
        }
        return new MmioRegion(bootInfo, virtualPage + offset, physicalAddress, byteLength, pages);
    }
}
