namespace Australis.Kernel.Console {
    // Allocation-free per keystroke. History and the active line are bounded
    // persistent buffers, so file-read command markers can rewind safely.
    public class LineEditor {
        private byte[] line;
        private byte[] history;
        private int[] historyLengths;
        private byte[] draft;
        private int length;
        private int cursor;
        private int historyNext;
        private int historyCount;
        private int browsing;
        private int draftLength;
        private bool overflow;
        private bool inputLost;

        public static int None() { return 0; }
        public static int Append() { return 1; }
        public static int Redraw() { return 2; }
        public static int Submit() { return 3; }
        public static int Cancel() { return 4; }
        public static int Bell() { return 5; }
        public static int EraseEnd() { return 6; }
        public static int ClearScreen() { return 7; }

        public LineEditor() {
            line = new byte[256];
            history = new byte[2048];
            historyLengths = new int[8];
            draft = new byte[256];
            length = 0;
            cursor = 0;
            historyNext = 0;
            historyCount = 0;
            browsing = 0;
            draftLength = 0;
            overflow = false;
            inputLost = false;
        }

        public int Length() { return length; }
        public int Cursor() { return cursor; }
        public byte ByteAt(int index) { return line[index]; }
        public byte[] Bytes() { return line; }
        public bool Overflowed() { return overflow; }
        public bool InputWasLost() { return inputLost; }

        public void Reset() {
            length = 0;
            cursor = 0;
            browsing = 0;
            draftLength = 0;
            overflow = false;
            inputLost = false;
        }

        public void Commit() {
            if (length == 0 || overflow || inputLost) { return; }
            int offset = historyNext * 256;
            int i = 0;
            while (i < length) { history[offset + i] = line[i]; i = i + 1; }
            historyLengths[historyNext] = length;
            historyNext = (historyNext + 1) % 8;
            if (historyCount < 8) { historyCount = historyCount + 1; }
            browsing = 0;
        }

        private void LoadHistory(int distance) {
            if (distance == 0) {
                length = draftLength;
                int i = 0;
                while (i < length) { line[i] = draft[i]; i = i + 1; }
            } else {
                int slot = (historyNext - distance + 8) % 8;
                length = historyLengths[slot];
                int i = 0;
                while (i < length) { line[i] = history[slot * 256 + i]; i = i + 1; }
            }
            cursor = length;
        }

        public int Apply(int key) {
            if (key == ConsoleKey.InputLost()) { inputLost = true; return Bell(); }
            if (key == 13) { return Submit(); }
            if (key == 3) { return Cancel(); }
            if (key == 12) { return ClearScreen(); }
            if (key == 21) {
                length = 0; cursor = 0; browsing = 0;
                overflow = false; inputLost = false;
                return Redraw();
            }
            if (key == ConsoleKey.Left()) {
                if (cursor == 0) { return None(); }
                cursor = cursor - 1; return Redraw();
            }
            if (key == ConsoleKey.Right()) {
                if (cursor == length) { return None(); }
                cursor = cursor + 1; return Redraw();
            }
            if (key == ConsoleKey.Home() || key == 1) {
                if (cursor == 0) { return None(); }
                cursor = 0; return Redraw();
            }
            if (key == ConsoleKey.End() || key == 5) {
                if (cursor == length) { return None(); }
                cursor = length; return Redraw();
            }
            if (key == ConsoleKey.Up()) {
                if (historyCount == 0 || browsing == historyCount) { return None(); }
                if (browsing == 0) {
                    draftLength = length;
                    int i = 0;
                    while (i < length) { draft[i] = line[i]; i = i + 1; }
                }
                browsing = browsing + 1;
                LoadHistory(browsing);
                return Redraw();
            }
            if (key == ConsoleKey.Down()) {
                if (browsing == 0) { return None(); }
                browsing = browsing - 1;
                LoadHistory(browsing);
                return Redraw();
            }
            if (key == 8) {
                if (cursor == 0) { return None(); }
                int oldLength = length;
                int i = cursor - 1;
                while (i + 1 < length) { line[i] = line[i + 1]; i = i + 1; }
                cursor = cursor - 1;
                length = length - 1;
                browsing = 0;
                if (cursor == length && oldLength > 0) { return EraseEnd(); }
                return Redraw();
            }
            if (key == ConsoleKey.Delete()) {
                if (cursor == length) { return None(); }
                int i = cursor;
                while (i + 1 < length) { line[i] = line[i + 1]; i = i + 1; }
                length = length - 1;
                browsing = 0;
                return Redraw();
            }
            if (key >= 32 && key <= 126) {
                if (length == line.Length || overflow) {
                    if (!overflow) { overflow = true; return Bell(); }
                    return None();
                }
                int i = length;
                while (i > cursor) { line[i] = line[i - 1]; i = i - 1; }
                line[cursor] = (byte)key;
                length = length + 1;
                cursor = cursor + 1;
                browsing = 0;
                if (cursor == length) { return Append(); }
                return Redraw();
            }
            return None();
        }
    }
}
