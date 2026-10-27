using Australis.Kernel.Console;
using Australis.Kernel.Dma;
using Australis.Kernel.Interrupts;
using Australis.Kernel.Storage;
using Australis.Kernel.Time;

namespace Australis.Kernel.Usb {
    // Each root device owns its contexts, transfer rings and event queues.
    public class NativeXhciDevice {
        public long inputContext;
        public long deviceContext;
        public long ep0Ring;
        public long keyboardRing;
        public long bulkInRing;
        public long descriptorBuffer;
        public long reportBuffer;
        public long transferBuffer;
        public int ep0Index;
        public int ep0Cycle;
        public int keyboardIndex;
        public int keyboardCycle;
        public int bulkOutIndex;
        public int bulkOutCycle;
        public int bulkInIndex;
        public int bulkInCycle;
        public int port;
        public int slot;
        public int speed;
        public int endpointId;
        public int maxPacket;
        public int bulkOutEndpoint;
        public int bulkInEndpoint;
        public int bulkInterface;
        public int bulkOutPacket;
        public int bulkInPacket;
        public int lastTransferCode;
        public int lastTransferEndpoint;
        public int lastTransferResidual;
        public long lastTransferPointer;
        public bool transferComplete;
        public bool keyboardReady;
        public bool mouseReady;
        public bool storageReady;
        public bool reportPending;
        public byte[] previousReport;
        public UsbMouseQueue mouseEvents;
        public int[] keyboardBuffers;
        public int[] bytes;
        public int byteHead;
        public int byteTail;
        public int dropped;
        public int heldUsage;
        public int heldModifiers;
        public long repeatDeadline;
        public int deviceKind;
        public int storageSectorSize;
        public long storageSectorCount;
        public long botTag;
        public NativeXhciDevice() {
            previousReport = new byte[8]; mouseEvents = new UsbMouseQueue();
            keyboardBuffers = new int[255]; bytes = new int[64];
        }
    }
    // One-controller, two-root-device xHCI owner. All controller events are
    // consumed here in normal context. Vector 0x32 only records and
    // acknowledges the interrupter, so command execution never enters an IRQ.
    public class NativeXhci : IConsoleInput, IUsbBulkTransport, IBlockTransport {
        private long bootInfo;
        private int bdf;
        private long mmio;
        private long mmioLength;
        private int capabilityLengthOverride;
        private DmaAllocator allocator;
        private DmaAllocation memory;
        private DmaAllocation extraMemory;
        private NativeXhciDevice[] devices;
        private int activeIndex;
        private int maxDevices;
        private bool initializing;
        private long dma;
        private int dmaPages;
        private long commandRing;
        private long eventRing;
        private long erst;
        private long inputContext;
        private long deviceContext;
        private long ep0Ring;
        private long keyboardRing;
        private long bulkInRing;
        private long descriptorBuffer;
        private long reportBuffer;
        private long transferBuffer;
        private long operational;
        private long runtime;
        private long doorbells;
        private int commandIndex;
        private int commandCycle;
        private int eventIndex;
        private int eventCycle;
        private int ep0Index;
        private int ep0Cycle;
        private int keyboardIndex;
        private int keyboardCycle;
        private int bulkOutIndex;
        private int bulkOutCycle;
        private int bulkInIndex;
        private int bulkInCycle;
        private int port;
        private int slot;
        private int speed;
        private int endpointId;
        private int maxPacket;
        private int bulkOutEndpoint;
        private int bulkInEndpoint;
        private int bulkInterface;
        private int bulkOutPacket;
        private int bulkInPacket;
        private int lastCommandCode;
        private int lastCommandSlot;
        private long lastCommandPointer;
        private int lastTransferCode;
        private int lastTransferEndpoint;
        private int lastTransferResidual;
        private long lastTransferPointer;
        private bool transferComplete;
        private bool keyboardReady;
        private bool mouseReady;
        private bool storageReady;
        private bool reportPending;
        private byte[] previousReport;
        private UsbMouseQueue mouseEvents;
        private int[] keyboardBuffers;
        private int[] bytes;
        private int byteHead;
        private int byteTail;
        private int dropped;
        private long lastDelivery;
        private int heldUsage;
        private int heldModifiers;
        private long repeatDeadline;
        private bool recoveryNeeded;
        private bool recovering;
        private int recoveryAttempts;
        private int recoveryFailures;
        private int deviceKind;
        private int storageSectorSize;
        private long storageSectorCount;
        private long botTag;

        public NativeXhci(long inputBootInfo, int inputBdf, long inputMmio,
            long inputLength, DmaAllocator inputAllocator) {
            bootInfo = inputBootInfo; bdf = inputBdf; mmio = inputMmio;
            mmioLength = inputLength; allocator = inputAllocator; memory = null; dma = 0; dmaPages = 0;
            capabilityLengthOverride = 0;
            extraMemory = null; devices = new NativeXhciDevice[2];
            devices[0] = new NativeXhciDevice();
            devices[1] = new NativeXhciDevice();
            activeIndex = -1; maxDevices = 1; initializing = false;
            commandIndex = 0; commandCycle = 1; eventIndex = 0; eventCycle = 1;
            ep0Index = 0; ep0Cycle = 1; keyboardIndex = 0; keyboardCycle = 1;
            bulkOutIndex = 0; bulkOutCycle = 1; bulkInIndex = 0; bulkInCycle = 1;
            port = 0; slot = 0; speed = 0; endpointId = 0; maxPacket = 0;
            bulkOutEndpoint = 0; bulkInEndpoint = 0; bulkInterface = 0;
            bulkOutPacket = 0; bulkInPacket = 0;
            lastCommandCode = 0; lastCommandSlot = 0; lastCommandPointer = 0;
            lastTransferCode = 0; lastTransferEndpoint = 0; lastTransferResidual = 0;
            lastTransferPointer = 0; transferComplete = false;
            keyboardReady = false; mouseReady = false; storageReady = false; reportPending = false;
            previousReport = new byte[8]; mouseEvents = new UsbMouseQueue();
            keyboardBuffers = new int[255]; bytes = new int[64];
            byteHead = 0; byteTail = 0; dropped = 0; lastDelivery = 0;
            heldUsage = 0; heldModifiers = 0; repeatDeadline = 0;
            recoveryNeeded = false; recovering = false; recoveryAttempts = 0; recoveryFailures = 0;
            deviceKind = 0; storageSectorSize = 0; storageSectorCount = 0; botTag = 1;
        }

        // A matched AUDR module may supply the xHCI capability length. If no
        // module succeeds, Initialize reads the register itself as before.
        public void UseCapabilityLength(int length) {
            if (length == 0 || (length >= 32 && length <= 252)) {
                capabilityLengthOverride = length;
            }
        }

