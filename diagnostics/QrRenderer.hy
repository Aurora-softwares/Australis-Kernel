
namespace Australis.Kernel.Diagnostics {

    public class QrRenderer {

        // Version 3 QR: 29 x 29 = 841 modules.
        //
        // Scratch memory:
        // +192  : 841 bytes of QR modules
        // +1056 : 841 bytes of reserved flags
        //
        // Modules:
        // 0 = white
        // 1 = black
        //
        // Reserved:
        // 0 = available for data
        // 1 = function pattern / format information

        private static void SetFunction(
            long modules,
            long reserved,
            int x,
            int y,
            int black) {

            if (x < 0 || x >= 29 ||
                y < 0 || y >= 29) {
                return;
            }

            int index = y * 29 + x;

            System.Kernel.Memory.Write8(
                modules + index, black);

            System.Kernel.Memory.Write8(
                reserved + index, 1);
        }

        // Draw a 7x7 finder plus its white separator.
        private static void DrawFinder(
            long modules,
            long reserved,
            int left,
            int top) {

            int y = -1;

            while (y <= 7) {
                int x = -1;

                while (x <= 7) {
                    int black = 0;

                    if (x >= 0 && x <= 6 &&
                        y >= 0 && y <= 6) {

                        if (x == 0 || x == 6 ||
                            y == 0 || y == 6 ||
                            (x >= 2 && x <= 4 &&
                             y >= 2 && y <= 4)) {

                            black = 1;
                        }
                    }

                    SetFunction(
                        modules,
                        reserved,
                        left + x,
                        top + y,
                        black);

                    x = x + 1;
                }

                y = y + 1;
            }
        }

        // Horizontal and vertical timing patterns.
        private static void DrawTiming(
            long modules,
            long reserved) {

            int i = 8;

            while (i <= 20) {
                int black = 0;

                if (i % 2 == 0) {
                    black = 1;
                }

                SetFunction(
                    modules, reserved,
                    i, 6, black);

                SetFunction(
                    modules, reserved,
                    6, i, black);

                i = i + 1;
            }
        }

        // Version 3 has one alignment pattern,
        // centred at module (22,22).
        private static void DrawAlignment(
            long modules,
            long reserved) {

            int y = -2;

            while (y <= 2) {
                int x = -2;

                while (x <= 2) {
                    int black = 0;

                    if (x == -2 || x == 2 ||
                        y == -2 || y == 2 ||
                        (x == 0 && y == 0)) {

                        black = 1;
                    }

                    SetFunction(
                        modules,
                        reserved,
                        22 + x,
                        22 + y,
                        black);

                    x = x + 1;
                }

                y = y + 1;
            }
        }

        // Reserve both copies of the QR format bits.
        // We'll write the actual L/mask-0 bits later.
        private static void ReserveFormat(
            long modules,
            long reserved) {

            int i = 0;

            // Around the upper-left finder.
            while (i <= 8) {
                if (i != 6) {
                    SetFunction(
                        modules, reserved,
                        i, 8, 0);

                    SetFunction(
                        modules, reserved,
                        8, i, 0);
                }

                i = i + 1;
            }

            // Upper-right format information.
            i = 21;

            while (i < 29) {
                SetFunction(
                    modules, reserved,
                    i, 8, 0);

                i = i + 1;
            }

            // Lower-left format information.
            i = 22;

            while (i < 29) {
                SetFunction(
                    modules, reserved,
                    8, i, 0);

                i = i + 1;
            }

            // Permanent dark module.
            SetFunction(
                modules, reserved,
                8, 21, 1);
        }

        // Prepare the Version 3 QR matrix.
        //
        // Returns 1 on success.
        // Returns 0 on failure.
        //
        // No allocation, strings or objects.
        public static int PrepareV3L(long scratch) {

            if (scratch < 4096 ||
                scratch % 4096 != 0) {
                return 0;
            }

            long modules = scratch + 192;
            long reserved = scratch + 1056;

            // Clear both matrices.
            int i = 0;

            while (i < 841) {
                System.Kernel.Memory.Write8(
                    modules + i, 0);

                System.Kernel.Memory.Write8(
                    reserved + i, 0);

                i = i + 1;
            }

            // Three finder patterns.
            DrawFinder(modules, reserved, 0, 0);
            DrawFinder(modules, reserved, 22, 0);
            DrawFinder(modules, reserved, 0, 22);

            // Timing patterns.
            DrawTiming(modules, reserved);

            // Alignment pattern.
            DrawAlignment(modules, reserved);

            // Format reservations and dark module.
            ReserveFormat(modules, reserved);

            // Validate the reserved-module count.
            int reservedCount = 0;
            i = 0;

            while (i < 841) {
                if (System.Kernel.Memory.Read8(
                    reserved + i) != 0) {

                    reservedCount = reservedCount + 1;
                }

                i = i + 1;
            }

            // 274 function/reserved modules;
            // 567 remaining for data and remainder bits.
            if (reservedCount != 274) {
                return 0;
            }

            return 1;
        }

