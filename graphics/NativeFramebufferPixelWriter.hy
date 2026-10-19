namespace Australis.Kernel.Graphics {
    public class NativeFramebufferPixelWriter : IFramebufferPixelWriter {
        public bool WritePixel(long address, int value) {
            System.Kernel.Memory.Write32(address, value);
            return true;
        }
    }
}