        private void SaveActive() {
            if (activeIndex < 0 || devices[activeIndex] == null) { return; }
            NativeXhciDevice device = devices[activeIndex];
            device.inputContext = inputContext;
            device.deviceContext = deviceContext;
            device.ep0Ring = ep0Ring;
            device.keyboardRing = keyboardRing;
            device.bulkInRing = bulkInRing;
            device.descriptorBuffer = descriptorBuffer;
            device.reportBuffer = reportBuffer;
            device.transferBuffer = transferBuffer;
            device.ep0Index = ep0Index;
            device.ep0Cycle = ep0Cycle;
            device.keyboardIndex = keyboardIndex;
            device.keyboardCycle = keyboardCycle;
            device.bulkOutIndex = bulkOutIndex;
            device.bulkOutCycle = bulkOutCycle;
            device.bulkInIndex = bulkInIndex;
            device.bulkInCycle = bulkInCycle;
            device.port = port;
            device.slot = slot;
            device.speed = speed;
            device.endpointId = endpointId;
            device.maxPacket = maxPacket;
            device.bulkOutEndpoint = bulkOutEndpoint;
            device.bulkInEndpoint = bulkInEndpoint;
            device.bulkInterface = bulkInterface;
            device.bulkOutPacket = bulkOutPacket;
            device.bulkInPacket = bulkInPacket;
            device.lastTransferCode = lastTransferCode;
            device.lastTransferEndpoint = lastTransferEndpoint;
            device.lastTransferResidual = lastTransferResidual;
            device.lastTransferPointer = lastTransferPointer;
            device.transferComplete = transferComplete;
            device.keyboardReady = keyboardReady;
            device.mouseReady = mouseReady;
            device.storageReady = storageReady;
            device.reportPending = reportPending;
            device.previousReport = previousReport;
            device.mouseEvents = mouseEvents;
            device.keyboardBuffers = keyboardBuffers;
            device.bytes = bytes;
            device.byteHead = byteHead;
            device.byteTail = byteTail;
            device.dropped = dropped;
            device.heldUsage = heldUsage;
            device.heldModifiers = heldModifiers;
            device.repeatDeadline = repeatDeadline;
            device.deviceKind = deviceKind;
            device.storageSectorSize = storageSectorSize;
            device.storageSectorCount = storageSectorCount;
            device.botTag = botTag;
        }
        private void SwitchTo(int index) {
            if (index < 0 || index >= devices.Length || devices[index] == null ||
                index == activeIndex) { return; }
            SaveActive(); activeIndex = index;
            NativeXhciDevice device = devices[index];
            inputContext = device.inputContext;
            deviceContext = device.deviceContext;
            ep0Ring = device.ep0Ring;
            keyboardRing = device.keyboardRing;
            bulkInRing = device.bulkInRing;
            descriptorBuffer = device.descriptorBuffer;
            reportBuffer = device.reportBuffer;
            transferBuffer = device.transferBuffer;
            ep0Index = device.ep0Index;
            ep0Cycle = device.ep0Cycle;
            keyboardIndex = device.keyboardIndex;
            keyboardCycle = device.keyboardCycle;
            bulkOutIndex = device.bulkOutIndex;
            bulkOutCycle = device.bulkOutCycle;
            bulkInIndex = device.bulkInIndex;
            bulkInCycle = device.bulkInCycle;
            port = device.port;
            slot = device.slot;
            speed = device.speed;
            endpointId = device.endpointId;
            maxPacket = device.maxPacket;
            bulkOutEndpoint = device.bulkOutEndpoint;
            bulkInEndpoint = device.bulkInEndpoint;
            bulkInterface = device.bulkInterface;
            bulkOutPacket = device.bulkOutPacket;
            bulkInPacket = device.bulkInPacket;
            lastTransferCode = device.lastTransferCode;
            lastTransferEndpoint = device.lastTransferEndpoint;
            lastTransferResidual = device.lastTransferResidual;
            lastTransferPointer = device.lastTransferPointer;
            transferComplete = device.transferComplete;
            keyboardReady = device.keyboardReady;
            mouseReady = device.mouseReady;
            storageReady = device.storageReady;
            reportPending = device.reportPending;
            previousReport = device.previousReport;
            mouseEvents = device.mouseEvents;
            keyboardBuffers = device.keyboardBuffers;
            bytes = device.bytes;
            byteHead = device.byteHead;
            byteTail = device.byteTail;
            dropped = device.dropped;
            heldUsage = device.heldUsage;
            heldModifiers = device.heldModifiers;
            repeatDeadline = device.repeatDeadline;
            deviceKind = device.deviceKind;
            storageSectorSize = device.storageSectorSize;
            storageSectorCount = device.storageSectorCount;
            botTag = device.botTag;
        }
        private void PrepareDevice(int index, long deviceBase) {
            NativeXhciDevice device = devices[index];
            device.inputContext = deviceBase;
            device.deviceContext = deviceBase + 4096;
            device.ep0Ring = deviceBase + 8192;
            device.keyboardRing = deviceBase + 12288;
            device.bulkInRing = deviceBase + 16384;
            device.descriptorBuffer = deviceBase + 20480;
            device.reportBuffer = deviceBase + 24576;
            device.transferBuffer = device.reportBuffer;
            device.ep0Cycle = 1; device.keyboardCycle = 1;
            device.bulkOutCycle = 1; device.bulkInCycle = 1;
            int report = 0;
            while (report < 8) { device.previousReport[report] = 0; report = report + 1; }
            device.mouseEvents.Clear();
            device.byteHead = 0; device.byteTail = 0;
            device.port = 0; device.slot = 0; device.speed = 0;
            device.endpointId = 0; device.maxPacket = 0;
            device.bulkOutEndpoint = 0; device.bulkInEndpoint = 0;
            device.bulkInterface = 0; device.bulkOutPacket = 0; device.bulkInPacket = 0;
            device.ep0Index = 0; device.keyboardIndex = 0;
            device.bulkOutIndex = 0; device.bulkInIndex = 0;
            device.lastTransferCode = 0; device.lastTransferEndpoint = 0;
            device.lastTransferResidual = 0; device.lastTransferPointer = 0;
            device.transferComplete = false; device.keyboardReady = false;
            device.mouseReady = false; device.storageReady = false;
            device.reportPending = false; device.heldUsage = 0;
            device.heldModifiers = 0; device.repeatDeadline = 0;
            device.deviceKind = 0; device.storageSectorSize = 0;
            device.storageSectorCount = 0;
            device.botTag = 1;
            devices[index] = device;
            if (activeIndex < 0) { activeIndex = index; }
            if (activeIndex == index) {
            inputContext = device.inputContext;
            deviceContext = device.deviceContext;
            ep0Ring = device.ep0Ring;
            keyboardRing = device.keyboardRing;
            bulkInRing = device.bulkInRing;
            descriptorBuffer = device.descriptorBuffer;
            reportBuffer = device.reportBuffer;
            transferBuffer = device.transferBuffer;
            ep0Index = device.ep0Index;
            ep0Cycle = device.ep0Cycle;
            keyboardIndex = device.keyboardIndex;
            keyboardCycle = device.keyboardCycle;
            bulkOutIndex = device.bulkOutIndex;
            bulkOutCycle = device.bulkOutCycle;
            bulkInIndex = device.bulkInIndex;
            bulkInCycle = device.bulkInCycle;
            port = device.port;
            slot = device.slot;
            speed = device.speed;
            endpointId = device.endpointId;
            maxPacket = device.maxPacket;
            bulkOutEndpoint = device.bulkOutEndpoint;
            bulkInEndpoint = device.bulkInEndpoint;
            bulkInterface = device.bulkInterface;
            bulkOutPacket = device.bulkOutPacket;
            bulkInPacket = device.bulkInPacket;
            lastTransferCode = device.lastTransferCode;
            lastTransferEndpoint = device.lastTransferEndpoint;
            lastTransferResidual = device.lastTransferResidual;
            lastTransferPointer = device.lastTransferPointer;
            transferComplete = device.transferComplete;
            keyboardReady = device.keyboardReady;
            mouseReady = device.mouseReady;
            storageReady = device.storageReady;
            reportPending = device.reportPending;
            previousReport = device.previousReport;
            mouseEvents = device.mouseEvents;
            keyboardBuffers = device.keyboardBuffers;
            bytes = device.bytes;
            byteHead = device.byteHead;
            byteTail = device.byteTail;
            dropped = device.dropped;
            heldUsage = device.heldUsage;
            heldModifiers = device.heldModifiers;
            repeatDeadline = device.repeatDeadline;
            deviceKind = device.deviceKind;
            storageSectorSize = device.storageSectorSize;
            storageSectorCount = device.storageSectorCount;
            botTag = device.botTag;
            }
        }
        private int IndexBySlot(int slotId) {
            SaveActive();
            int i = 0;
            while (i < devices.Length) {
                if (devices[i] != null && devices[i].slot == slotId && slotId > 0) {
                    return i;
                }
                i = i + 1;
            }
            return -1;
        }
        private int IndexByPort(int portId) {
            SaveActive();
            int i = 0;
            while (i < devices.Length) {
                if (devices[i] != null && devices[i].port == portId && portId > 0) {
                    return i;
                }
                i = i + 1;
            }
            return -1;
        }
        private int SelectKind(int kind) {
            SaveActive();
            int i = 0;
            while (i < devices.Length) {
                NativeXhciDevice device = devices[i];
                if (device != null && device.deviceKind == kind &&
                    ((kind == 1 && device.keyboardReady) ||
                     (kind == 2 && device.storageReady) ||
                     (kind == 3 && device.mouseReady))) {
                    SwitchTo(i); return i;
                }
                i = i + 1;
            }
            return -1;
        }

