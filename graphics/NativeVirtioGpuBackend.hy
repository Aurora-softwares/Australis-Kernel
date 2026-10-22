using Australis.Kernel.Dma;
using Australis.Kernel.Pci;

namespace Australis.Kernel.Graphics {
    // Persistent 2D scanout. All guest backing lives in the reserved DMA pool;
    // applications see only the owned RGB surfaces in DisplayDevice.
    public class NativeVirtioGpuBackend : IDisplayBackend, IGpuClientBlitter {
		private int CURSOR_WIDTH = 14; // const
		private int CURSOR_HEIGHT = 16; // const
		private int CURSOR_FILL_COLOUR = 0x101010; // 0x101010 const
		private int CURSOR_OUTLINE_COLOUR = 0xFFFFFF; // 0xFFFFFF const

        private long bootInfo;
        private IPciConfigAccess pci;
        private int bdf;
        private DmaAllocator allocator;
        private NativeVirtioGpuControl control;
        private VirtioGpu2D gpu;
        private VirtioGpu3D gpu3d;
        private VirglFrameComposer windowComposer;
        private IRenderSurface renderSurface;
        private VirtioGpuDisplayMode mode;
        private DmaAllocation backing;
        private DmaAllocation renderBacking;
        private DmaAllocation composerVertexBacking;
        private bool composerPrepared;
        private bool started;
        private bool cursorReady;
        private bool cursorVisible;
        private int cursorX;
        private int cursorY;
        private int[] cursorSaved;
        private int accelerationRecoveryAttempts;
        private int[] clientOwners;
        private int[] clientHandles;
        private VirtioGpu3D[] clientContexts;
        private IRenderSurface[] clientSurfaces;
        private DmaAllocation[] clientBackings;
        private PixelSurface[] clientPixels;
        private int nextClientHandle;
        private int lastError;
        private int ownedWindowProbeStage;
        private int ownedWindowProbePixel;

        public int OwnedWindowProbeStage() {
            return ownedWindowProbeStage;
        }

        public int OwnedWindowProbePixel() {
            return ownedWindowProbePixel;
        }

        public NativeVirtioGpuBackend(long inputBootInfo, IPciConfigAccess inputPci, int inputBdf, DmaAllocator inputAllocator) {
            bootInfo = inputBootInfo;
			pci = inputPci;
			bdf = inputBdf;
            allocator = inputAllocator;
			control = null;
			gpu = null;
            gpu3d = null;
            renderSurface = null;
			renderBacking = null;
            composerVertexBacking = null;
            composerPrepared = false;
            mode = null;
			backing = null;
            started = false;
			cursorReady = false;
			cursorVisible = false;
            cursorX = 0;
			cursorY = 0;
			cursorSaved = new int[280];
            accelerationRecoveryAttempts = 0;
            clientOwners = new int[4]; clientHandles = new int[4];
            clientContexts = new VirtioGpu3D[4];
            clientSurfaces = new IRenderSurface[4];
            clientBackings = new DmaAllocation[4];
            clientPixels = new PixelSurface[4];
            nextClientHandle = 1;
            lastError = 0;
        }
        public int LastError() {
			return lastError;
		}
        public int Kind() {
			return 2;
		}
        public int Width() {
			if (mode == null) {
				return 0;
			}
            return mode.Width();
		}
        public int Height() {
			if (mode == null) {
				return 0;
			}
            return mode.Height();
		}
        public int StrideBytes() {
			return Width() * 4;
		}
        public int ScanoutFormat() {
			return 1;
		}
        public int Capabilities() {
			if (cursorReady) {
				return 15;
			}
            return 7;
		}
        // The display contract uses this flag for a backend-managed cursor.
        // Draw it into scanout so QEMU input grabs cannot hide its overlay.
        public bool HardwareCursor() {
			return Ready() && cursorReady;
		}
        public bool AccelerationAvailable() {
            return Ready() && renderSurface != null && renderSurface.Ready();
        }

        public bool GpuWindowComposerReady() {
            return composerPrepared &&
                AccelerationAvailable() &&
                composerVertexBacking != null &&
                composerVertexBacking.Owned() &&
                gpu3d != null &&
                windowComposer != null &&
                windowComposer.Ready() &&
                gpu3d.PersistentVertexBufferReady();
        }

        public bool BeginGpuComposition(int backgroundRgb) {
            return GpuWindowComposerReady() &&
                windowComposer.BeginFrame(backgroundRgb);
        }

        public bool DrawGpuWindow(
            int processId,
            int handle,
            int x, int y) {

            if (!GpuWindowComposerReady() ||
                !windowComposer.FrameOpen()) {
                return false;
            }

            // Validate ownership using the existing
            // process-scoped handle lookup.
            int slot = ClientSlot(processId, handle);

            if (slot < 0) {
                return false;
            }

            PixelSurface pixels = clientPixels[slot];

            if (pixels == null ||
                !pixels.Ready() ||
                ClientReady(slot) == null) {
                return false;
            }

            int width = pixels.Width();
            int height = pixels.Height();

            // Validate the destination against the
            // current display geometry.
            if (x < 0 || y < 0 ||
                (long)x + width > Width() ||
                (long)y + height > Height()) {
                return false;
            }

            return windowComposer.DrawSourceTexture(
                clientContexts[slot],
                x, y, width, height);
        }