        // Read a single bit from our 70 QR codewords.
        // The 55 data bytes and 15 parity bytes occupy
        // separate regions of the preallocated scratch page.
        //
        // Bits are read most-significant-bit first.
        private static int ReadDataBit(
            long scratch,
            int bitIndex) {

            int codeword = bitIndex / 8;
            int bitWithinByte = bitIndex % 8;

            long address = scratch + 80 + codeword;

            if (codeword >= 55) {
                address = scratch + 144 + codeword - 55;
            }

            int value = (int)System.Kernel.Memory.Read8(
                address);

            int weight = 128;
            int i = 0;

            while (i < bitWithinByte) {
                weight = weight / 2;
                i = i + 1;
            }

            return (value / weight) % 2;
        }

        // Place all codewords in a Version 3 QR matrix.
        //
        // Requires PrepareV3L() to have succeeded.
        //
        // Layout:
        //   scratch + 80   : 55 data codewords
        //   scratch + 144  : 15 correction codewords
        //   scratch + 192  : 29x29 module matrix
        //   scratch + 1056 : 29x29 reserved flags
        //
        // Returns 1 on success, 0 on failure.
        public static int PlaceDataV3L(long scratch) {

            if (scratch < 4096 ||
                scratch % 4096 != 0) {
                return 0;
            }

            long modules = scratch + 192;
            long reserved = scratch + 1056;

            int bitIndex = 0;
            int right = 28;
            int upward = 1;

            // Process pairs of columns, right to left.
            while (right >= 1) {

                // Column 6 contains the vertical timing pattern.
                if (right == 6) {
                    right = 5;
                }

                int row = 0;

                while (row < 29) {

                    int y = row;

                    if (upward == 1) {
                        y = 28 - row;
                    }

                    // Right-hand column first, then left.
                    int side = 0;

                    while (side < 2) {

                        int x = right - side;
                        int index = y * 29 + x;

                        if (System.Kernel.Memory.Read8(
                            reserved + index) == 0) {

                            int black = 0;

                            // 70 codewords = 560 actual bits.
                            if (bitIndex < 560) {
                                black = ReadDataBit(
                                    scratch, bitIndex);
                            }

                            // The final seven remainder modules
                            // remain white until masking.
                            System.Kernel.Memory.Write8(
                                modules + index, black);

                            bitIndex = bitIndex + 1;
                        }

                        side = side + 1;
                    }

                    row = row + 1;
                }

                // Reverse vertical direction each column pair.
                if (upward == 1) {
                    upward = 0;
                } else {
                    upward = 1;
                }

                right = right - 2;
            }

            // 560 data/ECC bits plus seven remainder bits.
            if (bitIndex != 567) {
                return 0;
            }

            return 1;
        }

        // Return one bit of the fixed QR format information.
        //
        // Version 3, error correction L, mask 0:
        //   0x77C4 = 30660
        //
        // Bit index 0 is the least significant bit.
        private static int FormatBit(int bitIndex) {

            int value = 30660;
            int i = 0;

            while (i < bitIndex) {
                value = value / 2;
                i = i + 1;
            }

            return value % 2;
        }