        private void State(int state, int cause) {
            System.Kernel.Memory.Write32(bootInfo + 2384, state);
            System.Kernel.Memory.Write32(bootInfo + 2388, cause);
        }

        private int Read32(long address) { return System.Kernel.Memory.Read32(address); }
        private void Write32(long address, long value) { System.Kernel.Memory.Write32(address, value); }
        private void Write64(long address, long value) { System.Kernel.Memory.Write64(address, value); }
        private void Zero(long address, int bytesToClear) {
            int offset = 0;
            while (offset < bytesToClear) { Write64(address + offset, 0); offset = offset + 8; }
        }

        private int WithoutPortChanges(int value) {
            return value - (value / 131072 % 128) * 131072;
        }

        private bool WaitSet(long address, int divisor, int milliseconds) {
            long deadline = KernelClock.DeadlineAfter(bootInfo, milliseconds);
            while ((Read32(address) / divisor) % 2 == 0) {
                if (KernelClock.Expired(deadline)) { return false; }
                System.Kernel.Cpu.Pause();
            }
            return true;
        }

        private bool WaitClear(long address, int divisor, int milliseconds) {
            long deadline = KernelClock.DeadlineAfter(bootInfo, milliseconds);
            while ((Read32(address) / divisor) % 2 != 0) {
                if (KernelClock.Expired(deadline)) { return false; }
                System.Kernel.Cpu.Pause();
            }
            return true;
        }

        private bool StopReset() {
            long command = operational;
            long status = operational + 4;
            int value = Read32(command);
            if (value % 2 != 0) { Write32(command, value - 1); }
            if (!WaitSet(status, 1, 1000)) { State(2, 1); return false; }
            value = Read32(command);
            if ((value / 2) % 2 == 0) { Write32(command, value + 2); }
            if (!WaitClear(command, 2, 1000) || !WaitClear(status, 2048, 1000)) {
                State(2, 2); return false;
            }
            return true;
        }

        private void InitializeCommandRing() {
            Zero(commandRing, 4096);
            long link = commandRing + 255 * 16;
            Write64(link, commandRing);
            Write32(link + 8, 0);
            Write32(link + 12, XhciTrb.Control(6, 1) + 2);
            commandIndex = 0; commandCycle = 1;
        }

        private long SubmitCommand(long parameter, long status, long control) {
            if (commandIndex >= 255) {
                long link = commandRing + 255 * 16;
                Write32(link + 12, XhciTrb.Control(6, commandCycle) + 2);
                System.Kernel.Memory.Fence();
                commandIndex = 0; commandCycle = 1 - commandCycle;
            }
            long trb = commandRing + commandIndex * 16;
            Write64(trb, parameter); Write32(trb + 8, status);
            System.Kernel.Memory.Fence();
            Write32(trb + 12, control + commandCycle);
            commandIndex = commandIndex + 1;
            lastCommandCode = 0; lastCommandSlot = 0; lastCommandPointer = 0;
            System.Kernel.Memory.Fence(); Write32(doorbells, 0);
            return trb;
        }

        private void ConsumeEvents() {
            bool consumed = false;
            int originalIndex = activeIndex;
            while (true) {
                long event = eventRing + eventIndex * 16;
                long control = Read32(event + 12);
                if (XhciTrb.Cycle(control) != eventCycle) { break; }
                long parameter = System.Kernel.Memory.Read64(event);
                long status = Read32(event + 8);
                int type = XhciTrb.Type(control);
                if (type == 33) {
                    lastCommandPointer = parameter;
                    lastCommandCode = XhciTrb.CompletionCode(status);
                    lastCommandSlot = XhciTrb.SlotId(control);
                    System.Kernel.Memory.Write64(bootInfo + 2400,
                        System.Kernel.Memory.Read64(bootInfo + 2400) + 1);
                } else if (type == 32) {
                    int completion = XhciTrb.CompletionCode(status);
                    int completedEndpoint = XhciTrb.EndpointId(control);
                    int target = IndexBySlot(XhciTrb.SlotId(control));
                    if (target >= 0) {
                        SwitchTo(target);
                        if ((keyboardReady || mouseReady) && completedEndpoint == endpointId) {
                            HandleKeyboardCompletion(parameter, completion,
                                XhciTrb.TransferLength(status));
                        } else {
                            lastTransferCode = completion;
                            lastTransferEndpoint = completedEndpoint;
                            lastTransferResidual = XhciTrb.TransferLength(status);
                            lastTransferPointer = parameter;
                            transferComplete = true;
                        }
                    }
                    System.Kernel.Memory.Write64(bootInfo + 2408,
                        System.Kernel.Memory.Read64(bootInfo + 2408) + 1);
                } else if (type == 34) {
                    System.Kernel.Memory.Write64(bootInfo + 2416,
                        System.Kernel.Memory.Read64(bootInfo + 2416) + 1);
                    int changedPort = (int)(parameter / 16777216 % 256);
                    int target = IndexByPort(changedPort);
                    bool connected = changedPort > 0 &&
                        Read32(operational + 1024 + (changedPort - 1) * 16) % 2 != 0;
                    if (target >= 0 && !connected) {
                        SwitchTo(target);
                        keyboardReady = false; mouseReady = false; storageReady = false;
                        mouseEvents.Clear();
                        reportPending = false; recoveryNeeded = true;
                        heldUsage = 0; State(12, 0);
                        System.Kernel.Memory.Write64(bootInfo + 2464,
                            System.Kernel.Memory.Read64(bootInfo + 2464) + 1);
                    } else if (target < 0 && connected && maxDevices > 1 &&
                        devices[1].slot == 0) {
                        recoveryNeeded = true;
                    }
                }
                eventIndex = eventIndex + 1;
                if (eventIndex == 256) { eventIndex = 0; eventCycle = 1 - eventCycle; }
                consumed = true;
            }
            if (consumed) {
                SwitchTo(originalIndex);
                System.Kernel.Memory.Fence();
                Write64(runtime + 32 + 24, eventRing + eventIndex * 16 + 8);
            }
        }

        private void ServiceInterrupt() {
            // The IRQ stub increments this counter. Preserve IF while taking
            // one pending delivery so an IRQ cannot be lost to a stale store.
            long flags = System.Kernel.Cpu.ReadFlags();
            System.Kernel.Cpu.DisableInterrupts();
            int pending = System.Kernel.Memory.Read32(bootInfo + 2336);
            if (pending > 0) { System.Kernel.Memory.Write32(bootInfo + 2336, pending - 1); }
            if (flags / 512 % 2 != 0) { System.Kernel.Cpu.EnableInterrupts(); }
            ConsumeEvents();
            lastDelivery = System.Kernel.Memory.Read64(bootInfo + 2304);
        }

        private bool WaitCommand(long pointer, int milliseconds) {
            long deadline = KernelClock.DeadlineAfter(bootInfo, milliseconds);
            while (lastCommandPointer != pointer) {
                long delivery = System.Kernel.Memory.Read64(bootInfo + 2304);
                if (delivery != lastDelivery || System.Kernel.Memory.Read32(bootInfo + 2336) > 0) {
                    ServiceInterrupt();
                } else {
                    if (KernelClock.Expired(deadline)) { State(6, 20); return false; }
                    System.Kernel.Cpu.Halt();
                }
                if (KernelClock.Expired(deadline) && lastCommandPointer != pointer) { State(6, 20); return false; }
            }
            if (lastCommandCode != 1) { State(6, 100 + lastCommandCode); return false; }
            return true;
        }

        private void QueueEp0(long parameter, long status, long control) {
            long trb = ep0Ring + ep0Index * 16;
            Write64(trb, parameter); Write32(trb + 8, status); System.Kernel.Memory.Fence();
            Write32(trb + 12, control + ep0Cycle); ep0Index = ep0Index + 1;
        }

