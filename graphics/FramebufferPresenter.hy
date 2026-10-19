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
            long left = targetX; long top = targetY;
            long right = left + width; long bottom = top + height;
            if (left < 0) { left = 0; }
            if (top < 0) { top = 0; }
            if (right > mode.Width()) { right = mode.Width(); }
            if (bottom > mode.Height()) { bottom = mode.Height(); }
            if (left >= right || top >= bottom) { return true; }
            bool swap = mode.Format() == 0;
            int y = (int)top;
            while (y < bottom) {
                int sourceRow = sourceY + y - targetY;
                int sourceColumn = sourceX + (int)left - targetX;
                long address = mode.PixelAddress((int)left, y);
                if (address == 0) { return false; }
                int x = (int)left;
                while (x < right) {
                    int rgb = surface.Pixel(sourceColumn, sourceRow);
                    if (swap) {
                        rgb = (rgb % 256) * 65536 +
                            (rgb / 256 % 256) * 256 + rgb / 65536;
                    }
                    if (!writer.WritePixel(address, rgb)) { return false; }
                    address = address + 4;
                    sourceColumn = sourceColumn + 1;
                    x = x + 1;
                }
                y = y + 1;
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
