namespace Australis.Kernel.Graphics {
    public class DamageRect {
        private int x;
        private int y;
        private int width;
        private int height;
        public DamageRect(int inputX, int inputY, int inputWidth, int inputHeight) {
            x = inputX; y = inputY; width = inputWidth; height = inputHeight;
        }
        public int X() { return x; }
        public int Y() { return y; }
        public int Width() { return width; }
        public int Height() { return height; }
        public void Set(int nextX, int nextY, int nextWidth, int nextHeight) {
            x = nextX; y = nextY; width = nextWidth; height = nextHeight;
        }
    }

    // Dirty rectangles are clipped to the display. Overflow degrades to one
    // full-screen update, so a client cannot grow the queue without bound.
    public class DamageTracker {
        private int width;
        private int height;
        private DamageRect[] rectangles;
        private int count;
        public DamageTracker(int inputWidth, int inputHeight) {
            width = inputWidth; height = inputHeight;
            rectangles = new DamageRect[16]; count = 0;
            int i = 0;
            while (i < rectangles.Length) {
                rectangles[i] = new DamageRect(0, 0, 0, 0);
                i = i + 1;
            }
        }
        public int Count() { return count; }
        public int Width() { return width; }
        public int Height() { return height; }
        public DamageRect At(int index) {
            if (index < 0 || index >= count) { return null; }
            return rectangles[index];
        }
        public void Clear() {
            count = 0;
        }
        public bool Add(int x, int y, int rectWidth, int rectHeight) {
            if (width < 1 || height < 1 || rectWidth < 1 || rectHeight < 1) {
                return false;
            }
            long left = x; long top = y;
            long right = left + rectWidth; long bottom = top + rectHeight;
            if (left < 0) { left = 0; }
            if (top < 0) { top = 0; }
            if (right > width) { right = width; }
            if (bottom > height) { bottom = height; }
            if (left >= right || top >= bottom) { return true; }
            if (count == 1 && rectangles[0].X() == 0 &&
                rectangles[0].Y() == 0 && rectangles[0].Width() == width &&
                rectangles[0].Height() == height) { return true; }
            if (left == 0 && top == 0 && right == width && bottom == height) {
                return Full();
            }
            int i = 0;
            while (i < count) {
                DamageRect previous = rectangles[i];
                long previousRight = (long)previous.X() + previous.Width();
                long previousBottom = (long)previous.Y() + previous.Height();
                if (previous.X() <= left && previous.Y() <= top &&
                    previousRight >= right && previousBottom >= bottom) {
                    return true;
                }
                if (left <= previous.X() && top <= previous.Y() &&
                    right >= previousRight && bottom >= previousBottom) {
                    DamageRect reusable = rectangles[i];
                    int shift = i;
                    while (shift + 1 < count) {
                        rectangles[shift] = rectangles[shift + 1];
                        shift = shift + 1;
                    }
                    count = count - 1; rectangles[count] = reusable;
                } else { i = i + 1; }
            }
            if (count == rectangles.Length) {
                return Full();
            }
            rectangles[count].Set((int)left, (int)top,
                (int)(right - left), (int)(bottom - top));
            count = count + 1;
            return true;
        }
        public bool Full() {
            if (width < 1 || height < 1) { return false; }
            Clear();
            rectangles[0].Set(0, 0, width, height);
            count = 1;
            return true;
        }
    }
}