        private void QueueSetup(long low, long high, long status, long control) {
            long trb = ep0Ring + ep0Index * 16;
            Write32(trb, low); Write32(trb + 4, high); Write32(trb + 8, status);
            System.Kernel.Memory.Fence(); Write32(trb + 12, control + ep0Cycle);
            ep0Index = ep0Index + 1;
        }

        private bool WaitTransfer(int expectedEndpoint, int milliseconds) {
            long deadline = KernelClock.DeadlineAfter(bootInfo, milliseconds);
            while (!transferComplete) {
                long delivery = System.Kernel.Memory.Read64(bootInfo + 2304);
                if (delivery != lastDelivery || System.Kernel.Memory.Read32(bootInfo + 2336) > 0) {
                    ServiceInterrupt();
                } else {
                    if (KernelClock.Expired(deadline)) { State(8, 21); return false; }
                    System.Kernel.Cpu.Halt();
                }
                if (KernelClock.Expired(deadline) && !transferComplete) { State(8, 21); return false; }
            }
            if (lastTransferEndpoint != expectedEndpoint ||
                (lastTransferCode != 1 && lastTransferCode != 13)) {
                State(8, 120 + lastTransferCode); return false;
            }
            return true;
        }

        private bool ControlTransfer(int requestType, int request, int value, int index,
            int length, bool input) {
            if (length < 0 || length > 4096 || ep0Index > 250) { State(8, 22); return false; }
            long setupLow = requestType + request * 256 + value * 65536;
            long setupHigh = index + length * 65536;
            int transferType = 0;
            if (length > 0) { if (input) { transferType = 3; } else { transferType = 2; } }
            QueueSetup(setupLow, setupHigh, 8,
                XhciTrb.Control(2, 0) + 64 + transferType * 65536);
            if (length > 0) {
                long dataControl = XhciTrb.Control(3, 0);
                if (input) { dataControl = dataControl + 65536; }
                QueueEp0(descriptorBuffer, length, dataControl);
            }
            long statusControl = XhciTrb.Control(4, 0) + 32;
            if (length == 0 || !input) { statusControl = statusControl + 65536; }
            QueueEp0(0, 0, statusControl);
            transferComplete = false; lastTransferCode = 0; lastTransferEndpoint = 0;
            lastTransferResidual = 0; lastTransferPointer = 0;
            System.Kernel.Memory.Fence(); Write32(doorbells + slot * 4, 1);
            return WaitTransfer(1, 1000);
        }

        private bool ResetPort(int requestedPort) {
            int ports = Read32(mmio + 4) / 16777216 % 256;
            if (requestedPort < 0 || requestedPort > ports) { return false; }
            int candidate = 1; long deadline = KernelClock.DeadlineAfter(bootInfo, 2000);
            while (port == 0 && !KernelClock.Expired(deadline)) {
                candidate = 1;
                while (candidate <= ports && port == 0) {
                    int value = Read32(operational + 1024 + (candidate - 1) * 16);
                    if (value % 2 != 0 &&
                        (requestedPort == 0 || candidate == requestedPort)) {
                        port = candidate;
                    }
                    candidate = candidate + 1;
                }
                if (port == 0) { System.Kernel.Cpu.Pause(); }
            }
            if (port == 0) { State(5, 10); return false; }
            long portsc = operational + 1024 + (port - 1) * 16;
            int value = Read32(portsc); speed = value / 1024 % 16;
            Write32(portsc, WithoutPortChanges(value) + 16);
            deadline = KernelClock.DeadlineAfter(bootInfo, 1000);
            while (!KernelClock.Expired(deadline)) {
                value = Read32(portsc);
                if ((value / 16) % 2 == 0 && (value / 2) % 2 != 0) {
                    int changes = value / 131072 % 128;
                    if (changes != 0) { Write32(portsc, WithoutPortChanges(value) + changes * 131072); }
                    System.Kernel.Memory.Write32(bootInfo + 2392, port);
                    return true;
                }
                System.Kernel.Cpu.Pause();
            }
            State(5, 11); return false;
        }

        private int ConnectedPort() {
            if (mmio == 0 || operational == 0) { return 0; }
            int ports = Read32(mmio + 4) / 16777216 % 256;
            int candidate = 1;
            while (candidate <= ports) {
                if (Read32(operational + 1024 + (candidate - 1) * 16) % 2 != 0) { return candidate; }
                candidate = candidate + 1;
            }
            return 0;
        }

        private int AdditionalPort() {
            int ports = Read32(mmio + 4) / 16777216 % 256;
            int candidate = 1;
            while (candidate <= ports) {
                if (Read32(operational + 1024 + (candidate - 1) * 16) % 2 != 0 &&
                    IndexByPort(candidate) < 0) { return candidate; }
                candidate = candidate + 1;
            }
            return 0;
        }

        private bool AddressDevice() {
            long enable = SubmitCommand(0, 0, XhciTrb.Control(9, 0));
            if (!WaitCommand(enable, 1000) || lastCommandSlot < 1) { return false; }
            slot = lastCommandSlot; System.Kernel.Memory.Write32(bootInfo + 2396, slot);
            Write64(dma + slot * 8, deviceContext);
            Zero(inputContext, 4096); Zero(deviceContext, 4096); Zero(ep0Ring, 4096);
            Write32(inputContext + 4, 3);
            maxPacket = 8;
            if (speed == 3) { maxPacket = 64; }
            if (speed >= 4) { maxPacket = 512; }
            Write32(inputContext + 32, speed * 1048576 + 134217728);
            Write32(inputContext + 36, port * 65536);
            Write32(inputContext + 64 + 4, maxPacket * 65536 + 38);
            Write64(inputContext + 64 + 8, ep0Ring + 1);
            Write32(inputContext + 64 + 16, 8);
            ep0Index = 0; ep0Cycle = 1;
            long address = SubmitCommand(inputContext, 0,
                XhciTrb.Control(11, 0) + slot * 16777216);
            return WaitCommand(address, 1000);
        }

        private byte[] CopyDescriptor(int length) {
            byte[] data = new byte[length]; int i = 0;
            while (i < length) { data[i] = (byte)System.Kernel.Memory.Read8(descriptorBuffer + i); i = i + 1; }
            return data;
        }

        private bool UpdateEp0MaxPacket(int packetSize) {
            if (packetSize != 8 && packetSize != 16 && packetSize != 32 &&
                packetSize != 64 && packetSize != 512) { State(9, 30); return false; }
            Zero(inputContext, 4096);
            // Evaluate Context may change endpoint zero after the first short
            // device descriptor has revealed the device's actual packet size.
            Write32(inputContext + 4, 2);
            int offset = 0;
            while (offset < 32) {
                Write64(inputContext + 64 + offset,
                    System.Kernel.Memory.Read64(deviceContext + 32 + offset));
                offset = offset + 8;
            }
            int endpointWord = Read32(inputContext + 64 + 4);
            endpointWord = endpointWord - (endpointWord / 65536 % 65536) * 65536 +
                packetSize * 65536;
            Write32(inputContext + 64 + 4, endpointWord);
            long evaluate = SubmitCommand(inputContext, 0,
                XhciTrb.Control(13, 0) + slot * 16777216);
            if (!WaitCommand(evaluate, 1000)) { return false; }
            maxPacket = packetSize;
            return true;
        }

