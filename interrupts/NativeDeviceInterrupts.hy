using Australis.Kernel.Events;
namespace Australis.Kernel.Interrupts {
    public class NativeDeviceInterrupts {
        public static int XhciVector() { return 50; }
        public static bool Register(long bootInfo, int owner, long statusAddress, long statusMask) {
            if (bootInfo < 4096 || owner <= 0 || statusAddress < 4096 || statusMask == 0 ||
                System.Kernel.Memory.Read32(bootInfo + 2312) != 0) { return false; }
            System.Kernel.Memory.Write32(bootInfo + 2316, owner);
            System.Kernel.Memory.Write64(bootInfo + 2320, statusAddress);
            System.Kernel.Memory.Write32(bootInfo + 2328, statusMask);
            System.Kernel.Memory.Write32(bootInfo + 2332, 0);
            System.Kernel.Memory.Write32(bootInfo + 2336, 0);
            System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write32(bootInfo + 2312, XhciVector()); return true;
        }
        public static bool Unregister(long bootInfo, int owner) {
            if (bootInfo < 4096 || System.Kernel.Memory.Read32(bootInfo + 2316) != owner) { return false; }
            System.Kernel.Memory.Write32(bootInfo + 2312, 0); System.Kernel.Memory.Fence();
            System.Kernel.Memory.Write32(bootInfo + 2316, 0); System.Kernel.Memory.Write64(bootInfo + 2320, 0);
            System.Kernel.Memory.Write32(bootInfo + 2328, 0); System.Kernel.Memory.Write32(bootInfo + 2336, 0); return true;
        }
        public static bool QueueOne(long bootInfo, KernelEventLoop events) {
            if (bootInfo < 4096 || events == null) { return false; }
            int pending = System.Kernel.Memory.Read32(bootInfo + 2336); if (pending <= 0) { return false; }
            int owner = System.Kernel.Memory.Read32(bootInfo + 2316);
            long status = System.Kernel.Memory.Read32(bootInfo + 2332);
            if (!events.Enqueue(owner, status)) {
                System.Kernel.Memory.Write32(bootInfo + 2340, System.Kernel.Memory.Read32(bootInfo + 2340) + 1); return false;
            }
            System.Kernel.Memory.Write32(bootInfo + 2336, pending - 1); return true;
        }
    }
}
