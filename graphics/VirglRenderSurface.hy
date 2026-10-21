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
            return UploadRegion(source, 0, 0, width, height);
        }
        public bool UploadRegion(PixelSurface source, int x, int y,
            int regionWidth, int regionHeight) {
            if (!Ready() || source == null || !source.Ready() ||
                source.Width() != width || source.Height() != height ||
                x < 0 || y < 0 || regionWidth < 1 || regionHeight < 1 ||
                (long)x + regionWidth > width ||
                (long)y + regionHeight > height) {
                return false;
            }
            int row = y;
            while (row < y + regionHeight) {
                int column = x;
                while (column < x + regionWidth) {
                    int rgb = source.Pixel(column, row);
                    if (rgb < 0) { return false; }
                    System.Kernel.Memory.Write32(backing +
                        ((long)row * width + column) * 4,
                        (long)rgb + 4278190080);
                    column = column + 1;
                }
                row = row + 1;
            }
            System.Kernel.Memory.Fence();
            return gpu.UploadTextureRegion(x, y, regionWidth, regionHeight);
        }
        public bool Readback(PixelSurface destination) {
            return ReadbackRegion(destination, 0, 0, width, height);
        }
        public bool ReadbackRegion(PixelSurface destination, int x, int y,
            int regionWidth, int regionHeight) {
            if (!Ready() || destination == null ||
                !destination.Ready() || destination.Width() != width ||
                destination.Height() != height ||
                x < 0 || y < 0 || regionWidth < 1 || regionHeight < 1 ||
                (long)x + regionWidth > width ||
                (long)y + regionHeight > height ||
                !gpu.DownloadTextureRegion(x, y, regionWidth,
                    regionHeight)) { return false; }
            System.Kernel.Memory.Fence();
            int row = y;
            while (row < y + regionHeight) {
                int column = x;
                while (column < x + regionWidth) {
                    long pixel = System.Kernel.Memory.Read32(backing +
                        ((long)row * width + column) * 4);
                    if (!destination.SetPixel(column, row,
                        (int)(pixel % 16777216))) { return false; }
                    column = column + 1;
                }
                row = row + 1;
            }
            return true;
        }
        public bool Recover() {
            if (!created || gpu == null || gpu.Ready() ||
                backing < 4096 || width < 1 || height < 1) {
                return false;
            }
            int pixels = width * height;
            int i = 0;
            while (i < pixels) {
                System.Kernel.Memory.Write32(backing + (long)i * 4, 0);
                i = i + 1;
            }
            System.Kernel.Memory.Fence();
            return gpu.RecoverTexture(backing, pixels * 4);
        }
        public bool Destroy() {
            if (!created || gpu == null) { return false; }
            if (!gpu.DestroyTexture()) { return false; }
            created = false; return true;
        }
    }
}