        private bool ConfigureMassStorage(byte[] config, int total, int interfaceOffset,
            int configuration) {
            int outOffset = UsbDescriptors.FindEndpointOffset(config, total, interfaceOffset, 0, 2);
            int inOffset = UsbDescriptors.FindEndpointOffset(config, total, interfaceOffset, 1, 2);
            int outAddress = UsbDescriptors.FindEndpoint(config, total, interfaceOffset, 0, 2);
            int inAddress = UsbDescriptors.FindEndpoint(config, total, interfaceOffset, 1, 2);
            bulkInterface = UsbDescriptors.InterfaceNumber(config, total, interfaceOffset);
            bulkOutPacket = UsbDescriptors.EndpointMaxPacket(config, total, outOffset);
            bulkInPacket = UsbDescriptors.EndpointMaxPacket(config, total, inOffset);
            System.Kernel.Memory.Write32(bootInfo + 2528, outOffset);
            System.Kernel.Memory.Write32(bootInfo + 2532, inOffset);
            System.Kernel.Memory.Write32(bootInfo + 2536, outAddress + inAddress * 256);
            System.Kernel.Memory.Write32(bootInfo + 2540, bulkOutPacket + bulkInPacket * 65536);
            System.Kernel.Memory.Write32(bootInfo + 2544, bulkInterface);
            if (outAddress < 1 || outAddress > 15 || inAddress < 129 || inAddress > 143 ||
                bulkInterface < 0 || bulkOutPacket < 8 || bulkOutPacket > 1024 ||
                bulkInPacket < 8 || bulkInPacket > 1024) { State(14, 60); return false; }
            bulkOutEndpoint = (outAddress % 16) * 2;
            bulkInEndpoint = (inAddress % 16) * 2 + 1;
            if (!ControlTransfer(0, 9, configuration, 0, 0, false)) { return false; }
            Zero(inputContext, 4096); Zero(keyboardRing, 4096); Zero(bulkInRing, 4096);
            Write32(inputContext + 4, 1 + PowerOfTwo(bulkOutEndpoint) + PowerOfTwo(bulkInEndpoint));
            int entries = bulkOutEndpoint;
            if (bulkInEndpoint > entries) { entries = bulkInEndpoint; }
            int slotWord = Read32(deviceContext);
            slotWord = slotWord - (slotWord / 134217728 % 32) * 134217728 + entries * 134217728;
            Write32(inputContext + 32, slotWord);
            Write32(inputContext + 36, Read32(deviceContext + 4));
            long outContext = inputContext + (bulkOutEndpoint + 1) * 32;
            Write32(outContext + 4, bulkOutPacket * 65536 + 22);
            Write64(outContext + 8, keyboardRing + 1);
            Write32(outContext + 16, bulkOutPacket);
            long inContext = inputContext + (bulkInEndpoint + 1) * 32;
            Write32(inContext + 4, bulkInPacket * 65536 + 54);
            Write64(inContext + 8, bulkInRing + 1);
            Write32(inContext + 16, bulkInPacket);
            bulkOutIndex = 0; bulkOutCycle = 1; bulkInIndex = 0; bulkInCycle = 1;
            long configure = SubmitCommand(inputContext, 0,
                XhciTrb.Control(12, 0) + slot * 16777216);
            if (!WaitCommand(configure, 1000)) { return false; }
            deviceKind = 2; storageReady = true;
            System.Kernel.Memory.Write32(bootInfo + 2472, 2);
            System.Kernel.Memory.Write32(bootInfo + 2476,
                configuration + bulkInterface * 256 + bulkOutEndpoint * 65536 + bulkInEndpoint * 16777216);
            return DiscoverCapacity();
        }

        private bool ConfigureDevice() {
            Zero(descriptorBuffer, 4096);
            if (!ControlTransfer(128, 6, 256, 0, 18, true)) { return false; }
            int advertisedByte = System.Kernel.Memory.Read8(descriptorBuffer + 7);
            int advertised = advertisedByte;
            // USB 3 encodes bMaxPacketSize0 as a power of two. USB 2 and
            // earlier devices put the byte count in the descriptor directly.
            if (speed >= 4 && advertisedByte < 16) { advertised = PowerOfTwo(advertisedByte); }
            System.Kernel.Memory.Write32(bootInfo + 2520,
                advertisedByte + speed * 256 + maxPacket * 65536);
            if (advertised != maxPacket && !UpdateEp0MaxPacket(advertised)) { return false; }
            Zero(descriptorBuffer, 4096);
            if (!ControlTransfer(128, 6, 512, 0, 9, true)) { return false; }
            int total = System.Kernel.Memory.Read8(descriptorBuffer + 2) +
                System.Kernel.Memory.Read8(descriptorBuffer + 3) * 256;
            if (total < 9 || total > 4096) { State(9, 31); return false; }
            Zero(descriptorBuffer, 4096);
            if (!ControlTransfer(128, 6, 512, 0, total, true)) { return false; }
            byte[] config = CopyDescriptor(total);
            int interfaceOffset = UsbDescriptors.FindInterface(config, total, 3, 1, 1);
            bool mouseInterface = false;
            int configuration = UsbDescriptors.ConfigurationValue(config, total);
            if (interfaceOffset < 0) {
                interfaceOffset = UsbDescriptors.FindInterface(config, total, 3, 1, 2);
                if (interfaceOffset >= 0) { mouseInterface = true; }
                else {
                    int storageInterface = UsbDescriptors.FindInterface(config, total, 8, 6, 80);
                    if (storageInterface < 0 || configuration < 1) {
                        System.Kernel.Managed.Release(config); State(9, 32); return false;
                    }
                    bool storageConfigured =
                        ConfigureMassStorage(config, total, storageInterface, configuration);
                    System.Kernel.Managed.Release(config);
                    return storageConfigured;
                }
            }
            int endpointOffset = UsbDescriptors.FindEndpointOffset(config, total, interfaceOffset, 1, 3);
            int address = UsbDescriptors.FindEndpoint(config, total, interfaceOffset, 1, 3);
            int interfaceNumber = UsbDescriptors.InterfaceNumber(config, total, interfaceOffset);
            maxPacket = UsbDescriptors.EndpointMaxPacket(config, total, endpointOffset);
            int interval = UsbDescriptors.EndpointInterval(config, total, endpointOffset);
            int minimumReport = 8;
            if (mouseInterface) { minimumReport = 3; }
            if (address < 129 || interfaceNumber < 0 || configuration < 1 || maxPacket < minimumReport ||
                maxPacket > 64 || interval < 1) {
                System.Kernel.Managed.Release(config); State(9, 32); return false;
            }
            endpointId = (address % 16) * 2 + 1;
            if (!ControlTransfer(0, 9, configuration, 0, 0, false) ||
                !ControlTransfer(33, 11, 0, interfaceNumber, 0, false) ||
                !ControlTransfer(33, 10, 0, interfaceNumber, 0, false)) {
                System.Kernel.Managed.Release(config); return false;
            }
            Zero(inputContext, 4096); Zero(keyboardRing, 4096);
            Write32(inputContext + 4, 1 + PowerOfTwo(endpointId));
            int slotWord = Read32(deviceContext);
            slotWord = slotWord - (slotWord / 134217728 % 32) * 134217728 + endpointId * 134217728;
            Write32(inputContext + 32, slotWord);
            Write32(inputContext + 36, Read32(deviceContext + 4));
            int encodedInterval = interval + 2;
            if (speed >= 3) { encodedInterval = interval - 1; }
            if (encodedInterval < 0) { encodedInterval = 0; }
            if (encodedInterval > 15) { encodedInterval = 15; }
            long ep = inputContext + (endpointId + 1) * 32;
            Write32(ep, encodedInterval * 65536);
            Write32(ep + 4, maxPacket * 65536 + 62);
            Write64(ep + 8, keyboardRing + 1);
            Write32(ep + 16, maxPacket + maxPacket * 65536);
            keyboardIndex = 0; keyboardCycle = 1;
            long configure = SubmitCommand(inputContext, 0,
                XhciTrb.Control(12, 0) + slot * 16777216);
            bool ok = WaitCommand(configure, 1000);
            System.Kernel.Managed.Release(config);
            if (!ok) { return false; }
            deviceKind = 1;
            if (mouseInterface) { deviceKind = 3; }
            System.Kernel.Memory.Write32(bootInfo + 2472, deviceKind);
            System.Kernel.Memory.Write32(bootInfo + 2452,
                configuration + interfaceNumber * 256 + endpointId * 65536);
            return true;
        }

        private int PowerOfTwo(int exponent) {
            int value = 1; int i = 0;
            while (i < exponent) { value = value * 2; i = i + 1; }
            return value;
        }

