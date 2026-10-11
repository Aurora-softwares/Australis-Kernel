namespace Australis.Kernel.Dma {
    public class DmaAllocation {
        private long address;
        private int firstPage;
        private int pageCount;
        private bool owned;
        public DmaAllocation(long inputAddress, int inputFirstPage, int inputPageCount) {
            address = inputAddress; firstPage = inputFirstPage; pageCount = inputPageCount; owned = true;
        }
        public long Address() { return address; }
        public int FirstPage() { return firstPage; }
        public int PageCount() { return pageCount; }
        public bool Owned() { return owned; }
        public void MarkReleased() { owned = false; address = 0; }
    }

    public class DmaAllocator {
        private long baseAddress;
        private bool[] used;
        private int allocatedPages;
        private bool translationRequired;
        public DmaAllocator(long inputBase, int pages, bool inputTranslationRequired) {
            baseAddress = inputBase; if (pages < 0) { pages = 0; }
            used = new bool[pages]; allocatedPages = 0; translationRequired = inputTranslationRequired;
        }
        public bool Supported() { return !translationRequired && baseAddress >= 4096 && baseAddress % 4096 == 0; }
        public int CapacityPages() { return used.Length; }
        public int AllocatedPages() { return allocatedPages; }
        public DmaAllocation Allocate(int pages) {
            if (!Supported() || pages < 1 || pages > used.Length) { return null; }
            int first = 0;
            while (first <= used.Length - pages) {
                int i = 0; while (i < pages && !used[first + i]) { i = i + 1; }
                if (i == pages) {
                    i = 0; while (i < pages) { used[first + i] = true; i = i + 1; }
                    allocatedPages = allocatedPages + pages;
                    return new DmaAllocation(baseAddress + first * 4096, first, pages);
                }
                first = first + i + 1;
            }
            return null;
        }
        public bool Release(DmaAllocation allocation) {
            if (allocation == null || !allocation.Owned() || allocation.FirstPage() < 0 ||
                allocation.PageCount() < 1 || allocation.FirstPage() > used.Length - allocation.PageCount()) { return false; }
            int i = 0;
            while (i < allocation.PageCount()) {
                if (!used[allocation.FirstPage() + i]) { return false; }
                i = i + 1;
            }
            i = 0; while (i < allocation.PageCount()) { used[allocation.FirstPage() + i] = false; i = i + 1; }
            allocatedPages = allocatedPages - allocation.PageCount(); allocation.MarkReleased(); return true;
        }
    }

}
