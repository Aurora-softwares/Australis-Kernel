namespace Australis.Kernel.Dma {
    public class NativeDmaPool {
        public static DmaAllocator Create(long bootInfo, bool iommuTranslationRequired) {
            long reservation = System.Kernel.Memory.Read64(bootInfo + 280);
            int pages = System.Kernel.Memory.Read32(bootInfo + 296);
            if (reservation < 4096 || pages <= 16) { return new DmaAllocator(0, 0, iommuTranslationRequired); }
            return new DmaAllocator(reservation + 16 * 4096, pages - 16, iommuTranslationRequired);
        }
        public static void PrepareForDevice(DmaAllocation allocation) {
            if (allocation != null && allocation.Owned()) { System.Kernel.Memory.Fence(); }
        }
        public static void CompleteFromDevice(DmaAllocation allocation) {
            if (allocation != null && allocation.Owned()) { System.Kernel.Memory.Fence(); }
        }
    }
}