        private bool QueueKeyboardReport(int bufferIndex) {
            if (slot < 1 || endpointId < 2) { return false; }
            if (bufferIndex < 0 || bufferIndex >= 32) { return false; }
            if (keyboardIndex >= 255) {
                long link = keyboardRing + 255 * 16;
                Write64(link, keyboardRing); Write32(link + 8, 0);
                Write32(link + 12, XhciTrb.Control(6, keyboardCycle) + 2);
                System.Kernel.Memory.Fence(); keyboardIndex = 0; keyboardCycle = 1 - keyboardCycle;
            }
            long buffer = reportBuffer + bufferIndex * 64;
            Zero(buffer, 64);
            long trb = keyboardRing + keyboardIndex * 16;
            Write64(trb, buffer); Write32(trb + 8, maxPacket);
            System.Kernel.Memory.Fence();
            Write32(trb + 12, XhciTrb.Control(1, keyboardCycle) + 32);
            keyboardBuffers[keyboardIndex] = bufferIndex;
            keyboardIndex = keyboardIndex + 1; reportPending = true;
            System.Kernel.Memory.Fence(); Write32(doorbells + slot * 4, endpointId);
            return true;
        }

        private bool WasPresent(int usage) {
            int i = 2;
            while (i < 8) { if (previousReport[i] == usage) { return true; } i = i + 1; }
            return false;
        }

        private void EnqueueByte(int value) {
            int next = (byteHead + 1) % bytes.Length;
            if (next == byteTail) { dropped = dropped + 1; return; }
            bytes[byteHead] = value; byteHead = next;
        }

        private void EnqueueEscape(int finalByte) {
            EnqueueByte(27); EnqueueByte(91); EnqueueByte(finalByte);
        }

        private void EnqueueUsage(int usage, int modifiers) {
            int ascii = UsbHidBoot.UsAscii(usage, modifiers);
            bool control = modifiers % 2 != 0 || (modifiers / 16) % 2 != 0;
            if (control && usage >= 4 && usage <= 29) { ascii = usage - 3; }
            if (ascii != 0) { EnqueueByte(ascii); }
            else if (usage == 79) { EnqueueEscape(67); }
            else if (usage == 80) { EnqueueEscape(68); }
            else if (usage == 81) { EnqueueEscape(66); }
            else if (usage == 82) { EnqueueEscape(65); }
            else if (usage == 74) { EnqueueEscape(72); }
            else if (usage == 77) { EnqueueEscape(70); }
            else if (usage == 76) { EnqueueByte(27); EnqueueByte(91); EnqueueByte(51); EnqueueByte(126); }
        }

        private void DecodeReport(long buffer) {
            int modifiers = System.Kernel.Memory.Read8(buffer);
            int firstUsage = 0;
            int i = 2;
            while (i < 8) {
                int usage = System.Kernel.Memory.Read8(buffer + i);
                if (firstUsage == 0 && usage > 3) { firstUsage = usage; }
                if (usage > 3 && !WasPresent(usage)) {
                    EnqueueUsage(usage, modifiers);
                }
                i = i + 1;
            }
            i = 0;
            while (i < 8) { previousReport[i] = (byte)System.Kernel.Memory.Read8(buffer + i); i = i + 1; }
            if (firstUsage == 0) { heldUsage = 0; repeatDeadline = 0; }
            else if (firstUsage != heldUsage) {
                heldUsage = firstUsage; heldModifiers = modifiers;
                repeatDeadline = KernelClock.DeadlineAfter(bootInfo, 500);
            }
            System.Kernel.Memory.Write64(bootInfo + 2424,
                System.Kernel.Memory.Read64(bootInfo + 2424) + 1);
        }

        private void DecodeMouseReport(long buffer) {
            int buttons = System.Kernel.Memory.Read8(buffer);
            int x = System.Kernel.Memory.Read8(buffer + 1);
            int y = System.Kernel.Memory.Read8(buffer + 2);
            if (x >= 128) { x = x - 256; }
            if (y >= 128) { y = y - 256; }
            mouseEvents.Enqueue(buttons, x, y);
            System.Kernel.Memory.Write64(bootInfo + 2424,
                System.Kernel.Memory.Read64(bootInfo + 2424) + 1);
        }

        private void HandleKeyboardCompletion(long trbPointer, int completion, int residual) {
            long offset = trbPointer - keyboardRing;
            if (completion != 1 && completion != 13) {
                dropped = dropped + 1; keyboardReady = false; mouseReady = false; recoveryNeeded = true;
                State(11, 120 + completion); return;
            }
            if (offset < 0 || offset >= 255 * 16 || offset % 16 != 0) {
                dropped = dropped + 1; keyboardReady = false; mouseReady = false; recoveryNeeded = true;
                State(11, 49); return;
            }
            int trbIndex = (int)(offset / 16);
            int bufferIndex = keyboardBuffers[trbIndex];
            int required = 8;
            if (mouseReady) { required = 3; }
            if (residual < 0 || residual > maxPacket || maxPacket - residual < required) {
                dropped = dropped + 1;
                QueueKeyboardReport(bufferIndex);
                return;
            }
            if (mouseReady) { DecodeMouseReport(reportBuffer + bufferIndex * 64); }
            else { DecodeReport(reportBuffer + bufferIndex * 64); }
            QueueKeyboardReport(bufferIndex);
        }

        private long NextTag() {
            long value = botTag; botTag = botTag + 1;
            if (botTag > UsbMassStorage.MaxU32()) { botTag = 1; }
            return value;
        }

        private int BotCommand(byte[] cdb, int cdbLength, byte[] data, int dataLength,
            bool input, long tag) {
            byte[] cbw = new byte[31]; byte[] csw = new byte[13];
            System.Kernel.Memory.Write32(bootInfo + 2524, 1);
            if (!UsbMassStorage.BuildCbw(cbw, tag, dataLength, input, 0, cdb, cdbLength) ||
                BulkOut(cbw, 31) != 31) {
                System.Kernel.Memory.Write32(bootInfo + 2524, 101);
                System.Kernel.Managed.Release(cbw); System.Kernel.Managed.Release(csw); return -1;
            }
            System.Kernel.Memory.Write32(bootInfo + 2524, 2);
            int actual = dataLength;
            if (dataLength > 0) {
                if (input) { actual = BulkIn(data, dataLength); }
                else { actual = BulkOut(data, dataLength); }
                if (actual != dataLength) {
                    System.Kernel.Memory.Write32(bootInfo + 2524, 102);
                    System.Kernel.Managed.Release(cbw); System.Kernel.Managed.Release(csw); return -1;
                }
            }
            System.Kernel.Memory.Write32(bootInfo + 2524, 3);
            int cswLength = BulkIn(csw, 13);
            int status = UsbMassStorage.CheckCsw(csw, cswLength, tag);
            System.Kernel.Memory.Write32(bootInfo + 2524, 10 + status);
            System.Kernel.Managed.Release(cbw); System.Kernel.Managed.Release(csw);
            return status;
        }

        private int RequestSense() {
            byte[] cdb = new byte[6]; byte[] sense = new byte[18];
            cdb[0] = 3; cdb[4] = 18;
            int result = BotCommand(cdb, 6, sense, 18, true, NextTag());
            int key = -1;
            if (result == 0) { key = sense[2] % 16; }
            System.Kernel.Managed.Release(cdb); System.Kernel.Managed.Release(sense);
            System.Kernel.Memory.Write32(bootInfo + 2504, key);
            return key;
        }

