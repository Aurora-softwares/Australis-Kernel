namespace Australis.Kernel.Usb {
    // These interfaces keep the protocol code independent of the current boot
    // image builder. A freestanding port-I/O and MMIO backend is still needed.
    public interface IPciConfig {
        long Read32(int bus, int device, int function, int offset);
    }

    public interface IXhciRegisters {
        int Read32(int offset);
        void Write32(int offset, int value);
        void Pause();
    }

    public interface IUsbBulkTransport {
        // Return the actual byte count, or -1 on transfer failure.
        int BulkOut(byte[] data, int length);
        int BulkIn(byte[] data, int length);
        void ResetRecovery();
    }

    public class PciUsb {
        // Return bus:device.function packed as (bus * 256 + device * 8 + function).
        public static int FindXhci(IPciConfig pci) {
            int bus = 0;
            while (bus < 256) {
                int device = 0;
                while (device < 32) {
                    long id = pci.Read32(bus, device, 0, 0);
                    if (id % 65536 != 65535) {
                        long header = pci.Read32(bus, device, 0, 12);
                        int functions = 1;
                        if ((header / 8388608) % 2 != 0) { functions = 8; }
                        int function = 0;
                        while (function < functions) {
                            id = pci.Read32(bus, device, function, 0);
                            if (id % 65536 != 65535) {
                                long code = pci.Read32(bus, device, function, 8);
                                if ((code / 256) % 16777216 == 787248) {
                                    return bus * 256 + device * 8 + function;
                                }
                            }
                            function = function + 1;
                        }
                    }
                    device = device + 1;
                }
                bus = bus + 1;
            }
            return -1;
        }

        // PCI BAR0 must describe MMIO, not an I/O port BAR.
        public static bool HasMemoryBar(long bar0) {
            return bar0 % 2 == 0 && bar0 != 0 && bar0 != UsbMassStorage.MaxU32();
        }

        public static bool Has64BitBar(long bar0) {
            return HasMemoryBar(bar0) && (bar0 / 2) % 4 == 2;
        }
    }

    public class XhciController {
        // Reset is bounded. It leaves the controller halted; DMA rings, device
        // contexts, and port enumeration must be installed before Run/Stop=1.
        public static bool StopAndReset(IXhciRegisters io, int capabilityLength) {
            if (capabilityLength < 32 || capabilityLength > 252) { return false; }
            int command = capabilityLength;
            int status = capabilityLength + 4;
            int attempt = 0;
            while (attempt < 100000 && (io.Read32(status) / 2048) % 2 != 0) {
                io.Pause();
                attempt = attempt + 1;
            }
            if (attempt == 100000) { return false; }
            int value = io.Read32(command);
            if (value % 2 != 0) { io.Write32(command, value - 1); }
            attempt = 0;
            while (attempt < 100000 && io.Read32(status) % 2 == 0) {
                io.Pause();
                attempt = attempt + 1;
            }
            if (attempt == 100000) { return false; }
            value = io.Read32(command);
            if ((value / 2) % 2 == 0) { io.Write32(command, value + 2); }
            attempt = 0;
            while (attempt < 100000 && (io.Read32(command) / 2) % 2 != 0) {
                io.Pause();
                attempt = attempt + 1;
            }
            if (attempt == 100000) { return false; }
            attempt = 0;
            while (attempt < 100000 && (io.Read32(status) / 2048) % 2 != 0) {
                io.Pause();
                attempt = attempt + 1;
            }
            return attempt < 100000;
        }

        public static int CapabilityLength(byte[] capabilities) {
            if (capabilities.Length < 32) { return 0; }
            return capabilities[0];
        }

        public static int MaxSlots(byte[] capabilities) {
            if (capabilities.Length < 8) { return 0; }
            return capabilities[4];
        }
    }

    public class UsbDescriptors {
        // Return the offset of an interface descriptor in a complete, bounded
        // configuration descriptor; -1 also covers malformed descriptor chains.
        public static int FindInterface(byte[] data, int length, int deviceClass, int subclass, int protocol) {
            if (length < 9 || length > data.Length || data[1] != 2) { return -1; }
            int total = data[2] + data[3] * 256;
            if (total < 9 || total > length) { return -1; }
            int offset = 0;
            while (offset + 2 <= total) {
                int size = data[offset];
                if (size < 2 || offset + size > total) { return -1; }
                if (data[offset + 1] == 4 && size >= 9 &&
                    data[offset + 5] == deviceClass && data[offset + 6] == subclass &&
                    data[offset + 7] == protocol) { return offset; }
                offset = offset + size;
            }
            return -1;
        }

        // Endpoint address, or -1. direction is 0 for OUT and 1 for IN;
        // transferType is 2 for bulk or 3 for interrupt.
        public static int FindEndpointOffset(byte[] data, int length, int interfaceOffset, int direction, int transferType) {
            if (interfaceOffset < 0 || interfaceOffset + 9 > length || data[interfaceOffset + 1] != 4) { return -1; }
            int total = data[2] + data[3] * 256;
            if (total > length) { return -1; }
            int offset = interfaceOffset + data[interfaceOffset];
            while (offset + 2 <= total) {
                int size = data[offset];
                if (size < 2 || offset + size > total) { return -1; }
                if (data[offset + 1] == 4) { return -1; }
                if (data[offset + 1] == 5 && size >= 7) {
                    int address = data[offset + 2];
                    if ((address / 128) % 2 == direction && data[offset + 3] % 4 == transferType) { return offset; }
                }
                offset = offset + size;
            }
            return -1;
        }

        public static int FindEndpoint(byte[] data, int length, int interfaceOffset, int direction, int transferType) {
            int offset = FindEndpointOffset(data, length, interfaceOffset, direction, transferType);
            if (offset < 0) { return -1; }
            return data[offset + 2];
        }

        public static int ConfigurationValue(byte[] data, int length) {
            if (length < 9 || length > data.Length || data[0] < 9 || data[1] != 2) { return -1; }
            return data[5];
        }

        public static int InterfaceNumber(byte[] data, int length, int interfaceOffset) {
            if (interfaceOffset < 0 || interfaceOffset + 9 > length || data[interfaceOffset] < 9 ||
                data[interfaceOffset + 1] != 4) { return -1; }
            return data[interfaceOffset + 2];
        }

        public static int EndpointMaxPacket(byte[] data, int length, int endpointOffset) {
            if (endpointOffset < 0 || endpointOffset + 7 > length || data[endpointOffset] < 7 ||
                data[endpointOffset + 1] != 5) { return -1; }
            int low = data[endpointOffset + 4];
            int high = data[endpointOffset + 5];
            return low + high * 256;
        }

        public static int EndpointInterval(byte[] data, int length, int endpointOffset) {
            if (endpointOffset < 0 || endpointOffset + 7 > length || data[endpointOffset] < 7 ||
                data[endpointOffset + 1] != 5) { return -1; }
            return data[endpointOffset + 6];
        }
    }

    // Pure xHCI TRB helpers are shared by host tests and the native driver.
    // Keeping the field arithmetic here makes cycle and event decoding testable
    // without exposing controller MMIO to the hosted test process.
    public class XhciTrb {
        public static int Type(long control) { return (int)(control / 1024 % 64); }
        public static int Cycle(long control) { return (int)(control % 2); }
        public static int CompletionCode(long status) { return (int)(status / 16777216 % 256); }
        public static int TransferLength(long status) { return (int)(status % 16777216); }
        public static int EndpointId(long control) { return (int)(control / 65536 % 32); }
        public static int SlotId(long control) { return (int)(control / 16777216 % 256); }
        public static long Control(int type, int cycle) {
            if (type < 0 || type > 63 || (cycle != 0 && cycle != 1)) { return 0; }
            return type * 1024 + cycle;
        }
    }

    public class UsbMassStorage {
        public static long MaxU32() {
            long max = 2147483647;
            return max * 2 + 1;
        }
        private static void Write32(byte[] data, int offset, long value) {
            int i = 0;
            while (i < 4) {
                data[offset + i] = (byte)(value % 256);
                value = value / 256;
                i = i + 1;
            }
        }

        private static long Read32(byte[] data, int offset) {
            long a = data[offset];
            long b = data[offset + 1];
            long c = data[offset + 2];
            long d = data[offset + 3];
            return a + b * 256 + c * 65536 + d * 16777216;
        }

        // USB MSC Bulk-Only Transport CBW: 31 bytes, CDB padded to 16 bytes.
        public static bool BuildCbw(byte[] cbw, long tag, long transferBytes, bool dataIn, int lun, byte[] cdb, int cdbLength) {
            if (cbw.Length < 31 || tag < 0 || tag > MaxU32() ||
                transferBytes < 0 || transferBytes > MaxU32() ||
                lun < 0 || lun > 15 || cdbLength < 1 || cdbLength > 16 || cdbLength > cdb.Length) { return false; }
            int i = 0;
            while (i < 31) { cbw[i] = 0; i = i + 1; }
            Write32(cbw, 0, 1128420181);
            Write32(cbw, 4, tag);
            Write32(cbw, 8, transferBytes);
            if (dataIn) { cbw[12] = 128; }
            cbw[13] = (byte)lun;
            cbw[14] = (byte)cdbLength;
            i = 0;
            while (i < cdbLength) { cbw[15 + i] = cdb[i]; i = i + 1; }
            return true;
        }

        // 0 success, 1 command failed, 2 phase error, -1 invalid/stale CSW.
        public static int CheckCsw(byte[] csw, int actualLength, long expectedTag) {
            if (actualLength != 13 || csw.Length < 13 || expectedTag < 0 || expectedTag > MaxU32() ||
                Read32(csw, 0) != 1396855637 || Read32(csw, 4) != expectedTag || csw[12] > 2) { return -1; }
            return csw[12];
        }

        public static bool BuildRead10(byte[] cdb, long lba, int blocks) {
            if (cdb.Length < 10 || lba < 0 || lba > MaxU32() || blocks < 1 || blocks > 65535) { return false; }
            int i = 0;
            while (i < 10) { cdb[i] = 0; i = i + 1; }
            cdb[0] = 40;
            cdb[2] = (byte)((lba / 16777216) % 256);
            cdb[3] = (byte)((lba / 65536) % 256);
            cdb[4] = (byte)((lba / 256) % 256);
            cdb[5] = (byte)(lba % 256);
            cdb[7] = (byte)(blocks / 256);
            cdb[8] = (byte)(blocks % 256);
            return true;
        }


        // One synchronous BOT READ(10) transaction. The caller owns the LUN,
        // block size, unique tag and endpoint transport. No partial data is
        // reported as a successful block read.
        public static bool ReadBlocks(IUsbBulkTransport transport, int lun, long lba,
            int blocks, int blockSize, long tag, byte[] destination) {
            if (transport == null || destination == null || blockSize < 1 || blocks < 1 || blocks > 65535 ||
                blocks > destination.Length / blockSize) { return false; }
            int bytes = blocks * blockSize;
            byte[] cdb = new byte[10];
            byte[] cbw = new byte[31];
            if (!BuildRead10(cdb, lba, blocks) || !BuildCbw(cbw, tag, bytes, true, lun, cdb, 10)) { return false; }
            if (transport.BulkOut(cbw, 31) != 31) { transport.ResetRecovery(); return false; }
            byte[] staged = new byte[bytes];
            if (transport.BulkIn(staged, bytes) != bytes) { transport.ResetRecovery(); return false; }
            byte[] csw = new byte[13];
            int statusLength = transport.BulkIn(csw, 13);
            int result = CheckCsw(csw, statusLength, tag);
            if (result == 1) { return false; }
            if (result != 0 || Read32(csw, 8) != 0) {
                transport.ResetRecovery();
                return false;
            }
            int i = 0;
            while (i < bytes) { destination[i] = staged[i]; i = i + 1; }
            return true;
        }
    }

    public class UsbHidBoot {
        // Return a newly pressed HID usage; zero means no new key. Rollover
        // usages 1..3 are deliberately ignored.
        public static int NewKey(byte[] previous, byte[] current) {
            if (previous.Length < 8 || current.Length < 8) { return 0; }
            int i = 2;
            while (i < 8) {
                int key = current[i];
                if (key > 3) {
                    bool seen = false;
                    int j = 2;
                    while (j < 8) { if (previous[j] == key) { seen = true; } j = j + 1; }
                    if (!seen) { return key; }
                }
                i = i + 1;
            }
            return 0;
        }

        // US layout for the boot keyboard's printable keys and basic editing.
        // modifier is report byte 0; Caps Lock and non-US layouts need a later
        // keymap layer rather than changes to the HID usage decoder.
        public static int UsAscii(int usage, int modifiers) {
            bool shift = (modifiers / 2) % 2 != 0 || (modifiers / 32) % 2 != 0;
            if (usage >= 4 && usage <= 29) {
                if (shift) { return 65 + usage - 4; }
                return 97 + usage - 4;
            }
            if (usage >= 30 && usage <= 38) {
                if (shift) {
                    if (usage == 30) { return 33; }
                    if (usage == 31) { return 64; }
                    if (usage == 32) { return 35; }
                    if (usage == 33) { return 36; }
                    if (usage == 34) { return 37; }
                    if (usage == 35) { return 94; }
                    if (usage == 36) { return 38; }
                    if (usage == 37) { return 42; }
                    return 40;
                }
                return 49 + usage - 30;
            }
            if (usage == 39) { if (shift) { return 41; } return 48; }
            if (usage == 40) { return 13; }
            if (usage == 42) { return 8; }
            if (usage == 43) { return 9; }
            if (usage == 44) { return 32; }
            if (usage == 45) { if (shift) { return 95; } return 45; }
            if (usage == 46) { if (shift) { return 43; } return 61; }
            if (usage == 47) { if (shift) { return 123; } return 91; }
            if (usage == 48) { if (shift) { return 125; } return 93; }
            if (usage == 49) { if (shift) { return 124; } return 92; }
            if (usage == 51) { if (shift) { return 58; } return 59; }
            if (usage == 52) { if (shift) { return 34; } return 39; }
            if (usage == 53) { if (shift) { return 126; } return 96; }
            if (usage == 54) { if (shift) { return 60; } return 44; }
            if (usage == 55) { if (shift) { return 62; } return 46; }
            if (usage == 56) { if (shift) { return 63; } return 47; }
            return 0;
        }

        public static int MouseButtons(byte[] report) { if (report.Length < 3) { return 0; } return report[0]; }
        public static int MouseX(byte[] report) { if (report.Length < 3) { return 0; } int x = report[1]; if (x >= 128) { return x - 256; } return x; }
        public static int MouseY(byte[] report) { if (report.Length < 3) { return 0; } int y = report[2]; if (y >= 128) { return y - 256; } return y; }
    }
}