        public bool EndGpuComposition() {
            return GpuWindowComposerReady() &&
                windowComposer.EndFrame();
        }

        private bool PrepareWindowComposer() {
            if (!AccelerationAvailable() ||
                composerVertexBacking != null ||
                allocator == null) {
                return false;
            }

            // One persistent DMA page for six UV vertices.
            // The backend owns this page for the GPU
            // context's entire lifetime.
            composerVertexBacking = allocator.Allocate(1);

            if (composerVertexBacking == null ||
                !composerVertexBacking.Owned()) {
                return false;
            }

            composerPrepared =
                gpu3d.ProbeBlendState() &&
                gpu3d.ConfigureUvRenderStates() &&
                gpu3d.ProbeUvShaderState() &&
                gpu3d.ProbeUvVertexElements() &&
                gpu3d.ProbeCreateSamplerState() &&
                gpu3d.CreatePersistentVertexBuffer(
                    composerVertexBacking.Address());

            if (composerPrepared) {
                windowComposer = new VirglFrameComposer(gpu3d);
            }

            return GpuWindowComposerReady();
        }
        public bool RenderTargetMatchesDisplay() {
            if (!AccelerationAvailable() ||
                renderBacking == null ||
                !renderBacking.Owned()) {
                return false;
            }

            long requiredBytes =
                (long)Width() * Height() * 4;

            return renderSurface.Width() == Width() &&
                renderSurface.Height() == Height() &&
                (long)renderBacking.PageCount() * 4096 >=
                    requiredBytes;
        }

