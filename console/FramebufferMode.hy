namespace Australis.Kernel.Console {
    // The firmware-selected GOP mode is immutable after ExitBootServices.
    // This describes and validates the kernel's one mapped 32-bit surface.
    public class FramebufferMode {
        private long baseAddress;
        private long byteLength;
        private int pixelWidth;
        private int pixelHeight;
        private int pixelsPerLine;
        private int format;
        private bool supported;

        public FramebufferMode(long inputBase, long inputLength, int inputWidth,
            int inputHeight, int inputStride, int inputFormat) {
            baseAddress = inputBase; byteLength = inputLength;
            pixelWidth = inputWidth; pixelHeight = inputHeight;
            pixelsPerLine = inputStride; format = inputFormat;
            supported = inputBase >= 4096 && inputLength > 0 &&
                inputWidth >= 8 && inputWidth <= 16384 &&
                inputHeight >= 8 && inputHeight <= 16384 &&
                inputStride >= inputWidth && inputStride <= 16384 &&
                inputFormat >= 0 && inputFormat <= 1 &&
                (long)inputStride * inputHeight * 4 <= inputLength;
        }

        public bool Supported() { return supported; }
        public int Width() { return pixelWidth; }
        public int Height() { return pixelHeight; }
        public int Stride() { return pixelsPerLine; }
        public int Format() { return format; }
        public long Length() { return byteLength; }
        public long PixelAddress(int x, int y) {
            if (!supported || x < 0 || y < 0 || x >= pixelWidth || y >= pixelHeight) { return 0; }
            return baseAddress + ((long)y * pixelsPerLine + x) * 4;
        }
    }
}
