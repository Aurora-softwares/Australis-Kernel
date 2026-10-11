namespace Australis.Kernel.Console {
    // The PC-compatible 16550 at COM1 uses receive-data interrupts on legacy
    // PIC IRQ4. The interrupt drains the FIFO into a fixed ring; the shell
    // consumes that ring, keeping the handler allocation-free and safe at any
    // instruction.
    public class SerialPort : IConsoleInput, IConsoleByteSink {
        private int basePort;
        private long bootInfo;
        private bool ready;
        private bool receiveInterrupts;

        public SerialPort(int inputBasePort, long inputBootInfo) {
            basePort = inputBasePort;
            bootInfo = inputBootInfo;
            ready = false;
            receiveInterrupts = false;
        }

        public bool Initialize() {
            if (basePort < 0 || basePort > 65528 || bootInfo < 4096) { return false; }
            int scratch = System.Kernel.Port.Read8(basePort + 7);
            System.Kernel.Port.Write8(basePort + 7, 90);
            bool present = System.Kernel.Port.Read8(basePort + 7) == 90;
            System.Kernel.Port.Write8(basePort + 7, scratch);
            if (!present) { return false; }

            System.Kernel.Port.Write8(basePort + 1, 0);   // no UART IRQs during setup
            System.Kernel.Port.Write8(basePort + 3, 128); // divisor latch
            System.Kernel.Port.Write8(basePort, 1);       // 115200 baud
            System.Kernel.Port.Write8(basePort + 1, 0);
            System.Kernel.Port.Write8(basePort + 3, 3);   // 8 data, no parity, 1 stop
            System.Kernel.Port.Write8(basePort + 2, 199); // FIFO on, clear RX/TX
            System.Kernel.Port.Write8(basePort + 4, 3);   // DTR and RTS
            ready = System.Kernel.Port.Read8(basePort + 5) != 255;
            if (!ready) { return false; }

            // Clear a stale interrupt cause before exposing the PIC line, then
            // enable receiver-data-available only. Transmit interrupts remain
            // off because writes use bounded polling.
            // The IDT's IRQ4 handler owns this bounded 1024-byte ring. Clear
            // cursors before exposing receive interrupts to the PIC.
            System.Kernel.Memory.Write32(bootInfo + 1168, 0);
            System.Kernel.Memory.Write32(bootInfo + 1172, 0);
            System.Kernel.Memory.Write32(bootInfo + 1176, 0);
            int interruptCause = System.Kernel.Port.Read8(basePort + 2);
            System.Kernel.Port.Write8(basePort + 1, 1);
            int masterMask = System.Kernel.Port.Read8(33);
            if ((masterMask / 16) % 2 != 0) { masterMask = masterMask - 16; }
            System.Kernel.Port.Write8(33, masterMask); // unmask COM1 / IRQ4
            receiveInterrupts = true;
            return ready;
        }

        public bool IsReady() { return ready; }
        public bool ReceiveInterruptsEnabled() { return receiveInterrupts; }
        public int DroppedBytes() { return System.Kernel.Memory.Read32(bootInfo + 1176); }
        public bool CanHalt() { return true; }

        public bool WriteByte(int value) {
            if (!ready || value < 0 || value > 255) { return false; }
            int attempts = 0;
            while (attempts < 1000000) {
                int status = System.Kernel.Port.Read8(basePort + 5);
                if (status == 255) { ready = false; return false; }
                if ((status / 32) % 2 != 0) {
                    System.Kernel.Port.Write8(basePort, value);
                    return true;
                }
                System.Kernel.Cpu.Pause();
                attempts = attempts + 1;
            }
            return false;
        }

        // -1 means the IRQ-fed ring is empty; -2 means the UART disappeared.
        public int PollByte() {
            if (!ready) { return -2; }
            int tail = System.Kernel.Memory.Read32(bootInfo + 1172);
            int head = System.Kernel.Memory.Read32(bootInfo + 1168);
            if (tail < 0 || tail > 1023 || head < 0 || head > 1023) { ready = false; return -2; }
            if (tail == head) { return -1; }
            int value = System.Kernel.Memory.Read8(bootInfo + 1280 + tail);
            tail = (tail + 1) % 1024;
            System.Kernel.Memory.Write32(bootInfo + 1172, tail);
            return value;
        }
    }
}
