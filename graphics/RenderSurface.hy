namespace Australis.Kernel.Graphics {
    public interface IGpuClientBlitter {
        int ClientWidth(int processId, int handle);
        int ClientHeight(int processId, int handle);
        bool ClientBlit(int processId, int handle,
            PixelSurface destination, int x, int y);
        bool ClientBlitRegion(int processId, int handle,
            PixelSurface destination, int sourceX, int sourceY,
            int width, int height, int targetX, int targetY);
    }
    // One bounded render target. The compositor can keep its software path
    // while an accelerated implementation supplies the same operations.
    public interface IRenderSurface {
        int Kind(); // 1: software, 2: VirGL.
        int Width();
        int Height();
        bool Ready();
        bool Clear(int rgb);
        bool Upload(PixelSurface source);
        bool UploadRegion(PixelSurface source, int x, int y,
            int width, int height);
        bool Readback(PixelSurface destination);
        bool ReadbackRegion(PixelSurface destination, int x, int y,
            int width, int height);
        bool Recover();
        bool Destroy();
    }

    public class SoftwareRenderSurface : IRenderSurface {
        private PixelSurface surface;
        public SoftwareRenderSurface(int width, int height) {
            surface = new PixelSurface(width, height);
        }
        public int Kind() { return 1; }
        public int Width() { if (surface == null) { return 0; }
            return surface.Width(); }
        public int Height() { if (surface == null) { return 0; }
            return surface.Height(); }
        public bool Ready() { return surface != null && surface.Ready(); }
        public bool Clear(int rgb) { return Ready() && surface.Fill(rgb); }
        public bool Upload(PixelSurface source) {
            return UploadRegion(source, 0, 0, Width(), Height());
        }
        public bool UploadRegion(PixelSurface source, int x, int y,
            int width, int height) {
            return Ready() && source != null && source.Ready() &&
                source.Width() == Width() &&
                source.Height() == Height() &&
                x >= 0 && y >= 0 && width > 0 && height > 0 &&
                (long)x + width <= Width() &&
                (long)y + height <= Height() &&
                surface.CopyRegion(source, x, y, x, y, width, height);
        }
        public bool Readback(PixelSurface destination) {
            return ReadbackRegion(destination, 0, 0, Width(), Height());
        }
        public bool ReadbackRegion(PixelSurface destination, int x, int y,
            int width, int height) {
            return Ready() && destination != null && destination.Ready() &&
                destination.Width() == Width() &&
                destination.Height() == Height() &&
                x >= 0 && y >= 0 && width > 0 && height > 0 &&
                (long)x + width <= Width() &&
                (long)y + height <= Height() &&
                destination.CopyRegion(surface, x, y, x, y,
                    width, height);
        }
        public bool Recover() { return Ready(); }
        public bool Destroy() { surface = null; return true; }
    }

}
