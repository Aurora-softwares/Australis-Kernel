using Australis.Kernel.Pci;

namespace Australis.Kernel.Graphics {
    // Modern VirtIO PCI capability locations. BAR mapping and device startup
    // are separate so a missing GPU cannot affect the GOP display path.
    public class VirtioPciCapability {
        private int bar;
        private long offset;
        private long length;
        private long multiplier;
        public VirtioPciCapability(int inputBar, long inputOffset,
            long inputLength, long inputMultiplier) {
            bar = inputBar; offset = inputOffset; length = inputLength;
            multiplier = inputMultiplier;
        }
        public int Bar() { return bar; }
        public long Offset() { return offset; }
        public long Length() { return length; }
        public long NotifyMultiplier() { return multiplier; }
    }

    public class VirtioPciLayout {
        private VirtioPciCapability common;
        private VirtioPciCapability notify;
        private VirtioPciCapability isr;
        private VirtioPciCapability device;
        private bool validDevice;
        public VirtioPciLayout(IPciConfigAccess config, int bdf) {
            validDevice = false;
            if (config == null || bdf < 0 || bdf > 65535) { return; }
            long identity = config.Read32(bdf, 0);
            // PCI vendor 1AF4, modern VirtIO GPU device 1050.
            if (identity % 65536 != 6900 ||
                identity / 65536 % 65536 != 4176) { return; }
            validDevice = true;
            int pointer = Byte(config, bdf, 52);
            bool[] visited = new bool[256];
            int steps = 0;
            while (pointer >= 64 && pointer <= 252 &&
                pointer % 4 == 0 && steps < 48 && !visited[pointer]) {
                visited[pointer] = true; steps = steps + 1;
                int next = Byte(config, bdf, pointer + 1);
                int length = Byte(config, bdf, pointer + 2);
                int kind = Byte(config, bdf, pointer + 3);
                if (Byte(config, bdf, pointer) == 9 && length >= 16 &&
                    pointer + length <= 256) {
                    int bar = Byte(config, bdf, pointer + 4);
                    long offset = config.Read32(bdf, pointer + 8);
                    long range = config.Read32(bdf, pointer + 12);
                    long multiplier = 0;
                    if (kind == 2 && length >= 20) {
                        multiplier = config.Read32(bdf, pointer + 16);
                    }
                    if (bar <= 5 && range > 0 &&
                        offset >= 0 && offset + range <=
                        (long)65536 * 65536) {
                        VirtioPciCapability capability =
                            new VirtioPciCapability(bar, offset, range,
                                multiplier);
                        if (kind == 1 && common == null && range >= 56 &&
                            offset % 4 == 0) { common = capability; }
                        if (kind == 2 && notify == null && length >= 20 &&
                            range >= 2) { notify = capability; }
                        if (kind == 3 && isr == null) { isr = capability; }
                        if (kind == 4 && device == null &&
                            offset % 4 == 0) { device = capability; }
                    }
                }
                pointer = next;
            }
        }
        private static int Byte(IPciConfigAccess config, int bdf,
            int offset) {
            long word = config.Read32(bdf, offset - offset % 4);
            int shift = offset % 4;
            while (shift > 0) { word = word / 256; shift = shift - 1; }
            return (int)(word % 256);
        }
        public bool IsGpu() { return validDevice; }
        public bool Ready() {
            return validDevice && common != null && notify != null &&
                isr != null && device != null;
        }
        public VirtioPciCapability Common() { return common; }
        public VirtioPciCapability Notify() { return notify; }
        public VirtioPciCapability Isr() { return isr; }
        public VirtioPciCapability Device() { return device; }
        public long QueueNotifyOffset(int queueOffset) {
            if (!Ready() || queueOffset < 0 ||
                queueOffset > 65535) { return -1; }
            long position = (long)queueOffset * notify.NotifyMultiplier();
            if (position + 2 > notify.Length()) { return -1; }
            return notify.Offset() + position;
        }
    }

    // Split-ring bookkeeping for a single synchronous request/response pair.
    // The caller owns coherent DMA storage and copies these ring bytes to it.
    public class VirtioSplitQueue {
        private int depth;
        private byte[] descriptors;
        private byte[] available;
        private byte[] used;
        private int submitted;
        private int completed;
        private int responseLength;
        private bool busy;
        public VirtioSplitQueue(int inputDepth) {
            depth = inputDepth;
            int remaining = depth;
            while (remaining > 1 && remaining % 2 == 0) {
                remaining = remaining / 2;
            }
            if (depth < 2 || depth > 128 || remaining != 1) {
                depth = 0; return;
            }
            descriptors = new byte[depth * 16];
            available = new byte[6 + depth * 2];
            used = new byte[6 + depth * 8];
            submitted = 0; completed = 0; busy = false;
        }
        private void Write16(byte[] bytes, int offset, int value) {
            bytes[offset] = (byte)(value % 256);
            bytes[offset + 1] = (byte)(value / 256 % 256);
        }
        private void Write32(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 4) {
                bytes[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        private void Write64(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 8) {
                bytes[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        public bool Ready() { return depth > 0; }
        public byte[] Descriptors() { return descriptors; }
        public byte[] Available() { return available; }
        public byte[] Used() { return used; }
        public int Submitted() { return submitted; }
        public int Completed() { return completed; }
        public bool Busy() { return busy; }
        public bool Submit(long requestAddress, int requestBytes,
            long responseAddress, int responseBytes) {
            if (!Ready() || busy || requestAddress < 4096 ||
                responseAddress < 4096 || requestBytes < 1 ||
                responseBytes < 24 || requestBytes > 65536 ||
                responseBytes > 65536) { return false; }
            Write64(descriptors, 0, requestAddress);
            Write32(descriptors, 8, requestBytes);
            Write16(descriptors, 12, 1); // NEXT
            Write16(descriptors, 14, 1);
            Write64(descriptors, 16, responseAddress);
            Write32(descriptors, 24, responseBytes);
            Write16(descriptors, 28, 2); // WRITE
            Write16(descriptors, 30, 0);
            Write16(available, 4 + (submitted % depth) * 2, 0);
            submitted = (submitted + 1) % 65536;
            Write16(available, 2, submitted);
            responseLength = responseBytes; busy = true;
            return true;
        }
        public bool Complete(int usedIndex, int descriptorId,
            int writtenBytes) {
            if (!busy || usedIndex != (completed + 1) % 65536 ||
                descriptorId != 0 || writtenBytes < 24 ||
                writtenBytes > responseLength) { return false; }
            int entry = 4 + (completed % depth) * 8;
            Write32(used, entry, descriptorId);
            Write32(used, entry + 4, writtenBytes);
            completed = usedIndex;
            Write16(used, 2, completed);
            busy = false;
            return true;
        }
    }
}
