namespace Australis.Kernel.Graphics {
    // One bounded render target. The compositor can keep its software path
    // while an accelerated implementation supplies the same operations.
    public interface IRenderSurface {
        int Kind(); // 1: software, 2: VirGL.
        int Width();
        int Height();
        bool Ready();
        bool Clear(int rgb);
        bool Upload(PixelSurface source);
        bool Readback(PixelSurface destination);
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
            return Ready() && source != null && source.Ready() &&
                source.Width() == Width() &&
                source.Height() == Height() &&
                surface.CopyRegion(source, 0, 0, 0, 0,
                    Width(), Height());
        }
        public bool Readback(PixelSurface destination) {
            return Ready() && destination != null && destination.Ready() &&
                destination.Width() == Width() &&
                destination.Height() == Height() &&
                destination.CopyRegion(surface, 0, 0, 0, 0,
                    Width(), Height());
        }
        public bool Destroy() { surface = null; return true; }
    }

}
