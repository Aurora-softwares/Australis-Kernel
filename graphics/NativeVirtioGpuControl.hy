using Australis.Kernel.Pci;
using Australis.Kernel.Time;

namespace Australis.Kernel.Graphics {
    // Bounded polling modern PCI controlq transport for the boot probe and
    // persistent native scanout.
    public class NativeVirtioGpuControl : IVirtioGpuControl {
        private long bootInfo;
        private IPciConfigAccess pci;
        private int bdf;
        private VirtioPciLayout layout;
        private MmioRegion[] bars;
        private long common;
        private long notify;
        private long deviceConfig;
        private long ringPage;
        private long commandPage;
        private VirtioSplitQueue queue;
        private long cursorRingPage;
        private long cursorCommandPage;
        private long cursorNotify;
        private VirtioSplitQueue cursorQueue;
        private bool cursorReady;
        private bool virglReady;
        private int capsetCount;
        private bool ready;
        private int lastError;
        private int responseLength;

        public NativeVirtioGpuControl() {
            bars = new MmioRegion[6]; ready = false; lastError = 0;
            ringPage = 0; commandPage = 0;
            cursorRingPage = 0; cursorCommandPage = 0;
            cursorNotify = 0; cursorQueue = null; cursorReady = false;
            virglReady = false; capsetCount = 0;
            responseLength = 0;
        }
        public static int FindGpu(IPciConfigAccess config) {
            if (config == null) { return -1; }
            int bdf = 0;
            while (bdf < 65536) {
                long identity = config.Read32(bdf, 0);
                if (identity % 65536 == 6900 &&
                    identity / 65536 % 65536 == 4176) { return bdf; }
                bdf = bdf + 1;
            }
            return -1;
        }
        public bool Ready() { return ready; }
        public int LastError() { return lastError; }
        private bool Fail(int code) { lastError = code; return false; }
        private long Address(VirtioPciCapability capability) {
            if (capability == null || capability.Bar() < 0 ||
                capability.Bar() > 5) { return 0; }
            MmioRegion region = bars[capability.Bar()];
            if (region == null || !region.IsMapped() ||
                capability.Offset() < 0 ||
                capability.Offset() + capability.Length() >
                region.ByteLength()) { return 0; }
            return region.Address() + capability.Offset();
        }
        private bool NeedsBar(int index) {
            return layout.Common().Bar() == index ||
                layout.Notify().Bar() == index ||
                layout.Isr().Bar() == index ||
                layout.Device().Bar() == index;
        }
        private bool MapBars() {
            int i = 0;
            while (i < 6) {
                if (NeedsBar(i)) {
                    PciBarInfo bar = PciBars.Probe(pci, bdf, i);
                    if (!bar.IsValid() || bar.Size() > 65536) {
                        return Fail(2);
                    }
                    bars[i] = MmioMapper.Map(bootInfo, bar.Address(),
                        bar.Size());
                    if (bars[i] == null) { return Fail(3); }
                }
                i = i + 1;
            }
            common = Address(layout.Common());
            notify = Address(layout.Notify());
            deviceConfig = Address(layout.Device());
            if (common == 0 || notify == 0 ||
                Address(layout.Isr()) == 0 ||
                deviceConfig == 0) { return Fail(4); }
            return true;
        }
        private void ConfigureCursorQueue() {
            cursorReady = false;
            if (System.Kernel.Memory.Read16(common + 18) < 2) { return; }
            System.Kernel.Memory.Write16(common + 22, 1);
            if (System.Kernel.Memory.Read16(common + 24) < 2) { return; }
            System.Kernel.Memory.Write16(common + 24, 2);
            System.Kernel.Memory.Write16(common + 26, 65535);
            int queueOffset = System.Kernel.Memory.Read16(common + 30);
            long offset = layout.QueueNotifyOffset(queueOffset);
            if (offset < 0) { return; }
            cursorRingPage = PhysicalPages.AllocateZeroed(bootInfo);
            cursorCommandPage = PhysicalPages.AllocateZeroed(bootInfo);
            if (cursorRingPage == 0 || cursorCommandPage == 0) { return; }
            cursorQueue = new VirtioSplitQueue(2);
            if (!cursorQueue.Ready()) { return; }
            cursorNotify = bars[layout.Notify().Bar()].Address() + offset;
            System.Kernel.Memory.Write64(common + 32, cursorRingPage);
            System.Kernel.Memory.Write64(common + 40, cursorRingPage + 64);
            System.Kernel.Memory.Write64(common + 48, cursorRingPage + 128);
            System.Kernel.Memory.Write16(common + 28, 1);
            cursorReady = true;
        }
        public bool Initialize(long inputBootInfo,
            IPciConfigAccess inputPci, int inputBdf) {
            if (ready || inputBootInfo < 4096 || inputPci == null ||
                inputBdf < 0 || inputBdf > 65535) { return Fail(1); }
            bootInfo = inputBootInfo; pci = inputPci; bdf = inputBdf;
            layout = new VirtioPciLayout(pci, bdf);
            if (!layout.Ready() || !MapBars()) { return false; }
            long command = pci.Read32(bdf, 4);
            int bits = (int)(command % 65536);
            if (bits / 2 % 2 == 0) { command = command + 2; }
            if (bits / 4 % 2 == 0) { command = command + 4; }
            pci.Write32(bdf, 4, command);

            System.Kernel.Memory.Write8(common + 20, 0);
            System.Kernel.Memory.Write8(common + 20, 1);
            System.Kernel.Memory.Write8(common + 20, 3);
            System.Kernel.Memory.Write32(common, 0);
            long lowFeatures = System.Kernel.Memory.Read32(common + 4);
            System.Kernel.Memory.Write32(common, 1);
            long highFeatures = System.Kernel.Memory.Read32(common + 4);
            if (highFeatures % 2 == 0) { return Fail(5); }
            System.Kernel.Memory.Write32(common + 8, 0);
            if (lowFeatures % 2 == 1) {
                System.Kernel.Memory.Write32(common + 12, 1);
            } else {
                System.Kernel.Memory.Write32(common + 12, 0);
            }
            System.Kernel.Memory.Write32(common + 8, 1);
            System.Kernel.Memory.Write32(common + 12, 1);
            System.Kernel.Memory.Write8(common + 20, 11);
            if (System.Kernel.Memory.Read8(common + 20) / 8 % 2 == 0) {
                return Fail(6);
            }
            virglReady = lowFeatures % 2 == 1;
            long reportedCapsets = 0;
            if (layout.Device().Length() >= 16) {
                reportedCapsets = System.Kernel.Memory.Read32(deviceConfig + 12);
            }
            if (virglReady && reportedCapsets > 0 &&
                reportedCapsets <= 64) {
                capsetCount = (int)reportedCapsets;
            }
            if (System.Kernel.Memory.Read16(common + 18) < 1) {
                return Fail(7);
            }
            System.Kernel.Memory.Write16(common + 22, 0);
            int maximum = System.Kernel.Memory.Read16(common + 24);
            if (maximum < 2) { return Fail(8); }
            System.Kernel.Memory.Write16(common + 24, 2);
            System.Kernel.Memory.Write16(common + 26, 65535);
            int queueOffset = System.Kernel.Memory.Read16(common + 30);
            long offset = layout.QueueNotifyOffset(queueOffset);
            if (offset < 0) { return Fail(9); }
            notify = bars[layout.Notify().Bar()].Address() + offset;

            ringPage = PhysicalPages.AllocateZeroed(bootInfo);
            commandPage = PhysicalPages.AllocateZeroed(bootInfo);
            if (ringPage == 0 || commandPage == 0) { return Fail(10); }
            queue = new VirtioSplitQueue(2);
            if (!queue.Ready()) { return Fail(11); }
            System.Kernel.Memory.Write64(common + 32, ringPage);
            System.Kernel.Memory.Write64(common + 40, ringPage + 64);
            System.Kernel.Memory.Write64(common + 48, ringPage + 128);
            System.Kernel.Memory.Write16(common + 28, 1);
            ConfigureCursorQueue();
            System.Kernel.Memory.Write8(common + 20, 15);
            ready = true; lastError = 0;
            responseLength = 0;
            return true;
        }
        public long Response32(int offset) {
            if (!ready || commandPage == 0 || offset < 0 ||
                offset % 4 != 0 || offset + 4 > responseLength) { return -1; }
            return System.Kernel.Memory.Read32(commandPage + 512 + offset);
        }
        public bool CursorAvailable() { return ready && cursorReady; }
        public bool VirglAvailable() { return ready && virglReady; }
        public int CapsetCount() { if (!VirglAvailable()) { return 0; }
            return capsetCount; }
        public bool DisplayChanged() {
            if (!ready || deviceConfig == 0 ||
                System.Kernel.Memory.Read32(deviceConfig) % 2 == 0) {
                return false;
            }
            System.Kernel.Memory.Write32(deviceConfig + 4, 1);
            return true;
        }
        public bool Execute(byte[] request, int requestLength,
            int expectedResponseType) {
            responseLength = 0;
            if (!ready || request == null || requestLength < 24 ||
                requestLength > request.Length || requestLength > 256 ||
                expectedResponseType < 1 || expectedResponseType > 65535 ||
                !queue.Submit(commandPage, requestLength,
                    commandPage + 512, 512)) { return Fail(12); }
            int i = 0;
            while (i < requestLength) {
                System.Kernel.Memory.Write8(commandPage + i, request[i]);
                i = i + 1;
            }
            i = 0;
            while (i < 512) {
                System.Kernel.Memory.Write8(commandPage + 512 + i, 0);
                i = i + 1;
            }
            byte[] descriptors = queue.Descriptors();
            i = 0;
            while (i < 32) {
                System.Kernel.Memory.Write8(ringPage + i,
                    descriptors[i]);
                i = i + 1;
            }
            System.Kernel.Memory.Fence();
            byte[] available = queue.Available();
            System.Kernel.Memory.Write8(ringPage + 64, available[0]);
            System.Kernel.Memory.Write8(ringPage + 65, available[1]);
            i = 4;
            while (i < available.Length) {
                System.Kernel.Memory.Write8(ringPage + 64 + i,
                    available[i]);
                i = i + 1;
            }
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write8(ringPage + 66, available[2]);
            System.Kernel.Memory.Write8(ringPage + 67, available[3]);
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write16(notify, 0);
            long deadline = KernelClock.DeadlineAfter(bootInfo, 1000);
            int expected = (queue.Completed() + 1) % 65536;
            while (System.Kernel.Memory.Read16(ringPage + 130) != expected) {
                if (KernelClock.Expired(deadline) ||
                    System.Kernel.Memory.Read8(common + 20) / 64 % 2 != 0) {
                    ready = false; return Fail(13);
                }
                System.Kernel.Cpu.Pause();
            }
            System.Kernel.Memory.Fence();
            int slot = queue.Completed() % 2;
            int usedId = System.Kernel.Memory.Read32(ringPage + 132 + slot * 8);
            int usedLength = System.Kernel.Memory.Read32(ringPage + 136 + slot * 8);
            if (!queue.Complete(expected, usedId, usedLength) ||
                System.Kernel.Memory.Read32(commandPage + 512) !=
                    expectedResponseType ||
                System.Kernel.Memory.Read32(commandPage + 516) % 2 != 1 ||
                System.Kernel.Memory.Read64(commandPage + 520) !=
                    System.Kernel.Memory.Read64(commandPage + 8)) {
                ready = false; return Fail(14);
            }
            responseLength = usedLength;
            return true;
        }
        public bool ExecuteCursor(byte[] request, int requestLength,
            int expectedResponseType) {
            if (!CursorAvailable() || request == null ||
                requestLength != 56 || requestLength > request.Length ||
                expectedResponseType != 4352 ||
                !cursorQueue.Submit(cursorCommandPage, requestLength,
                    cursorCommandPage + 512, 512)) { return false; }
            int i = 0;
            while (i < requestLength) {
                System.Kernel.Memory.Write8(cursorCommandPage + i,
                    request[i]); i = i + 1;
            }
            i = 0;
            while (i < 512) {
                System.Kernel.Memory.Write8(cursorCommandPage + 512 + i,
                    0); i = i + 1;
            }
            byte[] descriptors = cursorQueue.Descriptors();
            i = 0;
            while (i < 32) {
                System.Kernel.Memory.Write8(cursorRingPage + i,
                    descriptors[i]); i = i + 1;
            }
            System.Kernel.Memory.Fence();
            byte[] available = cursorQueue.Available();
            System.Kernel.Memory.Write8(cursorRingPage + 64, available[0]);
            System.Kernel.Memory.Write8(cursorRingPage + 65, available[1]);
            i = 4;
            while (i < available.Length) {
                System.Kernel.Memory.Write8(cursorRingPage + 64 + i,
                    available[i]); i = i + 1;
            }
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write8(cursorRingPage + 66, available[2]);
            System.Kernel.Memory.Write8(cursorRingPage + 67, available[3]);
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write16(cursorNotify, 1);
            long deadline = KernelClock.DeadlineAfter(bootInfo, 1000);
            int expected = (cursorQueue.Completed() + 1) % 65536;
            while (System.Kernel.Memory.Read16(cursorRingPage + 130) !=
                expected) {
                if (KernelClock.Expired(deadline) ||
                    System.Kernel.Memory.Read8(common + 20) / 64 % 2 != 0) {
                    cursorReady = false; return false;
                }
                System.Kernel.Cpu.Pause();
            }
            System.Kernel.Memory.Fence();
            int slot = cursorQueue.Completed() % 2;
            int usedId = System.Kernel.Memory.Read32(
                cursorRingPage + 132 + slot * 8);
            int usedLength = System.Kernel.Memory.Read32(
                cursorRingPage + 136 + slot * 8);
            if (!cursorQueue.Complete(expected, usedId, usedLength) ||
                System.Kernel.Memory.Read32(cursorCommandPage + 512) !=
                    expectedResponseType ||
                System.Kernel.Memory.Read32(cursorCommandPage + 516) % 2 != 1 ||
                System.Kernel.Memory.Read64(cursorCommandPage + 520) !=
                    System.Kernel.Memory.Read64(cursorCommandPage + 8)) {
                cursorReady = false; return false;
            }
            return true;
        }
        public void Close() {
            if (common != 0) { System.Kernel.Memory.Write8(common + 20, 0); }
            ready = false;
            if (commandPage != 0) {
                PhysicalPages.Free(bootInfo, commandPage); commandPage = 0;
            }
            if (ringPage != 0) {
                PhysicalPages.Free(bootInfo, ringPage); ringPage = 0;
            }
            if (cursorCommandPage != 0) {
                PhysicalPages.Free(bootInfo, cursorCommandPage);
                cursorCommandPage = 0;
            }
            if (cursorRingPage != 0) {
                PhysicalPages.Free(bootInfo, cursorRingPage);
                cursorRingPage = 0;
            }
            int i = 0;
            while (i < bars.Length) {
                if (bars[i] != null) { bars[i].Release(); bars[i] = null; }
                i = i + 1;
            }
            common = 0; notify = 0; deviceConfig = 0;
            cursorNotify = 0; cursorReady = false; cursorQueue = null;
            virglReady = false; capsetCount = 0;
        }
    }
}
