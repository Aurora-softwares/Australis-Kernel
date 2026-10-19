namespace Australis.Kernel.Graphics {
    // Logical compositor pixels are packed RGBX8888. The scanout backend
    // converts to its own format and stride when a frame is presented.
    public class DisplayBufferLayout {
        private int width;
        private int height;
        private int strideBytes;
        private int format;
        private long byteLength;
        private bool valid;
        public static int Rgbx8888() { return 1; }
        public DisplayBufferLayout(int inputWidth, int inputHeight,
            int inputStrideBytes, int inputFormat) {
            width = inputWidth; height = inputHeight;
            strideBytes = inputStrideBytes; format = inputFormat;
            byteLength = 0; valid = false;
            long pixels = (long)width * height;
            long bytes = (long)strideBytes * height;
            if (width < 1 || width > 2048 || height < 1 || height > 2048 ||
                pixels > 1048576 || strideBytes < (long)width * 4 ||
                strideBytes % 4 != 0 || bytes > 8388608 ||
                format != Rgbx8888()) { return; }
            byteLength = bytes; valid = true;
        }
        public bool Ready() { return valid; }
        public int Width() { return width; }
        public int Height() { return height; }
        public int StrideBytes() { return strideBytes; }
        public int Format() { return format; }
        public long ByteLength() { return byteLength; }
    }
}
