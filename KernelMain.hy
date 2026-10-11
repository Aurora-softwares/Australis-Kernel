// Freestanding kernel bring-up checklist (QEMU/OVMF, AHCI and NVMe):
//   [x] Enter separate position-independent raw code on the kernel stack.
//   [x] Validate KernelBootInfo and allocate a zeroed physical page.
//   [x] Run page-backed object, array, and string allocation after handoff.
//   [x] Reinitialize a live AHCI or NVMe controller through kernel MMIO/DMA.
//   [x] Read sectors through BlockDevice and validate GPT through GptDisk.
//   [x] Publish a ready state, enable interrupts, and own the idle loop.
//   [x] Verify the complete entry and storage path in both QEMU boot tests.
//   [x] Keep host-tested VFS, read-only HyFS, and USB protocol modules in source.
//   [x] Select the HyFS GPT type, mount a live root, and read checked files
//       through the VFS on both AHCI and NVMe, including multiple sectors.
//   [x] Bring up COM1 after handoff and run an interactive kernel shell with
//       bounded line editing, help, echo, ls, cat, and version over serial.
//   [x] Route COM1 through a shared event queue and reusable line editor, then
//       mirror output to a cursor-controlled scrolling framebuffer terminal.
//   [x] Protect persistent kernel allocations from shell temporaries, record
//       allocation faults, and wake COM1 input through a PIC IRQ handler.
//   [x] Reuse freed physical pages and map/unmap explicit 4 KiB kernel pages
//       with a local TLB invalidation after every mapping transition.
//   [x] Release individual managed objects, arrays, and strings; stress page
//       reuse and repeated map/unmap cycles before mounting the root.
//   [x] Wait for AHCI MSI or NVMe MSI-X completions on vector 0x31, recover
//       one failed request through a controller reset, and retain diagnostics.
//   [x] Add generation-checked file handles and canonical mount traversal.
//   [ ] Add FAT/FAT32 and NTFS drivers if those volumes become boot requirements.
//   [x] Calibrate the TSC and replace controller poll budgets with deadlines.
//   [x] Add reusable IRQ ownership, acknowledgement, and deferred device events.
//   [ ] Add automatic managed lifetime tracking.
//   [x] Bring up one live xHCI root device and route boot-keyboard reports into
//       the shared COM1/framebuffer shell input path with bounded recovery.
//   [x] Connect live USB mass storage to the existing BOT protocol layer.
//   [x] Add the `exec` format, checked loader, file descriptors, system calls,
//       bounded cooperative scheduling, and a user shell command registry.
//   [ ] Add native ring-3 processes and preemptive threads after the checked
//       AUEX boundary has established the user-facing contracts.
//
// This method graph is compiled as position-independent freestanding x86-64
// code. The handoff passes the writable KernelBootInfo address as a long.
public class KernelCounter {
    private int value;

    public KernelCounter(int initial) { value = initial; }
    public int Value() { return value; }
}

public class KernelMain {
    private static byte[] HyfsTypeGuid() {
        // GPT stores the first three GUID fields in little-endian order.
        // 9f5eb82e-692e-5a8f-b968-adaaa349dd93
        byte[] guid = new byte[16];
        guid[0] = 46; guid[1] = 184; guid[2] = 94; guid[3] = 159;
        guid[4] = 46; guid[5] = 105; guid[6] = 143; guid[7] = 90;
        guid[8] = 185; guid[9] = 104; guid[10] = 173; guid[11] = 170;
        guid[12] = 163; guid[13] = 73; guid[14] = 221; guid[15] = 147;
        return guid;
    }

    private static byte[] HyfsDataTypeGuid() {
        // e9344e1c-1e85-5b78-9b94-488ef463fe7a
        byte[] guid = new byte[16];
        guid[0] = 28; guid[1] = 78; guid[2] = 52; guid[3] = 233;
        guid[4] = 133; guid[5] = 30; guid[6] = 120; guid[7] = 91;
        guid[8] = 155; guid[9] = 148; guid[10] = 72; guid[11] = 142;
        guid[12] = 244; guid[13] = 99; guid[14] = 254; guid[15] = 122;
        return guid;
    }

