using Australis.Kernel.Dma;
using Australis.Kernel.Pci;

namespace Australis.Kernel.Graphics {
    // Persistent 2D scanout. All guest backing lives in the reserved DMA pool;
    // applications see only the owned RGB surfaces in DisplayDevice.
    public class NativeVirtioGpuBackend : IDisplayBackend {
        private long bootInfo;
        private IPciConfigAccess pci;
        private int bdf;
        private DmaAllocator allocator;
        private NativeVirtioGpuControl control;
        private VirtioGpu2D gpu;
        private VirtioGpu3D gpu3d;
        private IRenderSurface renderSurface;
        private VirtioGpuDisplayMode mode;
        private DmaAllocation backing;
        private DmaAllocation cursorBacking;
        private DmaAllocation renderBacking;
        private bool started;
        private bool cursorReady;
        private bool cursorVisible;
        private int lastError;

        public NativeVirtioGpuBackend(long inputBootInfo,
            IPciConfigAccess inputPci, int inputBdf,
            DmaAllocator inputAllocator) {
            bootInfo = inputBootInfo; pci = inputPci; bdf = inputBdf;
            allocator = inputAllocator; control = null; gpu = null;
            gpu3d = null;
            renderSurface = null; renderBacking = null;
            mode = null; backing = null; cursorBacking = null;
            started = false; cursorReady = false; cursorVisible = false;
            lastError = 0;
        }
        public int LastError() { return lastError; }
        public int Kind() { return 2; }
        public int Width() { if (mode == null) { return 0; }
            return mode.Width(); }
        public int Height() { if (mode == null) { return 0; }
            return mode.Height(); }
        public int StrideBytes() { return Width() * 4; }
        public int ScanoutFormat() { return 1; }
        public int Capabilities() { if (cursorReady) { return 15; }
            return 7; }
        public bool HardwareCursor() { return Ready() && cursorReady; }
        public bool AccelerationAvailable() {
            return Ready() && renderSurface != null &&
                renderSurface.Ready();
        }
        public bool Ready() {
            return started && control != null && control.Ready() &&
                gpu != null && gpu.Current() != null &&
                backing != null && backing.Owned();
        }
        public bool Initialize() { return InitializeRequested(0, 0); }
        private bool InitializeRequested(int requestedWidth,
            int requestedHeight) {
            lastError = 0;
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
            PrepareCursor();
            if (cursorReady) { MoveCursor(Width() / 2, Height() / 2); }
            if (control.VirglAvailable() && control.CapsetCount() > 0) {
                gpu3d = new VirtioGpu3D(control, true,
                    control.CapsetCount());
                if (!gpu3d.Probe() || !gpu3d.CreateContext()) {
                    gpu3d = null;
                    if (!control.Ready()) {
                        lastError = 8; Shutdown(); return false;
                    }
                } else {
                    renderBacking = allocator.Allocate(4);
                    if (renderBacking != null && renderBacking.Owned()) {
                        int pixel = 0;
                        while (pixel < 4096) {
                            System.Kernel.Memory.Write32(
                                renderBacking.Address() + pixel * 4, 0);
                            pixel = pixel + 1;
                        }
                        System.Kernel.Memory.Fence();
                        renderSurface = new VirglRenderSurface(gpu3d,
                            64, 64, renderBacking.Address(), 16384);
                    }
                    if (renderSurface == null ||
                        !renderSurface.Ready()) {
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
                }
            }
            return true;
        }
        private void PrepareCursor() {
            cursorReady = false; cursorVisible = false;
            if (control == null || !control.CursorAvailable()) { return; }
            cursorBacking = allocator.Allocate(4);
            if (cursorBacking == null) { return; }
            int y = 0;
            while (y < 64) {
                int x = 0;
                while (x < 64) {
                    int argb = 0;
                    if (y < 14) {
                        int span = y / 2 + 2;
                        if (x < span) { argb = -15722464; }
                        if (x > 0 && x < span - 1) {
                            argb = -1;
                        }
                    } else if (y < 20) {
                        if (x >= 3 && x < 6) { argb = -15722464; }
                        if (x == 4 && y < 19) { argb = -1; }
                    }
                    System.Kernel.Memory.Write32(cursorBacking.Address() +
                        ((long)y * 64 + x) * 4, argb);
                    x = x + 1;
                }
                y = y + 1;
            }
            System.Kernel.Memory.Fence();
            if (gpu.CreateCursor(cursorBacking.Address(), 16384)) {
                cursorReady = true;
            }
        }
        public bool MoveCursor(int x, int y) {
            if (!HardwareCursor() || x < 0 || y < 0 || x >= Width() ||
                y >= Height()) { return false; }
            bool sent = false;
            if (cursorVisible) {
                sent = gpu.MoveCursor(mode.Scanout(), x, y);
            } else {
                sent = gpu.UpdateCursor(mode.Scanout(), x, y);
            }
            if (!sent) { cursorReady = false; return false; }
            cursorVisible = true; return true;
        }
        public void HideCursor() {
            if (cursorVisible && gpu != null && control != null &&
                control.CursorAvailable() && mode != null) {
                gpu.HideCursor(mode.Scanout());
            }
            cursorVisible = false;
        }
        public void Shutdown() {
            if (renderSurface != null) {
                if (control != null && control.Ready()) {
                    renderSurface.Destroy();
                }
                renderSurface = null;
            }
            if (gpu3d != null) {
                if (control != null && control.Ready()) {
                    gpu3d.DestroyContext();
                }
                gpu3d.Abandon(); gpu3d = null;
            }
            HideCursor();
            if (gpu != null && control != null && control.Ready() &&
                gpu.CursorResource() != null) { gpu.DestroyCursor(); }
            if (gpu != null && control != null && control.Ready() &&
                gpu.Current() != null) {
                gpu.DisableScanout(mode.Scanout());
                gpu.Destroy();
            }
            if (control != null) { control.Close(); }
            if (backing != null && backing.Owned() && allocator != null) {
                allocator.Release(backing);
            }
            if (cursorBacking != null && cursorBacking.Owned() &&
                allocator != null) { allocator.Release(cursorBacking); }
            if (renderBacking != null && renderBacking.Owned() &&
                allocator != null) { allocator.Release(renderBacking); }
            backing = null; gpu = null; control = null;
            cursorBacking = null; mode = null; started = false;
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
            int i = 0;
            while (i < damage.Count()) {
                DamageRect rect = damage.At(i);
                if (rect == null || !Bounds(rect.X(), rect.Y(),
                    rect.Width(), rect.Height())) { return false; }
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
                System.Kernel.Memory.Fence();
                if (!gpu.Update(rect.X(), rect.Y(), rect.Width(),
                    rect.Height())) { return false; }
                i = i + 1;
            }
            damage.Clear(); return true;
        }
        public bool FillImmediate(int x, int y, int width, int height,
            int rgb) {
            if (!Bounds(x, y, width, height) || rgb < 0 ||
                rgb > 16777215) { return false; }
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
            System.Kernel.Memory.Fence();
            return gpu.Update(x, y, width, height);
        }
    }

}
