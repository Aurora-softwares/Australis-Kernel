namespace Australis.Kernel.Graphics {
    public class NativeFramebufferPixelWriter : IFramebufferPixelWriter {
        public bool WritePixel(long address, int value) {
            System.Kernel.Memory.Write32(address, value);
            return true;
        }
    }
    public class NativeFrameClock : IFrameClock {
        private long bootInfo;
        public NativeFrameClock(long inputBootInfo) { bootInfo = inputBootInfo; }
        public long Now() { return Australis.Kernel.Time.KernelClock.Now(); }
        public long TicksPerMillisecond() {
            return System.Kernel.Memory.Read64(bootInfo + 2344);
        }
    }
}
