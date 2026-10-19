namespace Australis.Kernel.Graphics {
    // Geometry and ownership are kept separate from a client's pixel surface.
    // A future display service can render this model without giving clients
    // the framebuffer address or another window's storage.
    public class DesktopWindow {
        private int id;
        private int owner;
        private int x;
        private int y;
        private int width;
        private int height;
        private int savedX;
        private int savedY;
        private int savedWidth;
        private int savedHeight;
        private bool visible;
        private bool maximized;
        public DesktopWindow(int inputId, int inputOwner, int inputX, int inputY,
            int inputWidth, int inputHeight) {
            id = inputId; owner = inputOwner;
            x = inputX; y = inputY; width = inputWidth; height = inputHeight;
            savedX = x; savedY = y; savedWidth = width; savedHeight = height;
            visible = true; maximized = false;
        }
        public int Id() { return id; }
        public int Owner() { return owner; }
        public int X() { return x; }
        public int Y() { return y; }
        public int Width() { return width; }
        public int Height() { return height; }
        public bool Visible() { return visible; }
        public bool Maximized() { return maximized; }
        public bool Contains(int pointX, int pointY) {
            if (!visible || pointX < x || pointY < y ||
                (long)pointX >= (long)x + width ||
                (long)pointY >= (long)y + height) { return false; }
            if (maximized) { return true; }
            return PixelSurface.RoundedContains(pointX - x, pointY - y,
                width, height, 10);
        }
        public void SetPosition(int nextX, int nextY) { x = nextX; y = nextY; }
        public void SetSize(int nextWidth, int nextHeight) {
            width = nextWidth; height = nextHeight;
        }
        public void SetVisible(bool nextVisible) { visible = nextVisible; }
        public void Maximize(int barHeight, int displayWidth, int displayHeight) {
            if (maximized) { return; }
            savedX = x; savedY = y;
            savedWidth = width; savedHeight = height;
            x = 0; y = barHeight;
            width = displayWidth; height = displayHeight - barHeight;
            maximized = true;
        }
        public void Unmaximize() {
            if (!maximized) { return; }
            x = savedX; y = savedY;
            width = savedWidth; height = savedHeight;
            maximized = false;
        }
    }

    public class WindowLayout {
        private int displayWidth;
        private int displayHeight;
        private int barHeight;
        private DesktopWindow[] windows;
        private int count;
        private int nextId;
        private int focusedId;
        public WindowLayout(int inputWidth, int inputHeight, int inputBarHeight) {
            displayWidth = inputWidth; displayHeight = inputHeight;
            barHeight = inputBarHeight;
            windows = new DesktopWindow[8]; count = 0;
            nextId = 1; focusedId = 0;
        }
        public bool Ready() {
            return displayWidth >= 320 && displayWidth <= 2048 &&
                displayHeight >= 240 && displayHeight <= 2048 &&
                (long)displayWidth * displayHeight <= 1048576 &&
                barHeight >= 24 && barHeight <= 64 &&
                barHeight < displayHeight;
        }
        public int DisplayWidth() { return displayWidth; }
        public int DisplayHeight() { return displayHeight; }
        public int BarHeight() { return barHeight; }
        public int Count() { return count; }
        public int FocusedId() { return focusedId; }
        public DesktopWindow WindowAt(int index) {
            if (index < 0 || index >= count) { return null; }
            return windows[index];
        }
        private int Index(int id) {
            int i = 0;
            while (i < count) {
                if (windows[i].Id() == id) { return i; }
                i = i + 1;
            }
            return -1;
        }
        private bool Fits(int x, int y, int width, int height) {
            return width >= 96 && height >= 64 &&
                x >= 0 && y >= barHeight &&
                (long)x + width <= displayWidth &&
                (long)y + height <= displayHeight;
        }
        private void FocusTopVisible() {
            focusedId = 0;
            int i = count - 1;
            while (i >= 0) {
                if (windows[i].Visible()) { focusedId = windows[i].Id(); return; }
                i = i - 1;
            }
        }
        public int Open(int owner, int x, int y, int width, int height) {
            if (!Ready() || owner < 1 || count >= windows.Length ||
                nextId >= 2147483647 || !Fits(x, y, width, height)) { return -1; }
            DesktopWindow window = new DesktopWindow(nextId, owner, x, y, width, height);
            windows[count] = window;
            count = count + 1;
            focusedId = nextId;
            nextId = nextId + 1;
            return window.Id();
        }
        public bool Close(int owner, int id) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner) { return false; }
            int i = index;
            while (i + 1 < count) { windows[i] = windows[i + 1]; i = i + 1; }
            count = count - 1; windows[count] = null;
            FocusTopVisible();
            return true;
        }
        public int CloseOwner(int owner) {
            if (owner < 1) { return 0; }
            int removed = 0;
            int i = count - 1;
            while (i >= 0) {
                if (windows[i].Owner() == owner && Close(owner, windows[i].Id())) {
                    removed = removed + 1;
                }
                i = i - 1;
            }
            return removed;
        }
        public bool Focus(int id) {
            int index = Index(id);
            if (index < 0 || !windows[index].Visible()) { return false; }
            DesktopWindow focused = windows[index];
            int i = index;
            while (i + 1 < count) { windows[i] = windows[i + 1]; i = i + 1; }
            windows[count - 1] = focused;
            focusedId = id;
            return true;
        }
        public int HitTest(int x, int y) {
            if (!Ready() || x < 0 || y < 0 ||
                x >= displayWidth || y >= displayHeight) { return 0; }
            if (y < barHeight) {
                int top = count - 1;
                while (top >= 0) {
                    if (windows[top].Visible() && windows[top].Maximized()) {
                        return windows[top].Id();
                    }
                    top = top - 1;
                }
                return 0;
            }
            int i = count - 1;
            while (i >= 0) {
                if (windows[i].Contains(x, y)) { return windows[i].Id(); }
                i = i - 1;
            }
            return 0;
        }
        public int FocusAt(int x, int y) {
            int id = HitTest(x, y);
            if (id > 0) { Focus(id); }
            return id;
        }
        // The invisible resize grip includes the rounded corner's clipped
        // pixels, but is limited to the window's own rectangular bounds.
        public int ResizeHitTest(int x, int y) {
            if (!Ready() || x < 0 || y < barHeight ||
                x >= displayWidth || y >= displayHeight) { return 0; }
            int i = count - 1;
            while (i >= 0) {
                DesktopWindow window = windows[i];
                if (window.Visible() && !window.Maximized() &&
                    x >= window.X() + window.Width() - 6 &&
                    x < window.X() + window.Width() &&
                    y >= window.Y() + window.Height() - 6 &&
                    y < window.Y() + window.Height()) { return window.Id(); }
                if (window.Contains(x, y)) { return 0; }
                i = i - 1;
            }
            return 0;
        }
        public bool Minimize(int owner, int id) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner ||
                !windows[index].Visible()) { return false; }
            windows[index].SetVisible(false);
            FocusTopVisible();
            return true;
        }
        public bool RestoreMinimized(int owner, int id) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner ||
                windows[index].Visible()) { return false; }
            windows[index].SetVisible(true);
            return Focus(id);
        }
        public bool Maximize(int owner, int id) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner ||
                !windows[index].Visible()) { return false; }
            int i = 0;
            while (i < count) {
                if (windows[i].Maximized() && windows[i].Id() != id) {
                    windows[i].Unmaximize();
                }
                i = i + 1;
            }
            windows[index].Maximize(barHeight, displayWidth, displayHeight);
            return Focus(id);
        }
        public bool Unmaximize(int owner, int id) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner ||
                !windows[index].Maximized()) { return false; }
            windows[index].Unmaximize();
            return true;
        }
        public bool Move(int owner, int id, int x, int y) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner ||
                windows[index].Maximized() || !windows[index].Visible() ||
                !Fits(x, y, windows[index].Width(), windows[index].Height())) {
                return false;
            }
            windows[index].SetPosition(x, y);
            return true;
        }
        public bool Resize(int owner, int id, int width, int height) {
            int index = Index(id);
            if (index < 0 || windows[index].Owner() != owner ||
                windows[index].Maximized() || !windows[index].Visible() ||
                !Fits(windows[index].X(), windows[index].Y(), width, height)) {
                return false;
            }
            windows[index].SetSize(width, height);
            return true;
        }
        public int TopBarMode() {
            int i = count - 1;
            while (i >= 0) {
                if (windows[i].Visible() && windows[i].Maximized()) { return 2; }
                i = i - 1;
            }
            return 1; // frosted when no window is maximized
        }
        public int ControlAt(int x, int y) {
            int id = HitTest(x, y);
            int index = Index(id);
            if (index < 0) { return 0; }
            DesktopWindow window = windows[index];
            int left = window.X();
            int top = window.Y();
            if (window.Maximized()) { left = 0; top = 0; }
            if (y < top + 8 || y >= top + 26) { return 0; }
            int relativeX = x - left;
            if (relativeX >= 10 && relativeX < 26) { return 1; } // close
            if (relativeX >= 32 && relativeX < 48) { return 2; } // minimize
            if (relativeX >= 54 && relativeX < 70) { return 3; } // maximize/restore
            return 0;
        }
    }
}
