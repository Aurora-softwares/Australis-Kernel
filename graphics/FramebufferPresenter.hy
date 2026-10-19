using Australis.Kernel.Console;

namespace Australis.Kernel.Graphics {
    public interface IFramebufferPixelWriter {
        bool WritePixel(long address, int value);
    }

    // The presenter is the only graphics-layer object that sees a physical
    // framebuffer address. Surfaces and future clients retain RGB pixels only.
    public class FramebufferPresenter {
        private FramebufferMode mode;
        private IFramebufferPixelWriter writer;
        public FramebufferPresenter(FramebufferMode inputMode,
            IFramebufferPixelWriter inputWriter) {
            mode = inputMode; writer = inputWriter;
        }
        public bool Ready() {
            return mode != null && mode.Supported() && writer != null;
        }
        public int Encode(int rgb) {
            if (!Ready() || rgb < 0 || rgb > 16777215) { return -1; }
            if (mode.Format() == 1) { return rgb; }
            int red = rgb / 65536;
            int green = rgb / 256 % 256;
            int blue = rgb % 256;
            return blue * 65536 + green * 256 + red;
        }
        public bool Present(PixelSurface surface, int targetX, int targetY) {
            if (!Ready() || surface == null || !surface.Ready()) { return false; }
            return PresentRegion(surface, 0, 0, surface.Width(), surface.Height(),
                targetX, targetY);
        }
        public bool PresentRegion(PixelSurface surface, int sourceX, int sourceY,
            int width, int height, int targetX, int targetY) {
            if (!Ready() || surface == null || !surface.Ready() ||
                sourceX < 0 || sourceY < 0 || width < 1 || height < 1 ||
                (long)sourceX + width > surface.Width() ||
                (long)sourceY + height > surface.Height()) { return false; }
            int row = 0;
            while (row < height) {
                long y = (long)targetY + row;
                if (y >= 0 && y < mode.Height()) {
                    int column = 0;
                    while (column < width) {
                        long x = (long)targetX + column;
                        if (x >= 0 && x < mode.Width()) {
                            long address = mode.PixelAddress((int)x, (int)y);
                            if (address == 0 || !writer.WritePixel(address,
                                Encode(surface.Pixel(sourceX + column,
                                    sourceY + row)))) { return false; }
                        }
                        column = column + 1;
                    }
                }
                row = row + 1;
            }
            return true;
        }
        public bool PresentDamage(PixelSurface surface, DamageTracker damage) {
            if (!Ready() || surface == null || !surface.Ready() ||
                damage == null || damage.Width() != mode.Width() ||
                damage.Height() != mode.Height() ||
                surface.Width() != mode.Width() ||
                surface.Height() != mode.Height()) { return false; }
            int i = 0;
            while (i < damage.Count()) {
                DamageRect rect = damage.At(i);
                if (rect == null || !PresentRegion(surface, rect.X(), rect.Y(),
                    rect.Width(), rect.Height(), rect.X(), rect.Y())) {
                    return false;
                }
                i = i + 1;
            }
            damage.Clear();
            return true;
        }
    }
}
