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
        // Display buffers reserve the protocol's maximum pixel count once,
        // then change logical geometry without replacing their storage.
        public PixelSurface(int inputWidth, int inputHeight,
            bool reserveForModes) {
            width = 0; height = 0; pixels = null;
            long count = (long)inputWidth * inputHeight;
            if (inputWidth < 1 || inputHeight < 1 ||
                inputWidth > 2048 || inputHeight > 2048 ||
                count > 1048576) { return; }
            width = inputWidth; height = inputHeight;
            if (reserveForModes) { pixels = new int[1048576]; }
            else { pixels = new int[(int)count]; }
        }
        public bool Reshape(int nextWidth, int nextHeight) {
            if (!Ready() || nextWidth < 1 || nextHeight < 1 ||
                nextWidth > 2048 || nextHeight > 2048 ||
                (long)nextWidth * nextHeight > pixels.Length) {
                return false;
            }
            width = nextWidth; height = nextHeight;
            return Fill(0);
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
            int count = width * height;
            while (i < count) { pixels[i] = rgb; i = i + 1; }
            return true;
        }
        // Copy an opaque rectangle from a cached layer with no per-pixel
        // blending or bounds checks.
        public bool CopyRegion(PixelSurface source, int sourceX, int sourceY,
            int targetX, int targetY, int copyWidth, int copyHeight) {
            if (!Ready() || source == null || !source.Ready() ||
                source == this || sourceX < 0 || sourceY < 0 ||
                targetX < 0 || targetY < 0 ||
                copyWidth < 1 || copyHeight < 1 ||
                (long)sourceX + copyWidth > source.width ||
                (long)sourceY + copyHeight > source.height ||
                (long)targetX + copyWidth > width ||
                (long)targetY + copyHeight > height) { return false; }
            int row = 0;
            while (row < copyHeight) {
                int sourceIndex = (sourceY + row) * source.width + sourceX;
                int targetIndex = (targetY + row) * width + targetX;
                int end = targetIndex + copyWidth;
                while (targetIndex < end) {
                    pixels[targetIndex] = source.pixels[sourceIndex];
                    sourceIndex = sourceIndex + 1;
                    targetIndex = targetIndex + 1;
                }
                row = row + 1;
            }
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
            long firstX = 0; long firstY = 0;
            if (targetX < 0) { firstX = 0 - (long)targetX; }
            if (targetY < 0) { firstY = 0 - (long)targetY; }
            long lastX = source.width; long lastY = source.height;
            if ((long)targetX + lastX > width) { lastX = (long)width - targetX; }
            if ((long)targetY + lastY > height) { lastY = (long)height - targetY; }
            if (firstX >= lastX || firstY >= lastY) { return true; }
            int row = (int)firstY;
            while (row < lastY) {
                int sourceIndex = row * source.width + (int)firstX;
                int targetIndex = (targetY + row) * width + targetX + (int)firstX;
                int column = (int)firstX;
                while (column < lastX) {
                    int color = source.pixels[sourceIndex];
                    if (opacity < 255) {
                        color = BlendColor(color, pixels[targetIndex], opacity);
                    }
                    pixels[targetIndex] = color;
                    sourceIndex = sourceIndex + 1;
                    targetIndex = targetIndex + 1;
                    column = column + 1;
                }
                row = row + 1;
            }
            return true;
        }
    }
}
