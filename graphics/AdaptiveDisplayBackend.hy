using Australis.Kernel.Console;

namespace Australis.Kernel.Graphics {
    // Keep the native scanout selected through transient failures so the next
    // presentation can reset it. GOP is the final fallback at matching geometry.
    public class AdaptiveDisplayBackend : IDisplayBackend {
        private IDisplayBackend nativeBackend;
        private IDisplayBackend gopBackend;
        private IDisplayBackend active;
        private int nativeWidth;
        private int nativeHeight;
        public AdaptiveDisplayBackend(IDisplayBackend inputNative,
            IDisplayBackend inputGop) {
            nativeBackend = inputNative; gopBackend = inputGop;
            active = null; nativeWidth = 0; nativeHeight = 0;
        }
        public int Kind() { if (active == null) { return 0; }
            return active.Kind(); }
        public int Width() { if (active == null) { return 0; }
            return active.Width(); }
        public int Height() { if (active == null) { return 0; }
            return active.Height(); }
        public int StrideBytes() { if (active == null) { return 0; }
            return active.StrideBytes(); }
        public int ScanoutFormat() { if (active == null) { return 0; }
            return active.ScanoutFormat(); }
        public int Capabilities() { if (active == null) { return 0; }
            return active.Capabilities(); }
        public bool Ready() {
            return active != null &&
                (active.Ready() || active == nativeBackend);
        }
        public bool Initialize() {
            if (nativeBackend != null && nativeBackend.Initialize() &&
                nativeBackend.Ready()) {
                active = nativeBackend;
                nativeWidth = nativeBackend.Width();
                nativeHeight = nativeBackend.Height();
                return true;
            }
            if (nativeBackend != null) { nativeBackend.Shutdown(); }
            if (gopBackend != null && gopBackend.Initialize() &&
                gopBackend.Ready()) {
                active = gopBackend; return true;
            }
            active = null; return false;
        }
        public void Shutdown() {
            if (nativeBackend != null) { nativeBackend.Shutdown(); }
            if (gopBackend != null) { gopBackend.Shutdown(); }
            active = null;
        }
        public bool Recover() { Shutdown(); return Initialize(); }
        public bool HardwareCursor() {
            return active != null && active.HardwareCursor();
        }
        public bool MoveCursor(int x, int y) {
            return active != null && active.MoveCursor(x, y);
        }
        public void HideCursor() {
            if (active != null) { active.HideCursor(); }
        }
        public bool Reconfigure(int width, int height) {
            if (active != nativeBackend ||
                !nativeBackend.Reconfigure(width, height)) { return false; }
            nativeWidth = nativeBackend.Width();
            nativeHeight = nativeBackend.Height();
            return true;
        }
        public bool PollModeChange() {
            if (active != nativeBackend ||
                !nativeBackend.PollModeChange()) { return false; }
            nativeWidth = nativeBackend.Width();
            nativeHeight = nativeBackend.Height();
            return true;
        }
        private bool SwitchToGop() {
            if (active != nativeBackend || gopBackend == null ||
                gopBackend.Width() != nativeWidth ||
                gopBackend.Height() != nativeHeight) { return false; }
            nativeBackend.Shutdown();
            if (!gopBackend.Initialize()) { return false; }
            active = gopBackend; return true;
        }
        public bool PresentDamage(PixelSurface surface, DamageTracker damage) {
            if (!Ready() || surface == null || !surface.Ready() ||
                damage == null || surface.Width() != Width() ||
                surface.Height() != Height() || damage.Width() != Width() ||
                damage.Height() != Height()) {
                return false;
            }
            if (active.Ready() && active.PresentDamage(surface, damage)) {
                return true;
            }
            if (active != nativeBackend) { return false; }
            if (nativeBackend.Recover()) {
                damage.Full();
                if (nativeBackend.PresentDamage(surface, damage)) {
                    return true;
                }
            }
            if (!SwitchToGop()) { return false; }
            damage.Full();
            return gopBackend.PresentDamage(surface, damage);
        }
        public bool FillImmediate(int x, int y, int width, int height,
            int rgb) {
            if (!Ready() || x < 0 || y < 0 || width < 1 || height < 1 ||
                (long)x + width > Width() ||
                (long)y + height > Height() || rgb < 0 ||
                rgb > 16777215) { return false; }
            if (active.Ready() &&
                active.FillImmediate(x, y, width, height, rgb)) {
                return true;
            }
            if (active != nativeBackend) { return false; }
            if (nativeBackend.Recover() &&
                nativeBackend.FillImmediate(x, y, width, height, rgb)) {
                return true;
            }
            if (!SwitchToGop()) { return false; }
            return gopBackend.FillImmediate(x, y, width, height, rgb);
        }
    }
}
