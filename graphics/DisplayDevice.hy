using Australis.Kernel.Console;

namespace Australis.Kernel.Graphics {
    public interface IFrameClock {
        long Now();
        long TicksPerMillisecond();
    }

    // The sole hardware-facing display lease. The process host authenticates
    // and authorizes the PID before Claim; callers never receive GOP addresses.
    public class DisplayDevice {
        private IGpuWindowComposer gpuComposer;
        private IDisplayBackend backend;
        private DisplayBufferLayout frameLayout;
        private ConsoleWriter console;
        private ConsoleInputMux inputMux;
        private int owner;
        private bool keyboardCaptured;
        private PixelSurface frame;
        private DamageTracker frameDamage;
        private bool frameOpen;
        private bool gpuFrameComplete;
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
		private WindowLayout retainedLayout;
		private WindowRenderer retainedRenderer;

        public DisplayDevice(FramebufferMode inputMode, IFramebufferPixelWriter inputWriter, ConsoleWriter inputConsole) {
            backend = new GopDisplayBackend(inputMode, inputWriter);
            backend.Initialize();
			console = inputConsole;
            frameLayout = MakeLayout();
            owner = 0;
			inputMux = null;
			keyboardCaptured = false;
            frame = null;
			frameDamage = null;
			frameOpen = false;
            frameClock = null;
			submittedFrames = 0;
			presentedFrames = 0;
            droppedFrames = 0;
			lastPresentationMicros = 0;
            maxPresentationMicros = 0;
            pacingMilliseconds = 0;
			lastCompleted = 0;
            hasCompleted = false;
            buffers = new DisplayBuffer[3];
            nextBufferHandle = 1;
			nextFence = 1;
            cursorX = 0;
			cursorY = 0;
			retainedLayout = null;
			retainedRenderer = null;
        }

        public DisplayDevice(IDisplayBackend inputBackend,
            ConsoleWriter inputConsole) {
            backend = inputBackend;
            if (backend != null) { backend.Initialize(); }
            console = inputConsole;
            frameLayout = MakeLayout();
            owner = 0;
			inputMux = null;
			keyboardCaptured = false;
            frame = null;
			frameDamage = null;
			frameOpen = false;
            frameClock = null;
			submittedFrames = 0;
			presentedFrames = 0;
            droppedFrames = 0;
			lastPresentationMicros = 0;
            maxPresentationMicros = 0;
            pacingMilliseconds = 0;
			lastCompleted = 0;
            hasCompleted = false;
            buffers = new DisplayBuffer[3];
            nextBufferHandle = 1;
			nextFence = 1;
            cursorX = 0;
			cursorY = 0;
			retainedLayout = null;
			retainedRenderer = null;
        }

        private DisplayBufferLayout MakeLayout() {
            if (backend == null || backend.Width() < 1 ||
                backend.Width() > 2147483647 / 4) { return null; }
            return new DisplayBufferLayout(backend.Width(), backend.Height(),
                backend.Width() * 4, DisplayBufferLayout.Rgbx8888());
        }

        public void AttachInputMux(ConsoleInputMux mux) {
			inputMux = mux;
		}

        public void AttachFrameClock(IFrameClock clock) {
			frameClock = clock;
		}

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

        public DisplayBufferLayout BufferLayout() {
			return frameLayout;
		}

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

        public void AttachGpuComposer(IGpuWindowComposer composer) {

            gpuComposer = composer;
        }

        public int BeginGpuWindowFrame(
            int processId, int backgroundRgb) {

            if (processId < 1 || owner != processId) {
                return -13;
            }

            if (backgroundRgb < 0 ||
                backgroundRgb > 16777215) {
                return -22;
            }

            if (BackendKind() != 2 ||
                gpuComposer == null ||
                !gpuComposer.GpuWindowComposerReady()) {
                return -95;
            }

            if (gpuComposer.GpuCompositionOpen()) {
                return -16;
            }
            gpuFrameComplete = false;
            if (gpuComposer.BeginGpuComposition(backgroundRgb)) {
                return 0;
            }
            return -5;
        }

        public int DrawGpuWindowFrame(
            int processId, int handle, int x, int y) {

            if (processId < 1 || owner != processId) {
                return -13;
            }

            if (BackendKind() != 2 ||
                gpuComposer == null ||
                !gpuComposer.GpuWindowComposerReady()) {
                return -95;
            }

            if (!gpuComposer.GpuCompositionOpen()) {
                return -22;
            }

            // The GPU handle must belong to the caller.
            int width =
                gpuComposer.ClientWidth(processId, handle);

            int height =
                gpuComposer.ClientHeight(processId, handle);

            if (width < 1 || height < 1) {
                return -13;
            }

            if (x < 0 || y < 0 ||
                (long)x + width > Width() ||
                (long)y + height > Height()) {
                return -22;
            }

            if (gpuComposer.DrawGpuWindow(
                processId, handle, x, y)) {
                return 0;
            }
            return -5;
        }

