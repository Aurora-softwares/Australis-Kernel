namespace Australis.Kernel.Graphics {
    // A handle names kernel-owned storage, never a user or scanout address.
    // The display lease is the authority for every operation on this object.
    public class DisplayBuffer {
        private int handle;
        private int owner;
        private DisplayBufferLayout layout;
        private PixelSurface surface;
        private DamageTracker damage;
        private int state; // 0: available, 1: drawing, 2: submitted.
        private int fence;
        private long started;

        public DisplayBuffer(int inputHandle, int inputOwner,
            DisplayBufferLayout inputLayout) {
            handle = inputHandle; owner = inputOwner; layout = inputLayout;
            state = 0; fence = 0; started = 0;
            surface = null; damage = null;
            if (layout == null || !layout.Ready() ||
                layout.StrideBytes() != layout.Width() * 4) { return; }
            surface = new PixelSurface(layout.Width(), layout.Height());
            if (!surface.Ready()) { return; }
            damage = new DamageTracker(layout.Width(), layout.Height());
        }
        public bool Ready() { return surface != null && surface.Ready() &&
            damage != null; }
        public int Handle() { return handle; }
        public int Owner() { return owner; }
        public int Width() { return layout.Width(); }
        public int Height() { return layout.Height(); }
        public void Activate(int inputHandle, int inputOwner) {
            handle = inputHandle; owner = inputOwner;
            state = 0; fence = 0; started = 0;
            surface.Fill(0); damage.Clear();
        }
        public int State() { return state; }
        public int Fence() { return fence; }
        public long Started() { return started; }
        public PixelSurface Surface() { return surface; }
        public DamageTracker Damage() { return damage; }
        public bool Begin(long now) {
            if (!Ready() || state != 0) { return false; }
            damage.Clear(); state = 1; started = now; return true;
        }
        public bool FillRect(int x, int y, int width, int height, int rgb) {
            if (state != 1 || !Ready() || x < 0 || y < 0 ||
                width < 1 || height < 1 || rgb < 0 || rgb > 16777215 ||
                (long)x + width > layout.Width() ||
                (long)y + height > layout.Height() ||
                (long)width * height > 65536) { return false; }
            return surface.FillRect(x, y, width, height, rgb) &&
                damage.Add(x, y, width, height);
        }
        public void Submitted(int inputFence) {
            fence = inputFence; state = 2;
        }
        public bool Release(int inputFence) {
            if (state != 2 || fence != inputFence) { return false; }
            state = 0; fence = 0; return true;
        }
        public void Destroy() {
            // Keep the bounded slot's storage for its next owner. No stale
            // pixel data or fence survives a lease transition.
            if (surface != null) { surface.Fill(0); }
            if (damage != null) { damage.Clear(); }
            state = 0; fence = 0; started = 0;
            handle = 0; owner = 0;
        }
    }
}
