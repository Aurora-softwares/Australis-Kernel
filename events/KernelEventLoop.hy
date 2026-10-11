namespace Australis.Kernel.Events {
    public class KernelEventLoop {
        private int[] kinds;
        private long[] values;
        private int head;
        private int tail;
        private int count;
        private int dropped;

        public KernelEventLoop(int capacity) {
            if (capacity < 1) { capacity = 1; }
            kinds = new int[capacity]; values = new long[capacity];
            head = 0; tail = 0; count = 0; dropped = 0;
        }
        public int Capacity() { return kinds.Length; }
        public int Pending() { return count; }
        public int Dropped() { return dropped; }
        public bool Enqueue(int kind, long value) {
            if (kind <= 0 || count == kinds.Length) { dropped = dropped + 1; return false; }
            kinds[head] = kind; values[head] = value;
            head = (head + 1) % kinds.Length; count = count + 1; return true;
        }
        public int PeekKind() { if (count == 0) { return 0; } return kinds[tail]; }
        public long PeekValue() { if (count == 0) { return 0; } return values[tail]; }
        public bool CompleteOne() {
            if (count == 0) { return false; }
            kinds[tail] = 0; values[tail] = 0;
            tail = (tail + 1) % kinds.Length; count = count - 1; return true;
        }
    }
}
