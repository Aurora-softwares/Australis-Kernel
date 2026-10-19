using Australis.Kernel.Console;

namespace Australis.Kernel.Graphics {
    // The sole hardware-facing display lease. The process host authenticates
    // and authorizes the PID before Claim; callers never receive GOP addresses.
    public class DisplayDevice {
        private FramebufferMode mode;
        private IFramebufferPixelWriter writer;
        private ConsoleWriter console;
        private ConsoleInputMux inputMux;
        private int owner;
        private bool keyboardCaptured;
        public DisplayDevice(FramebufferMode inputMode,
            IFramebufferPixelWriter inputWriter, ConsoleWriter inputConsole) {
            mode = inputMode; writer = inputWriter; console = inputConsole;
            owner = 0; inputMux = null; keyboardCaptured = false;
        }
        public void AttachInputMux(ConsoleInputMux mux) { inputMux = mux; }
        public bool KeyboardCaptured() { return keyboardCaptured; }
        public int CaptureKeyboard(int processId, bool capture) {
            if (processId < 1 || owner != processId) { return -13; }
            keyboardCaptured = capture;
            if (inputMux != null) { inputMux.SetSecondEnabled(!capture); }
            return 0;
        }
        public bool Ready() { return mode != null && mode.Supported() && writer != null; }
        public int Owner() { return owner; }
        // Keep the recovery path independent of string allocation and formatting.
        private void WriteRecoveryNotice() {
            if (console == null) { return; }
            console.WriteByte(13); console.WriteByte(10);
            console.WriteByte(68); console.WriteByte(105); console.WriteByte(115);
            console.WriteByte(112); console.WriteByte(108); console.WriteByte(97);
            console.WriteByte(121); console.WriteByte(32); console.WriteByte(115);
            console.WriteByte(116); console.WriteByte(111); console.WriteByte(112);
            console.WriteByte(112); console.WriteByte(101); console.WriteByte(100);
            console.WriteByte(59); console.WriteByte(32); console.WriteByte(67);
            console.WriteByte(79); console.WriteByte(77); console.WriteByte(49);
            console.WriteByte(32); console.WriteByte(97); console.WriteByte(99);
            console.WriteByte(116); console.WriteByte(105); console.WriteByte(118);
            console.WriteByte(101);
            console.WriteByte(13); console.WriteByte(10);
        }
        public int Claim(int processId) {
            if (!Ready()) { return -19; }
            if (processId < 1) { return -22; }
            if (owner != 0) { return -16; }
            owner = processId;
            if (console != null) { console.SetMirrorEnabled(false); }
            return 0;
        }
        public int Release(int processId) {
            if (processId < 1 || owner != processId) { return -13; }
            owner = 0;
            keyboardCaptured = false;
            if (inputMux != null) { inputMux.SetSecondEnabled(true); }
            if (console != null) {
                console.SetMirrorEnabled(true);
                console.ClearMirrorScreen();
                WriteRecoveryNotice();
            }
            return 0;
        }
        public void ReleaseOnExit(int processId) {
            if (owner == processId) { Release(processId); }
        }
        public int SetMode(int processId, int width, int height) {
            if (processId < 1 || owner != processId) { return -13; }
            if (width < 1 || height < 1) { return -22; }
            return -95; // GOP has no post-handoff mode-change operation.
        }
        public int FillRect(int processId, int x, int y, int width,
            int height, int rgb) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!Ready() || x < 0 || y < 0 || width < 1 || height < 1 ||
                rgb < 0 || rgb > 16777215 ||
                (long)x + width > mode.Width() ||
                (long)y + height > mode.Height() ||
                (long)width * height > 65536) { return -22; }
            int encoded = rgb;
            if (mode.Format() == 0) {
                encoded = (rgb % 256) * 65536 + (rgb / 256 % 256) * 256 +
                    rgb / 65536;
            }
            int row = 0;
            while (row < height) {
                int column = 0;
                while (column < width) {
                    long address = mode.PixelAddress(x + column, y + row);
                    if (address == 0 || !writer.WritePixel(address, encoded)) {
                        return -5;
                    }
                    column = column + 1;
                }
                row = row + 1;
            }
            return 0;
        }
    }
}
