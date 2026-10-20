using Australis.Kernel.Console;

namespace Australis.Kernel.Graphics {
    public interface IFrameClock {
        long Now();
        long TicksPerMillisecond();
    }

    // The sole hardware-facing display lease. The process host authenticates
    // and authorizes the PID before Claim; callers never receive GOP addresses.
    public class DisplayDevice {
        private IDisplayBackend backend;
        private DisplayBufferLayout frameLayout;
        private ConsoleWriter console;
        private ConsoleInputMux inputMux;
        private int owner;
        private bool keyboardCaptured;
        private PixelSurface frame;
        private DamageTracker frameDamage;
        private bool frameOpen;
        private IFrameClock frameClock;
        private int submittedFrames;
        private int presentedFrames;
        private int droppedFrames;
        private int lastPresentationMicros;
        private int maxPresentationMicros;
        private long frameStarted;
        private int pacingMilliseconds;
        private long lastCompleted;
        private bool hasCompleted;
        private DisplayBuffer[] buffers;
        private int nextBufferHandle;
        private int nextFence;
        private int cursorX;
        private int cursorY;
        public DisplayDevice(FramebufferMode inputMode,
            IFramebufferPixelWriter inputWriter, ConsoleWriter inputConsole) {
            backend = new GopDisplayBackend(inputMode, inputWriter);
            backend.Initialize(); console = inputConsole;
            frameLayout = MakeLayout();
            owner = 0; inputMux = null; keyboardCaptured = false;
            frame = null; frameDamage = null; frameOpen = false;
            frameClock = null; submittedFrames = 0; presentedFrames = 0;
            droppedFrames = 0; lastPresentationMicros = 0;
            maxPresentationMicros = 0;
            pacingMilliseconds = 0; lastCompleted = 0;
            hasCompleted = false;
            buffers = new DisplayBuffer[3];
            nextBufferHandle = 1; nextFence = 1;
            cursorX = 0; cursorY = 0;
        }
        public DisplayDevice(IDisplayBackend inputBackend,
            ConsoleWriter inputConsole) {
            backend = inputBackend;
            if (backend != null) { backend.Initialize(); }
            console = inputConsole;
            frameLayout = MakeLayout();
            owner = 0; inputMux = null; keyboardCaptured = false;
            frame = null; frameDamage = null; frameOpen = false;
            frameClock = null; submittedFrames = 0; presentedFrames = 0;
            droppedFrames = 0; lastPresentationMicros = 0;
            maxPresentationMicros = 0;
            pacingMilliseconds = 0; lastCompleted = 0;
            hasCompleted = false;
            buffers = new DisplayBuffer[3];
            nextBufferHandle = 1; nextFence = 1;
            cursorX = 0; cursorY = 0;
        }
        private DisplayBufferLayout MakeLayout() {
            if (backend == null || backend.Width() < 1 ||
                backend.Width() > 2147483647 / 4) { return null; }
            return new DisplayBufferLayout(backend.Width(), backend.Height(),
                backend.Width() * 4, DisplayBufferLayout.Rgbx8888());
        }
        public void AttachInputMux(ConsoleInputMux mux) { inputMux = mux; }
        public void AttachFrameClock(IFrameClock clock) { frameClock = clock; }
        public int BackendKind() {
            if (backend == null) { return 0; }
            return backend.Kind();
        }
        public int Width() {
            if (backend == null) { return 0; }
            return backend.Width();
        }
        public int Height() {
            if (backend == null) { return 0; }
            return backend.Height();
        }
        public int StrideBytes() {
            if (backend == null) { return 0; }
            return backend.StrideBytes();
        }
        public int ScanoutFormat() {
            if (backend == null) { return 0; }
            return backend.ScanoutFormat();
        }
        public int Capabilities() {
            if (backend == null) { return 0; }
            return backend.Capabilities();
        }
        public bool HardwareCursor() {
            return backend != null && backend.HardwareCursor();
        }
        public bool MoveCursorDelta(int dx, int dy) {
            if (owner == 0 || backend == null || !backend.HardwareCursor()) {
                return false;
            }
            int x = cursorX + dx; int y = cursorY + dy;
            if (x < 0) { x = 0; }
            if (y < 0) { y = 0; }
            if (x > Width() - 14) { x = Width() - 14; }
            if (y > Height() - 20) { y = Height() - 20; }
            if (backend.MoveCursor(x, y)) {
                cursorX = x; cursorY = y; return true;
            }
            return false;
        }
        public DisplayBufferLayout BufferLayout() { return frameLayout; }
        private DisplayBuffer FindBuffer(int processId, int handle) {
            if (processId < 1 || owner != processId || handle < 1) {
                return null;
            }
            int i = 0;
            while (i < buffers.Length) {
                DisplayBuffer candidate = buffers[i];
                if (candidate != null && candidate.Handle() == handle &&
                    candidate.Owner() == processId) { return candidate; }
                i = i + 1;
            }
            return null;
        }
        private void DestroyBuffers() {
            int i = 0;
            while (i < buffers.Length) {
                if (buffers[i] != null) {
                    buffers[i].Destroy();
                }
                i = i + 1;
            }
        }
        // Only a claimed, display-capable process can request a buffer. The
        // present path currently accepts tightly packed full-screen RGBX.
        public int AllocateBuffer(int processId, int width, int height,
            int strideBytes, int format) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!Ready() || frameLayout == null || !frameLayout.Ready()) {
                return -19;
            }
            if (width != frameLayout.Width() ||
                height != frameLayout.Height() ||
                strideBytes != frameLayout.StrideBytes() ||
                format != DisplayBufferLayout.Rgbx8888()) { return -22; }
            if (nextBufferHandle == 2147483647) { return -75; }
            int slot = 0;
            while (slot < buffers.Length && buffers[slot] != null &&
                buffers[slot].Handle() != 0) {
                slot = slot + 1;
            }
            if (slot == buffers.Length) { return -12; }
            DisplayBuffer allocated = buffers[slot];
            if (allocated == null) {
                DisplayBufferLayout layout = new DisplayBufferLayout(width,
                    height, strideBytes, format);
                if (!layout.Ready()) { return -22; }
                allocated = new DisplayBuffer(nextBufferHandle,
                    processId, layout);
                if (!allocated.Ready()) { return -12; }
                buffers[slot] = allocated;
            } else {
                if (allocated.Width() != width ||
                    allocated.Height() != height) { return -95; }
                allocated.Activate(nextBufferHandle, processId);
            }
            nextBufferHandle = nextBufferHandle + 1;
            return allocated.Handle();
        }
        public int DestroyBuffer(int processId, int handle) {
            DisplayBuffer buffer = FindBuffer(processId, handle);
            if (buffer == null) { return -13; }
            if (buffer.State() != 0) { return -16; }
            int i = 0;
            while (i < buffers.Length) {
                if (buffers[i] == buffer) {
                    buffer.Destroy();
                    return 0;
                }
                i = i + 1;
            }
            return -2;
        }
        public int BeginBuffer(int processId, int handle) {
            DisplayBuffer buffer = FindBuffer(processId, handle);
            if (buffer == null) { return -13; }
            if (!Ready()) { return -19; }
            long now = 0;
            if (frameClock != null) { now = frameClock.Now(); }
            if (!buffer.Begin(now)) { return -16; }
            submittedFrames = submittedFrames + 1;
            return 0;
        }
        public int FillBufferRect(int processId, int handle, int x, int y,
            int width, int height, int rgb) {
            DisplayBuffer buffer = FindBuffer(processId, handle);
            if (buffer == null) { return -13; }
            if (!buffer.FillRect(x, y, width, height, rgb)) { return -22; }
            return 0;
        }
        // A positive fence identifies the exact successful submission.
        // GOP and the current polling native backend complete synchronously.
        // An asynchronous backend may later report a pending fence.
        public int SubmitBuffer(int processId, int handle) {
            DisplayBuffer buffer = FindBuffer(processId, handle);
            if (buffer == null) { return -13; }
            if (buffer.State() != 1) { return -22; }
            if (!PacingReady()) { return -11; }
            if (nextFence == 2147483647) { return -75; }
            if (!Ready() || !backend.PresentDamage(buffer.Surface(),
                buffer.Damage())) { return -5; }
            int fence = nextFence; nextFence = nextFence + 1;
            buffer.Submitted(fence);
            presentedFrames = presentedFrames + 1;
            RecordCompletion(buffer.Started());
            return fence;
        }
        public int BufferCompletion(int processId, int handle, int fence) {
            DisplayBuffer buffer = FindBuffer(processId, handle);
            if (buffer == null) { return -13; }
            if (fence < 1 || buffer.State() != 2 ||
                buffer.Fence() != fence) { return -22; }
            return 1;
        }
        public int ReleaseBuffer(int processId, int handle, int fence) {
            DisplayBuffer buffer = FindBuffer(processId, handle);
            if (buffer == null) { return -13; }
            if (!buffer.Release(fence)) { return -22; }
            return 0;
        }
        public void ShutdownBackend() {
            if (owner != 0) { Release(owner); }
            if (backend != null) { backend.Shutdown(); }
        }
        public bool RecoverBackend() {
            if (owner != 0 || backend == null) { return false; }
            if (!backend.Recover() || !backend.Ready()) { return false; }
            frameLayout = MakeLayout();
            if (frameLayout == null || !frameLayout.Ready() ||
                (frame != null &&
                (frame.Width() != frameLayout.Width() ||
                frame.Height() != frameLayout.Height()))) {
                backend.Shutdown(); return false;
            }
            int i = 0;
            while (i < buffers.Length) {
                if (buffers[i] != null &&
                    (buffers[i].Width() != frameLayout.Width() ||
                    buffers[i].Height() != frameLayout.Height())) {
                    backend.Shutdown(); return false;
                }
                i = i + 1;
            }
            return true;
        }
        public bool SetFramePacing(int milliseconds) {
            if (milliseconds < 0 || milliseconds > 1000) { return false; }
            pacingMilliseconds = milliseconds; return true;
        }
        public int SubmittedFrames() { return submittedFrames; }
        public int PresentedFrames() { return presentedFrames; }
        public int DroppedFrames() { return droppedFrames; }
        public int LastPresentationMicros() { return lastPresentationMicros; }
        public int MaxPresentationMicros() { return maxPresentationMicros; }
        private void WriteStat(byte[] destination, int offset, int value) {
            destination[offset] = (byte)(value % 256);
            destination[offset + 1] = (byte)(value / 256 % 256);
            destination[offset + 2] = (byte)(value / 65536 % 256);
            destination[offset + 3] = (byte)(value / 16777216 % 256);
        }
        public int Stats(int processId, byte[] destination) {
            if (processId < 1 || owner != processId) { return -13; }
            if (destination == null || destination.Length != 20) { return -4; }
            WriteStat(destination, 0, submittedFrames);
            WriteStat(destination, 4, presentedFrames);
            WriteStat(destination, 8, droppedFrames);
            WriteStat(destination, 12, lastPresentationMicros);
            WriteStat(destination, 16, maxPresentationMicros);
            return 20;
        }
        public bool KeyboardCaptured() { return keyboardCaptured; }
        public int CaptureKeyboard(int processId, bool capture) {
            if (processId < 1 || owner != processId) { return -13; }
            keyboardCaptured = capture;
            if (inputMux != null) { inputMux.SetSecondEnabled(!capture); }
            return 0;
        }
        public bool Ready() { return backend != null && backend.Ready(); }
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
            frameOpen = false;
            if (frameDamage != null) { frameDamage.Clear(); }
            if (frame != null) { frame.Fill(0); }
            submittedFrames = 0; presentedFrames = 0; droppedFrames = 0;
            lastPresentationMicros = 0; maxPresentationMicros = 0;
            lastCompleted = 0; hasCompleted = false;
            if (console != null) { console.SetMirrorEnabled(false); }
            cursorX = Width() / 2; cursorY = Height() / 2;
            if (backend.HardwareCursor()) {
                backend.MoveCursor(cursorX, cursorY);
            }
            return 0;
        }
        public int Release(int processId) {
            if (processId < 1 || owner != processId) { return -13; }
            DestroyBuffers();
            if (backend != null) { backend.HideCursor(); }
            owner = 0;
            frameOpen = false;
            if (frameDamage != null) { frameDamage.Clear(); }
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
        private void ResetModeState() {
            DestroyBuffers();
            int i = 0;
            while (i < buffers.Length) {
                if (buffers[i] != null) {
                    buffers[i].Reconfigure(Width(), Height());
                }
                i = i + 1;
            }
            if (frame != null) { frame.Reshape(Width(), Height()); }
            if (frameDamage != null) {
                frameDamage.Resize(Width(), Height());
            }
            frameOpen = false;
            frameLayout.Resize(Width(), Height(), Width() * 4);
            hasCompleted = false; lastCompleted = 0;
            cursorX = Width() / 2; cursorY = Height() / 2;
            if (backend.HardwareCursor()) {
                backend.MoveCursor(cursorX, cursorY);
            }
        }
        public int SetMode(int processId, int width, int height) {
            if (processId < 1 || owner != processId) { return -13; }
            if (width == 0 && height == 0 && backend != null &&
                backend.Kind() == 2) {
                if (backend.PollModeChange()) { ResetModeState(); }
                int packed = Width() + Height() * 65536;
                if (backend.HardwareCursor()) {
                    packed = packed + 268435456;
                }
                return packed;
            }
            if (width < 1 || height < 1 || width > 2048 ||
                height > 2048 || (long)width * height > 1048576) {
                return -22;
            }
            if (backend == null || backend.Kind() != 2) { return -95; }
            if (width == Width() && height == Height()) { return 0; }
            if (!backend.Reconfigure(width, height)) { return -5; }
            ResetModeState(); return 0;
        }
        public int BeginFrame(int processId) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!Ready() || frameLayout == null || !frameLayout.Ready() ||
                backend.Width() != frameLayout.Width() ||
                backend.Height() != frameLayout.Height()) {
                return -95;
            }
            if (!frameOpen && !PacingReady()) { return -11; }
            if (frame == null) {
                frame = new PixelSurface(backend.Width(), backend.Height(),
                    true);
                frameDamage = new DamageTracker(backend.Width(), backend.Height());
                if (!frame.Ready()) { return -12; }
            }
            if (frameOpen) { droppedFrames = droppedFrames + 1; }
            submittedFrames = submittedFrames + 1;
            frameOpen = true;
            if (frameClock != null) { frameStarted = frameClock.Now(); }
            return 0;
        }
        public int PresentFrame(int processId) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!frameOpen || frame == null || frameDamage == null) {
                return -22;
            }
            if (!Ready() || !backend.PresentDamage(frame, frameDamage)) {
                return -5;
            }
            frameOpen = false; presentedFrames = presentedFrames + 1;
            RecordCompletion(frameStarted);
            return 0;
        }
        private bool PacingReady() {
            if (!hasCompleted || frameClock == null ||
                pacingMilliseconds <= 0) { return true; }
            long now = frameClock.Now();
            long scale = frameClock.TicksPerMillisecond();
            return scale <= 0 || scale > 2147483647 ||
                now < lastCompleted ||
                now - lastCompleted >= scale * pacingMilliseconds;
        }
        private void RecordCompletion(long started) {
            if (frameClock != null) {
                long finished = frameClock.Now();
                lastCompleted = finished; hasCompleted = true;
                long elapsed = finished - started;
                long scale = frameClock.TicksPerMillisecond();
                if (elapsed >= 0 && scale > 0) {
                    long micros = elapsed / scale * 1000 +
                        elapsed % scale * 1000 / scale;
                    if (micros > 2147483647) { micros = 2147483647; }
                    lastPresentationMicros = (int)micros;
                    if (lastPresentationMicros > maxPresentationMicros) {
                        maxPresentationMicros = lastPresentationMicros;
                    }
                }
            }
        }
        public int FillRect(int processId, int x, int y, int width,
            int height, int rgb) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!Ready() || x < 0 || y < 0 || width < 1 || height < 1 ||
                rgb < 0 || rgb > 16777215 ||
                (long)x + width > backend.Width() ||
                (long)y + height > backend.Height() ||
                (long)width * height > 65536) { return -22; }
            if (frame != null && !frame.FillRect(x, y, width, height, rgb)) {
                return -5;
            }
            if (frameOpen) {
                if (!frameDamage.Add(x, y, width, height)) { return -5; }
                return 0;
            }
            if (!backend.FillImmediate(x, y, width, height, rgb)) { return -5; }
            return 0;
        }
    }
}
