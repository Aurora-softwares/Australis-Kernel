namespace Australis.Kernel.Console {
    // Input is polled only by the shell. Hardware handlers enqueue bytes and
    // count drops; they never parse a command or touch the filesystem.
    public interface IConsoleInput {
        bool IsReady();
        int PollByte();
        int DroppedBytes();
        bool CanHalt();
    }

    // Merge independent byte producers before ANSI decoding. Alternating the
    // first source prevents sustained serial input from starving USB reports.
    public class ConsoleInputMux : IConsoleInput {
        private IConsoleInput first;
        private IConsoleInput second;
        private bool pollSecondFirst;
        public ConsoleInputMux(IConsoleInput inputFirst, IConsoleInput inputSecond) {
            first = inputFirst; second = inputSecond; pollSecondFirst = false;
        }
        public bool IsReady() {
            return (first != null && first.IsReady()) || (second != null && second.IsReady());
        }
        public int PollByte() {
            int value = -1;
            if (pollSecondFirst) {
                if (second != null) { value = second.PollByte(); }
                if (value < 0 && first != null) { value = first.PollByte(); }
            } else {
                if (first != null) { value = first.PollByte(); }
                if (value < 0 && second != null) { value = second.PollByte(); }
            }
            pollSecondFirst = !pollSecondFirst;
            return value;
        }
        public int DroppedBytes() {
            int value = 0;
            if (first != null) { value = value + first.DroppedBytes(); }
            if (second != null) { value = value + second.DroppedBytes(); }
            return value;
        }
        public bool CanHalt() {
            bool firstCan = first == null || first.CanHalt();
            bool secondCan = second == null || second.CanHalt();
            return firstCan && secondCan;
        }
    }

    // Printable ASCII and simple controls retain their byte values. Keyboard
    // drivers can enqueue the same non-byte codes after xHCI is available.
    public class ConsoleKey {
        public static int Up() { return 256; }
        public static int Down() { return 257; }
        public static int Right() { return 258; }
        public static int Left() { return 259; }
        public static int Home() { return 260; }
        public static int End() { return 261; }
        public static int Delete() { return 262; }
        public static int InputLost() { return 263; }
    }

    // One producer in the shell's normal context today. A future HID producer
    // must synchronize with this queue or defer its enqueue from the IRQ.
    public class ConsoleEventQueue {
        private int[] items;
        private int head;
        private int tail;
        private int dropped;

        public ConsoleEventQueue() {
            items = new int[1024];
            head = 0;
            tail = 0;
            dropped = 0;
        }

        public bool Enqueue(int value) {
            int next = (head + 1) % items.Length;
            if (next == tail) { dropped = dropped + 1; return false; }
            items[head] = value;
            head = next;
            return true;
        }

        public int Poll() {
            if (tail == head) { return -1; }
            int value = items[tail];
            tail = (tail + 1) % items.Length;
            return value;
        }

        public int Dropped() { return dropped; }
        public int Pending() { return (head - tail + items.Length) % items.Length; }
    }

    // Decode the small ANSI keyboard subset in normal context. IRQ4 only
    // moves UART bytes into its hardware receive ring.
    public class SerialKeyDecoder {
        private IConsoleInput source;
        private ConsoleEventQueue queue;
        private int state;
        private int csiNumber;
        private bool previousCr;
        private int lastSourceDrops;

        public SerialKeyDecoder(IConsoleInput inputSource, ConsoleEventQueue inputQueue) {
            source = inputSource;
            queue = inputQueue;
            state = 0;
            csiNumber = 0;
            previousCr = false;
            lastSourceDrops = source.DroppedBytes();
        }

        private void Decode(int value) {
            if (state == 1) {
                state = 0;
                if (value == 91) { state = 2; return; }
                if (value == 79) { state = 3; return; }
            } else if (state == 2 || state == 3) {
                int oldState = state;
                state = 0;
                if (value == 65) { queue.Enqueue(ConsoleKey.Up()); return; }
                if (value == 66) { queue.Enqueue(ConsoleKey.Down()); return; }
                if (value == 67) { queue.Enqueue(ConsoleKey.Right()); return; }
                if (value == 68) { queue.Enqueue(ConsoleKey.Left()); return; }
                if (value == 72) { queue.Enqueue(ConsoleKey.Home()); return; }
                if (value == 70) { queue.Enqueue(ConsoleKey.End()); return; }
                if (oldState == 2 && (value == 49 || value == 51 || value == 52 ||
                    value == 55 || value == 56)) {
                    csiNumber = value - 48;
                    state = 4;
                    return;
                }
                return;
            } else if (state == 4) {
                state = 0;
                if (value == 126) {
                    if (csiNumber == 3) { queue.Enqueue(ConsoleKey.Delete()); }
                    else if (csiNumber == 1 || csiNumber == 7) { queue.Enqueue(ConsoleKey.Home()); }
                    else if (csiNumber == 4 || csiNumber == 8) { queue.Enqueue(ConsoleKey.End()); }
                }
                return;
            }
            if (value == 27) { state = 1; return; }
            if (value == 10 && previousCr) { previousCr = false; return; }
            previousCr = value == 13;
            if (value == 10 || value == 13) { queue.Enqueue(13); return; }
            if (value == 127) { queue.Enqueue(8); return; }
            if ((value >= 32 && value <= 126) || value == 8 || value == 3 ||
                value == 21 || value == 1 || value == 5 || value == 12) {
                queue.Enqueue(value);
            }
        }

        public void Pump() {
            int drops = source.DroppedBytes();
            if (drops != lastSourceDrops) {
                lastSourceDrops = drops;
                queue.Enqueue(ConsoleKey.InputLost());
            }
            int count = 0;
            while (count < 64) {
                int value = source.PollByte();
                if (value < 0) { break; }
                Decode(value);
                count = count + 1;
            }
        }
    }
}