        public bool ProbeGpuScanoutRoundTrip() {
            if (!Ready() || !RenderTargetMatchesDisplay() || gpu3d == null || gpu == null || mode == null || renderBacking == null || !renderBacking.Owned()) {
                return false;
            }

            int scanoutId = mode.Scanout();

            // Preserve the existing cursor state.
            bool hadCursor = cursorVisible;
            int savedCursorX = cursorX;
            int savedCursorY = cursorY;

            if (hadCursor) {
                HideCursor();
            }

            // Render a known colour entirely through VirGL.
            bool rendered =
                renderSurface.Clear(0x224488);

            // Verify the GPU-generated pixels before presentation.
            bool pixelsCorrect = false;

            if (rendered) {
                int sampleX = Width() / 2;
                int sampleY = Height() / 2;

                if (gpu3d.DownloadTextureRegion(
                    sampleX, sampleY, 1, 1)) {

                    System.Kernel.Memory.Fence();

                    long address = renderBacking.Address() +
                        ((long)sampleY * Width() + sampleX) * 4;

                    long pixel =
                        System.Kernel.Memory.Read32(address);

                    int red = (int)(pixel / 65536 % 256);
                    int green = (int)(pixel / 256 % 256);
                    int blue = (int)(pixel % 256);

                    pixelsCorrect =
                        red >= 26 && red <= 42 &&
                        green >= 60 && green <= 76 &&
                        blue >= 128 && blue <= 144;
                }
            }

            // Temporarily select the GPU-rendered texture
            // as the actual hardware scanout.
            bool selected = false;
            bool flushed = false;

            if (pixelsCorrect) {
                selected =
                    gpu3d.ScanoutTexture(scanoutId);

                if (selected) {
                    flushed = gpu3d.FlushTexture(
                        0, 0, Width(), Height());
                }
            }

            // ALWAYS restore the existing 2D scanout,
            // including after a failed GPU presentation.
            bool restored = gpu.Scanout(scanoutId);

            if (restored) {
                restored = gpu.Update(
                    0, 0, Width(), Height());
            }

            // Restore the cursor only after 2D returns.
            if (hadCursor && restored) {
                restored = MoveCursor(
                    savedCursorX, savedCursorY);
            }

            // If the original display cannot be restored,
            // try the existing device recovery mechanism.
            if (!restored) {
                Recover();
                return false;
            }

            return rendered &&
                pixelsCorrect &&
                selected &&
                flushed &&
                restored;
        }
        private int ClientSlot(int processId, int handle) {
            if (processId < 1 || handle < 1) { return -1; }
            int i = 0;
            while (i < clientHandles.Length) {
                if (clientOwners[i] == processId &&
                    clientHandles[i] == handle) { return i; }
                i = i + 1;
            }
            return -1;
        }
        // Ordinary clients retain one small texture. The active display
        // owner may hold three window-sized surfaces. All handles remain
        // process-scoped, and neither context IDs nor DMA addresses escape.
        public int ClientCreate(int processId, int width, int height,
            bool compositor) {
            long bytes = (long)width * height * 4;
            if (processId < 1 || width < 1 || height < 1 ||
                (compositor && (width > 2048 || height > 2048 ||
                    bytes > 4194304)) ||
                (!compositor && (width > 64 || height > 64))) {
                return -22;
            }
            if (!Ready() || control == null ||
                !control.VirglAvailable()) { return -19; }
            if (nextClientHandle == 2147483647) { return -75; }
            int i = 0; int free = -1; int owned = 0;
            while (i < clientOwners.Length) {
                if (clientOwners[i] == processId) { owned = owned + 1; }
                if (free < 0 && clientBackings[i] == null) { free = i; }
                i = i + 1;
            }
            if (free < 0 || (compositor && owned >= 3) ||
                (!compositor && owned >= 1)) { return -12; }
            int pages = (int)((bytes + 4095) / 4096);
            DmaAllocation allocation = allocator.Allocate(pages);
            if (allocation == null || !allocation.Owned()) { return -12; }
            i = 0;
            while (i < (long)pages * 1024) {
                System.Kernel.Memory.Write32(
                    allocation.Address() + (long)i * 4, 0);
                i = i + 1;
            }
            System.Kernel.Memory.Fence();
            VirtioGpu3D context = new VirtioGpu3D(control, true,
                control.CapsetCount(), free + 2, 65537 + free);
            clientBackings[free] = allocation;
            clientContexts[free] = context;
            if (!context.Probe() || !context.CreateContext()) {
                ClientDiscard(free); return -5;
            }
            IRenderSurface surface = new VirglRenderSurface(context,
                width, height, allocation.Address(), pages * 4096);
            clientSurfaces[free] = surface;
            if (!surface.Ready()) { ClientDiscard(free); return -5; }
            PixelSurface pixels = new PixelSurface(width, height);
            if (!pixels.Ready()) { ClientDiscard(free); return -12; }
            clientPixels[free] = pixels;
            clientOwners[free] = processId;
            clientHandles[free] = nextClientHandle;
            nextClientHandle = nextClientHandle + 1;
            return clientHandles[free];
        }
        private bool ClientDiscard(int slot) {
            VirtioGpu3D context = clientContexts[slot];
            bool clean = context == null;
            if (context != null && control != null && control.Ready()) {
                clean = context.DestroyContext();
            }
            clientOwners[slot] = 0; clientHandles[slot] = 0;
            clientSurfaces[slot] = null; clientPixels[slot] = null;
            if (clean) {
                if (clientBackings[slot] != null &&
                    clientBackings[slot].Owned()) {
                    allocator.Release(clientBackings[slot]);
                }
                clientBackings[slot] = null;
                clientContexts[slot] = null;
            }
            return clean;
        }
        public int ClientDestroy(int processId, int handle) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0) { return -13; }
            if (ClientDiscard(slot)) { return 0; }
            return -5;
        }
        public void ClientReleaseOnExit(int processId) {
            int i = 0;
            while (i < clientOwners.Length) {
                if (clientOwners[i] == processId) { ClientDiscard(i); }
                i = i + 1;
            }
        }
        private IRenderSurface ClientReady(int slot) {
            IRenderSurface surface = clientSurfaces[slot];
            if (surface == null || !Ready()) { return null; }
            if (!surface.Ready()) {
                if (!surface.Recover() ||
                    !surface.Upload(clientPixels[slot])) { return null; }
            }
            if (!surface.Ready()) { return null; }
            return surface;
        }
        public int ClientClear(int processId, int handle, int rgb) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0) { return -13; }
            if (rgb < 0 || rgb > 16777215) { return -22; }
            IRenderSurface surface = ClientReady(slot);
            if (surface == null || !surface.Clear(rgb)) { return -5; }
            clientPixels[slot].Fill(rgb);
            return 0;
        }
        public int ClientFillRect(int processId, int handle, int x, int y,
            int width, int height, int rgb) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0) { return -13; }
            PixelSurface pixels = clientPixels[slot];
            if (pixels == null || x < 0 || y < 0 || width < 1 || height < 1 || rgb < 0 || rgb > 16777215 || (long)x + width > pixels.Width() || (long)y + height > pixels.Height()) {
				return -22;
			}
            IRenderSurface surface = ClientReady(slot);
            if (surface == null) { return -5; }
            // Save only the changed rectangle so a failed transfer leaves
            // the authoritative CPU shadow at its previous value.
            int[] previous = new int[width * height];
            int row = 0;
            while (row < height) {
                int column = 0;
                while (column < width) {
                    previous[row * width + column] =
                        pixels.Pixel(x + column, y + row);
                    column = column + 1;
                }
                row = row + 1;
            }
            if (!pixels.FillRect(x, y, width, height, rgb) ||
                !surface.UploadRegion(pixels, x, y, width, height)) {
                row = 0;
                while (row < height) {
                    int column = 0;
                    while (column < width) {
                        pixels.SetPixel(x + column, y + row,
                            previous[row * width + column]);
                        column = column + 1;
                    }
                    row = row + 1;
                }
                return -5;
            }
            return 0;
        }
        public int ClientReadPixel(int processId, int handle, int x,
            int y) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0) { return -13; }
            PixelSurface pixels = clientPixels[slot];
            if (pixels == null || x < 0 || y < 0 ||
                x >= pixels.Width() || y >= pixels.Height()) { return -22; }
            IRenderSurface surface = ClientReady(slot);
            if (surface == null || !surface.ReadbackRegion(pixels,
                x, y, 1, 1)) { return -5; }
            return pixels.Pixel(x, y);
        }
        public int ClientCopyRegion(int processId, int sourceHandle,
            int targetHandle, int sourceX, int sourceY, int width,
            int height, int targetX, int targetY) {
            int sourceSlot = ClientSlot(processId, sourceHandle);
            int targetSlot = ClientSlot(processId, targetHandle);
            if (sourceSlot < 0 || targetSlot < 0) { return -13; }
            if (sourceSlot == targetSlot || sourceX < 0 || sourceY < 0 ||
                targetX < 0 || targetY < 0 || width < 1 || height < 1) {
                return -22;
            }
            PixelSurface sourcePixels = clientPixels[sourceSlot];
            PixelSurface targetPixels = clientPixels[targetSlot];
            if (sourcePixels == null || targetPixels == null ||
                (long)sourceX + width > sourcePixels.Width() ||
                (long)sourceY + height > sourcePixels.Height() ||
                (long)targetX + width > targetPixels.Width() ||
                (long)targetY + height > targetPixels.Height()) {
                return -22;
            }
            if (ClientReady(sourceSlot) == null ||
                ClientReady(targetSlot) == null ||
                !clientContexts[targetSlot].CopyTextureRegionFrom(
                    clientContexts[sourceSlot], sourceX, sourceY,
                    width, height, targetX, targetY)) { return -5; }
            if (!targetPixels.CopyRegion(sourcePixels, sourceX,
                sourceY, targetX, targetY, width, height)) { return -5; }
            return 0;
        }
        public int ClientWidth(int processId, int handle) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0 || clientPixels[slot] == null) { return -13; }
            return clientPixels[slot].Width();
        }
        public int ClientHeight(int processId, int handle) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0 || clientPixels[slot] == null) { return -13; }
            return clientPixels[slot].Height();
        }
        public bool ClientBlit(int processId, int handle,
            PixelSurface destination, int x, int y) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0 || clientPixels[slot] == null) { return false; }
            return ClientBlitRegion(processId, handle, destination,
                0, 0, clientPixels[slot].Width(),
                clientPixels[slot].Height(), x, y);
        }
        public bool ClientBlitRegion(int processId, int handle,
            PixelSurface destination, int sourceX, int sourceY,
            int width, int height, int targetX, int targetY) {
            int slot = ClientSlot(processId, handle);
            if (slot < 0 || destination == null ||
                !destination.Ready() || sourceX < 0 || sourceY < 0 ||
                width < 1 || height < 1 || targetX < 0 ||
                targetY < 0) { return false; }
            PixelSurface pixels = clientPixels[slot];
            if (pixels == null ||
                (long)sourceX + width > pixels.Width() ||
                (long)sourceY + height > pixels.Height() ||
                (long)targetX + width > destination.Width() ||
                (long)targetY + height > destination.Height()) {
                return false;
            }
            // Every supported client write updates this shadow after its
            // fenced GPU operation. The software scanout can compose from
            // it without a synchronous GPU-to-CPU transfer per window.
            return ClientReady(slot) != null &&
                destination.CopyRegion(pixels, sourceX, sourceY,
                    targetX, targetY, width, height);
        }
        private void RecoverAcceleration() {
            if (!Ready() || renderSurface == null ||
                renderSurface.Ready() || gpu3d == null ||
                accelerationRecoveryAttempts >= 2) { return; }
            accelerationRecoveryAttempts =
                accelerationRecoveryAttempts + 1;
            renderSurface.Recover();
        }
        public bool Ready() {
            return started && control != null && control.Ready() &&
                gpu != null && gpu.Current() != null &&
                backing != null && backing.Owned();
        }
        public bool Initialize() {
			return InitializeRequested(0, 0);
		}
        private bool InitializeRequested(int requestedWidth,
            int requestedHeight) {
            lastError = 0;
            accelerationRecoveryAttempts = 0;
            if (started || bootInfo < 4096 || pci == null || bdf < 0 ||
                allocator == null || !allocator.Supported()) {
                lastError = 1; return false;
            }
            control = new NativeVirtioGpuControl();
            if (!control.Initialize(bootInfo, pci, bdf)) {
                lastError = 2;
                Shutdown(); return false;
            }
            gpu = new VirtioGpu2D(control);
            mode = gpu.DiscoverMode();
            if (mode != null && requestedWidth > 0 &&
                requestedHeight > 0) {
                mode = new VirtioGpuDisplayMode(mode.Scanout(),
                    requestedWidth, requestedHeight);
            }
            if (mode == null || mode.Width() < 8 || mode.Height() < 8 ||
                mode.Width() > 2048 || mode.Height() > 2048 ||
                (long)mode.Width() * mode.Height() > 1048576) {
                lastError = 3;
                Shutdown(); return false;
            }
            long bytes = (long)mode.Width() * mode.Height() * 4;
            int pages = (int)((bytes + 4095) / 4096);
            backing = allocator.Allocate(pages);
            if (backing == null ||
                (long)backing.PageCount() * 4096 < bytes) {
                lastError = 4;
                Shutdown(); return false;
            }
            long index = 0;
            while (index < bytes / 4) {
                System.Kernel.Memory.Write32(backing.Address() + index * 4, 0);
                index = index + 1;
            }
            if (!gpu.Create(mode.Width(), mode.Height(),
                backing.Address(), (int)bytes)) {
                lastError = 5;
                Shutdown(); return false;
            }
            if (!gpu.Scanout(mode.Scanout())) {
                lastError = 6;
                Shutdown(); return false;
            }
            if (!gpu.Update(0, 0, mode.Width(), mode.Height())) {
                lastError = 7;
                Shutdown(); return false;
            }
            started = true;
            cursorReady = true;
            MoveCursor(Width() / 2, Height() / 2);
            if (gpu.Current() != null) {
                control.PublishPanicScanout(
                    System.Kernel.Memory.Read64(bootInfo + 3664),
                    backing.Address(), Width(), Height(),
                    gpu.Current().Id());
            }
            if (control.VirglAvailable() && control.CapsetCount() > 0) {
                gpu3d = new VirtioGpu3D(control, true,
                    control.CapsetCount());
                if (!gpu3d.Probe() || !gpu3d.CreateContext()) {
                    gpu3d = null;
                    if (!control.Ready()) {
                        lastError = 8; Shutdown(); return false;
                    }
                } else {
                    int renderWidth = mode.Width();
                    int renderHeight = mode.Height();

                    long renderBytes =
                        (long)renderWidth * renderHeight * 4;

                    int renderPages =
                        (int)((renderBytes + 4095) / 4096);

                    renderBacking = allocator.Allocate(renderPages);

                    if (renderBacking != null &&
                        renderBacking.Owned() &&
                        (long)renderBacking.PageCount() * 4096 >=
                            renderBytes) {

                        int pixel = 0;
                        int pixelCount = renderWidth * renderHeight;

                        while (pixel < pixelCount) {
                            System.Kernel.Memory.Write32(
                                renderBacking.Address() + (long)pixel * 4,
                                0);
                            pixel = pixel + 1;
                        }

                        System.Kernel.Memory.Fence();

                        renderSurface =
                            new VirglRenderSurface(
                                gpu3d,
                                renderWidth,
                                renderHeight,
                                renderBacking.Address(),
                                renderPages * 4096);
                    }
                    if (renderSurface == null || !renderSurface.Ready()) {
                        if (control.Ready() &&
                            !gpu3d.DestroyContext()) {
                            lastError = 8; Shutdown(); return false;
                        }
                        if (!control.Ready()) {
                            lastError = 8; Shutdown(); return false;
                        }
                        gpu3d.Abandon(); gpu3d = null;
                        renderSurface = null;
                        if (renderBacking != null &&
                            renderBacking.Owned()) {
                            allocator.Release(renderBacking);
                        }
                        renderBacking = null;
                    }
                    if (renderSurface != null &&
                        renderSurface.Ready()) {

                        // Optional acceleration setup.
                        // Failure must not prevent native 2D scanout.
                        PrepareWindowComposer();
                    }
                }
            }
            return true;
        }
		private int CursorColor(int x, int y) {
			if (x < 0 || x >= CURSOR_WIDTH || y < 0 || y >= CURSOR_HEIGHT) {
				return -1;
			}

			//    | | | | | | | | | |1|1|1|1
			//   0|1|2|3|4|5|6|7|8|9|0|1|2|3
			// 0 X X # # # # # # # # # # # #
			// 1 X # X # # # # # # # # # # #
			// 2 X # # X # # # # # # # # # #
			// 3 X # # # X # # # # # # # # #
			// 4 X # # # # X # # # # # # # #
			// 5 X # # # # # X # # # # # # #
			// 6 X # # # # # # X # # # # # #
			// 7 X # # # # # # # X # # # # #
			// 8 X # # # # # # # # X # # # #
			// 9 X # # # # # # # # # X # # #
			//10 X # # # # X X X X X X X # #
			//11 X # X # # # X # # # # # # #
			//12 X X # X # # X # # # # # # #
			//13 X # # X # # # X # # # # # #
			//14 # # # # X # # X # # # # # #
			//15 # # # # # X X # # # # # # #
			// Calculation for the diagonal
			if (y < 10) {
				int span = y + 1;
				if (x == 0 || x == span) {
					return CURSOR_OUTLINE_COLOUR;  // Colour in the outline of the
				}
				if (x > 0 && x < span) {
					return CURSOR_FILL_COLOUR; // Colour in the middle of the cursor.
				}
			} else if (y == 10) {
				if (x == 0 || (x >= 5 && x <= 11)) {
					return CURSOR_OUTLINE_COLOUR;
				}
				if (x >= 1 && x <= 4) {
					return CURSOR_FILL_COLOUR;
				}
			} else if (y == 11) {
				if (x == 0 || x == 2 || x == 6) {
					return CURSOR_OUTLINE_COLOUR;
				}
				if (x == 1 || (x >= 3 && x <= 5)) {
					return CURSOR_FILL_COLOUR;
				}
			} else if (y == 12) {
				if (x == 0 || x == 1 || x == 3 || x == 6) {
					return CURSOR_OUTLINE_COLOUR;
				}
				if ((x >= 4 && x <= 6)) {
					return CURSOR_FILL_COLOUR;
				}
			} else if (y == 13) {
				if (x == 0 || x == 3 || x == 7) {
					return CURSOR_OUTLINE_COLOUR;
				}
				if (x >= 4 && x <= 6) {
					return CURSOR_FILL_COLOUR;
				}
			} else if (y == 14) {
				if (x == 4 || x == 7) {
					return CURSOR_OUTLINE_COLOUR;
				}
				if (x == 5 || x == 6) {
					return CURSOR_FILL_COLOUR;
				}
			} else if (y == 15) {
				if (x == 5 || x == 6) {
					return CURSOR_OUTLINE_COLOUR;
				}
			}

			return -1;
		}
        private void RestoreCursor() {
            int y = 0;
            while (y < CURSOR_HEIGHT) {
                int x = 0;
                while (x < CURSOR_HEIGHT) {
                    long address = backing.Address() +
                        ((long)(cursorY + y) * Width() + cursorX + x) * 4;
                    System.Kernel.Memory.Write32(address,
                        cursorSaved[y * CURSOR_HEIGHT + x]);
                    x = x + 1;
                }
                y = y + 1;
            }
        }
        private void PaintCursor(int x, int y) {
            int row = 0;
            while (row < CURSOR_HEIGHT) {
                int column = 0;
                while (column < CURSOR_HEIGHT) {
                    long address = backing.Address() +
                        ((long)(y + row) * Width() + x + column) * 4;
                    cursorSaved[row * CURSOR_HEIGHT + column] =
                        (int)System.Kernel.Memory.Read32(address);
                    int color = CursorColor(column, row);
                    if (color >= 0) {
                        System.Kernel.Memory.Write32(address, color);
                    }
                    column = column + 1;
                }
                row = row + 1;
            }
            cursorX = x; cursorY = y; cursorVisible = true;
        }
        public bool MoveCursor(int x, int y) {
            if (!HardwareCursor() || x < 0 || y < 0 || x + CURSOR_HEIGHT > Width() || y + CURSOR_HEIGHT > Height()) { return false; }
            if (cursorVisible && x == cursorX && y == cursorY) {
                return true;
            }
            bool oldVisible = cursorVisible;
            int oldX = cursorX; int oldY = cursorY;
            if (oldVisible) { RestoreCursor(); }
            PaintCursor(x, y);
            System.Kernel.Memory.Fence();
            // Nearby positions share one small transfer and flush instead of
            // four synchronous control queue requests.
            bool updated = false;
            if (oldVisible && x < oldX + CURSOR_HEIGHT && oldX < x + CURSOR_HEIGHT &&
                y < oldY + CURSOR_HEIGHT && oldY < y + CURSOR_HEIGHT) {
                int left = x; if (oldX < left) { left = oldX; }
                int top = y; if (oldY < top) { top = oldY; }
                int right = x + CURSOR_HEIGHT;
                if (oldX + CURSOR_HEIGHT > right) { right = oldX + CURSOR_HEIGHT; }
                int bottom = y + CURSOR_HEIGHT;
                if (oldY + CURSOR_HEIGHT > bottom) { bottom = oldY + CURSOR_HEIGHT; }
                updated = gpu.Update(left, top, right - left,
                    bottom - top);
            } else {
                updated = (!oldVisible || gpu.Update(oldX, oldY, CURSOR_HEIGHT, CURSOR_HEIGHT)) &&
                    gpu.Update(x, y, CURSOR_HEIGHT, CURSOR_HEIGHT);
            }
            if (!updated) {
                cursorReady = false; return false;
            }
            return true;
        }
        public void HideCursor() {
            if (cursorVisible && Ready()) {
                RestoreCursor();
                System.Kernel.Memory.Fence();
                if (!gpu.Update(cursorX, cursorY, CURSOR_HEIGHT, CURSOR_HEIGHT)) {
                    cursorReady = false;
                }
            }
            cursorVisible = false;
        }

        public bool ProbeOwnedWindowComposition() {
            ownedWindowProbeStage = 1;
            ownedWindowProbePixel = -1;

            if (!GpuWindowComposerReady() ||
                Width() < 64 || Height() < 64) {
                return false;
            }

            // Test-only owner PID. No user process owns
            // these handles, and they never escape kernel code.
            ownedWindowProbeStage = 1;
            int ownerPid = 31000;

            int windowA = ClientCreate(ownerPid, 32, 24, true);

            int windowB = -1;

            if (windowA > 0) {
                windowB = ClientCreate(ownerPid, 32, 24, true);
            }

            bool correct =
                windowA > 0 &&
                windowB > 0;

            if (correct) {
                ownedWindowProbeStage = 2;
                correct =
                    ClientClear(ownerPid, windowA,
                        0xCC3300) == 0 &&
                    ClientClear(ownerPid, windowB,
                        0x0055CC) == 0;
            }

            // Frame 1: A behind B.
            if (correct) {
                ownedWindowProbeStage = 3;
                correct =
                    BeginGpuComposition(0x00FF00) &&
                    DrawGpuWindow(
                        ownerPid, windowA, 12, 16) &&
                    DrawGpuWindow(
                        ownerPid, windowB, 28, 24) &&
                    EndGpuComposition();
            }

            if (correct) {
                ownedWindowProbeStage = 4;
                correct =
                    ComposedPixelNear(16, 20,
                        204, 51, 0) &&
                    ComposedPixelNear(54, 42,
                        0, 85, 204) &&
                    ComposedPixelNear(32, 30,
                        0, 85, 204) &&
                    ComposedPixelNear(4, 4,
                        0, 255, 0);
            }

            // Frame 2: Reverse stacking.
            if (correct) {
                ownedWindowProbeStage = 5;
                correct =
                    BeginGpuComposition(0x00FF00) &&
                    DrawGpuWindow(
                        ownerPid, windowB, 28, 24) &&
                    DrawGpuWindow(
                        ownerPid, windowA, 12, 16) &&
                    EndGpuComposition();
            }

            if (correct) {
                ownedWindowProbeStage = 6;
                correct =
                    ComposedPixelNear(32, 30,
                        204, 51, 0) &&
                    ComposedPixelNear(54, 42,
                        0, 85, 204) &&
                    ComposedPixelNear(4, 4,
                        0, 255, 0);
            }

            // Cross-process handles must remain denied.
            if (correct) {
                ownedWindowProbeStage = 7;
                correct =
                    ClientWidth(
                        ownerPid + 1, windowA) == -13;
            }
            ownedWindowProbeStage = 8;

            // Every draw must have released its temporary
            // sampler view before the source is destroyed.
            bool releasedB = true;
            bool releasedA = true;

            if (windowB > 0) {
                releasedB = ClientDestroy(ownerPid, windowB) == 0;
            }

            if (windowA > 0) {
                releasedA = ClientDestroy(ownerPid, windowA) == 0;
            }

            if (!releasedA || !releasedB) {
                ownedWindowProbeStage = 8;
            }

            bool passed = correct && releasedA && releasedB;

            if (passed) {
                ownedWindowProbeStage = 0;
            }

            return passed;
        }

        private bool ComposedPixelNear(
            int x, int y,
            int red, int green, int blue) {

            if (!GpuWindowComposerReady() ||
                x < 0 || y < 0 ||
                x >= Width() || y >= Height() ||
                !gpu3d.DownloadTextureRegion(x, y, 1, 1)) {
                return false;
            }

            System.Kernel.Memory.Fence();

            long address =
                renderBacking.Address() +
                ((long)y * Width() + x) * 4;

            long pixel = System.Kernel.Memory.Read32(address);

            ownedWindowProbePixel = (int)(pixel % 16777216);

            int r = (int)(pixel / 65536 % 256);
            int g = (int)(pixel / 256 % 256);
            int b = (int)(pixel % 256);

            return r >= red - 8 && r <= red + 8 &&
                g >= green - 8 && g <= green + 8 &&
                b >= blue - 8 && b <= blue + 8;
        }

        public void Shutdown() {
            int client = 0;
            while (client < clientOwners.Length) {
                if (clientContexts[client] != null) {
                    ClientDiscard(client);
                }
                client = client + 1;
            }
            if (control != null) {
                control.ClearPanicScanout(
                    System.Kernel.Memory.Read64(bootInfo + 3664));
            }
            if (renderSurface != null) {
                if (control != null && control.Ready()) {
                    renderSurface.Destroy();
                }
                renderSurface = null;
            }

            bool composerBackingSafe = gpu3d == null;
            windowComposer = null;

            if (gpu3d != null) {
                if (control != null && control.Ready()) {
                    composerBackingSafe =
                        gpu3d.DestroyContext();
                }

                gpu3d.Abandon();
                gpu3d = null;
            }

            // Never reuse DMA backing that may still be
            // referenced by an incompletely destroyed GPU
            // resource. Quarantine it until device reset.
            if (composerVertexBacking != null &&
                composerVertexBacking.Owned() &&
                composerBackingSafe &&
                allocator != null) {

                allocator.Release(composerVertexBacking);
            }

            composerVertexBacking = null;
            composerPrepared = false;

            HideCursor();
            if (gpu != null && control != null && control.Ready() &&
                gpu.Current() != null) {
                gpu.DisableScanout(mode.Scanout());
                gpu.Destroy();
            }
            if (control != null) { control.Close(); }
            client = 0;
            while (client < clientBackings.Length) {
                if (clientBackings[client] != null &&
                    clientBackings[client].Owned()) {
                    allocator.Release(clientBackings[client]);
                }
                clientBackings[client] = null;
                clientContexts[client] = null;
                client = client + 1;
            }
            if (backing != null && backing.Owned() && allocator != null) {
                allocator.Release(backing);
            }
            if (renderBacking != null && renderBacking.Owned() &&
                allocator != null) { allocator.Release(renderBacking); }
            backing = null; gpu = null; control = null;
            mode = null; started = false;
            renderBacking = null;
            cursorReady = false; cursorVisible = false;
        }
        public bool Recover() {
            int expectedWidth = Width(); int expectedHeight = Height();
            Shutdown();
            if (!Initialize()) { return false; }
            if (expectedWidth > 0 && (Width() != expectedWidth ||
                Height() != expectedHeight)) {
                Shutdown(); return false;
            }
            return true;
        }
        public bool Reconfigure(int width, int height) {
            if (!Ready() || width < 320 || height < 240 ||
                width > 2048 || height > 2048 ||
                (long)width * height > 1048576) { return false; }
            if (width == Width() && height == Height()) { return true; }
            int oldWidth = Width(); int oldHeight = Height();
            Shutdown();
            if (InitializeRequested(width, height)) { return true; }
            Shutdown();
            InitializeRequested(oldWidth, oldHeight);
            return false;
        }
        public bool PollModeChange() {
            RecoverAcceleration();
            if (!Ready() || !control.DisplayChanged()) { return false; }
            VirtioGpuDisplayMode preferred = gpu.DiscoverMode();
            if (preferred == null ||
                (preferred.Width() == Width() &&
                preferred.Height() == Height())) { return false; }
            return Reconfigure(preferred.Width(), preferred.Height());
        }
        private bool Bounds(int x, int y, int width, int height) {
            return Ready() && x >= 0 && y >= 0 && width > 0 &&
                height > 0 && (long)x + width <= Width() &&
                (long)y + height <= Height();
        }
        public bool PresentDamage(PixelSurface surface, DamageTracker damage) {
            if (!Ready() || surface == null || !surface.Ready() ||
                damage == null || surface.Width() != Width() ||
                surface.Height() != Height() ||
                damage.Width() != Width() ||
                damage.Height() != Height()) { return false; }
            RecoverAcceleration();
            int i = 0;
            while (i < damage.Count()) {
                DamageRect rect = damage.At(i);
                if (rect == null || !Bounds(rect.X(), rect.Y(),
                    rect.Width(), rect.Height())) { return false; }
                i = i + 1;
            }
            bool showCursor = cursorVisible;
            int shownX = cursorX; int shownY = cursorY;
            if (showCursor) {
                RestoreCursor(); cursorVisible = false;
            }
            i = 0;
            while (i < damage.Count()) {
                DamageRect rect = damage.At(i);
                int y = rect.Y();
                while (y < rect.Y() + rect.Height()) {
                    int x = rect.X();
                    long row = backing.Address() +
                        ((long)y * Width() + x) * 4;
                    while (x < rect.X() + rect.Width()) {
                        System.Kernel.Memory.Write32(row,
                            surface.Pixel(x, y));
                        row = row + 4; x = x + 1;
                    }
                    y = y + 1;
                }
                i = i + 1;
            }
            if (showCursor) { PaintCursor(shownX, shownY); }
            System.Kernel.Memory.Fence();
            i = 0;
            while (i < damage.Count()) {
                DamageRect rect = damage.At(i);
                if (!gpu.Update(rect.X(), rect.Y(), rect.Width(),
                    rect.Height())) { return false; }
                i = i + 1;
            }
            if (showCursor && !gpu.Update(shownX, shownY, CURSOR_HEIGHT, CURSOR_HEIGHT)) {
                return false;
            }
            damage.Clear(); return true;
        }
        public bool FillImmediate(int x, int y, int width, int height, int rgb) {
            if (!Bounds(x, y, width, height) || rgb < 0 || rgb > 16777215) { return false; }
            bool showCursor = cursorVisible;
            int shownX = cursorX; int shownY = cursorY;
            if (showCursor) {
                RestoreCursor(); cursorVisible = false;
            }
            int row = y;
            while (row < y + height) {
                int column = x;
                long address = backing.Address() +
                    ((long)row * Width() + x) * 4;
                while (column < x + width) {
                    System.Kernel.Memory.Write32(address, rgb);
                    address = address + 4; column = column + 1;
                }
                row = row + 1;
            }
            if (showCursor) { PaintCursor(shownX, shownY); }
            System.Kernel.Memory.Fence();
            if (!gpu.Update(x, y, width, height)) { return false; }
            return !showCursor || gpu.Update(shownX, shownY, CURSOR_HEIGHT, CURSOR_HEIGHT);
        }
    }

}
