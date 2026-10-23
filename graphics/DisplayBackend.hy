using Australis.Kernel.Console;

namespace Australis.Kernel.Graphics {
    // The compositor uses RGB pixels. A backend owns the output mapping and
    // translates them to its scanout format; callers never see that mapping.
    public interface IDisplayBackend {
        int Kind(); // 1: GOP, 2: native GPU.
        int Width();
        int Height();
        int StrideBytes();
        int ScanoutFormat(); // 1: BGRX8888, 2: RGBX8888.
        int Capabilities(); // bits 0-3: damage, immediate, sync, cursor.
        int ReadGpuCompositionPixel(int x, int y);
        bool Initialize();
        bool Ready();
        void Shutdown();
        bool Recover();
        bool HardwareCursor();
        bool MoveCursor(int x, int y);
        void HideCursor();
        bool Reconfigure(int width, int height);
        bool PollModeChange();
        bool PresentDamage(PixelSurface surface, DamageTracker damage);
        bool FillImmediate(int x, int y, int width, int height, int rgb);
    }

    public interface IGpuWindowComposer {
        bool GpuWindowComposerReady();
        bool GpuCompositionOpen();

        bool BeginGpuComposition(int backgroundRgb);

        bool DrawGpuWindow(
            int processId,
            int handle,
            int x,
            int y);
        bool DrawGpuSolidRect(
            int x, int y, int width, int height, int rgb);
        bool EndGpuComposition();
        void AbortGpuComposition();

        int ClientWidth(int processId, int handle);
        int ClientHeight(int processId, int handle);

        // Read a pixel from the completed GPU composition.
        int ReadGpuCompositionPixel(int x, int y);
    }

    public class GopDisplayBackend : IDisplayBackend {
        private FramebufferMode mode;
        private IFramebufferPixelWriter writer;
        private FramebufferPresenter presenter;
        private bool started;
        public GopDisplayBackend(FramebufferMode inputMode,
            IFramebufferPixelWriter inputWriter) {
            mode = inputMode; writer = inputWriter;
            presenter = new FramebufferPresenter(mode, writer);
            started = false;
        }
        public int Kind() { return 1; }
        public int Width() {
            if (mode == null) { return 0; }
            return mode.Width();
        }
        public int Height() {
            if (mode == null) { return 0; }
            return mode.Height();
        }
        public int StrideBytes() {
            if (mode == null) { return 0; }
            return mode.Stride() * 4;
        }
        public int ScanoutFormat() {
            if (mode == null) { return 0; }
            if (mode.Format() == 0) { return 1; }
            return 2;
        }
        public int Capabilities() { return 7; }
        public bool Initialize() {
            started = presenter.Ready(); return started;
        }
        public bool Ready() { return started && presenter.Ready(); }
        public void Shutdown() { started = false; }
        public bool Recover() { Shutdown(); return Initialize(); }
        public bool HardwareCursor() { return false; }
        public bool MoveCursor(int x, int y) { return false; }
        public void HideCursor() { }
        public bool Reconfigure(int width, int height) { return false; }
        public bool PollModeChange() { return false; }
        public bool PresentDamage(PixelSurface surface, DamageTracker damage) {
            return Ready() && presenter.PresentDamage(surface, damage);
        }
        public bool FillImmediate(int x, int y, int width, int height,
            int rgb) {
            if (!Ready() || x < 0 || y < 0 || width < 1 || height < 1 ||
                rgb < 0 || rgb > 16777215 ||
                (long)x + width > mode.Width() ||
                (long)y + height > mode.Height()) { return false; }
            int encoded = presenter.Encode(rgb);
            int row = 0;
            while (row < height) {
                int column = 0;
                while (column < width) {
                    long address = mode.PixelAddress(x + column, y + row);
                    if (address == 0 || !writer.WritePixel(address, encoded)) {
                        return false;
                    }
                    column = column + 1;
                }
                row = row + 1;
            }
            return true;
        }
    }
}