        public int EndGpuWindowFrame(int processId) {

            if (processId < 1 || owner != processId) {
                return -13;
            }

            if (gpuComposer == null ||
                BackendKind() != 2) {
                return -95;
            }

            if (!gpuComposer.GpuCompositionOpen()) {
                return -22;
            }

            if (gpuComposer.EndGpuComposition()) {
                gpuFrameComplete = true;
                return 0;
            }
            return -5;
        }

        public int FillGpuWindowFrameRect(
            int processId,
            int x, int y,
            int width, int height,
            int rgb) {

            if (processId < 1 || owner != processId) {
                return -13;
            }

            if (x < 0 || y < 0 ||
                width < 1 || height < 1 ||
                rgb < 0 || rgb > 16777215 ||
                width > Width() ||
                height > Height() ||
                x > Width() - width ||
                y > Height() - height) {
                return -22;
            }

            if (BackendKind() != 2 ||
                gpuComposer == null ||
                !gpuComposer.GpuWindowComposerReady()) {
                return -19;
            }

            if (!gpuComposer.GpuCompositionOpen()) {
                return -22;
            }

            if (!gpuComposer.DrawGpuSolidRect(
                x, y, width, height, rgb)) {
                return -5;
            }

            return 0;
        }

        public int ReadGpuWindowFramePixel(
            int processId, int x, int y) {

            if (processId < 1 || owner != processId) {
                return -13;
            }

            if (x < 0 || y < 0 ||
                x >= Width() || y >= Height()) {
                return -22;
            }

            if (BackendKind() != 2 ||
                gpuComposer == null ||
                !gpuComposer.GpuWindowComposerReady()) {
                return -19;
            }

            // Only completed frames may be inspected.
            if (!gpuFrameComplete ||
                gpuComposer.GpuCompositionOpen()) {
                return -22;
            }

            return gpuComposer.ReadGpuCompositionPixel(x, y);
        }

		public int RetainedEnable(int processId, int barHeight) {
			if (processId < 1 || owner != processId) {
				return -13;
			}

			if (!Ready()) {
				return -19;
			}

			if (frameOpen || retainedRenderer != null) {
				return -16;
			}

			WindowLayout nextLayout = new WindowLayout(
				Width(), Height(), barHeight);

			if (!nextLayout.Ready()) {
				return -22;
			}

			WindowRenderer nextRenderer =
				new WindowRenderer(nextLayout);

			if (!nextRenderer.Ready()) {
				return -12;
			}

			retainedLayout = nextLayout;
			retainedRenderer = nextRenderer;

			return 0;
		}

		private bool RetainedOwned(int processId, int windowId) {
			if (retainedLayout == null || windowId < 1) {
				return false;
			}

			int i = 0;

			while (i < retainedLayout.Count()) {
				DesktopWindow window = retainedLayout.WindowAt(i);

				if (window != null && window.Id() == windowId) {
					return window.Owner() == processId;
				}

				i = i + 1;
			}

			return false;
		}

		public int RetainedOpen(int processId, int x, int y, int width, int height) {

			if (processId < 1 || owner != processId) {
				return -13;
			}

			if (retainedLayout == null) {
				return -19;
			}

			return retainedLayout.Open(
				processId, x, y, width, height);
		}

		public int RetainedFocus(int processId, int windowId) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Focus(windowId)) {
				return -22;
			}

