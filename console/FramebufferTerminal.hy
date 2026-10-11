namespace Australis.Kernel.Console {
    // The bootloader leaves GOP's 32-bit pixel framebuffer mapped after the
    // firmware handoff. This renderer owns no IRQ state: all drawing happens
    // in the shell's normal kernel context.
    public class FramebufferTerminal : IConsoleByteSink {
        private long bootInfo;
        private long pixels;
        private int width;
        private int height;
        private int stride;
        private int cursorX;
        private int cursorY;
        private int[] font;
        private int[] cursorUnder;
        private bool cursorDrawn;
        private int escapeState;
        private int csiValue;
        private bool csiDigits;
        private bool ready;

        public FramebufferTerminal(long inputBootInfo) {
            bootInfo = inputBootInfo;
            ready = false;
            if (bootInfo < 4096 || System.Kernel.Memory.Read32(bootInfo + 36) < 127) { return; }
            pixels = System.Kernel.Memory.Read64(bootInfo + 112);
            long size = System.Kernel.Memory.Read64(bootInfo + 120);
            width = System.Kernel.Memory.Read32(bootInfo + 128);
            height = System.Kernel.Memory.Read32(bootInfo + 132);
            stride = System.Kernel.Memory.Read32(bootInfo + 136);
            int pixelFormat = System.Kernel.Memory.Read32(bootInfo + 140);
            if (pixels < 4096 || width < 8 || height < 8 || stride < width ||
                stride > 16384 || height > 16384 || pixelFormat < 0 || pixelFormat > 1 ||
                (long)stride * height * 4 > size) { return; }
            // Keep the visible text region on complete glyph rows. A partial
            // final pixel row would otherwise survive a scroll.
            height = (height / 8) * 8;
            cursorX = System.Kernel.Memory.Read32(bootInfo + 144);
            cursorY = System.Kernel.Memory.Read32(bootInfo + 148);
            if (cursorX < 0 || cursorX >= width) { cursorX = 0; }
            if (cursorY < 0 || cursorY + 8 > height) { cursorY = 0; }
            cursorX = (cursorX / 8) * 8;
            cursorY = (cursorY / 8) * 8;
            font = new int[190];
            LoadFont();
            cursorUnder = new int[8];
            cursorDrawn = false;
            escapeState = 0;
            csiValue = 0;
            csiDigits = false;
            ready = true;
            ShowCursor();
        }

        public bool IsReady() { return ready; }

        private void LoadFont() {
            // Same 8x8 printable ASCII glyphs used by the bootstrap renderer.
            // Each signed dword stores four little-endian rows.
            font[0] = 0;
            font[1] = 0;
            font[2] = 406600728;
            font[3] = 1572888;
            font[4] = 2385510;
            font[5] = 0;
            font[6] = 1828613228;
            font[7] = 7105790;
            font[8] = 1012940312;
            font[9] = 1604614;
            font[10] = 416073216;
            font[11] = 13002288;
            font[12] = 1983409208;
            font[13] = 7785692;
            font[14] = 3151896;
            font[15] = 0;
            font[16] = 808458252;
            font[17] = 792624;
            font[18] = 202119216;
            font[19] = 3151884;
            font[20] = -12818944;
            font[21] = 26172;
            font[22] = 2115508224;
            font[23] = 6168;
            font[24] = 0;
            font[25] = 806885376;
            font[26] = 2113929216;
            font[27] = 0;
            font[28] = 0;
            font[29] = 1579008;
            font[30] = 806882310;
            font[31] = 8437856;
            font[32] = -691639240;
            font[33] = 3697862;
            font[34] = 404240408;
            font[35] = 8263704;
            font[36] = 470206076;
            font[37] = 16672304;
            font[38] = 1007076988;
            font[39] = 8177158;
            font[40] = -865321956;
            font[41] = 1969406;
            font[42] = -54476546;
            font[43] = 8177158;
            font[44] = -54501320;
            font[45] = 8177350;
            font[46] = 403490558;
            font[47] = 3158064;
            font[48] = 2093401724;
            font[49] = 8177350;
            font[50] = 2126956156;
            font[51] = 7867398;
            font[52] = 1579008;
            font[53] = 1579008;
            font[54] = 1579008;
            font[55] = 806885376;
            font[56] = 806882310;
            font[57] = 396312;
            font[58] = 8257536;
            font[59] = 32256;
            font[60] = 202911840;
            font[61] = 6303768;
            font[62] = 403490428;
            font[63] = 1572888;
            font[64] = -555825540;
            font[65] = 7913694;
            font[66] = -20550600;
            font[67] = 13027014;
            font[68] = 2087085820;
            font[69] = 16541286;
            font[70] = -1061132740;
            font[71] = 3958464;
            font[72] = 1717988600;
            font[73] = 16280678;
            font[74] = 2020107006;
            font[75] = 16671336;
            font[76] = 2020107006;
            font[77] = 15753320;
            font[78] = -1061132740;
            font[79] = 3827406;
            font[80] = -20527418;
            font[81] = 13027014;
            font[82] = 404232252;
            font[83] = 3938328;
            font[84] = 202116126;
            font[85] = 7916748;
            font[86] = 2020370150;
            font[87] = 15099500;
            font[88] = 1616929008;
            font[89] = 16672354;
            font[90] = -16847162;
            font[91] = 13027030;
            font[92] = -554244410;
            font[93] = 13027022;
            font[94] = -960051588;
            font[95] = 8177350;
            font[96] = 2087085820;
            font[97] = 15753312;
            font[98] = -960051588;
            font[99] = 243060422;
            font[100] = 2087085820;
            font[101] = 15099500;
            font[102] = 405825084;
            font[103] = 3958284;
            font[104] = 408583806;
            font[105] = 3938328;
            font[106] = -960051514;
            font[107] = 8177350;
            font[108] = -960051514;
            font[109] = 3697862;
            font[110] = -691616058;
            font[111] = 7143126;
            font[112] = 946652870;
            font[113] = 13026924;
            font[114] = 1013343846;
            font[115] = 3938328;
            font[116] = 411879166;
            font[117] = 16672306;
            font[118] = 808464444;
            font[119] = 3944496;
            font[120] = 405823680;
            font[121] = 132620;
            font[122] = 202116156;
            font[123] = 3935244;
            font[124] = -965986288;
            font[125] = 0;
            font[126] = 0;
            font[127] = -16777216;
            font[128] = 792624;
            font[129] = 0;
            font[130] = 209190912;
            font[131] = 7785596;
            font[132] = 1719427296;
            font[133] = 14444134;
            font[134] = -964952064;
            font[135] = 8177344;
            font[136] = -864285668;
            font[137] = 7785676;
            font[138] = -964952064;
            font[139] = 8175870;
            font[140] = -127900100;
            font[141] = 15753312;
            font[142] = -864681984;
            font[143] = -133399348;
            font[144] = 1986814176;
            font[145] = 15099494;
            font[146] = 406323224;
            font[147] = 3938328;
            font[148] = 101056518;
            font[149] = 1013343750;
            font[150] = 1818648800;
            font[151] = 15101048;
            font[152] = 404232248;
            font[153] = 3938328;
            font[154] = -18087936;
            font[155] = 14079702;
            font[156] = 1725693952;
            font[157] = 6710886;
            font[158] = -964952064;
            font[159] = 8177350;
            font[160] = 1725693952;
            font[161] = -262112154;
            font[162] = -864681984;
            font[163] = 504134860;
            font[164] = 1994129408;
            font[165] = 15753312;
            font[166] = -1065484288;
            font[167] = 16516732;
            font[168] = 821833776;
            font[169] = 1848880;
            font[170] = -859045888;
            font[171] = 7785676;
            font[172] = -960102400;
            font[173] = 3697862;
            font[174] = -691666944;
            font[175] = 7143126;
            font[176] = 1824915456;
            font[177] = 13003832;
            font[178] = -960102400;
            font[179] = -66683194;
            font[180] = 1283325952;
            font[181] = 8270360;
            font[182] = 1880627214;
            font[183] = 923672;
            font[184] = 404232216;
            font[185] = 1579032;
            font[186] = 236460144;
            font[187] = 7346200;
            font[188] = 56438;
            font[189] = 0;
        }

        private void SaveCursor() {
            System.Kernel.Memory.Write32(bootInfo + 144, cursorX);
            System.Kernel.Memory.Write32(bootInfo + 148, cursorY);
        }

        private void HideCursor() {
            if (!cursorDrawn) { return; }
            long pixel = pixels + ((long)(cursorY + 7) * stride + cursorX) * 4;
            int column = 0;
            while (column < 8) {
                System.Kernel.Memory.Write32(pixel + (long)column * 4, cursorUnder[column]);
                column = column + 1;
            }
            cursorDrawn = false;
        }

        private void ShowCursor() {
            if (cursorX + 8 > width || cursorY + 8 > height) { return; }
            long pixel = pixels + ((long)(cursorY + 7) * stride + cursorX) * 4;
            int column = 0;
            while (column < 8) {
                int color = System.Kernel.Memory.Read32(pixel + (long)column * 4);
                cursorUnder[column] = color;
                int cursorColor = 0;
                if (color == 0) { cursorColor = 16777215; }
                System.Kernel.Memory.Write32(pixel + (long)column * 4, cursorColor);
                column = column + 1;
            }
            cursorDrawn = true;
        }

        private void ClearLine(int start, int end) {
            int x = start;
            while (x < end) {
                int row = 0;
                while (row < 8) {
                    long pixel = pixels + ((long)(cursorY + row) * stride + x) * 4;
                    int column = 0;
                    while (column < 8 && x + column < width) {
                        System.Kernel.Memory.Write32(pixel + (long)column * 4, 0);
                        column = column + 1;
                    }
                    row = row + 1;
                }
                x = x + 8;
            }
        }

        private void ClearScreen() {
            int row = 0;
            while (row < height) {
                long pixel = pixels + (long)row * stride * 4;
                int column = 0;
                while (column < stride) {
                    System.Kernel.Memory.Write32(pixel + (long)column * 4, 0);
                    column = column + 1;
                }
                row = row + 1;
            }
            cursorX = 0;
            cursorY = 0;
        }

        private void ExecuteCsi(int command) {
            int count = 1;
            if (csiDigits) { count = csiValue; }
            if (command == 68) { // cursor left
                while (count > 0 && cursorX >= 8) { cursorX = cursorX - 8; count = count - 1; }
            } else if (command == 67) { // cursor right
                while (count > 0 && cursorX + 16 <= width) { cursorX = cursorX + 8; count = count - 1; }
            } else if (command == 72) { // home
                cursorX = 0; cursorY = 0;
            } else if (command == 74 && csiValue == 2) { // clear display
                ClearScreen();
            } else if (command == 75) { // erase line
                if (csiValue == 2) { ClearLine(0, width); }
                else { ClearLine(cursorX, width); }
            }
        }

        private void Scroll() {
            int row = 0;
            while (row < height - 8) {
                long target = pixels + (long)row * stride * 4;
                long source = target + (long)stride * 8 * 4;
                int column = 0;
                while (column < stride) {
                    System.Kernel.Memory.Write32(target + (long)column * 4,
                        System.Kernel.Memory.Read32(source + (long)column * 4));
                    column = column + 1;
                }
                row = row + 1;
            }
            while (row < height) {
                long target = pixels + (long)row * stride * 4;
                int column = 0;
                while (column < stride) {
                    System.Kernel.Memory.Write32(target + (long)column * 4, 0);
                    column = column + 1;
                }
                row = row + 1;
            }
        }

        private void NextLine() {
            cursorX = 0;
            cursorY = cursorY + 8;
            if (cursorY + 8 > height) {
                Scroll();
                cursorY = cursorY - 8;
            }
        }

        private int GlyphRow(int character, int row) {
            if (character < 32 || character > 126) { character = 63; }
            int packed = font[(character - 32) * 2 + row / 4];
            int low = packed % 65536;
            if (low < 0) { low = low + 65536; }
            int high = (packed - low) / 65536;
            if (high < 0) { high = high + 65536; }
            if (row % 4 == 0) { return low % 256; }
            if (row % 4 == 1) { return low / 256; }
            if (row % 4 == 2) { return high % 256; }
            return high / 256;
        }

        private void DrawGlyph(int character) {
            int row = 0;
            while (row < 8) {
                int bits = GlyphRow(character, row);
                long pixel = pixels + ((long)(cursorY + row) * stride + cursorX) * 4;
                int column = 0;
                int mask = 128;
                while (column < 8) {
                    int color = 0;
                    if ((bits / mask) % 2 != 0) { color = 16777215; }
                    System.Kernel.Memory.Write32(pixel + (long)column * 4, color);
                    mask = mask / 2;
                    column = column + 1;
                }
                row = row + 1;
            }
        }

        public bool WriteByte(int value) {
            if (!ready || value < 0 || value > 255) { return false; }
            HideCursor();
            if (escapeState == 1) {
                escapeState = 0;
                if (value == 91) { escapeState = 2; }
                csiValue = 0;
                csiDigits = false;
            } else if (escapeState == 2) {
                if (value >= 48 && value <= 57 && csiValue < 1000) {
                    csiValue = csiValue * 10 + value - 48;
                    csiDigits = true;
                } else {
                    ExecuteCsi(value);
                    escapeState = 0;
                }
            } else if (value == 27) {
                escapeState = 1;
            } else if (value == 13) {
                cursorX = 0;
            } else if (value == 10) {
                NextLine();
            } else if (value == 8 || value == 127) {
                if (cursorX >= 8) { cursorX = cursorX - 8; }
                else if (cursorY >= 8) {
                    cursorY = cursorY - 8;
                    cursorX = ((width / 8) - 1) * 8;
                }
            } else if (value >= 32 && value <= 126) {
                if (cursorX + 8 > width) { NextLine(); }
                DrawGlyph(value);
                cursorX = cursorX + 8;
            }
            SaveCursor();
            ShowCursor();
            return true;
        }
    }
}