        private bool DiscoverCapacity() {
            byte[] cdb = new byte[10]; byte[] capacity = new byte[8];
            cdb[0] = 37;
            int result = BotCommand(cdb, 10, capacity, 8, true, NextTag());
            // Removable media commonly reports UNIT ATTENTION on the first
            // command after attachment. Consume its sense data, then retry
            // capacity once without rebuilding a healthy controller.
            if (result == 1) {
                RequestSense();
                result = BotCommand(cdb, 10, capacity, 8, true, NextTag());
            }
            if (result != 0) {
                if (result == 1) { RequestSense(); }
                System.Kernel.Managed.Release(cdb); System.Kernel.Managed.Release(capacity);
                storageReady = false;
                if (result == 1) { State(15, 61); }
                return false;
            }
            int last0 = capacity[0]; int last1 = capacity[1];
            int last2 = capacity[2]; int last3 = capacity[3];
            int size0 = capacity[4]; int size1 = capacity[5];
            int size2 = capacity[6]; int size3 = capacity[7];
            long last = last0 * 16777216 + last1 * 65536 + last2 * 256 + last3;
            long size = size0 * 16777216 + size1 * 65536 + size2 * 256 + size3;
            System.Kernel.Memory.Write64(bootInfo + 2552, last);
            System.Kernel.Memory.Write64(bootInfo + 2560, size);
            System.Kernel.Managed.Release(cdb); System.Kernel.Managed.Release(capacity);
            if (last <= 0 || (size != 512 && size != 1024 && size != 2048 && size != 4096)) {
                storageReady = false; State(15, 62); return false;
            }
            storageSectorSize = (int)size; storageSectorCount = last + 1;
            System.Kernel.Memory.Write32(bootInfo + 2480, storageSectorSize);
            System.Kernel.Memory.Write64(bootInfo + 2488, storageSectorCount);
            return true;
        }

        private bool PrepareBulkRing(bool input) {
            if (input) {
                if (bulkInIndex < 255) { return true; }
                long link = bulkInRing + 255 * 16;
                Write64(link, bulkInRing); Write32(link + 8, 0);
                Write32(link + 12, XhciTrb.Control(6, bulkInCycle) + 2);
                bulkInIndex = 0; bulkInCycle = 1 - bulkInCycle; return true;
            }
            if (bulkOutIndex < 255) { return true; }
            long link = keyboardRing + 255 * 16;
            Write64(link, keyboardRing); Write32(link + 8, 0);
            Write32(link + 12, XhciTrb.Control(6, bulkOutCycle) + 2);
            bulkOutIndex = 0; bulkOutCycle = 1 - bulkOutCycle; return true;
        }

        public int BulkOut(byte[] data, int length) {
            Pump();
            if (SelectKind(2) < 0) { return -1; }
            if (!storageReady || data == null || length < 0 || length > data.Length || length > 65536) { return -1; }
            int i = 0; while (i < length) { System.Kernel.Memory.Write8(transferBuffer + i, data[i]); i = i + 1; }
            PrepareBulkRing(false);
            long trb = keyboardRing + bulkOutIndex * 16;
            Write64(trb, transferBuffer); Write32(trb + 8, length); System.Kernel.Memory.Fence();
            Write32(trb + 12, XhciTrb.Control(1, bulkOutCycle) + 32);
            bulkOutIndex = bulkOutIndex + 1; transferComplete = false;
            System.Kernel.Memory.Fence(); Write32(doorbells + slot * 4, bulkOutEndpoint);
            if (!WaitTransfer(bulkOutEndpoint, 3000)) { return -1; }
            return length - lastTransferResidual;
        }

        public int BulkIn(byte[] data, int length) {
            Pump();
            if (SelectKind(2) < 0) { return -1; }
            if (!storageReady || data == null || length < 0 || length > data.Length || length > 65536) { return -1; }
            Zero(transferBuffer, length); PrepareBulkRing(true);
            long trb = bulkInRing + bulkInIndex * 16;
            Write64(trb, transferBuffer); Write32(trb + 8, length); System.Kernel.Memory.Fence();
            Write32(trb + 12, XhciTrb.Control(1, bulkInCycle) + 32);
            bulkInIndex = bulkInIndex + 1; transferComplete = false;
            System.Kernel.Memory.Fence(); Write32(doorbells + slot * 4, bulkInEndpoint);
            if (!WaitTransfer(bulkInEndpoint, 3000)) { return -1; }
            int actual = length - lastTransferResidual;
            int i = 0; while (i < actual) { data[i] = (byte)System.Kernel.Memory.Read8(transferBuffer + i); i = i + 1; }
            return actual;
        }

        public void ResetRecovery() {
            if (SelectKind(2) < 0) { return; }
            storageReady = false; recoveryNeeded = true; State(21, 63);
        }

        public int SectorSize() {
            if (SelectKind(2) < 0) { return 0; }
            return storageSectorSize;
        }
        public long SectorCount() {
            if (SelectKind(2) < 0) { return 0; }
            return storageSectorCount;
        }
        public bool Read(long lba, int sectors, byte[] destination) {
            Pump();
            if (SelectKind(2) < 0) { return false; }
            if (!storageReady || destination == null || lba < 0 || sectors < 1 ||
                sectors > 65535 || sectors > destination.Length / storageSectorSize ||
                lba > UsbMassStorage.MaxU32() || lba >= storageSectorCount ||
                sectors > storageSectorCount - lba) { return false; }
            int bytesToRead = sectors * storageSectorSize;
            if (bytesToRead > 65536) { return false; }
            byte[] cdb = new byte[10]; byte[] staged = new byte[bytesToRead];
            if (!UsbMassStorage.BuildRead10(cdb, lba, sectors)) {
                System.Kernel.Managed.Release(cdb); System.Kernel.Managed.Release(staged); return false;
            }
            int result = BotCommand(cdb, 10, staged, bytesToRead, true, NextTag());
            System.Kernel.Managed.Release(cdb);
            if (result != 0) {
                if (result == 1) { RequestSense(); } else { ResetRecovery(); }
                System.Kernel.Managed.Release(staged); return false;
            }
            int i = 0; while (i < bytesToRead) { destination[i] = staged[i]; i = i + 1; }
            System.Kernel.Managed.Release(staged);
            System.Kernel.Memory.Write64(bootInfo + 2496,
                System.Kernel.Memory.Read64(bootInfo + 2496) + 1);
            return true;
        }
        public bool Flush() { return SelectKind(2) >= 0; }
        public bool Write(long lba, int sectors, byte[] source) { return false; }
        public bool IsKeyboard() { return SelectKind(1) >= 0; }
        public bool IsMouse() { return SelectKind(3) >= 0; }
        public bool PollMouseEvent(int[] destination) {
            Pump();
            if (SelectKind(3) < 0) { return false; }
            return mouseEvents.PollCoalesced(destination);
        }
        public int DroppedMouseEvents() {
            if (SelectKind(3) < 0) { return 0; }
            return mouseEvents.Dropped();
        }
        public bool IsStorage() { return SelectKind(2) >= 0; }
        public int KindAt(int index) {
            SaveActive();
            if (index < 0 || index >= devices.Length || devices[index].port == 0) {
                return 0;
            }
            NativeXhciDevice device = devices[index];
            if ((device.deviceKind == 1 && device.keyboardReady) ||
                (device.deviceKind == 2 && device.storageReady) ||
                (device.deviceKind == 3 && device.mouseReady)) {
                return device.deviceKind;
            }
            return -1;
        }
        public int StorageIndex() { return SelectKind(2); }

        private bool FinishDevice() {
            if (deviceKind == 2) { storageReady = true; State(20, 0); return true; }
            if (deviceKind == 3) { mouseReady = true; State(14, 0); }
            else { keyboardReady = true; State(10, 0); }
            int queued = 0;
            while (queued < 32) {
                if (!QueueKeyboardReport(queued)) { State(10, 48); return false; }
                queued = queued + 1;
            }
            return true;
        }

        private void DropSecond() {
            int abandonedSlot = slot;
            if (abandonedSlot > 0) {
                long disable = SubmitCommand(0, 0,
                    XhciTrb.Control(10, 0) + abandonedSlot * 16777216);
                WaitCommand(disable, 1000);
                Write64(dma + abandonedSlot * 8, 0);
            }
            SwitchTo(0);
            devices[1].port = 0; devices[1].slot = 0;
            devices[1].keyboardReady = false;
            devices[1].mouseReady = false;
            devices[1].storageReady = false;
            if (extraMemory != null && extraMemory.Owned()) {
                allocator.Release(extraMemory);
                System.Kernel.Managed.Release(extraMemory);
            }
            extraMemory = null;
        }