    private static int ValidateBootInfo(long bootInfo) {
        if (bootInfo < 4096) { return 1; }
        if (System.Kernel.Memory.Read32(bootInfo) != 1229083969) { return 2; }
        if (System.Kernel.Memory.Read32(bootInfo + 4) != 7) { return 3; }
        return 0;
    }

    public static int Run(long bootInfo) {
        int headerStatus = ValidateBootInfo(bootInfo);
        if (headerStatus != 0) { return headerStatus; }
        if (!KernelAddressSpace.Validate(bootInfo)) {
            System.Kernel.Memory.Write32(bootInfo + 1164, 1);
            return 21;
        }
        if (System.Kernel.Memory.Read32(bootInfo + 36) != 131071) { return 4; }
        if (System.Kernel.Memory.Read32(bootInfo + 304) == 0) { return 5; }
        if (System.Kernel.Memory.Read32(bootInfo + 316) != 512) { return 6; }
        if (System.Kernel.Memory.Read64(bootInfo + 384) == 0) { return 7; }
        long page = PhysicalPages.AllocateZeroed(bootInfo);
        if (page == 0 || System.Kernel.Memory.Read64(page + 8) != 0) { return 8; }
        System.Kernel.Memory.Write64(bootInfo + 480, page);
        System.Kernel.Memory.Write64(page + 8, 123456789);
        // Exercise the post-handoff ownership contract before managed runtime
        // allocations begin. The page is unmapped before it is returned to the
        // free pool, so later object allocation cannot retain a stale mapping.
        long mappingPage = PhysicalPages.AllocateZeroed(bootInfo);
        // Select a lower canonical PML4 slot outside the bootstrap identity
        // aperture, whose large leaves this API will not split.
        long mappingAddress = KernelAddressSpace.FindUnmappedPml4Base(bootInfo);
        if (mappingAddress == 0) { System.Kernel.Memory.Write32(bootInfo + 1200, 7); return 22; }
        if (mappingPage == 0) { System.Kernel.Memory.Write32(bootInfo + 1200, 1); return 22; }
        if (!KernelAddressSpace.MapPage(bootInfo, mappingAddress, mappingPage, KernelAddressSpace.ReadWrite())) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 2); return 22;
        }
        if (KernelAddressSpace.Translate(bootInfo, mappingAddress) != mappingPage) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 3); return 22;
        }
        if (KernelAddressSpace.IsExecutable(bootInfo, mappingAddress)) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 10); return 22;
        }
        if (!KernelAddressSpace.UnmapPage(bootInfo, mappingAddress)) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 4); return 22;
        }
        if (KernelAddressSpace.Translate(bootInfo, mappingAddress) != 0) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 5); return 22;
        }
        if (!PhysicalPages.Free(bootInfo, mappingPage)) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 6); return 22;
        }
        // A duplicate free must be rejected, and the next allocation must
        // return the original page after clearing its diagnostic state.
        if (PhysicalPages.Free(bootInfo, mappingPage)) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 8); return 22;
        }
        long reusedPage = PhysicalPages.AllocateZeroed(bootInfo);
        if (reusedPage != mappingPage || !PhysicalPages.Free(bootInfo, reusedPage)) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 9); return 22;
        }
        long stableNext = 0;
        long stableFree = 0;
        int mappingCycle = 0;
        while (mappingCycle < 64) {
            long frame = PhysicalPages.AllocateZeroed(bootInfo);
            if (frame == 0 || !KernelAddressSpace.MapPage(bootInfo, mappingAddress,
                frame, KernelAddressSpace.ReadWrite())) {
                System.Kernel.Memory.Write32(bootInfo + 1200, 11); return 22;
            }
            System.Kernel.Memory.Write64(mappingAddress + 8, mappingCycle + 1);
            if (System.Kernel.Memory.Read64(frame + 8) != mappingCycle + 1 ||
                !KernelAddressSpace.UnmapPage(bootInfo, mappingAddress) ||
                KernelAddressSpace.Translate(bootInfo, mappingAddress) != 0 ||
                !PhysicalPages.Free(bootInfo, frame)) {
                System.Kernel.Memory.Write32(bootInfo + 1200, 12); return 22;
            }
            long cycleNext = System.Kernel.Memory.Read64(bootInfo + 40);
            long cycleFree = System.Kernel.Memory.Read64(bootInfo + 1192);
            if (mappingCycle == 0) { stableNext = cycleNext; stableFree = cycleFree; }
            else if (cycleNext != stableNext || cycleFree != stableFree ||
                System.Kernel.Memory.Read64(bootInfo + 1216) != 0) {
                System.Kernel.Memory.Write32(bootInfo + 1200, 13); return 22;
            }
            mappingCycle = mappingCycle + 1;
        }
        byte[] scratch = new byte[16];
        scratch[0] = 42;
        scratch[15] = 99;
        if (scratch.Length != 16 || scratch[0] != 42 || scratch[15] != 99) { return 9; }
        KernelCounter counter = new KernelCounter(57);
        if (counter.Value() != 57) { return 10; }
        string greeting = "Australis";
        if (greeting.Length != 9) { return 11; }
        // Each managed kind owns its page span and can hand it back for reuse.
        KernelCounter ownedObject = new KernelCounter(7);
        long ownedPage = System.Kernel.Memory.Read64(bootInfo + 72);
        if (!System.Kernel.Managed.Release(ownedObject) ||
            System.Kernel.Managed.Release(ownedObject)) {
            System.Kernel.Memory.Write32(bootInfo + 1204, 1); return 24;
        }
        byte[] ownedArray = new byte[64];
        if (System.Kernel.Memory.Read64(bootInfo + 72) != ownedPage ||
            ownedArray.Length != 64 || !System.Kernel.Managed.Release(ownedArray)) {
            System.Kernel.Memory.Write32(bootInfo + 1204, 2); return 24;
        }
        string ownedString = "managed release";
        if (System.Kernel.Memory.Read64(bootInfo + 72) != ownedPage ||
            ownedString.Length != 15 || !System.Kernel.Managed.Release(ownedString)) {
            System.Kernel.Memory.Write32(bootInfo + 1204, 3); return 24;
        }
        long managedNext = System.Kernel.Memory.Read64(bootInfo + 40);
        long managedFree = System.Kernel.Memory.Read64(bootInfo + 1192);
        int allocationCycle = 0;
        while (allocationCycle < 128) {
            KernelCounter temporaryObject = new KernelCounter(allocationCycle);
            if (temporaryObject.Value() != allocationCycle ||
                !System.Kernel.Managed.Release(temporaryObject)) {
                System.Kernel.Memory.Write32(bootInfo + 1204, 4); return 24;
            }
            byte[] temporaryArray = new byte[64];
            temporaryArray[63] = (byte)(allocationCycle % 256);
            if (temporaryArray[63] != allocationCycle % 256 ||
                !System.Kernel.Managed.Release(temporaryArray)) {
                System.Kernel.Memory.Write32(bootInfo + 1204, 5); return 24;
            }
            string temporaryString = "reuse";
            if (temporaryString.Length != 5 || !System.Kernel.Managed.Release(temporaryString) ||
                System.Kernel.Memory.Read64(bootInfo + 40) != managedNext ||
                System.Kernel.Memory.Read64(bootInfo + 1192) != managedFree) {
                System.Kernel.Memory.Write32(bootInfo + 1204, 6); return 24;
            }
            allocationCycle = allocationCycle + 1;
        }
        byte[] largeManagedArray = new byte[1024];
        long largeBase = System.Kernel.Memory.Read64(bootInfo + 72);
        largeManagedArray[1023] = 73;
        if (largeManagedArray[1023] != 73 || !System.Kernel.Managed.Release(largeManagedArray)) {
            System.Kernel.Memory.Write32(bootInfo + 1204, 7); return 24;
        }
        long released2 = PhysicalPages.AllocateZeroed(bootInfo);
        long released1 = PhysicalPages.AllocateZeroed(bootInfo);
        long released0 = PhysicalPages.AllocateZeroed(bootInfo);
        if (released2 != largeBase + 8192 || released1 != largeBase + 4096 ||
            released0 != largeBase || !PhysicalPages.Free(bootInfo, released2) ||
            !PhysicalPages.Free(bootInfo, released1) || !PhysicalPages.Free(bootInfo, released0)) {
            System.Kernel.Memory.Write32(bootInfo + 1204, 8); return 24;
        }
        // Calibrate the invariant TSC against PIT channel 2 before any live
        // controller starts a deadline-based wait.
        if (!Australis.Kernel.Time.KernelClock.Calibrate(bootInfo)) { return 25; }

        // The bootloader reserves 64 contiguous low pages. Storage retains the
        // first sixteen; runtime USB owners allocate and release the remainder.
        Australis.Kernel.Dma.DmaAllocator dmaPool =
            Australis.Kernel.Dma.NativeDmaPool.Create(bootInfo, false);
        if (!dmaPool.Supported() || dmaPool.CapacityPages() != 48) {
            System.Kernel.Memory.Write32(bootInfo + 2360, 1); return 26;
        }
        int dmaCycle = 0;
        while (dmaCycle < 128) {
            Australis.Kernel.Dma.DmaAllocation commandDma = dmaPool.Allocate(2);
            Australis.Kernel.Dma.DmaAllocation transferDma = dmaPool.Allocate(8);
            if (commandDma == null || transferDma == null || dmaPool.AllocatedPages() != 10) {
                System.Kernel.Memory.Write32(bootInfo + 2360, 2); return 26;
            }
            Australis.Kernel.Dma.NativeDmaPool.PrepareForDevice(commandDma);
            Australis.Kernel.Dma.NativeDmaPool.CompleteFromDevice(transferDma);
            if (!dmaPool.Release(commandDma) || !dmaPool.Release(transferDma) ||
                dmaPool.AllocatedPages() != 0 || !System.Kernel.Managed.Release(commandDma) ||
                !System.Kernel.Managed.Release(transferDma)) {
                System.Kernel.Memory.Write32(bootInfo + 2360, 3); return 26;
            }
            dmaCycle = dmaCycle + 1;
        }

        // Size the complete xHCI BAR instead of assuming the bootstrap's 64 KiB
        // aperture. Its retained uncached mapping is the handoff to Stage 3.
        int xhciBdf = System.Kernel.Memory.Read32(bootInfo + 204);
        if (xhciBdf >= 0) {
            Australis.Kernel.Pci.NativePciConfigAccess pci =
                new Australis.Kernel.Pci.NativePciConfigAccess();
            Australis.Kernel.Pci.PciBarInfo xhciBar =
                Australis.Kernel.Pci.PciBars.Probe(pci, xhciBdf, 0);
            if (!xhciBar.IsValid()) { System.Kernel.Memory.Write32(bootInfo + 2360, 4); return 26; }
            int mmioCycle = 0;
            long stableMmioNext = 0; long stableMmioFree = 0;
            while (mmioCycle < 32) {
                MmioRegion testRegion = MmioMapper.Map(bootInfo, xhciBar.Address(), xhciBar.Size());
                if (testRegion == null || !testRegion.IsMapped() || !testRegion.Release() ||
                    !System.Kernel.Managed.Release(testRegion)) {
                    System.Kernel.Memory.Write32(bootInfo + 2360, 5); return 26;
                }
                long mmioNext = System.Kernel.Memory.Read64(bootInfo + 40);
                long mmioFree = System.Kernel.Memory.Read64(bootInfo + 1192);
                if (mmioCycle == 0) { stableMmioNext = mmioNext; stableMmioFree = mmioFree; }
                else if (mmioNext != stableMmioNext || mmioFree != stableMmioFree ||
                    System.Kernel.Memory.Read64(bootInfo + 1216) != 0) {
                    System.Kernel.Memory.Write32(bootInfo + 2360, 6); return 26;
                }
                mmioCycle = mmioCycle + 1;
            }
            MmioRegion xhciRegion = MmioMapper.Map(bootInfo, xhciBar.Address(), xhciBar.Size());
            if (xhciRegion == null) { System.Kernel.Memory.Write32(bootInfo + 2360, 7); return 26; }
            System.Kernel.Memory.Write64(bootInfo + 2368, xhciRegion.Address());
            System.Kernel.Memory.Write64(bootInfo + 2376, xhciRegion.ByteLength());
            int irqCycle = 0;
            while (irqCycle < 128) {
                if (!Australis.Kernel.Interrupts.NativeDeviceInterrupts.Register(
                    bootInfo, 1, xhciRegion.Address(), 1) ||
                    !Australis.Kernel.Interrupts.NativeDeviceInterrupts.Unregister(bootInfo, 1)) {
                    System.Kernel.Memory.Write32(bootInfo + 2360, 8); return 26;
                }
                irqCycle = irqCycle + 1;
            }
            System.Kernel.Memory.Write32(bootInfo + 2356, 1);
        }
        System.Kernel.Memory.Write32(bootInfo + 2360, 0);
        System.Kernel.Memory.Write32(bootInfo + 496, 0);
        Australis.Kernel.Storage.BlockDevice disk = null;
        if (System.Kernel.Memory.Read32(bootInfo + 304) == 2) {
            Australis.Kernel.Storage.NativeNvmeIo io = new Australis.Kernel.Storage.NativeNvmeIo(bootInfo);
            Australis.Kernel.Storage.NvmeController controller = new Australis.Kernel.Storage.NvmeController(io, 512);
            if (!StorageInterrupts.Configure(bootInfo, 2)) { return 23; }
            System.Kernel.Cpu.EnableInterrupts();
            if (!controller.Initialize()) {
                int cause = controller.LastError();
                if (cause == 0) { cause = 4; }
                io.ReportFailure(cause, 2);
                return 12;
            }
            disk = new Australis.Kernel.Storage.BlockDevice(controller);
            byte[] gptHeader = new byte[512];
            if (disk.Read(1, 1, gptHeader) != 0) { return 13; }
            if (gptHeader[0] != 69 || gptHeader[1] != 70 || gptHeader[2] != 73 ||
                gptHeader[3] != 32 || gptHeader[4] != 80 || gptHeader[5] != 65 ||
                gptHeader[6] != 82 || gptHeader[7] != 84) { return 14; }
            System.Kernel.Memory.Write32(bootInfo + 496, 1);
        } else {
            Australis.Kernel.Storage.NativeAhciIo io = new Australis.Kernel.Storage.NativeAhciIo(bootInfo);
            Australis.Kernel.Storage.AhciController controller = new Australis.Kernel.Storage.AhciController(io, 512);
            if (!StorageInterrupts.Configure(bootInfo, 1)) { return 23; }
            System.Kernel.Cpu.EnableInterrupts();
            if (!controller.Initialize()) {
                int cause = controller.LastError();
                if (cause == 0) { cause = 7; }
                io.ReportFailure(cause, 2);
                return 17;
            }
            disk = new Australis.Kernel.Storage.BlockDevice(controller);
            byte[] ahciHeader = new byte[512];
            if (disk.Read(1, 1, ahciHeader) != 0 || ahciHeader[0] != 69 || controller.LastError() != 0) { return 18; }
        }
        Australis.Kernel.Storage.GptDisk gpt = new Australis.Kernel.Storage.GptDisk();
        int gptStatus = gpt.Open(disk);
        System.Kernel.Memory.Write32(bootInfo + 504, gptStatus);
        System.Kernel.Memory.Write32(bootInfo + 508, disk.LastStatus());
        if (gptStatus != 0) { return 15; }
        Australis.Kernel.Storage.Partition partition = gpt.FirstPresent();
        if (!partition.Present() || partition.FirstLba() != System.Kernel.Memory.Read64(bootInfo + 376) ||
            partition.BlockCount() != System.Kernel.Memory.Read64(bootInfo + 384)) { return 16; }
        System.Kernel.Memory.Write32(bootInfo + 500, 1);

        Australis.Kernel.Storage.Partition root = gpt.FirstWithTypeGuid(HyfsTypeGuid());
        if (gpt.LastStatus() != Australis.Kernel.Storage.GptDiskStatus.Ok() || !root.Present()) { return 19; }
        System.Kernel.Memory.Write64(bootInfo + 1096, root.FirstLba());
        System.Kernel.Memory.Write64(bootInfo + 1104, root.BlockCount());
        Australis.Kernel.Vfs.Vfs vfs = new Australis.Kernel.Vfs.Vfs();
        int mountStatus = vfs.MountRoot(new Australis.Kernel.Vfs.HyfsAuto(), disk, root);
        System.Kernel.Memory.Write32(bootInfo + 1076, mountStatus);
        if (mountStatus != Australis.Kernel.Vfs.VfsStatus.Ok() || !vfs.IsRootMounted()) { return 20; }
        int rootState = 1;
        System.Kernel.Memory.Write32(bootInfo + 1072, rootState);

        // Keep the boot image read-only. The separately typed raw HyFS 2 data
        // partition is the persistent writable volume at /data.
        Australis.Kernel.Vfs.Vfs dataVfs = new Australis.Kernel.Vfs.Vfs();
        Australis.Kernel.Storage.Partition dataPartition =
            gpt.FirstWithTypeGuid(HyfsDataTypeGuid());
        if (gpt.LastStatus() == Australis.Kernel.Storage.GptDiskStatus.Ok() &&
            dataPartition.Present() && dataPartition.FirstLba() >= 0 &&
            dataPartition.BlockCount() > 0 &&
            dataPartition.FirstLba() < disk.SectorCount() &&
            dataPartition.BlockCount() <= disk.SectorCount() - dataPartition.FirstLba() &&
            (dataPartition.FirstLba() >= root.FirstLba() + root.BlockCount() ||
             root.FirstLba() >= dataPartition.FirstLba() + dataPartition.BlockCount())) {
            System.Kernel.Memory.Write64(bootInfo + 2696, dataPartition.FirstLba());
            System.Kernel.Memory.Write64(bootInfo + 2704, dataPartition.BlockCount());
            int dataMount = dataVfs.MountRootWritableAs(
                new Australis.Kernel.Vfs.Hyfs2(), disk, dataPartition, 3);
            System.Kernel.Memory.Write32(bootInfo + 2692, dataMount);
            if (dataMount == Australis.Kernel.Vfs.VfsStatus.Ok()) {
                Australis.Kernel.Vfs.VfsNamespace dataNamespace =
                    new Australis.Kernel.Vfs.VfsNamespace(vfs, null, dataVfs);
                Australis.Kernel.Vfs.VfsPath dataPath = dataNamespace.Resolve("/data");
                Australis.Kernel.Vfs.VfsFileInfo dataInfo = dataNamespace.Stat("/data");
                if (dataPath.IsValid() && dataPath.Volume() == dataVfs &&
                    dataPath.LocalPath() == "/" && dataInfo.Exists() &&
                    dataInfo.Kind() == 2) {
                    System.Kernel.Memory.Write32(bootInfo + 2688, 1);
                    System.Kernel.Memory.Write32(bootInfo + 2712,
                        Australis.Kernel.Storage.DataVolumeProbe.Run(disk, dataPartition));
                }
            }
        }

        // These bounded reads publish diagnostics for the boot image. A valid
        // root with different files remains bootable; QEMU verifies both
        // fixture files and their complete checksums separately.
        Australis.Kernel.Vfs.VfsFileInfo helloInfo = vfs.StatRootFile("/hello.txt");
        if (helloInfo.Exists() && helloInfo.ByteLength() <= 2048) {
            byte[] hello = new byte[(int)helloInfo.ByteLength()];
            int readStatus = vfs.ReadRootFile("/hello.txt", 0, hello);
            System.Kernel.Memory.Write32(bootInfo + 1112, readStatus);
            if (readStatus == Australis.Kernel.Vfs.VfsStatus.Ok()) {
                System.Kernel.Memory.Write64(bootInfo + 1080, helloInfo.ByteLength());
                System.Kernel.Memory.Write64(bootInfo + 1088,
                    Australis.Kernel.Storage.PartitionBytes.Crc32(hello, 0, hello.Length, hello.Length, 0));
                rootState = rootState + 2;
            }
        }

        Australis.Kernel.Vfs.VfsFileInfo readmeInfo = vfs.StatRootFile("/readme.txt");
        if (readmeInfo.Exists() && readmeInfo.ByteLength() <= 2048) {
            byte[] readme = new byte[(int)readmeInfo.ByteLength()];
            int readmeStatus = vfs.ReadRootFile("/readme.txt", 0, readme);
            System.Kernel.Memory.Write32(bootInfo + 1136, readmeStatus);
            if (readmeStatus == Australis.Kernel.Vfs.VfsStatus.Ok()) {
                System.Kernel.Memory.Write64(bootInfo + 1120, readmeInfo.ByteLength());
                System.Kernel.Memory.Write64(bootInfo + 1128,
                    Australis.Kernel.Storage.PartitionBytes.Crc32(readme, 0, readme.Length, readme.Length, 0));
                rootState = rootState + 4;
            }
        }
        System.Kernel.Memory.Write32(bootInfo + 1072, rootState);

        System.Kernel.Memory.Write32(bootInfo + 488, scratch[0] + counter.Value());
        System.Kernel.Memory.Write32(bootInfo + 492, greeting.Length);
        System.Kernel.Memory.Write32(bootInfo + 472, 1);
        System.Kernel.Memory.Write32(bootInfo + 36, 262143);
        Australis.Kernel.Console.SerialPort serial = new Australis.Kernel.Console.SerialPort(1016, bootInfo);
        bool serialReady = serial.Initialize();
        if (serialReady) {
            int serialFlags = 1;
            if (serial.ReceiveInterruptsEnabled()) { serialFlags = serialFlags + 2; }
            System.Kernel.Memory.Write32(bootInfo + 1140, serialFlags);
        }
        System.Kernel.Cpu.EnableInterrupts();
        Australis.Kernel.Usb.NativeXhci usbKeyboard = null;
        bool usbKeyboardReady = false;
        Australis.Kernel.Vfs.Vfs removableVfs = new Australis.Kernel.Vfs.Vfs();
        if (xhciBdf >= 0 && System.Kernel.Memory.Read32(bootInfo + 2356) == 1) {
            usbKeyboard = new Australis.Kernel.Usb.NativeXhci(bootInfo, xhciBdf,
                System.Kernel.Memory.Read64(bootInfo + 2368),
                System.Kernel.Memory.Read64(bootInfo + 2376), dmaPool);
            usbKeyboardReady = usbKeyboard.Initialize();
            if (!usbKeyboardReady) {
                System.Kernel.Memory.Write32(bootInfo + 2432, 1);
                usbKeyboardReady = usbKeyboard.Initialize();
            }
            if (usbKeyboardReady && usbKeyboard.IsStorage()) {
                Australis.Kernel.Storage.BlockDevice usbDisk =
                    new Australis.Kernel.Storage.BlockDevice(usbKeyboard);
                Australis.Kernel.Storage.GptDisk usbGpt = new Australis.Kernel.Storage.GptDisk();
                int usbGptStatus = usbGpt.Open(usbDisk);
                System.Kernel.Memory.Write32(bootInfo + 2512, usbGptStatus);
                if (usbGptStatus == Australis.Kernel.Storage.GptDiskStatus.Ok()) {
                    Australis.Kernel.Storage.Partition usbRoot =
                        usbGpt.FirstWithTypeGuid(HyfsTypeGuid());
                    if (usbRoot.Present()) {
                        int usbMount = removableVfs.MountRootAs(
                            new Australis.Kernel.Vfs.HyfsAuto(), usbDisk, usbRoot, 2);
                        System.Kernel.Memory.Write32(bootInfo + 2516, usbMount);
                    }
                }
            }
        }
        if (serialReady) {
            Australis.Kernel.Console.FramebufferTerminal framebuffer =
                new Australis.Kernel.Console.FramebufferTerminal(bootInfo);
            Australis.Kernel.Console.ConsoleWriter output =
                new Australis.Kernel.Console.ConsoleWriter(serial, framebuffer);
            Australis.Kernel.Console.IConsoleInput shellInput = serial;
            if (usbKeyboardReady && usbKeyboard.IsKeyboard()) {
                shellInput = new Australis.Kernel.Console.ConsoleInputMux(serial, usbKeyboard);
            }
            Australis.Kernel.Console.ConsoleShell shell =
                new Australis.Kernel.Console.ConsoleShell(shellInput, output, vfs,
                    removableVfs, dataVfs, usbKeyboard, bootInfo);
            shell.Run();
        }
        while (true) { System.Kernel.Cpu.Halt(); }
        return 0;
    }
}
