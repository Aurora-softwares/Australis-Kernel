namespace Australis.Kernel.Diagnostics {
    // Panic-only VirtIO-GPU 2D update. All pages and MMIO mappings were
    // prepared while the kernel was healthy; this path allocates nothing.
    public class PanicGpuScanout {
        private static void Clear(long address, int bytes) {
            int i = 0;
            while (i < bytes) {
                System.Kernel.Memory.Write8(address + i, 0);
                i = i + 1;
            }
        }

        private static bool Submit(long bootInfo, long ring,
            long command, long notify, long common, int type,
            int width, int height, int resourceId) {
            int available = System.Kernel.Memory.Read16(ring + 66);
            int completed = System.Kernel.Memory.Read16(ring + 130);
            if (available != completed ||
                System.Kernel.Memory.Read8(common + 20) / 4 % 2 == 0) {
                return false;
            }
            long fence = System.Kernel.Memory.Read64(command + 8) + 1;
            if (fence < 1) { fence = 1; }
            int length = 48;
            if (type == 261) { length = 56; }
            Clear(command, length);
            Clear(command + 512, 512);
            System.Kernel.Memory.Write32(command, type);
            System.Kernel.Memory.Write32(command + 4, 1);
            System.Kernel.Memory.Write64(command + 8, fence);
            System.Kernel.Memory.Write32(command + 24, 0);
            System.Kernel.Memory.Write32(command + 28, 0);
            System.Kernel.Memory.Write32(command + 32, width);
            System.Kernel.Memory.Write32(command + 36, height);
            if (type == 261) {
                System.Kernel.Memory.Write64(command + 40, 0);
                System.Kernel.Memory.Write32(command + 48, resourceId);
            } else {
                System.Kernel.Memory.Write32(command + 40, resourceId);
            }
            System.Kernel.Memory.Write64(ring, command);
            System.Kernel.Memory.Write32(ring + 8, length);
            System.Kernel.Memory.Write16(ring + 12, 1);
            System.Kernel.Memory.Write16(ring + 14, 1);
            System.Kernel.Memory.Write64(ring + 16, command + 512);
            System.Kernel.Memory.Write32(ring + 24, 512);
            System.Kernel.Memory.Write16(ring + 28, 2);
            System.Kernel.Memory.Write16(ring + 30, 0);
            System.Kernel.Memory.Write16(ring + 68 +
                (available % 2) * 2, 0);
            int expected = (available + 1) % 65536;
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write16(ring + 66, expected);
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write16(notify, 0);
            long deadline = Australis.Kernel.Time.KernelClock.DeadlineAfter(
                bootInfo, 1000);
            while (System.Kernel.Memory.Read16(ring + 130) != expected) {
                if (Australis.Kernel.Time.KernelClock.Expired(deadline) ||
                    System.Kernel.Memory.Read8(common + 20) / 64 % 2 != 0) {
                    return false;
                }
                System.Kernel.Cpu.Pause();
            }
            System.Kernel.Memory.Fence();
            int slot = completed % 2;
            int usedId = System.Kernel.Memory.Read32(
                ring + 132 + slot * 8);
            int usedLength = System.Kernel.Memory.Read32(
                ring + 136 + slot * 8);
            return usedId == 0 && usedLength >= 24 &&
                usedLength <= 512 &&
                System.Kernel.Memory.Read32(command + 512) == 4352 &&
                System.Kernel.Memory.Read32(command + 516) % 2 == 1 &&
                System.Kernel.Memory.Read64(command + 520) == fence;
        }

        // 0: no native scanout, 1: shown, 2: native scanout unavailable.
        public static int Present(long bootInfo, long scratch) {
            if (bootInfo < 4096 || scratch < 4096 ||
                System.Kernel.Memory.Read32(scratch + 2048) != 0x41554750) {
                return 0;
            }
            long backing = System.Kernel.Memory.Read64(scratch + 2056);
            int width = System.Kernel.Memory.Read32(scratch + 2064);
            int height = System.Kernel.Memory.Read32(scratch + 2068);
            long ring = System.Kernel.Memory.Read64(scratch + 2072);
            long command = System.Kernel.Memory.Read64(scratch + 2080);
            long notify = System.Kernel.Memory.Read64(scratch + 2088);
            long common = System.Kernel.Memory.Read64(scratch + 2096);
            int resourceId = System.Kernel.Memory.Read32(scratch + 2104);
            int backingBytes = System.Kernel.Memory.Read32(scratch + 2108);
            long framebuffer = System.Kernel.Memory.Read64(bootInfo + 112);
            long framebufferBytes =
                System.Kernel.Memory.Read64(bootInfo + 120);
            int sourceWidth = System.Kernel.Memory.Read32(bootInfo + 128);
            int sourceHeight = System.Kernel.Memory.Read32(bootInfo + 132);
            int sourceStride = System.Kernel.Memory.Read32(bootInfo + 136);
            if (backing < 4096 || backing % 4096 != 0 ||
                ring < 4096 || ring % 4096 != 0 ||
                command < 4096 || command % 4096 != 0 ||
                notify == 0 || common == 0 ||
                width < 750 || height < 270 ||
                (long)width * height > 1048576 ||
                backingBytes != width * height * 4 ||
                resourceId < 1 || resourceId > 65535 ||
                framebuffer < 4096 || framebufferBytes <= 0 ||
                sourceWidth < 1 || sourceHeight < 1 ||
                sourceHeight > 16384 || sourceStride < sourceWidth ||
                sourceStride > 16384 ||
                (long)sourceStride * sourceHeight * 4 >
                    framebufferBytes ||
                System.Kernel.Memory.Read16(ring + 66) !=
                    System.Kernel.Memory.Read16(ring + 130) ||
                System.Kernel.Memory.Read8(common + 20) / 4 % 2 == 0) {
                return 2;
            }

            // The firmware panic renderer has already drawn readable text.
            // Start with a black scanout and copy its left text area; redraw
            // the QR at the current native mode's right edge.
            int y = 0;
            while (y < height) {
                int x = 0;
                while (x < width) {
                    System.Kernel.Memory.Write32(backing +
                        ((long)y * width + x) * 4, 0);
                    x = x + 1;
                }
                y = y + 1;
            }
            int textWidth = 512;
            if (sourceWidth < textWidth) { textWidth = sourceWidth; }
            if (width < textWidth) { textWidth = width; }
            int textHeight = 300;
            if (sourceHeight < textHeight) { textHeight = sourceHeight; }
            if (height < textHeight) { textHeight = height; }
            y = 0;
            while (y < textHeight) {
                int x = 0;
                while (x < textWidth) {
                    System.Kernel.Memory.Write32(backing +
                        ((long)y * width + x) * 4,
                        System.Kernel.Memory.Read32(framebuffer +
                            ((long)y * sourceStride + x) * 4));
                    x = x + 1;
                }
                y = y + 1;
            }

            int originX = width - 238;
            int my = 0;
            while (my < 37) {
                int mx = 0;
                while (mx < 37) {
                    int color = 16777215;
                    if (mx >= 4 && mx < 33 && my >= 4 && my < 33 &&
                        System.Kernel.Memory.Read8(scratch + 192 +
                            (my - 4) * 29 + mx - 4) == 1) {
                        color = 0;
                    }
                    int py = 0;
                    while (py < 6) {
                        int px = 0;
                        while (px < 6) {
                            int x = originX + mx * 6 + px;
                            int row = 24 + my * 6 + py;
                            System.Kernel.Memory.Write32(backing +
                                ((long)row * width + x) * 4, color);
                            px = px + 1;
                        }
                        py = py + 1;
                    }
                    mx = mx + 1;
                }
                my = my + 1;
            }
            System.Kernel.Memory.Fence();
            if (!Submit(bootInfo, ring, command, notify, common,
                    261, width, height, resourceId) ||
                !Submit(bootInfo, ring, command, notify, common,
                    260, width, height, resourceId)) { return 2; }
            return 1;
        }
    }
}
