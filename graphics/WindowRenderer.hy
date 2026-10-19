namespace Australis.Kernel.Graphics {
    public class WindowPaint {
        private int id;
        private int owner;
        private PixelSurface pixels;
        public WindowPaint(int inputId, int inputOwner, PixelSurface inputPixels) {
            id = inputId; owner = inputOwner; pixels = inputPixels;
        }
        public int Id() { return id; }
        public int Owner() { return owner; }
        public PixelSurface Pixels() { return pixels; }
    }

    // Software compositor prototype. Its input is copied into service-owned
    // surfaces; no client sees the display's physical framebuffer address.
    public class WindowRenderer {
        private WindowLayout layout;
        private PixelSurface frame;
        private WindowPaint[] paints;
        private int[] blurSource;
        private int hoverX;
        private int hoverY;
        public WindowRenderer(WindowLayout inputLayout) {
            layout = inputLayout; frame = null; blurSource = null;
            paints = new WindowPaint[8]; hoverX = -1; hoverY = -1;
            if (layout != null && layout.Ready()) {
                frame = new PixelSurface(layout.DisplayWidth(), layout.DisplayHeight());
                blurSource = new int[layout.DisplayWidth() * layout.BarHeight()];
            }
        }
        public bool Ready() { return frame != null && frame.Ready(); }
        public void Hover(int x, int y) { hoverX = x; hoverY = y; }
        private DesktopWindow FindWindow(int id) {
            int i = 0;
            while (i < layout.Count()) {
                DesktopWindow window = layout.WindowAt(i);
                if (window.Id() == id) { return window; }
                i = i + 1;
            }
            return null;
        }
        private WindowPaint FindPaint(int id) {
            int i = 0;
            while (i < paints.Length) {
                if (paints[i] != null && paints[i].Id() == id) { return paints[i]; }
                i = i + 1;
            }
            return null;
        }
        public bool Submit(int owner, int id, PixelSurface source) {
            if (!Ready() || source == null || !source.Ready()) { return false; }
            DesktopWindow window = FindWindow(id);
            if (window == null || window.Owner() != owner ||
                source.Width() > window.Width() ||
                source.Height() > window.Height()) { return false; }
            WindowPaint old = FindPaint(id);
            if (old != null) {
                if (old.Owner() != owner || old.Pixels().Width() != source.Width() ||
                    old.Pixels().Height() != source.Height()) { return false; }
                return old.Pixels().Fill(0) && old.Pixels().Blit(source, 0, 0, 255);
            }
            int slot = 0;
            while (slot < paints.Length && paints[slot] != null) { slot = slot + 1; }
            if (slot == paints.Length) { return false; }
            PixelSurface copy = new PixelSurface(source.Width(), source.Height());
            if (!copy.Ready() || !copy.Blit(source, 0, 0, 255)) { return false; }
            paints[slot] = new WindowPaint(id, owner, copy);
            return true;
        }
        public bool Remove(int owner, int id) {
            int i = 0;
            while (i < paints.Length) {
                if (paints[i] != null && paints[i].Id() == id &&
                    paints[i].Owner() == owner) { paints[i] = null; return true; }
                i = i + 1;
            }
            return false;
        }
        private void Wallpaper() {
            int width = layout.DisplayWidth();
            int height = layout.DisplayHeight();
            int y = 0;
            while (y < height) {
                int x = 0;
                while (x < width) {
                    int red = 27 + y * 24 / height;
                    int green = 38 + x * 30 / width;
                    int blue = 56 + (x + y) * 28 / (width + height);
                    frame.SetPixel(x, y, red * 65536 + green * 256 + blue);
                    x = x + 1;
                }
                y = y + 1;
            }
        }
        private void PaintWindow(DesktopWindow window) {
            if (!window.Visible()) { return; }
            WindowPaint paint = FindPaint(window.Id());
            PixelSurface content = null;
            if (paint != null) { content = paint.Pixels(); }
            int titleHeight = 28;
            if (window.Maximized()) { titleHeight = 0; }
            int row = 0;
            while (row < window.Height()) {
                int y = window.Y() + row;
                if (y >= 0 && y < layout.DisplayHeight()) {
                    int column = 0;
                    while (column < window.Width()) {
                        int x = window.X() + column;
                        if (x >= 0 && x < layout.DisplayWidth() &&
                            (window.Maximized() || PixelSurface.RoundedContains(
                                column, row, window.Width(), window.Height(), 10))) {
                            int color = 0xE8EDF2;
                            if (row < titleHeight) {
                                color = 0xC5CCD5;
                                if (layout.FocusedId() == window.Id()) {
                                    color = 0xE1E6EC;
                                }
                            } else if (content != null &&
                                column < content.Width() &&
                                row - titleHeight < content.Height()) {
                                color = content.Pixel(column, row - titleHeight);
                            }
                            frame.SetPixel(x, y, color);
                        }
                        column = column + 1;
                    }
                }
                row = row + 1;
            }
            if (!window.Maximized()) {
                DrawControls(window.Id(), window.X(), window.Y());
            }
        }
        private void DrawIcon(int kind, int centerX, int centerY) {
            int offset = -2;
            while (offset <= 2) {
                if (kind == 1) {
                    frame.SetPixel(centerX + offset, centerY + offset, 0x383838);
                    frame.SetPixel(centerX + offset, centerY - offset, 0x383838);
                } else if (kind == 2) {
                    frame.SetPixel(centerX + offset, centerY + 2, 0x383838);
                } else {
                    frame.SetPixel(centerX + offset, centerY, 0x383838);
                    frame.SetPixel(centerX, centerY + offset, 0x383838);
                }
                offset = offset + 1;
            }
        }
        private void DrawControls(int id, int left, int top) {
            int hoverId = layout.HitTest(hoverX, hoverY);
            int hoveredControl = layout.ControlAt(hoverX, hoverY);
            int kind = 1;
            while (kind <= 3) {
                int centerX = left + 18 + (kind - 1) * 22;
                int centerY = top + 16;
                int color = 0xFF5F57;
                if (kind == 2) { color = 0xFEBC2E; }
                if (kind == 3) { color = 0x28C840; }
                frame.FillCircle(centerX, centerY, 7, color);
                if (hoverId == id && hoveredControl == kind) {
                    DrawIcon(kind, centerX, centerY);
                }
                kind = kind + 1;
            }
        }
        private void TopBar() {
            int width = layout.DisplayWidth();
            int bar = layout.BarHeight();
            if (layout.TopBarMode() == 2) {
                frame.FillRect(0, 0, width, bar, 0);
                int i = layout.Count() - 1;
                while (i >= 0) {
                    DesktopWindow window = layout.WindowAt(i);
                    if (window.Visible() && window.Maximized()) {
                        DrawControls(window.Id(), 0, 0);
                        return;
                    }
                    i = i - 1;
                }
                return;
            }
            int y = 0;
            while (y < bar) {
                int x = 0;
                while (x < width) {
                    blurSource[y * width + x] = frame.Pixel(x, y);
                    x = x + 1;
                }
                y = y + 1;
            }
            y = 0;
            while (y < bar) {
                int x = 0;
                while (x < width) {
                    int red = 0; int green = 0; int blue = 0; int samples = 0;
                    int dy = -2;
                    while (dy <= 2) {
                        int sampleY = y + dy;
                        if (sampleY >= 0 && sampleY < bar) {
                            int dx = -2;
                            while (dx <= 2) {
                                int sampleX = x + dx;
                                if (sampleX >= 0 && sampleX < width) {
                                    int color = blurSource[sampleY * width + sampleX];
                                    red = red + color / 65536;
                                    green = green + color / 256 % 256;
                                    blue = blue + color % 256;
                                    samples = samples + 1;
                                }
                                dx = dx + 1;
                            }
                        }
                        dy = dy + 1;
                    }
                    int blurred = (red / samples) * 65536 +
                        (green / samples) * 256 + blue / samples;
                    frame.SetPixel(x, y,
                        PixelSurface.BlendColor(0xDDE7EE, blurred, 160));
                    x = x + 1;
                }
                y = y + 1;
            }
        }
        public PixelSurface Compose() {
            if (!Ready()) { return null; }
            Wallpaper();
            int i = 0;
            while (i < layout.Count()) {
                PaintWindow(layout.WindowAt(i));
                i = i + 1;
            }
            TopBar();
            return frame;
        }
    }
}
