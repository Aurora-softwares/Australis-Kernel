namespace Australis.Kernel.Time {
    public class KernelClock {
        private static long TicksPerMillisecondOffset() { return 2344; }
        private static long CalibrationStateOffset() { return 2352; }
        public static bool Calibrate(long bootInfo) {
            if (bootInfo < 4096) { return false; }
            int original = System.Kernel.Port.Read8(97);
            int disabled = original - original % 4;
            System.Kernel.Port.Write8(97, disabled);
            System.Kernel.Port.Write8(67, 176);
            int count = 59659;
            System.Kernel.Port.Write8(66, count % 256);
            System.Kernel.Port.Write8(66, count / 256);
            long start = System.Kernel.Cpu.Timestamp();
            System.Kernel.Port.Write8(97, disabled + 1);
            int polls = 0;
            while ((System.Kernel.Port.Read8(97) / 32) % 2 == 0 && polls < 20000000) {
                System.Kernel.Cpu.Pause(); polls = polls + 1;
            }
            long finish = System.Kernel.Cpu.Timestamp();
            System.Kernel.Port.Write8(97, original);
            if (polls == 20000000 || finish <= start || (finish - start) / 50 <= 0) {
                System.Kernel.Memory.Write32(bootInfo + CalibrationStateOffset(), 2); return false;
            }
            System.Kernel.Memory.Write64(bootInfo + TicksPerMillisecondOffset(), (finish - start) / 50);
            System.Kernel.Memory.Write32(bootInfo + CalibrationStateOffset(), 1); return true;
        }
        public static long Now() { return System.Kernel.Cpu.Timestamp(); }
        public static long DeadlineAfter(long bootInfo, int milliseconds) {
            long scale = System.Kernel.Memory.Read64(bootInfo + TicksPerMillisecondOffset());
            if (scale <= 0 || milliseconds < 1) { return 0; }
            long now = Now(); long delta = scale * milliseconds;
            if (delta < scale) { return 0; }
            long deadline = now + delta; if (deadline < now) { return 0; }
            return deadline;
        }
        public static bool Expired(long deadline) { return deadline <= 0 || Now() >= deadline; }
    }
}
