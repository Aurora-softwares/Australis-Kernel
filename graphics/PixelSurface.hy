namespace Australis.Kernel.Graphics {
    // A bounded, owned RGB888 image. The high byte is always zero; opacity is
    // supplied when one surface is composited onto another.
    public class PixelSurface {
        private int width;
        private int height;
        private int[] pixels;

        public PixelSurface(int inputWidth, int inputHeight) {
            width = 0; height = 0; pixels = null;
            long count = (long)inputWidth * inputHeight;
            if (inputWidth < 1 || inputHeight < 1 ||
                inputWidth > 2048 || inputHeight > 2048 ||
                count > 1048576) { return; }
            width = inputWidth; height = inputHeight;
            pixels = new int[(int)count];
        }

        public bool Ready() { return pixels != null; }
        public int Width() { return width; }
        public int Height() { return height; }
        public int Pixel(int x, int y) {
            if (!Ready() || x < 0 || y < 0 || x >= width || y >= height) { return -1; }
            return pixels[y * width + x];
        }
        public bool SetPixel(int x, int y, int rgb) {
            if (!Ready() || x < 0 || y < 0 || x >= width || y >= height ||
                rgb < 0 || rgb > 16777215) { return false; }
            pixels[y * width + x] = rgb;
            return true;
        }
        public bool Fill(int rgb) {
            if (!Ready() || rgb < 0 || rgb > 16777215) { return false; }
            int i = 0;
            while (i < pixels.Length) { pixels[i] = rgb; i = i + 1; }
            return true;
        }
        public bool FillRect(int x, int y, int rectWidth, int rectHeight, int rgb) {
            if (!Ready() || rectWidth < 1 || rectHeight < 1 ||
                rgb < 0 || rgb > 16777215) { return false; }
            long left = x; long top = y;
            long right = left + rectWidth; long bottom = top + rectHeight;
            if (left < 0) { left = 0; }
            if (top < 0) { top = 0; }
            if (right > width) { right = width; }
            if (bottom > height) { bottom = height; }
            int row = (int)top;
            while (row < bottom) {
                int column = (int)left;
                while (column < right) {
                    pixels[row * width + column] = rgb;
                    column = column + 1;
                }
                row = row + 1;
            }
            return true;
        }
        public static bool RoundedContains(int dx, int dy, int rectWidth,
            int rectHeight, int radius) {
            if (rectWidth < 1 || rectHeight < 1 || radius < 0 ||
                dx < 0 || dy < 0 || dx >= rectWidth || dy >= rectHeight) { return false; }
            if (radius > rectWidth / 2) { radius = rectWidth / 2; }
            if (radius > rectHeight / 2) { radius = rectHeight / 2; }
            if (dx >= radius && dx < rectWidth - radius) { return true; }
            if (dy >= radius && dy < rectHeight - radius) { return true; }
            int cornerX = dx;
            int cornerY = dy;
            if (dx >= rectWidth - radius) { cornerX = rectWidth - dx - 1; }
            if (dy >= rectHeight - radius) { cornerY = rectHeight - dy - 1; }
            int distanceX = radius * 2 - cornerX * 2 - 1;
            int distanceY = radius * 2 - cornerY * 2 - 1;
            return distanceX * distanceX + distanceY * distanceY <=
                radius * radius * 4;
        }
        public bool FillRoundedRect(int x, int y, int rectWidth, int rectHeight,
            int radius, int rgb) {
            if (!Ready() || rectWidth < 1 || rectHeight < 1 || radius < 0 ||
                rgb < 0 || rgb > 16777215) { return false; }
            if (radius > rectWidth / 2) { radius = rectWidth / 2; }
            if (radius > rectHeight / 2) { radius = rectHeight / 2; }
            long left = x; long top = y;
            long right = left + rectWidth; long bottom = top + rectHeight;
            if (left < 0) { left = 0; }
            if (top < 0) { top = 0; }
            if (right > width) { right = width; }
            if (bottom > height) { bottom = height; }
            int row = (int)top;
            while (row < bottom) {
                int column = (int)left;
                while (column < right) {
                    if (RoundedContains(column - x, row - y,
                        rectWidth, rectHeight, radius)) {
                        pixels[row * width + column] = rgb;
                    }
                    column = column + 1;
                }
                row = row + 1;
            }
            return true;
        }
        public bool FillCircle(int centerX, int centerY, int radius, int rgb) {
            if (!Ready() || radius < 1 || radius > 1024 ||
                rgb < 0 || rgb > 16777215) { return false; }
            long left = (long)centerX - radius;
            long top = (long)centerY - radius;
            long right = (long)centerX + radius + 1;
            long bottom = (long)centerY + radius + 1;
            if (left < 0) { left = 0; }
            if (top < 0) { top = 0; }
            if (right > width) { right = width; }
            if (bottom > height) { bottom = height; }
            int row = (int)top;
            while (row < bottom) {
                int column = (int)left;
                while (column < right) {
                    long dx = (long)column - centerX;
                    long dy = (long)row - centerY;
                    if (dx * dx + dy * dy <= (long)radius * radius) {
                        pixels[row * width + column] = rgb;
                    }
                    column = column + 1;
                }
                row = row + 1;
            }
            return true;
        }
        public static int BlendColor(int source, int destination, int opacity) {
            if (source < 0 || source > 16777215 || destination < 0 ||
                destination > 16777215 || opacity < 0 || opacity > 255) { return -1; }
            if (opacity == 0) { return destination; }
            if (opacity == 255) { return source; }
            int inverse = 255 - opacity;
            int red = ((source / 65536) * opacity +
                (destination / 65536) * inverse + 127) / 255;
            int green = ((source / 256 % 256) * opacity +
                (destination / 256 % 256) * inverse + 127) / 255;
            int blue = ((source % 256) * opacity +
                (destination % 256) * inverse + 127) / 255;
            return red * 65536 + green * 256 + blue;
        }
        public bool Blit(PixelSurface source, int targetX, int targetY, int opacity) {
            if (!Ready() || source == null || !source.Ready() || source == this ||
                opacity < 0 || opacity > 255) { return false; }
            if (opacity == 0) { return true; }
            int row = 0;
            while (row < source.Height()) {
                long destinationY = (long)targetY + row;
                if (destinationY >= 0 && destinationY < height) {
                    int column = 0;
                    while (column < source.Width()) {
                        long destinationX = (long)targetX + column;
                        if (destinationX >= 0 && destinationX < width) {
                            int index = (int)destinationY * width + (int)destinationX;
                            int color = source.Pixel(column, row);
                            if (opacity < 255) {
                                color = BlendColor(color, pixels[index], opacity);
                            }
                            pixels[index] = color;
                        }
                        column = column + 1;
                    }
                }
                row = row + 1;
            }
            return true;
        }
    }
}