        // Complete the Version 3-L QR matrix.
        //
        // Call exactly once, after PlaceDataV3L().
        // Applying the mask a second time would undo it.
        //
        // Returns 1 on success or 0 on invalid input.
        public static int FinalizeV3L(long scratch) {

            if (scratch < 4096 ||
                scratch % 4096 != 0) {
                return 0;
            }

            long modules = scratch + 192;
            long reserved = scratch + 1056;

            // Apply QR mask pattern 0 to data and
            // remainder modules only.
            //
            // Never alter the finder, timing, alignment
            // or reserved format-information modules.

            int y = 0;

            while (y < 29) {
                int x = 0;

                while (x < 29) {
                    int index = y * 29 + x;

                    if (System.Kernel.Memory.Read8(
                        reserved + index) == 0) {

                        if ((x + y) % 2 == 0) {

                            int current =
                                (int)System.Kernel.Memory.Read8(
                                    modules + index);

                            if (current != 0 && current != 1) {
                                return 0;
                            }

                            System.Kernel.Memory.Write8(
                                modules + index,
                                1 - current);
                        }
                    }

                    x = x + 1;
                }

                y = y + 1;
            }

            // First format-information copy:
            // surrounding the top-left finder.

            int i = 0;

            while (i <= 5) {
                SetFunction(
                    modules, reserved,
                    8, i, FormatBit(i));

                i = i + 1;
            }

            SetFunction(
                modules, reserved,
                8, 7, FormatBit(6));

            SetFunction(
                modules, reserved,
                8, 8, FormatBit(7));

            SetFunction(
                modules, reserved,
                7, 8, FormatBit(8));

            i = 9;

            while (i < 15) {
                SetFunction(
                    modules, reserved,
                    14 - i, 8, FormatBit(i));

                i = i + 1;
            }

            // Second format-information copy:
            // across the upper-right and lower-left.

            i = 0;

            while (i < 8) {
                SetFunction(
                    modules, reserved,
                    28 - i, 8, FormatBit(i));

                i = i + 1;
            }

            i = 8;

            while (i < 15) {
                SetFunction(
                    modules, reserved,
                    8, 14 + i, FormatBit(i));

                i = i + 1;
            }

            // Permanent dark module at (8, 21).
            SetFunction(
                modules, reserved,
                8, 21, 1);

            return 1;
        }

		
        // Draw a completed Version 3 QR matrix.
        // No heap allocations, framebuffer clears, or
        // changes to the saved diagnostic information.
        //
        // Returns 1 if drawn, 0 if unavailable.
        public static int DrawFramebufferV3L(
            long bootInfo, long scratch) {

            if (bootInfo < 4096 ||
                scratch < 4096 ||
                scratch % 4096 != 0) {
                return 0;
            }

            long framebuffer =
                System.Kernel.Memory.Read64(bootInfo + 112);
            long framebufferBytes =
                System.Kernel.Memory.Read64(bootInfo + 120);

            int width =
                System.Kernel.Memory.Read32(bootInfo + 128);
            int height =
                System.Kernel.Memory.Read32(bootInfo + 132);
            int stride =
                System.Kernel.Memory.Read32(bootInfo + 136);
            int format =
                System.Kernel.Memory.Read32(bootInfo + 140);

            if (framebuffer < 4096 ||
                framebuffer % 4 != 0 ||
                framebufferBytes <= 0 ||
                framebuffer + framebufferBytes <= framebuffer ||
                width < 8 || width > 16384 ||
                height < 8 || height > 16384 ||
                stride < width || stride > 16384 ||
                format < 0 || format > 1) {
                return 0;
            }

            if ((long)stride * height * 4 > framebufferBytes) {
                return 0;
            }

            // Four-module quiet zone around a 29x29 QR.
            int scale = 6;
            int side = 37 * scale;

            // Reserve the left 512 pixels for the
            // existing readable panic report.
            if (width < 512 + side + 16 ||
                height < side + 48) {
                return 0;
            }

            int originX = width - side - 16;
            int originY = 24;

            long matrix = scratch + 192;

            // Validate before touching the framebuffer.
            int i = 0;
            while (i < 841) {
                int bit = (int)System.Kernel.Memory.Read8(
                    matrix + i);

                if (bit != 0 && bit != 1) {
                    return 0;
                }

                i = i + 1;
            }

            int my = 0;
            while (my < 37) {
                int mx = 0;

                while (mx < 37) {
                    int color = 16777215;

                    if (mx >= 4 && mx < 33 &&
                        my >= 4 && my < 33) {

                        int module = (int)
                            System.Kernel.Memory.Read8(
                                matrix +
                                (my - 4) * 29 +
                                (mx - 4));

                        if (module == 1) {
                            color = 0;
                        }
                    }

                    int py = 0;
                    while (py < scale) {
                        int px = 0;

                        while (px < scale) {
                            int x = originX + mx * scale + px;
                            int y = originY + my * scale + py;

                            long address = framebuffer +
                                ((long)y * stride + x) * 4;

                            System.Kernel.Memory.Write32(
                                address, color);

                            px = px + 1;
                        }

                        py = py + 1;
                    }

                    mx = mx + 1;
                }

                my = my + 1;
            }

            return 1;
        }
    }
}