			return 0;
		}

		public int RetainedMove(int processId, int windowId, int x, int y) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Move(
				processId, windowId, x, y)) {
				return -22;
			}

			return 0;
		}

		public int RetainedClose(int processId, int windowId) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Close(processId, windowId)) {
				return -22;
			}

			if (retainedRenderer != null) {
				retainedRenderer.Remove(processId, windowId);
			}

			return 0;
		}

		public int RetainedMinimize(int processId, int windowId) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Minimize(processId, windowId)) {
				return -22;
			}

			return 0;
		}

		public int RetainedRestore(int processId, int windowId) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.RestoreMinimized(
				processId, windowId)) {
				return -22;
			}

			return 0;
		}

		public int RetainedMaximize(int processId, int windowId) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Maximize(processId, windowId)) {
				return -22;
			}

			return 0;
		}

		public int RetainedUnmaximize(int processId, int windowId) {
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Unmaximize(processId, windowId)) {
				return -22;
			}

			return 0;
		}

		public int RetainedResize(
			int processId, int windowId, int width, int height) {

			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (!retainedLayout.Resize(
				processId, windowId, width, height)) {
				return -22;
			}

			return 0;
		}

		// Kernel-internal operation for trusted pixel submissions.
		// Userland will later use a validated byte-buffer API.
		public int RetainedSubmit(int processId, int windowId,
			PixelSurface content) {

			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (retainedRenderer == null ||
				content == null || !content.Ready()) {
				return -22;
			}

			if (!retainedRenderer.Submit(
				processId, windowId, content)) {
				return -22;
			}

			return 0;
		}

		// Expand a compact 4x4 RGB888 cell grid into a persistent
        // retained CPU image. This is a first demo-content protocol; the
        // retained compositor's lower-level PixelSurface API stays generic.
        public int RetainedSubmitCells(
            int processId, int windowId, byte[] cells) {
            if (processId < 1 || owner != processId ||
                !RetainedOwned(processId, windowId)) { return -13; }
            if (!Ready() || retainedLayout == null ||
                retainedRenderer == null) { return -19; }
            if (cells == null || cells.Length != 48) { return -22; }

            DesktopWindow window = null;
            int i = 0;
            while (i < retainedLayout.Count()) {
                DesktopWindow candidate = retainedLayout.WindowAt(i);
                if (candidate != null && candidate.Id() == windowId) {
                    window = candidate; break;
                }
                i = i + 1;
            }
            if (window == null) { return -22; }
            int width = window.Width();
            int titleHeight = 30;
            if (window.Maximized()) { titleHeight = 0; }
            int height = window.Height() - titleHeight;
            if (width < 1 || height < 1 ||
                (long)width * height > 1048576) { return -22; }

            PixelSurface surface = new PixelSurface(width, height);
            if (!surface.Ready()) { return -12; }
            int row = 0;
            while (row < 4) {
                int column = 0;
                while (column < 4) {
                    int left = column * width / 4;
                    int right = (column + 1) * width / 4;
                    int top = row * height / 4;
                    int bottom = (row + 1) * height / 4;
                    int at = (row * 4 + column) * 3;
                    int rgb = (int)cells[at] * 65536 +
                        (int)cells[at + 1] * 256 + (int)cells[at + 2];
                    if (right > left && bottom > top &&
                        !surface.FillRect(left, top,
                            right - left, bottom - top, rgb)) {
                        return -5;
                    }
                    column = column + 1;
                }
                row = row + 1;
            }
            return RetainedSubmit(processId, windowId, surface);
        }

        public int RetainedSubmitGpu(
			int processId, int windowId, int gpuHandle,
			IGpuClientBlitter gpu) {

			// Only the display owner may submit content.
			if (processId < 1 || owner != processId ||
				!RetainedOwned(processId, windowId)) {
				return -13;
			}

			if (retainedRenderer == null ||
				gpu == null || !Ready()) {
				return -19;
			}

			// Look up the GPU surface using process-scoped ownership.
			int width = gpu.ClientWidth(processId, gpuHandle);
			int height = gpu.ClientHeight(processId, gpuHandle);

			if (width < 1 || height < 1) {
				return -13;
			}

			// Validate size before allocating a pixel snapshot.
			DesktopWindow window = null;
			int i = 0;

			while (i < retainedLayout.Count()) {
				DesktopWindow candidate =
					retainedLayout.WindowAt(i);

				if (candidate != null &&
					candidate.Id() == windowId) {
					window = candidate;
					break;
				}

				i = i + 1;
			}

			if (window == null ||
				width > window.Width() ||
				height > window.Height()) {
				return -22;
			}

			// Copy the validated GPU shadow into kernel-owned storage.
			PixelSurface snapshot =
				new PixelSurface(width, height);

			if (!snapshot.Ready()) {
				return -12;
			}

			if (!gpu.ClientBlit(
				processId, gpuHandle, snapshot, 0, 0)) {
				return -5;
			}

			// The retained renderer makes its own persistent copy.
			return RetainedSubmit(
				processId, windowId, snapshot);
		}

		public int RetainedHover(int processId, int x, int y) {
			if (processId < 1 || owner != processId) {
				return -13;
			}

			if (retainedRenderer == null) {
				return -19;
			}

			if (!((x == -1 && y == -1) ||
				(x >= 0 && y >= 0 &&
				x < Width() && y < Height()))) {
				return -22;
			}

			retainedRenderer.Hover(x, y);
			return 0;
		}

		public int RetainedCompose(int processId,
			DamageTracker damage) {

			if (processId < 1 || owner != processId) {
				return -13;
			}

			if (retainedRenderer == null) {
				return -19;
			}

			// Reuse the bridge we implemented and tested earlier.
			return ComposeRetainedDamage(
				processId, retainedRenderer, damage);
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

        public int SubmittedFrames() {
			return submittedFrames;
		}

        public int PresentedFrames() {
			return presentedFrames;
		}

        public int DroppedFrames() {
			return droppedFrames;
		}

        public int LastPresentationMicros() {
			return lastPresentationMicros;
		}

        public int MaxPresentationMicros() {
			return maxPresentationMicros;
		}

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

        public bool KeyboardCaptured() {
			return keyboardCaptured;
		}

        public int CaptureKeyboard(int processId, bool capture) {
            if (processId < 1 || owner != processId) { return -13; }
            keyboardCaptured = capture;
            if (inputMux != null) { inputMux.SetSecondEnabled(!capture); }
            return 0;
        }

        public bool Ready() {
			return backend != null && backend.Ready();
		}

        public int Owner() {
			return owner;
		}

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
            if (gpuComposer != null) {
                gpuComposer.AbortGpuComposition();
            }
            DestroyBuffers();
			retainedRenderer = null;
			retainedLayout = null;
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
			retainedRenderer = null;
			retainedLayout = null;
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

		public int ComposeRetainedDamage(
			int processId,
			WindowRenderer renderer,
			DamageTracker damage) {

			// Only the current display owner may compose frames.
			if (processId < 1 || owner != processId) {
				return -13;
			}

			if (!frameOpen || frame == null ||
				frameDamage == null || !Ready()) {
				return -19;
			}

			if (renderer == null || damage == null ||
				damage.Width() != Width() ||
				damage.Height() != Height()) {
				return -22;
			}

			// Validate all rectangles before modifying the framebuffer.
			int i = 0;

			while (i < damage.Count()) {
				DamageRect rect = damage.At(i);

				if (rect == null ||
					rect.X() < 0 || rect.Y() < 0 ||
					rect.Width() < 1 || rect.Height() < 1 ||
					(long)rect.X() + rect.Width() > Width() ||
					(long)rect.Y() + rect.Height() > Height()) {
					return -22;
				}

				i = i + 1;
			}

			// Compose directly into the active backbuffer. The previous
			// intermediate surface copy repeated work for every dirty pixel.
			if (!renderer.ComposeDamageInto(frame, damage)) {
				return -5;
			}

			// Present only the changed pixels.
			i = 0;

			while (i < damage.Count()) {
				DamageRect rect = damage.At(i);

				if (!frameDamage.Add(
					rect.X(), rect.Y(),
					rect.Width(), rect.Height())) {
					return -5;
				}

				i = i + 1;
			}

			return 0;
		}

        // Only the display lease owner may place its own validated GPU
        // texture into the active software frame. The ordinary damage path
        // then presents the same pixels through native scanout or GOP.
        public int ComposeGpuSurface(int processId, int handle, int x,
            int y, IGpuClientBlitter gpu) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!frameOpen || frame == null || frameDamage == null ||
                gpu == null || !Ready()) { return -19; }
            int width = gpu.ClientWidth(processId, handle);
            int height = gpu.ClientHeight(processId, handle);
            if (width < 1 || height < 1) { return -13; }
            if (x < 0 || y < 0 || (long)x + width > Width() ||
                (long)y + height > Height()) { return -22; }
            if (!gpu.ClientBlit(processId, handle, frame, x, y) ||
                !frameDamage.Add(x, y, width, height)) { return -5; }
            return 0;
        }

        public int ComposeGpuRegion(int processId, int handle,
            int sourceX, int sourceY, int width, int height,
            int targetX, int targetY, IGpuClientBlitter gpu) {
            if (processId < 1 || owner != processId) { return -13; }
            if (!frameOpen || frame == null || frameDamage == null ||
                gpu == null || !Ready()) { return -19; }
            int surfaceWidth = gpu.ClientWidth(processId, handle);
            int surfaceHeight = gpu.ClientHeight(processId, handle);
            if (surfaceWidth < 1 || surfaceHeight < 1) { return -13; }
            if (sourceX < 0 || sourceY < 0 || width < 1 || height < 1 ||
                targetX < 0 || targetY < 0 ||
                (long)sourceX + width > surfaceWidth ||
                (long)sourceY + height > surfaceHeight ||
                (long)targetX + width > Width() ||
                (long)targetY + height > Height()) { return -22; }
            if (!gpu.ClientBlitRegion(processId, handle, frame,
                sourceX, sourceY, width, height, targetX, targetY) ||
                !frameDamage.Add(targetX, targetY, width, height)) {
                return -5;
            }
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
