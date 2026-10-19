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
        }
        public int Count() { return count; }
        public int Width() { return width; }
        public int Height() { return height; }
        public DamageRect At(int index) {
            if (index < 0 || index >= count) { return null; }
            return rectangles[index];
        }
        public void Clear() {
            int i = 0;
            while (i < count) { rectangles[i] = null; i = i + 1; }
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
            if (count == rectangles.Length) {
                return Full();
            }
            rectangles[count] = new DamageRect((int)left, (int)top,
                (int)(right - left), (int)(bottom - top));
            count = count + 1;
            return true;
        }
        public bool Full() {
            if (width < 1 || height < 1) { return false; }
            Clear();
            rectangles[0] = new DamageRect(0, 0, width, height);
            count = 1;
            return true;
        }
    }
}