        public bool Initialize() {
            State(1, 0);
            if (bootInfo < 4096 || mmio < 4096 || mmioLength < 4096 || allocator == null ||
                !allocator.Supported()) { State(2, 40); return false; }
            int capabilityLength = Read32(mmio) % 256;
            if (capabilityLengthOverride != 0) { capabilityLength = capabilityLengthOverride; }
            if (capabilityLength < 32 || capabilityLength > 252 ||
                (Read32(mmio + 16) / 4) % 2 != 0) { State(2, 41); return false; }
            operational = mmio + capabilityLength;
            doorbells = mmio + (Read32(mmio + 20) - Read32(mmio + 20) % 4);
            runtime = mmio + (Read32(mmio + 24) - Read32(mmio + 24) % 32);
            if (doorbells < mmio || runtime < mmio || doorbells >= mmio + mmioLength ||
                runtime + 64 >= mmio + mmioLength) { State(2, 42); return false; }
            if (!StopReset()) { return false; }
            int scratchpads = (Read32(mmio + 8) / 134217728 % 32) +
                (Read32(mmio + 8) / 2097152 % 32) * 32;
            if (scratchpads > 256 || scratchpads > allocator.CapacityPages() - 26) {
                State(2, 43); return false;
            }
            dmaPages = 26 + scratchpads;
            maxDevices = 1;
            if (Read32(mmio + 4) % 256 >= 2 &&
                allocator.CapacityPages() - dmaPages >= 22) { maxDevices = 2; }
            memory = allocator.Allocate(dmaPages);
            if (memory == null) { State(2, 44); return false; }
            dma = memory.Address(); Zero(dma, dmaPages * 4096);
            commandRing = dma + 4096; eventRing = dma + 8192; erst = dma + 12288;
            activeIndex = -1;
            PrepareDevice(0, dma + 16384);
            InitializeCommandRing(); eventIndex = 0; eventCycle = 1;
            if (scratchpads > 0) {
                long scratchpadArray = dma + 2048;
                Write64(dma, scratchpadArray);
                int scratchpad = 0;
                while (scratchpad < scratchpads) {
                    Write64(scratchpadArray + scratchpad * 8,
                        dma + (26 + scratchpad) * 4096);
                    scratchpad = scratchpad + 1;
                }
            }
            System.Kernel.Memory.Write32(bootInfo + 2456, scratchpads);
            System.Kernel.Memory.Write32(bootInfo + 2460, 1); // US keyboard layout
            Write64(erst, eventRing); Write32(erst + 8, 256);
            Write64(operational + 48, dma);
            Write64(operational + 24, commandRing + 1);
            Write32(runtime + 32 + 8, 1);
            Write64(runtime + 32 + 16, erst);
            Write64(runtime + 32 + 24, eventRing);
            Write32(runtime + 32 + 4, 0);
            Write32(operational + 56, maxDevices);
            if (!NativeDeviceInterrupts.Register(bootInfo, 3, runtime + 32, 1)) {
                State(3, 45); Release(); return false;
            }
            int messageMode = XhciInterrupts.Configure(bdf, mmio, mmioLength);
            System.Kernel.Memory.Write32(bootInfo + 2448, messageMode);
            if (messageMode == 0) { State(3, 46); Release(); return false; }
            Write32(runtime + 32, 2);
            int command = Read32(operational);
            if ((command / 4) % 2 == 0) { command = command + 4; }
            if (command % 2 == 0) { command = command + 1; }
            Write32(operational, command);
            if (!WaitClear(operational + 4, 1, 1000)) { State(4, 47); Release(); return false; }
            lastDelivery = System.Kernel.Memory.Read64(bootInfo + 2304);
            initializing = true;
            if (!ResetPort(0) || !AddressDevice() || !ConfigureDevice() ||
                !FinishDevice()) { Release(); return false; }
            SaveActive();
            int nextPort = 0;
            if (maxDevices > 1) { nextPort = AdditionalPort(); }
            if (nextPort > 0) {
                extraMemory = allocator.Allocate(22);
                if (extraMemory != null) {
                    Zero(extraMemory.Address(), 22 * 4096);
                    PrepareDevice(1, extraMemory.Address());
                    SwitchTo(1);
                    if (!ResetPort(nextPort) || !AddressDevice() ||
                        !ConfigureDevice() || !FinishDevice()) { DropSecond(); }
                }
            }
            SwitchTo(0);
            recoveryNeeded = false; recoveryFailures = 0;
            initializing = false;
            if (deviceKind == 2) { State(20, 0); }
            else if (deviceKind == 3) { State(14, 0); }
            else { State(10, 0); }
            System.Kernel.Memory.Write64(bootInfo + 2440, dma);
            return true;
        }

        public void Pump() {
            if (System.Kernel.Memory.Read64(bootInfo + 2304) != lastDelivery ||
                System.Kernel.Memory.Read32(bootInfo + 2336) > 0) { ServiceInterrupt(); }
            if (recoveryNeeded && !recovering && !initializing && ConnectedPort() != 0) {
                recovering = true; recoveryAttempts = recoveryAttempts + 1;
                recoveryFailures = recoveryFailures + 1;
                System.Kernel.Memory.Write32(bootInfo + 2432, recoveryAttempts);
                Release(); port = 0; slot = 0; endpointId = 0;
                bulkOutEndpoint = 0; bulkInEndpoint = 0; deviceKind = 0;
                if (recoveryFailures <= 3) {
                    Initialize();
                } else {
                    State(13, 50);
                }
                recovering = false;
            }
            if (dma != 0 && (Read32(operational + 4) / 4096) % 2 != 0) {
                keyboardReady = false; mouseReady = false; storageReady = false;
                mouseEvents.Clear(); recoveryNeeded = true; State(11, 51);
            }
            SelectKind(1);
            if (keyboardReady && heldUsage != 0 && repeatDeadline != 0 &&
                KernelClock.Expired(repeatDeadline)) {
                EnqueueUsage(heldUsage, heldModifiers);
                repeatDeadline = KernelClock.DeadlineAfter(bootInfo, 40);
            }
        }

        public bool IsReady() { return SelectKind(1) >= 0; }
        public int PollByte() {
            Pump();
            if (SelectKind(1) < 0) { return -1; }
            if (byteTail == byteHead) { return -1; }
            int value = bytes[byteTail]; byteTail = (byteTail + 1) % bytes.Length; return value;
        }
        public int DroppedBytes() {
            if (SelectKind(1) < 0) { return 0; }
            return dropped;
        }
        public bool CanHalt() {
            if (SelectKind(1) < 0) { return true; }
            return heldUsage == 0;
        }

        public bool Release() {
            initializing = false;
            keyboardReady = false; mouseReady = false; storageReady = false; reportPending = false;
            mouseEvents.Clear();
            if (runtime != 0) { Write32(runtime + 32, 0); }
            if (operational != 0) {
                int command = Read32(operational);
                if (command % 2 != 0) { Write32(operational, command - 1); }
            }
            if (System.Kernel.Memory.Read32(bootInfo + 2316) == 3) {
                NativeDeviceInterrupts.Unregister(bootInfo, 3);
            }
            bool released = true;
            if (extraMemory != null && extraMemory.Owned()) {
                if (!allocator.Release(extraMemory)) { released = false; }
                System.Kernel.Managed.Release(extraMemory); extraMemory = null;
            }
            if (memory != null && memory.Owned()) {
                released = allocator.Release(memory);
                System.Kernel.Managed.Release(memory); memory = null;
            }
            dma = 0; System.Kernel.Memory.Write64(bootInfo + 2440, 0);
            SaveActive();
            devices[0].port = 0; devices[0].slot = 0;
            devices[1].port = 0; devices[1].slot = 0;
            devices[0].keyboardReady = false; devices[0].mouseReady = false;
            devices[0].storageReady = false;
            devices[1].keyboardReady = false; devices[1].mouseReady = false;
            devices[1].storageReady = false;
            activeIndex = -1;
            return released;
        }
    }
}
