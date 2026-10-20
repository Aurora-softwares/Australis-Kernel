namespace Australis.Kernel.Graphics {
    public class VirglRenderSurface : IRenderSurface {
        private VirtioGpu3D gpu;
        private long backing;
        private int width;
        private int height;
        private bool created;
        public VirglRenderSurface(VirtioGpu3D inputGpu, int inputWidth,
            int inputHeight, long inputBacking, int backingBytes) {
            gpu = inputGpu; backing = inputBacking;
            width = inputWidth; height = inputHeight;
            created = gpu != null && gpu.CreateTexture(width, height,
                backing, backingBytes);
        }
        public int Kind() { return 2; }
        public int Width() { return width; }
        public int Height() { return height; }
        public bool Ready() {
            return created && gpu != null && gpu.Ready() &&
                gpu.TextureReady();
        }
        public bool Clear(int rgb) {
            return Ready() && gpu.ClearTexture(rgb);
        }
        public bool Upload(PixelSurface source) {
            if (!Ready() || source == null || !source.Ready() ||
                source.Width() != width || source.Height() != height) {
                return false;
            }
            int y = 0;
            while (y < height) {
                int x = 0;
                while (x < width) {
                    int rgb = source.Pixel(x, y);
                    if (rgb < 0) { return false; }
                    System.Kernel.Memory.Write32(backing +
                        ((long)y * width + x) * 4,
                        (long)rgb + 4278190080);
                    x = x + 1;
                }
                y = y + 1;
            }
            System.Kernel.Memory.Fence();
            return gpu.UploadTexture();
        }
        public bool Readback(PixelSurface destination) {
            if (!Ready() || destination == null ||
                !destination.Ready() || destination.Width() != width ||
                destination.Height() != height ||
                !gpu.DownloadTexture()) { return false; }
            System.Kernel.Memory.Fence();
            int y = 0;
            while (y < height) {
                int x = 0;
                while (x < width) {
                    long pixel = System.Kernel.Memory.Read32(backing +
                        ((long)y * width + x) * 4);
                    if (!destination.SetPixel(x, y,
                        (int)(pixel % 16777216))) { return false; }
                    x = x + 1;
                }
                y = y + 1;
            }
            return true;
        }
        public bool Destroy() {
            if (!created || gpu == null) { return false; }
            if (!gpu.DestroyTexture()) { return false; }
            created = false; return true;
        }
    }
}
