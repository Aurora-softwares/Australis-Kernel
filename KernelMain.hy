// Freestanding kernel bring-up checklist (QEMU/OVMF, AHCI and NVMe):
//   🟢 Enter separate position-independent raw code on the kernel stack.
//   🟢 Validate KernelBootInfo and allocate a zeroed physical page.
//   🟢 Run page-backed object, array, and string allocation after handoff.
//   🟢 Reinitialize a live AHCI or NVMe controller through kernel MMIO/DMA.
//   🟢 Read sectors through BlockDevice and validate GPT through GptDisk.
//   🟢 Publish a ready state, enable interrupts, and own the idle loop.
//   🟢 Verify the complete entry and storage path in both QEMU boot tests.
//   🟢 Keep host-tested VFS, read-only HyFS, and USB protocol modules in source.
//   🟢 Select the HyFS GPT type, mount a live root, and read checked files
//       through the VFS on both AHCI and NVMe, including multiple sectors.
//   🟢 Bring up COM1 after handoff and run an interactive kernel shell with
//       bounded line editing, help, echo, ls, cat, and version over serial.
//   🟢 Route COM1 through a shared event queue and reusable line editor, then
//       mirror output to a cursor-controlled scrolling framebuffer terminal.
//   🟢 Protect persistent kernel allocations from shell temporaries, record
//       allocation faults, and wake COM1 input through a PIC IRQ handler.
//   🟢 Reuse freed physical pages and map/unmap explicit 4 KiB kernel pages
//       with a local TLB invalidation after every mapping transition.
//   🟢 Release individual managed objects, arrays, and strings; stress page
//       reuse and repeated map/unmap cycles before mounting the root.
//   🟢 Wait for AHCI MSI or NVMe MSI-X completions on vector 0x31, recover
//       one failed request through a controller reset, and retain diagnostics.
//   🟢 Add generation-checked file handles and canonical mount traversal.
//   🔴 Add FAT/FAT32 and NTFS drivers if those volumes become boot requirements.
//   🟢 Calibrate the TSC and replace controller poll budgets with deadlines.
//   🟢 Add reusable IRQ ownership, acknowledgement, and deferred device events.
//   🔴 Add automatic managed lifetime tracking.
//   🟢 Bring up one live xHCI root device and route boot-keyboard reports into
//       the shared COM1/framebuffer shell input path with bounded recovery.
//   🟢 Connect live USB mass storage to the existing BOT protocol layer.
//   🟢 Add the `exec` format, checked loader, file descriptors, system calls,
//       bounded cooperative scheduling, and a user shell command registry.
//   🔴 Add native ring-3 processes and preemptive threads after the checked
//       AUEX boundary has established the user-facing contracts.
//
// This method graph is compiled as position-independent freestanding x86-64
// code. The handoff passes the writable KernelBootInfo address as a long.
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

    private static int RunRecovery(long bootInfo) {
        // This monitor needs no mounted volume or AUEX image. Explicit R boot
        // enters here before storage startup; a normal boot can also enter
        // after a failed GPT or root mount.
        System.Kernel.Memory.Write32(bootInfo + 3476, 1);
        Australis.Kernel.Console.SerialPort serial =
            new Australis.Kernel.Console.SerialPort(1016, bootInfo);
        bool serialReady = serial.Initialize();
        if (serialReady) {
            int serialFlags = 1;
            if (serial.ReceiveInterruptsEnabled()) { serialFlags = serialFlags + 2; }
            System.Kernel.Memory.Write32(bootInfo + 1140, serialFlags);
        }
        System.Kernel.Cpu.EnableInterrupts();
        if (serialReady) {
            Australis.Kernel.Console.FramebufferTerminal framebuffer =
                new Australis.Kernel.Console.FramebufferTerminal(bootInfo);
            Australis.Kernel.Console.ConsoleWriter output =
                new Australis.Kernel.Console.ConsoleWriter(serial, framebuffer);
            Australis.Kernel.Vfs.Vfs unavailableRoot = new Australis.Kernel.Vfs.Vfs();
            Australis.Kernel.Vfs.Vfs unavailableRemovable = new Australis.Kernel.Vfs.Vfs();
            Australis.Kernel.Vfs.Vfs unavailableData = new Australis.Kernel.Vfs.Vfs();
            Australis.Kernel.Console.ConsoleShell shell =
                new Australis.Kernel.Console.ConsoleShell(serial, output, unavailableRoot,
                    unavailableRemovable, unavailableData, null, bootInfo);
            System.Kernel.Memory.Write32(bootInfo + 3476, 2);
            shell.Run();
        }
        while (true) { System.Kernel.Cpu.Halt(); }
        return 0;
    }

    public static int Run(long bootInfo) {
        int headerStatus = ValidateBootInfo(bootInfo);
        if (headerStatus != 0) { return headerStatus; }
        if (!PhysicalPages.Initialize(bootInfo)) { return 29; }
        if (!KernelAddressSpace.Validate(bootInfo)) {
            System.Kernel.Memory.Write32(bootInfo + 1164, 1);
            return 21;
        }

        // Reserve one permanent 4 KiB scratch page for Hydrogen's kernel panic QR generator.
        //
        // Allocate while the kernel is healthy. Never allocate during an actual panic.
        //
        // KernelBootInfo + 3664: uint64 panicQrScratchAddress
        if (System.Kernel.Memory.Read64(bootInfo + 3664) != 0) {
            return 30;
        }

        long panicQrScratch = PhysicalPages.AllocateZeroed(bootInfo);
        if (panicQrScratch == 0 ||
            panicQrScratch % 4096 != 0) {
            return 30;
        }

        // Verify that the page was zero-initialised.
        if (System.Kernel.Memory.Read64(panicQrScratch) != 0 ||
            System.Kernel.Memory.Read64(panicQrScratch + 4088) != 0) {
            return 30;
        }

        // Publish the address only after successful allocation.
        System.Kernel.Memory.Write64(bootInfo + 3664, panicQrScratch);

        // Reserve a permanent 16 KiB emergency stack.
        //
        // Allocation occurs while the kernel is healthy.
        // The exception handler must never allocate memory.
        //
        // +3672 = stack base
        // +3680 = stack top (exclusive)

        if (System.Kernel.Memory.Read64(bootInfo + 3672) != 0 ||
            System.Kernel.Memory.Read64(bootInfo + 3680) != 0) {
            return 31;
        }

        long panicStackBase = PhysicalPages.AllocateZeroed(bootInfo);

        if (panicStackBase == 0 || panicStackBase % 4096 != 0) {
            return 31;
        }

        // Stack pages must be physically contiguous.
        int panicStackPage = 1;

        while (panicStackPage < 4) {
            long nextStackPage = PhysicalPages.AllocateZeroed(bootInfo);

            if (nextStackPage != panicStackBase + (long)panicStackPage * 4096) {
                return 31;
            }

            panicStackPage = panicStackPage + 1;
        }

        System.Kernel.Memory.Write64(bootInfo + 3672, panicStackBase);

        System.Kernel.Memory.Write64(bootInfo + 3680, panicStackBase + 16384);

        // Debug-boot QR self-test.
        //
        // Boot mode 1 is Debug mode.
        // Normal boot does not execute this test.
        //
        // Generate the complete QR matrix on the healthy
        // kernel stack, without triggering an exception.
        //
        // The matrix stays in the reserved scratch page
        // so QEMU can inspect it after startup.

        if (System.Kernel.Memory.Read32(bootInfo + 3472) == 1) {

            int qrTestResult = Australis.Kernel.Diagnostics.PanicQr.SelfTest(bootInfo);
			int qrDrawResult = 0;
			if (qrTestResult == 0) {
				qrDrawResult = Australis.Kernel.Diagnostics.QrRenderer.DrawFramebufferV3L(bootInfo, panicQrScratch);
			}

			System.Kernel.Memory.Write32(panicQrScratch + 1912, qrDrawResult);

            // Store an identifying marker and result in
            // otherwise unused scratch-page bytes.
            //
            // QR matrices end before offset 1897.

            System.Kernel.Memory.Write32(
                panicQrScratch + 1904,
                0x51525354);

            System.Kernel.Memory.Write32(
                panicQrScratch + 1908,
                qrTestResult);
        }

        if (System.Kernel.Memory.Read32(bootInfo + 3472) == 3) {
            return RunRecovery(bootInfo);
        }
        if (System.Kernel.Memory.Read32(bootInfo + 36) != 131071) { return 4; }
        if (System.Kernel.Memory.Read32(bootInfo + 304) == 0) { return 5; }
        if (System.Kernel.Memory.Read32(bootInfo + 316) != 512) { return 6; }
        if (System.Kernel.Memory.Read64(bootInfo + 384) == 0) { return 7; }
        long page = PhysicalPages.AllocateZeroed(bootInfo);
        if (page == 0 || System.Kernel.Memory.Read64(page + 8) != 0) { return 8; }
        if (PhysicalPages.Free(bootInfo, bootInfo) ||
            PhysicalPages.Free(bootInfo, page + 1) ||
            PhysicalPages.Free(bootInfo, System.Kernel.Memory.Read64(bootInfo + 3608) - 4096)) {
            System.Kernel.Memory.Write32(bootInfo + 1200, 14); return 22;
        }
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
        if (!NativeUserPageTables.Probe(bootInfo)) { return 28; }
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

        // The bootloader reserves 2112 contiguous low pages. Storage retains
        // the first sixteen; runtime USB and GPU share the remaining pool.
        Australis.Kernel.Dma.DmaAllocator dmaPool =
            Australis.Kernel.Dma.NativeDmaPool.Create(bootInfo, false);
        if (!dmaPool.Supported() || dmaPool.CapacityPages() != 5168) {
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
            long oversizedMask = 65536;
            oversizedMask = oversizedMask * 65536;
            if (Australis.Kernel.Interrupts.NativeDeviceInterrupts.Unregister(bootInfo, 0) ||
                Australis.Kernel.Interrupts.NativeDeviceInterrupts.Register(
                    bootInfo, 1, xhciRegion.Address() + 1, 1) ||
                Australis.Kernel.Interrupts.NativeDeviceInterrupts.Register(
                    bootInfo, 1, xhciRegion.Address(), oversizedMask)) {
                System.Kernel.Memory.Write32(bootInfo + 2360, 10); return 26;
            }
            int irqCycle = 0;
            while (irqCycle < 128) {
                if (!Australis.Kernel.Interrupts.NativeDeviceInterrupts.Register(
                    bootInfo, 1, xhciRegion.Address(), 1)) {
                    System.Kernel.Memory.Write32(bootInfo + 2360, 8); return 26;
                }
                if (!Australis.Kernel.Interrupts.NativeDeviceInterrupts.Unregister(bootInfo, 1)) {
                    System.Kernel.Memory.Write32(bootInfo + 2360, 9); return 26;
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
        if (gptStatus != 0) { return RunRecovery(bootInfo); }
        Australis.Kernel.Storage.Partition partition = gpt.FirstPresent();
        if (!partition.Present() || partition.FirstLba() != System.Kernel.Memory.Read64(bootInfo + 376) ||
            partition.BlockCount() != System.Kernel.Memory.Read64(bootInfo + 384)) {
            return RunRecovery(bootInfo);
        }
        System.Kernel.Memory.Write32(bootInfo + 500, 1);

        Australis.Kernel.Storage.Partition root = gpt.FirstWithTypeGuid(HyfsTypeGuid());
        if (gpt.LastStatus() != Australis.Kernel.Storage.GptDiskStatus.Ok() ||
            !root.Present()) { return RunRecovery(bootInfo); }
        System.Kernel.Memory.Write64(bootInfo + 1096, root.FirstLba());
        System.Kernel.Memory.Write64(bootInfo + 1104, root.BlockCount());
        Australis.Kernel.Vfs.Vfs vfs = new Australis.Kernel.Vfs.Vfs();
        int mountStatus = vfs.MountRoot(new Australis.Kernel.Vfs.HyfsAuto(), disk, root);
        System.Kernel.Memory.Write32(bootInfo + 1076, mountStatus);
        if (mountStatus != Australis.Kernel.Vfs.VfsStatus.Ok() ||
            !vfs.IsRootMounted()) { return RunRecovery(bootInfo); }
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
            Australis.Kernel.Pci.NativePciConfigAccess gpuPci =
                new Australis.Kernel.Pci.NativePciConfigAccess();
            int gpuBdf = Australis.Kernel.Graphics.NativeVirtioGpuControl.FindGpu(gpuPci);
            if (gpuBdf >= 0) {
                Australis.Kernel.Graphics.NativeVirtioGpuControl gpuControl =
                    new Australis.Kernel.Graphics.NativeVirtioGpuControl();
                bool gpuOk = gpuControl.Initialize(bootInfo, gpuPci, gpuBdf);
                bool virglProbe = false;
                bool virglTextureProbe = false;
                bool virglSubmissionProbe = false;
                bool virglSurfaceUploadProbe = false;
                bool virglClearProbe = false;
                bool virglScanoutProbe = false;
                bool virglBlendStateProbe = false;
                bool virglPostFboClearProbe = false;
				bool virglSamplerStateProbe = false;
                bool virglShaderStateProbe = false;
                bool virglAlphaDrawProbe = false;
                bool virglTexturedAlphaProbe = false;
				bool virglUvShaderProbe = false;
				bool virglUvVertexProbe = false;
				bool virglUvPixelsProbe = false;
				bool virglUvPositionedProbe = false;
				bool virglUvOffsetProbe = false;
				bool virglUvMultiRectangleProbe = false;
				bool virglUvOverlapProbe = false;
                bool virglClearSubmitted = false;
                bool virglDownloaded = false;
				bool virglPersistentVertexProbe = false;
				bool virglPersistentReuseProbe = false;
                bool virglTwoSourceProbe = false;
                bool virglPersistentSamplerProbe = false;
                bool persistentSamplerSourceSafe = true;
                bool virglPersistentSamplerDrawProbe = false;
                bool virglFrameComposerProbe = false;
                bool virglNonSquareViewportProbe = false;
                long virglPixel = 0;
                Australis.Kernel.Dma.DmaAllocation probeTexture = null;
                long gpuBacking = 0;
                if (gpuOk) {
                    gpuBacking = PhysicalPages.AllocateZeroed(bootInfo);
                    if (gpuBacking == 0) { gpuOk = false; }
                }
                if (gpuOk) {
                    int pixel = 0;
                    while (pixel < 1024) {
                        System.Kernel.Memory.Write32(gpuBacking + pixel * 4,
                            0x3366CC);
                        pixel = pixel + 1;
                    }
                    Australis.Kernel.Graphics.VirtioGpu2D gpu2d =
                        new Australis.Kernel.Graphics.VirtioGpu2D(gpuControl);
                    gpuOk = gpu2d.Create(32, 32, gpuBacking, 4096);
                    if (gpuOk) { gpuOk = gpu2d.Scanout(0); }
                    if (gpuOk) { gpuOk = gpu2d.Update(0, 0, 32, 32); }
                    if (gpu2d.Current() != null) {
                        if (!gpu2d.DisableScanout(0)) { gpuOk = false; }
                        if (!gpu2d.Destroy()) { gpuOk = false; }
                    }
                    if (gpuOk && gpuControl.VirglAvailable()) {
                        Australis.Kernel.Graphics.VirtioGpu3D gpu3d =
                            new Australis.Kernel.Graphics.VirtioGpu3D(
                                gpuControl, true, gpuControl.CapsetCount());
                        virglProbe = gpu3d.Probe();
                        if (virglProbe) {
                            virglProbe = gpu3d.CreateContext();
                        }
                        if (virglProbe) {
                            probeTexture = dmaPool.Allocate(4);
                            if (probeTexture != null) {
                                int texel = 0;
                                while (texel < 4096) {
                                    System.Kernel.Memory.Write32(
                                        probeTexture.Address() + texel * 4,
                                        0xFF3366CC);
                                    texel = texel + 1;
                                }
                                System.Kernel.Memory.Fence();
                                Australis.Kernel.Graphics.IRenderSurface
                                    probeSurface =
                                    new Australis.Kernel.Graphics.VirglRenderSurface(
                                        gpu3d, 64, 64,
                                        probeTexture.Address(), 16384);
                                virglTextureProbe = probeSurface.Ready();
                                if (virglTextureProbe) {
                                    byte[] noop = new byte[4];
                                    virglSubmissionProbe =
                                        gpu3d.SubmitKernelCommands(noop, 4);
                                    if (virglSubmissionProbe) {
                                        Australis.Kernel.Graphics.PixelSurface
                                            uploadPixels =
                                            new Australis.Kernel.Graphics.PixelSurface(
                                                64, 64);
                                        Australis.Kernel.Graphics.PixelSurface
                                            uploadReadback =
                                            new Australis.Kernel.Graphics.PixelSurface(
                                                64, 64);
                                        virglSurfaceUploadProbe =
                                            uploadPixels.Fill(0x112233) &&
                                            probeSurface.Upload(uploadPixels) &&
                                            probeSurface.Readback(uploadReadback) &&
                                            uploadReadback.Pixel(0, 0) ==
                                                0x112233 &&
                                            uploadReadback.Pixel(63, 63) ==
                                                0x112233;
                                        virglClearSubmitted =
                                            virglSurfaceUploadProbe &&
                                            probeSurface.Clear(0x228844);
                                        if (virglClearSubmitted) {
                                            Australis.Kernel.Graphics.PixelSurface
                                                downloadedPixels =
                                                new Australis.Kernel.Graphics.PixelSurface(
                                                    64, 64);
                                            virglDownloaded =
                                                probeSurface.Readback(
                                                    downloadedPixels);
                                            if (virglDownloaded) {
                                                virglPixel =
                                                    downloadedPixels.Pixel(0, 0);
                                            }
                                        }
                                        if (virglDownloaded) {
                                            int red = (int)(virglPixel /
                                                65536 % 256);
                                            int green = (int)(virglPixel /
                                                256 % 256);
                                            int blue = (int)(virglPixel % 256);
                                            virglClearProbe =
                                                red >= 34 && red <= 35 &&
                                                green >= 136 &&
                                                green <= 137 && blue == 68;
                                        }
                                        virglBlendStateProbe = gpu3d.ProbeBlendState();
                                        if (virglBlendStateProbe) {
                                            Australis.Kernel.Graphics.PixelSurface cleared = new Australis.Kernel.Graphics.PixelSurface(64, 64);
                                            virglPostFboClearProbe = gpu3d.ClearTexture(0x0000FF) && probeSurface.Readback(cleared) &&cleared.Pixel(32, 32) / 65536 % 256 <= 2 && cleared.Pixel(32, 32) / 256 % 256 <= 2 && cleared.Pixel(32, 32) % 256 >= 254;
											virglShaderStateProbe = gpu3d.ProbeShaderState();
                                        }
                                        Australis.Kernel.Dma.DmaAllocation vertexPage = null;
                                        if (virglShaderStateProbe) {
                                            vertexPage = dmaPool.Allocate(1);
                                        }
                                        if (vertexPage != null && vertexPage.Owned() && gpu3d.ProbeAlphaTriangle(vertexPage.Address())) {
                                            Australis.Kernel.Graphics.PixelSurface blended = new Australis.Kernel.Graphics.PixelSurface(64, 64);
                                            if (probeSurface.Readback(blended)) {
                                                int color =
                                                    blended.Pixel(32, 32);
                                                int red = color / 65536 % 256;
                                                int green = color / 256 % 256;
                                                int blue = color % 256;
                                                virglAlphaDrawProbe =
                                                    red >= 120 && red <= 136 &&
                                                    green >= 119 &&
                                                    green <= 136 && blue <= 4;
                                            }
                                        }
                                        // The sampler is independent of the
                                        // solid-color alpha draw, and must be
                                        // bound before the textured draw.
                                        virglSamplerStateProbe = gpu3d.ProbeCreateSamplerState();
                                        if (virglAlphaDrawProbe &&
                                            virglSamplerStateProbe) {
                                            Australis.Kernel.Dma.DmaAllocation
                                                sampleBacking =
                                                dmaPool.Allocate(4);
                                            if (sampleBacking != null &&
                                                sampleBacking.Owned()) {
												int texel = 0;
												while (texel < 4096) {
													int x = texel % 64;
													int color = 0x800000FF; // 50% blue
													if (x < 32) {
														color = 0x80FF0000; // 50% red
													}
													System.Kernel.Memory.Write32(sampleBacking.Address() + texel * 4, color);
													texel = texel + 1;
												}
												System.Kernel.Memory.Fence();
                                                Australis.Kernel.Graphics.VirtioGpu3D
                                                    sampleGpu = new
                                                    Australis.Kernel.Graphics.VirtioGpu3D(
                                                        gpuControl, true,
                                                        gpuControl.CapsetCount(),
                                                        2, 65537);
                                                bool sampleContext =
                                                    sampleGpu.Probe() &&
                                                    sampleGpu.CreateContext();
                                                if (sampleContext && sampleGpu.CreateTexture(64, 64, sampleBacking.Address(), 16384) && gpu3d.ProbeTexturedAlphaFrom(sampleGpu)) {
                                                    Australis.Kernel.Graphics.PixelSurface sampled = new Australis.Kernel.Graphics.PixelSurface(64, 64);
                                                    if (probeSurface.Readback(sampled)) {
                                                        int color = sampled.Pixel(32, 32);
                                                        int red = color / 65536 % 256;
                                                        int green = color / 256 % 256;
                                                        int blue = color % 256;
                                                        virglTexturedAlphaProbe = red <= 4 && green >= 119 && green <= 136 && blue >= 120 && blue <= 136;
														virglUvShaderProbe = virglTexturedAlphaProbe && gpu3d.ProbeUvShaderState();
														virglUvVertexProbe = virglUvShaderProbe && gpu3d.ProbeUvVertexElements();
														if (virglUvVertexProbe) {
															Australis.Kernel.Dma.DmaAllocation uvPage = dmaPool.Allocate(1);
															if (uvPage != null && uvPage.Owned()) {
																bool drawn = gpu3d.ProbeUvMappedDrawFrom(
																	sampleGpu, uvPage.Address());

																// Only release DMA memory after confirmed GPU cleanup.
																bool safeToRelease = drawn;

																// ==========================================
																// Test 1: Fullscreen UV texture mapping
																// ==========================================

																if (drawn) {
																	Australis.Kernel.Graphics.PixelSurface result =
																		new Australis.Kernel.Graphics.PixelSurface(64, 64);

																	if (probeSurface.Readback(result)) {
																		int left = result.Pixel(16, 32);
																		int right = result.Pixel(48, 32);

																		int lr = left / 65536 % 256;
																		int lg = left / 256 % 256;
																		int lb = left % 256;

																		int rr = right / 65536 % 256;
																		int rg = right / 256 % 256;
																		int rb = right % 256;

																		virglUvPixelsProbe =
																			lr >= 120 && lr <= 136 &&
																			lg >= 119 && lg <= 136 &&
																			lb <= 8 &&
																			rr <= 8 &&
																			rg >= 119 && rg <= 136 &&
																			rb >= 120 && rb <= 136;
																	}
																}

																// ==========================================
																// Test 2: Positioned 32x32 UV rectangle
																// ==========================================

																if (virglUvPixelsProbe) {
																	bool resetOk = gpu3d.ClearTexture(0x00FF00);

																	if (resetOk) {
																		Australis.Kernel.Graphics.PixelSurface resetPixels =
																			new Australis.Kernel.Graphics.PixelSurface(64, 64);

																		if (probeSurface.Readback(resetPixels)) {
																			WriteUvPixel(output, "after reset outside",
																				resetPixels.Pixel(8, 8));
																			WriteUvPixel(output, "after reset inside ",
																				resetPixels.Pixel(24, 32));
																		} else {
																			output.WriteLine("UVDBG: reset readback failed");
																		}
																	} else {
																		output.WriteLine("UVDBG: reset clear failed");
																	}
																	output.WriteLine("UVDBG: starting positioned draw");

																	bool positionedDrawn =
																		gpu3d.ProbePositionedUvMappedDrawFrom(
																			sampleGpu, uvPage.Address());

																	// A failed draw may leave GPU resources attached.
																	safeToRelease = positionedDrawn;

																	if (positionedDrawn) {
																		output.WriteLine("UVDBG: draw and cleanup passed");

																		Australis.Kernel.Graphics.PixelSurface positioned =
																			new Australis.Kernel.Graphics.PixelSurface(64, 64);

																		if (probeSurface.Readback(positioned)) {
																			output.WriteLine("UVDBG: positioned readback passed");

																			int left = positioned.Pixel(24, 32);
																			int right = positioned.Pixel(40, 32);
																			int outsideA = positioned.Pixel(8, 8);
																			int outsideB = positioned.Pixel(56, 32);

																			WriteUvPixel(output, "inside left ", left);
																			WriteUvPixel(output, "inside right", right);
																			WriteUvPixel(output, "outside A   ", outsideA);
																			WriteUvPixel(output, "outside B   ", outsideB);

																			int lr = left / 65536 % 256;
																			int lg = left / 256 % 256;
																			int lb = left % 256;

																			int rr = right / 65536 % 256;
																			int rg = right / 256 % 256;
																			int rb = right % 256;

																			int ar = outsideA / 65536 % 256;
																			int ag = outsideA / 256 % 256;
																			int ab = outsideA % 256;

																			int br = outsideB / 65536 % 256;
																			int bg = outsideB / 256 % 256;
																			int bb = outsideB % 256;

																			virglUvPositionedProbe =
																				lr >= 120 && lr <= 136 &&
																				lg >= 119 && lg <= 136 &&
																				lb <= 8 &&

																				rr <= 8 &&
																				rg >= 119 && rg <= 136 &&
																				rb >= 120 && rb <= 136 &&

																				ar <= 4 &&
																				ag >= 250 &&
																				ab <= 4 &&

																				br <= 4 &&
																				bg >= 250 &&
																				bb <= 4;

																			if (virglUvPositionedProbe) {
																				output.WriteLine(
																					"UVDBG: positioned pixels correct");
																			} else {
																				output.WriteLine(
																					"UVDBG: positioned pixels incorrect");
																			}
																		} else {
																			output.WriteLine(
																				"UVDBG: positioned readback failed");
																		}
																	} else {
																		output.WriteLine(
																			"UVDBG: draw or cleanup failed");
																	}
																}

																// ==========================================
																// Test 3: off-centre, non-square rectangle
																// ==========================================
																
																if (virglUvPositionedProbe && safeToRelease) {
																	output.WriteLine("UVDBG: testing offset rectangle");
																	bool offsetDrawn = gpu3d.ProbeUvRectangleFrom(sampleGpu, uvPage.Address(), 8, 12, 24, 40);
																	// The draw method must finish GPU resource cleanup
																	// before we can safely return the DMA allocation.
																	safeToRelease = offsetDrawn;

																	if (offsetDrawn) {
																		Australis.Kernel.Graphics.PixelSurface offsetPixels =
																			new Australis.Kernel.Graphics.PixelSurface(64, 64);

																		if (probeSurface.Readback(offsetPixels)) {
																			int left = offsetPixels.Pixel(14, 32);
																			int right = offsetPixels.Pixel(26, 32);

																			int outsideLeft = offsetPixels.Pixel(4, 32);
																			int outsideRight = offsetPixels.Pixel(40, 32);
																			int outsideTop = offsetPixels.Pixel(14, 8);
																			int outsideBottom = offsetPixels.Pixel(14, 56);

																			int lr = left / 65536 % 256;
																			int lg = left / 256 % 256;
																			int lb = left % 256;

																			int rr = right / 65536 % 256;
																			int rg = right / 256 % 256;
																			int rb = right % 256;

																			bool leftCorrect =
																				lr >= 120 && lr <= 136 &&
																				lg >= 119 && lg <= 136 &&
																				lb <= 8;

																			bool rightCorrect =
																				rr <= 8 &&
																				rg >= 119 && rg <= 136 &&
																				rb >= 120 && rb <= 136;

																			bool outsideCorrect =
																				outsideLeft / 65536 % 256 <= 4 &&
																				outsideLeft / 256 % 256 >= 250 &&
																				outsideLeft % 256 <= 4 &&

																				outsideRight / 65536 % 256 <= 4 &&
																				outsideRight / 256 % 256 >= 250 &&
																				outsideRight % 256 <= 4 &&

																				outsideTop / 65536 % 256 <= 4 &&
																				outsideTop / 256 % 256 >= 250 &&
																				outsideTop % 256 <= 4 &&

																				outsideBottom / 65536 % 256 <= 4 &&
																				outsideBottom / 256 % 256 >= 250 &&
																				outsideBottom % 256 <= 4;

																			virglUvOffsetProbe =
																				leftCorrect &&
																				rightCorrect &&
																				outsideCorrect;

																			if (virglUvOffsetProbe) {
																				output.WriteLine(
																					"UVDBG: offset rectangle pixels correct");
																			} else {
																				output.WriteLine(
																					"UVDBG: offset rectangle pixels incorrect");

																				WriteUvPixel(output, "offset left", left);
																				WriteUvPixel(output, "offset right", right);
																				WriteUvPixel(output, "outside left", outsideLeft);
																				WriteUvPixel(output, "outside right", outsideRight);
																				WriteUvPixel(output, "outside top", outsideTop);
																				WriteUvPixel(output, "outside bottom", outsideBottom);
																			}
																		}
																	} else {
																		output.WriteLine(
																			"UVDBG: offset rectangle draw failed");
																	}
																}

																// ==========================================
																// Test 4: Test two sets of rectangles in one frame
																// ==========================================
																
																if (virglUvOffsetProbe && safeToRelease) {
																	output.WriteLine("UVDBG: testing multi-rectangle composition");

																	// Rectangle A is already on the target.
																	// Draw B without clearing A.
																	bool overlayDrawn =
																		gpu3d.ProbeUvRectangleOverlayFrom(
																			sampleGpu,
																			uvPage.Address(),
																			36, 16, 20, 24);

																	safeToRelease = overlayDrawn;

																	if (overlayDrawn) {
																		Australis.Kernel.Graphics.PixelSurface composed =
																			new Australis.Kernel.Graphics.PixelSurface(64, 64);

																		if (probeSurface.Readback(composed)) {
																			// Rectangle A must still be visible.
																			bool firstPreserved =
																				UvNearColor(
																					composed.Pixel(14, 32),
																					128, 127, 0) &&
																				UvNearColor(
																					composed.Pixel(26, 32),
																					0, 127, 128);

																			// Rectangle B must appear in its new position.
																			bool secondVisible =
																				UvNearColor(
																					composed.Pixel(41, 28),
																					128, 127, 0) &&
																				UvNearColor(
																					composed.Pixel(51, 28),
																					0, 127, 128);

																			// Everything outside A and B stays green.
																			bool backgroundPreserved =
																				UvNearColor(
																					composed.Pixel(4, 4),
																					0, 255, 0) &&
																				UvNearColor(
																					composed.Pixel(34, 32),
																					0, 255, 0) &&
																				UvNearColor(
																					composed.Pixel(60, 60),
																					0, 255, 0);

																			virglUvMultiRectangleProbe =
																				firstPreserved &&
																				secondVisible &&
																				backgroundPreserved;

																			if (virglUvMultiRectangleProbe) {
																				output.WriteLine(
																					"UVDBG: multi-rectangle composition correct");
																			} else {
																				output.WriteLine(
																					"UVDBG: multi-rectangle composition incorrect");

																				WriteUvPixel(output, "first left",
																					composed.Pixel(14, 32));
																				WriteUvPixel(output, "first right",
																					composed.Pixel(26, 32));
																				WriteUvPixel(output, "second left",
																					composed.Pixel(41, 28));
																				WriteUvPixel(output, "second right",
																					composed.Pixel(51, 28));
																				WriteUvPixel(output, "background",
																					composed.Pixel(34, 32));
																			}
																		}
																	} else {
																		output.WriteLine(
																			"UVDBG: multi-rectangle draw failed");
																	}
																}

																// ==========================================
																// Test 5: Test two sets of overlapping-rectangles in one frame
																// ==========================================

																if (virglUvMultiRectangleProbe && safeToRelease) {
																	output.WriteLine("UVDBG: testing overlapping rectangles");

																	// Start a new frame with a green background.
																	bool cleared = gpu3d.ClearTexture(0x00FF00);

																	if (cleared) {
																		// First rectangle: A.
																		bool firstDrawn =
																			gpu3d.ProbeUvRectangleOverlayFrom(
																				sampleGpu, uvPage.Address(),
																				8, 12, 24, 40);

																		safeToRelease = firstDrawn;

																		if (firstDrawn) {
																			// Second rectangle: B, overlapping A.
																			bool secondDrawn =
																				gpu3d.ProbeUvRectangleOverlayFrom(
																					sampleGpu, uvPage.Address(),
																					20, 20, 24, 24);

																			safeToRelease = secondDrawn;

																			if (secondDrawn) {
																				Australis.Kernel.Graphics.PixelSurface pixels = new Australis.Kernel.Graphics.PixelSurface(64, 64);

																				if (probeSurface.Readback(pixels)) {
																					// A remains visible outside B.
																					bool firstVisible = UvNearColor(pixels.Pixel(14, 32), 128, 127, 0);

																					// B remains visible outside A.
																					bool secondVisible = UvNearColor(pixels.Pixel(34, 32), 0, 127, 128);

																					// At (24,32), B's half-alpha red
																					// overlays A's half-alpha blue.
																					bool overlapCorrect = UvNearColor(pixels.Pixel(24, 32), 128, 63, 64);

																					// Untouched background remains green.
																					bool backgroundCorrect =
																						UvNearColor(
																							pixels.Pixel(4, 4),
																							0, 255, 0);

																					virglUvOverlapProbe =
																						firstVisible &&
																						secondVisible &&
																						overlapCorrect &&
																						backgroundCorrect;

																					if (virglUvOverlapProbe) {
																						output.WriteLine(
																							"UVDBG: overlapping alpha correct");
																					} else {
																						output.WriteLine(
																							"UVDBG: overlapping alpha incorrect");

																						WriteUvPixel(output, "A only",
																							pixels.Pixel(14, 32));
																						WriteUvPixel(output, "B only",
																							pixels.Pixel(38, 32));
																						WriteUvPixel(output, "overlap",
																							pixels.Pixel(24, 32));
																						WriteUvPixel(output, "background",
																							pixels.Pixel(4, 4));
																					}
																				}
																			}
																		}
																	}
																}

																// ==========================================
																// Test 5: Persistent vertex buffers
																// ==========================================


																if (virglUvOverlapProbe) {
																	output.WriteLine("GPUDBG: testing persistent vertex reuse");

																	Australis.Kernel.Dma.DmaAllocation persistentPage =
																		dmaPool.Allocate(1);

																	if (persistentPage != null &&
																		persistentPage.Owned()) {

																		bool created = gpu3d.CreatePersistentVertexBuffer(
																			persistentPage.Address());

																		bool ready = created &&
																			gpu3d.PersistentVertexBufferReady();

																		bool reused = false;

																		if (ready) {
																			output.WriteLine(
																				"GPUDBG: persistent buffer created");

																			// First rectangle: clear background, then draw A.
																			bool firstDrawn =
																				gpu3d.ProbeUvRectanglePersistentFrom(
																					sampleGpu, 8, 12, 24, 40, true);

																			if (firstDrawn) {
																				// Second rectangle: overwrite the SAME
																				// GPU vertex buffer with new coordinates.
																				// Preserve the existing destination image.
																				bool secondDrawn =
																					gpu3d.ProbeUvRectanglePersistentFrom(
																						sampleGpu, 36, 16, 20, 24, false);

																				if (secondDrawn) {
																					Australis.Kernel.Graphics.PixelSurface pixels =
																						new Australis.Kernel.Graphics.PixelSurface(
																							64, 64);

																					if (probeSurface.Readback(pixels)) {
																						bool firstVisible =
																							UvNearColor(
																								pixels.Pixel(14, 32),
																								128, 127, 0) &&
																							UvNearColor(
																								pixels.Pixel(26, 32),
																								0, 127, 128);

																						bool secondVisible =
																							UvNearColor(
																								pixels.Pixel(41, 28),
																								128, 127, 0) &&
																							UvNearColor(
																								pixels.Pixel(51, 28),
																								0, 127, 128);

																						bool backgroundCorrect =
																							UvNearColor(
																								pixels.Pixel(34, 32),
																								0, 255, 0) &&
																							UvNearColor(
																								pixels.Pixel(60, 60),
																								0, 255, 0);

																						reused =
																							firstVisible &&
																							secondVisible &&
																							backgroundCorrect;

																						if (reused) {
																							output.WriteLine(
																								"GPUDBG: persistent buffer reuse correct");
																						} else {
																							output.WriteLine(
																								"GPUDBG: persistent buffer reuse incorrect");

																							WriteUvPixel(output, "first left",
																								pixels.Pixel(14, 32));
																							WriteUvPixel(output, "first right",
																								pixels.Pixel(26, 32));
																							WriteUvPixel(output, "second left",
																								pixels.Pixel(41, 28));
																							WriteUvPixel(output, "second right",
																								pixels.Pixel(51, 28));
																						}
																					}
																				} else {
																					output.WriteLine(
																						"GPUDBG: second persistent draw failed");
																				}
																			} else {
																				output.WriteLine(
																					"GPUDBG: first persistent draw failed");
																			}
																		}
                                                                        if (ready && reused) {
                                                                            output.WriteLine("GPUDBG: testing two independent source textures");

                                                                            // Allocate backing for Window B.
                                                                            Australis.Kernel.Dma.DmaAllocation secondBacking = dmaPool.Allocate(4);

                                                                            if (secondBacking != null && secondBacking.Owned()) {
                                                                                // Window B is uniformly yellow at 50% alpha.
                                                                                // B8G8R8A8_UNORM, stored in little-endian memory.
                                                                                int texel = 0;

                                                                                while (texel < 4096) {
                                                                                    System.Kernel.Memory.Write32(secondBacking.Address() + texel * 4, 0x80FFFF00);
                                                                                    texel = texel + 1;
                                                                                }

                                                                                System.Kernel.Memory.Fence();
                                                                                // Separate source context and texture resource.
                                                                                Australis.Kernel.Graphics.VirtioGpu3D secondGpu = new Australis.Kernel.Graphics.VirtioGpu3D(gpuControl, true, gpuControl.CapsetCount(), 3, 65538);
                                                                                bool secondContext = secondGpu.Probe() && secondGpu.CreateContext();
                                                                                bool secondTexture = secondContext && secondGpu.CreateTexture(64, 64, secondBacking.Address(), 16384);
                                                                                bool pixelsCorrect = false;
                                                                                bool secondSamplerSourceSafe = true;

                                                                                if (secondTexture) {
                                                                                    // Clear once for the entire composition.
                                                                                    bool cleared = gpu3d.ClearTexture(0x00FF00);
                                                                                    // Window A: existing red/blue source.
                                                                                    bool firstDrawn = false;
                                                                                    if (cleared) {
                                                                                        firstDrawn =
                                                                                            gpu3d.ProbeUvRectanglePersistentFrom(
                                                                                                sampleGpu,
                                                                                                8, 12, 24, 40,
                                                                                                false);
                                                                                    }

                                                                                    // Window B: independent yellow source.
                                                                                    // Draw over A without clearing.
                                                                                    bool secondDrawn = false;

                                                                                    if (firstDrawn) {
                                                                                        secondDrawn =
                                                                                            gpu3d.ProbeUvRectanglePersistentFrom(
                                                                                                secondGpu,
                                                                                                20, 20, 24, 24,
                                                                                                false);
                                                                                    }

                                                                                    if (secondDrawn) {
                                                                                        Australis.Kernel.Graphics.PixelSurface pixels =
                                                                                            new Australis.Kernel.Graphics.PixelSurface(
                                                                                                64, 64);

                                                                                        if (probeSurface.Readback(pixels)) {
                                                                                            int aOnly = pixels.Pixel(14, 32);
                                                                                            int bOnly = pixels.Pixel(38, 32);
                                                                                            int overlap = pixels.Pixel(24, 32);
                                                                                            int background = pixels.Pixel(4, 4);

                                                                                            // A: half-alpha red over green.
                                                                                            bool aCorrect =
                                                                                                UvNearColor(
                                                                                                    aOnly,
                                                                                                    128, 127, 0);

                                                                                            // B: half-alpha yellow over green.
                                                                                            bool bCorrect =
                                                                                                UvNearColor(
                                                                                                    bOnly,
                                                                                                    128, 255, 0);

                                                                                            // B's yellow over A's blue/green.
                                                                                            bool overlapCorrect =
                                                                                                UvNearColor(
                                                                                                    overlap,
                                                                                                    128, 191, 64);

                                                                                            // Uncovered destination remains green.
                                                                                            bool backgroundCorrect =
                                                                                                UvNearColor(
                                                                                                    background,
                                                                                                    0, 255, 0);

                                                                                            pixelsCorrect =
                                                                                                aCorrect &&
                                                                                                bCorrect &&
                                                                                                overlapCorrect &&
                                                                                                backgroundCorrect;

                                                                                            if (pixelsCorrect) {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: two-source pixels correct");
                                                                                            } else {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: two-source pixels incorrect");

                                                                                                WriteUvPixel(output,
                                                                                                    "window A", aOnly);

                                                                                                WriteUvPixel(output,
                                                                                                    "window B", bOnly);

                                                                                                WriteUvPixel(output,
                                                                                                    "overlap", overlap);

                                                                                                WriteUvPixel(output,
                                                                                                    "background", background);
                                                                                            }
                                                                                        } else {
                                                                                            output.WriteLine(
                                                                                                "GPUDBG: two-source readback failed");
                                                                                        }
                                                                                    } else {
                                                                                        output.WriteLine("GPUDBG: two-source draw failed");
                                                                                    }

                                                                                    if (pixelsCorrect && gpu3d.PersistentVertexBufferReady()) {
                                                                                        output.WriteLine("GPUDBG: testing persistent sampler draws");
                                                                                        // Window A uses slot 0, handle 14.
                                                                                        bool viewA = gpu3d.CreatePersistentSamplerView(sampleGpu, 0);
                                                                                        // Window B uses slot 1, handle 15.
                                                                                        bool viewB = false;
                                                                                        if (viewA) {
                                                                                            viewB = gpu3d.CreatePersistentSamplerView(secondGpu, 1);
                                                                                        }

                                                                                        bool rendered = false;

                                                                                        if (viewA && viewB) {
                                                                                            bool cleared = gpu3d.ClearTexture(0x00FF00);
                                                                                            // A: split red/blue source.
                                                                                            bool drewA = cleared && gpu3d.ProbeUvRectangleWithPersistentSampler(0, 8, 12, 24, 40);
                                                                                            // B: independent half-alpha yellow source.
                                                                                            bool drewB = drewA && gpu3d.ProbeUvRectangleWithPersistentSampler(1, 20, 20, 24, 24);
                                                                                            // A again, proving its sampler view survived
                                                                                            // the switch to B.
                                                                                            bool drewAAgain = drewB && gpu3d.ProbeUvRectangleWithPersistentSampler(0, 36, 16, 20, 24);
                                                                                            if (drewAAgain) {
                                                                                                Australis.Kernel.Graphics.PixelSurface pixels = new Australis.Kernel.Graphics.PixelSurface(64, 64);
                                                                                                if (probeSurface.Readback(pixels)) {
                                                                                                    bool aCorrect = UvNearColor(pixels.Pixel(14, 32), 128, 127, 0);
                                                                                                    bool bCorrect = UvNearColor( pixels.Pixel(34, 32), 128, 255, 0);
                                                                                                    bool overlapCorrect = UvNearColor(pixels.Pixel(24, 32), 128, 191, 64);
                                                                                                    bool thirdLowerLeft = UvNearColor(pixels.Pixel(38, 32), 192, 127, 0);
                                                                                                    bool thirdUpperLeft = UvNearColor(pixels.Pixel(40, 18), 128, 127, 0);
                                                                                                    bool thirdUpperRight = UvNearColor(pixels.Pixel(50, 18), 0, 127, 128);
                                                                                                    bool thirdMiddleRight = UvNearColor(pixels.Pixel(50, 28), 0, 127, 128);
                                                                                                    bool aAgainCorrect = thirdLowerLeft && thirdUpperLeft && thirdUpperRight && thirdMiddleRight;
                                                                                                    bool backgroundCorrect = UvNearColor( pixels.Pixel(4, 4), 0, 255, 0);
                                                                                                    rendered = aCorrect && bCorrect && overlapCorrect && aAgainCorrect && backgroundCorrect;
                                                                                                    if (rendered) {
                                                                                                        output.WriteLine("GPUDBG: persistent sampler pixels correct");
                                                                                                    } else {
                                                                                                        output.WriteLine("GPUDBG: persistent sampler pixels incorrect");
                                                                                                        WriteUvPixel(output, "A", pixels.Pixel(14, 32));
                                                                                                        WriteUvPixel(output, "B only", pixels.Pixel(34, 32));
                                                                                                        WriteUvPixel(output, "A3 lower-left", pixels.Pixel(38, 32));
                                                                                                        WriteUvPixel(output, "A3 upper-left", pixels.Pixel(40, 18));
                                                                                                        WriteUvPixel(output, "A3 upper-right", pixels.Pixel(50, 18));
                                                                                                        WriteUvPixel(output, "A3 middle-right", pixels.Pixel(50, 28));
                                                                                                        WriteUvPixel(output, "overlap", pixels.Pixel(24, 32));
                                                                                                        WriteUvPixel(output, "A again left", pixels.Pixel(40, 18));
                                                                                                        WriteUvPixel(output, "A again right", pixels.Pixel(50, 18));
                                                                                                        WriteUvPixel(output, "background", pixels.Pixel(4, 4));
                                                                                                    }
                                                                                                }
                                                                                            }
                                                                                        }

                                                                                        if (rendered && viewA && viewB) {

                                                                                            output.WriteLine(
                                                                                                "GPUDBG: testing reusable frame composer");

                                                                                            Australis.Kernel.Graphics.VirglFrameComposer composer =
                                                                                                new Australis.Kernel.Graphics.VirglFrameComposer(
                                                                                                    gpu3d);

                                                                                            // ==========================================
                                                                                            // Frame 1: Window A behind Window B
                                                                                            // ==========================================

                                                                                            bool frame1 = composer.BeginFrame(0x00FF00);

                                                                                            if (frame1) {
                                                                                                frame1 = composer.DrawWindow(
                                                                                                    0, 8, 8, 24, 28);
                                                                                            }

                                                                                            if (frame1) {
                                                                                                frame1 = composer.DrawWindow(
                                                                                                    1, 20, 20, 24, 24);
                                                                                            }

                                                                                            if (frame1) {
                                                                                                frame1 = composer.EndFrame();
                                                                                            }

                                                                                            bool frame1Pixels = false;

                                                                                            if (frame1) {
                                                                                                Australis.Kernel.Graphics.PixelSurface pixels1 =
                                                                                                    new Australis.Kernel.Graphics.PixelSurface(
                                                                                                        64, 64);

                                                                                                if (probeSurface.Readback(pixels1)) {

                                                                                                    frame1Pixels =
                                                                                                        UvNearColor(
                                                                                                            pixels1.Pixel(14, 14),
                                                                                                            128, 127, 0) &&

                                                                                                        UvNearColor(
                                                                                                            pixels1.Pixel(38, 32),
                                                                                                            128, 255, 0) &&

                                                                                                        UvNearColor(
                                                                                                            pixels1.Pixel(24, 26),
                                                                                                            128, 191, 64) &&

                                                                                                        UvNearColor(
                                                                                                            pixels1.Pixel(4, 4),
                                                                                                            0, 255, 0);
                                                                                                }
                                                                                            }

                                                                                            if (frame1Pixels) {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: frame 1 composition correct");
                                                                                            } else {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: frame 1 composition failed");
                                                                                            }

                                                                                            // ==========================================
                                                                                            // Frame 2: Reverse window stacking order
                                                                                            // ==========================================

                                                                                            bool frame2 = false;
                                                                                            bool frame2Pixels = false;

                                                                                            if (frame1Pixels) {
                                                                                                frame2 = composer.BeginFrame(0x00FF00);
                                                                                            }

                                                                                            // Window B is now behind Window A.
                                                                                            if (frame2) {
                                                                                                frame2 = composer.DrawWindow(
                                                                                                    1, 8, 8, 24, 28);
                                                                                            }

                                                                                            if (frame2) {
                                                                                                frame2 = composer.DrawWindow(
                                                                                                    0, 20, 20, 24, 24);
                                                                                            }

                                                                                            if (frame2) {
                                                                                                frame2 = composer.EndFrame();
                                                                                            }

                                                                                            if (frame2) {
                                                                                                Australis.Kernel.Graphics.PixelSurface pixels2 =
                                                                                                    new Australis.Kernel.Graphics.PixelSurface(
                                                                                                        64, 64);

                                                                                                if (probeSurface.Readback(pixels2)) {

                                                                                                    // Window B only: yellow over green.
                                                                                                    bool bOnly =
                                                                                                        UvNearColor(
                                                                                                            pixels2.Pixel(14, 14),
                                                                                                            128, 255, 0);

                                                                                                    // Window A only: blue over green.
                                                                                                    bool aOnly =
                                                                                                        UvNearColor(
                                                                                                            pixels2.Pixel(38, 32),
                                                                                                            0, 127, 128);

                                                                                                    // A's red overlays B's yellow.
                                                                                                    bool overlap =
                                                                                                        UvNearColor(
                                                                                                            pixels2.Pixel(24, 26),
                                                                                                            192, 127, 0);

                                                                                                    bool background =
                                                                                                        UvNearColor(
                                                                                                            pixels2.Pixel(4, 4),
                                                                                                            0, 255, 0);

                                                                                                    frame2Pixels =
                                                                                                        bOnly &&
                                                                                                        aOnly &&
                                                                                                        overlap &&
                                                                                                        background;

                                                                                                    if (!frame2Pixels) {
                                                                                                        WriteUvPixel(output, "frame2 B",
                                                                                                            pixels2.Pixel(14, 14));

                                                                                                        WriteUvPixel(output, "frame2 A",
                                                                                                            pixels2.Pixel(38, 32));

                                                                                                        WriteUvPixel(output, "frame2 overlap",
                                                                                                            pixels2.Pixel(24, 26));

                                                                                                        WriteUvPixel(output, "frame2 background",
                                                                                                            pixels2.Pixel(4, 4));
                                                                                                    }
                                                                                                }
                                                                                            }

                                                                                            if (frame2Pixels) {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: frame 2 composition correct");
                                                                                            } else {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: frame 2 composition failed");
                                                                                            }

                                                                                            // Both frames must have completed successfully
                                                                                            // using the same persistent GPU resources.
                                                                                            virglFrameComposerProbe =
                                                                                                frame1Pixels &&
                                                                                                frame2Pixels &&
                                                                                                !composer.FrameOpen() &&
                                                                                                !composer.Failed() &&
                                                                                                composer.CompletedFrames() == 2 &&
                                                                                                composer.LastDrawCount() == 2;

                                                                                            if (virglFrameComposerProbe) {
                                                                                                output.WriteLine(
                                                                                                    "GPUDBG: reusable frame composer correct");
                                                                                            }
                                                                                        }

                                                                                        // Always attempt both cleanups.
                                                                                        // Do not use short-circuit && here.
                                                                                        bool cleanedB = gpu3d.DestroyPersistentSamplerView(1);
                                                                                        bool cleanedA = gpu3d.DestroyPersistentSamplerView(0);

                                                                                        // A failed operation must not lead to premature
                                                                                        // release of a potentially referenced source.
                                                                                        persistentSamplerSourceSafe =
                                                                                            persistentSamplerSourceSafe &&
                                                                                            viewA && cleanedA;

                                                                                        secondSamplerSourceSafe =
                                                                                            viewB && cleanedB;

                                                                                        virglPersistentSamplerDrawProbe =
                                                                                            rendered &&
                                                                                            viewA &&
                                                                                            viewB &&
                                                                                            cleanedA &&
                                                                                            cleanedB;

                                                                                        if (virglPersistentSamplerDrawProbe) {
                                                                                            output.WriteLine(
                                                                                                "GPUDBG: persistent sampler reuse correct");
                                                                                        } else {
                                                                                            output.WriteLine(
                                                                                                "GPUDBG: persistent sampler reuse failed");
                                                                                        }
                                                                                    }

                                                                                } else {
                                                                                    output.WriteLine("GPUDBG: second texture creation failed");
                                                                                }
                                                                                // Destroy B's context and texture independently.
                                                                                // This must complete before freeing its DMA backing.
                                                                                bool secondCleaned = !secondContext;
                                                                                if (secondContext && secondSamplerSourceSafe) {
                                                                                    secondCleaned = secondGpu.DestroyContext();
                                                                                }
                                                                                if (secondCleaned) {
                                                                                    dmaPool.Release(secondBacking);
                                                                                } else {
                                                                                    output.WriteLine("GPUDBG: second texture cleanup incomplete");
                                                                                    // Do not release DMA while the GPU might
                                                                                    // still reference this allocation.
                                                                                }
                                                                                virglTwoSourceProbe = pixelsCorrect && secondCleaned;
                                                                            }
                                                                        }

                                                                        if (ready && reused) {
                                                                            output.WriteLine(
                                                                                "GPUDBG: testing persistent sampler view");

                                                                            bool viewCreated =
                                                                                gpu3d.CreatePersistentSamplerView(
                                                                                    sampleGpu, 0);

                                                                            bool firstBind = false;
                                                                            bool secondBind = false;

                                                                            if (viewCreated &&
                                                                                gpu3d.PersistentSamplerViewReady(0)) {

                                                                                output.WriteLine(
                                                                                    "GPUDBG: persistent sampler created");

                                                                                // Bind the same sampler view twice.
                                                                                // The view object must survive between bindings.
                                                                                firstBind =
                                                                                    gpu3d.BindPersistentSamplerView(0);

                                                                                if (firstBind) {
                                                                                    secondBind =
                                                                                        gpu3d.BindPersistentSamplerView(0);
                                                                                }
                                                                            }

                                                                            // Attempt cleanup even if creation was only partial.
                                                                            bool viewDestroyed =
                                                                                gpu3d.DestroyPersistentSamplerView(0);

                                                                            persistentSamplerSourceSafe = viewDestroyed;

                                                                            virglPersistentSamplerProbe =
                                                                                viewCreated &&
                                                                                firstBind &&
                                                                                secondBind &&
                                                                                viewDestroyed &&
                                                                                !gpu3d.PersistentSamplerViewReady(0);

                                                                            if (virglPersistentSamplerProbe) {
                                                                                output.WriteLine(
                                                                                    "GPUDBG: persistent sampler lifecycle correct");
                                                                            } else {
                                                                                output.WriteLine(
                                                                                    "GPUDBG: persistent sampler lifecycle failed");
                                                                            }
                                                                        }
																		bool destroyed = false;

																		if (created) {
																			destroyed =
																				gpu3d.DestroyPersistentVertexBuffer();
																		}

																		virglPersistentVertexProbe =
																			ready && destroyed &&
																			!gpu3d.PersistentVertexBufferReady();

																		virglPersistentReuseProbe =
																			reused && virglPersistentVertexProbe;

																		if (destroyed) {
																			output.WriteLine(
																				"GPUDBG: persistent buffer destroyed");

																			// The resource backing is no longer GPU-accessible.
																			dmaPool.Release(persistentPage);
																		} else {
																			output.WriteLine(
																				"GPUDBG: persistent buffer cleanup incomplete");
																			// Retain DMA memory until safe recovery.
																		}
																	}
																}
	

                                                                // ==========================================
                                                                // Test 6: Non-square GPU composition target
                                                                // ==========================================

                                                                if (virglFrameComposerProbe && sampleGpu.TextureReady()) {
                                                                    output.WriteLine("GPUDBG: testing non-square GPU viewport");

                                                                    // 96 * 80 * 4 = 30,720 bytes.
                                                                    // Eight 4 KiB pages provide 32,768 bytes.
                                                                    Australis.Kernel.Dma.DmaAllocation wideBacking =
                                                                        dmaPool.Allocate(8);

                                                                    Australis.Kernel.Dma.DmaAllocation wideVertices =
                                                                        dmaPool.Allocate(1);

                                                                    if (wideBacking != null &&
                                                                        wideBacking.Owned() &&
                                                                        wideVertices != null &&
                                                                        wideVertices.Owned()) {

                                                                        // Separate destination context and resource ID.
                                                                        Australis.Kernel.Graphics.VirtioGpu3D wideGpu =
                                                                            new Australis.Kernel.Graphics.VirtioGpu3D(
                                                                                gpuControl, true,
                                                                                gpuControl.CapsetCount(),
                                                                                4, 65539);

                                                                        bool wideContext =
                                                                            wideGpu.Probe() &&
                                                                            wideGpu.CreateContext();

                                                                        Australis.Kernel.Graphics.VirglRenderSurface
                                                                            wideSurface = null;

                                                                        if (wideContext) {
                                                                            wideSurface =
                                                                                new Australis.Kernel.Graphics.VirglRenderSurface(
                                                                                    wideGpu, 96, 80,
                                                                                    wideBacking.Address(), 32768);
                                                                        }

                                                                        bool pipelineReady =
                                                                            wideSurface != null &&
                                                                            wideSurface.Ready() &&
                                                                            wideGpu.ProbeBlendState() &&
                                                                            wideGpu.ConfigureUvRenderStates() &&
                                                                            wideGpu.ProbeUvShaderState() &&
                                                                            wideGpu.ProbeUvVertexElements() &&
                                                                            wideGpu.ProbeCreateSamplerState() &&
                                                                            wideGpu.CreatePersistentVertexBuffer(
                                                                                wideVertices.Address()) &&
                                                                            wideGpu.CreatePersistentSamplerView(
                                                                                sampleGpu, 0);

                                                                        bool correctPixels = false;

                                                                        if (pipelineReady) {

                                                                            Australis.Kernel.Graphics.VirglFrameComposer
                                                                                composer =
                                                                                    new Australis.Kernel.Graphics.VirglFrameComposer(
                                                                                        wideGpu);

                                                                            bool drawn =
                                                                                composer.BeginFrame(0x00FF00) &&
                                                                                composer.DrawWindow(
                                                                                    0, 60, 10, 24, 36) &&
                                                                                composer.EndFrame();

                                                                            if (drawn) {
                                                                                Australis.Kernel.Graphics.PixelSurface pixels =
                                                                                    new Australis.Kernel.Graphics.PixelSurface(
                                                                                        96, 80);

                                                                                if (wideSurface.Readback(pixels)) {

                                                                                    bool red =
                                                                                        UvNearColor(
                                                                                            pixels.Pixel(65, 18),
                                                                                            128, 127, 0);

                                                                                    bool blue =
                                                                                        UvNearColor(
                                                                                            pixels.Pixel(79, 18),
                                                                                            0, 127, 128);

                                                                                    bool outside =
                                                                                        UvNearColor(
                                                                                            pixels.Pixel(4, 4),
                                                                                            0, 255, 0) &&
                                                                                        UvNearColor(
                                                                                            pixels.Pixel(65, 50),
                                                                                            0, 255, 0);

                                                                                    correctPixels =
                                                                                        red && blue && outside;

                                                                                    if (!correctPixels) {
                                                                                        WriteUvPixel(output, "wide red",
                                                                                            pixels.Pixel(65, 18));

                                                                                        WriteUvPixel(output, "wide blue",
                                                                                            pixels.Pixel(79, 18));

                                                                                        WriteUvPixel(output, "wide background",
                                                                                            pixels.Pixel(65, 50));
                                                                                    }
                                                                                }
                                                                            }
                                                                        }

                                                                        // Destroy the compositor's sampler, vertex
                                                                        // and texture resources before freeing DMA.
                                                                        bool wideDestroyed = !wideContext;

                                                                        if (wideContext) {
                                                                            wideDestroyed = wideGpu.DestroyContext();
                                                                        }

                                                                        if (wideDestroyed) {
                                                                            dmaPool.Release(wideVertices);
                                                                            dmaPool.Release(wideBacking);
                                                                        } else {
                                                                            // This context may still reference sampleGpu.
                                                                            // Keep its source backing alive until reset.
                                                                            persistentSamplerSourceSafe = false;
                                                                        }

                                                                        virglNonSquareViewportProbe =
                                                                            correctPixels && wideDestroyed;

                                                                    } else {
                                                                        // Release allocations that never reached the GPU.
                                                                        if (wideVertices != null &&
                                                                            wideVertices.Owned()) {
                                                                            dmaPool.Release(wideVertices);
                                                                        }

                                                                        if (wideBacking != null &&
                                                                            wideBacking.Owned()) {
                                                                            dmaPool.Release(wideBacking);
                                                                        }
                                                                    }

                                                                    if (virglNonSquareViewportProbe) {
                                                                        output.WriteLine(
                                                                            "GPUDBG: non-square GPU viewport correct");
                                                                    } else {
                                                                        output.WriteLine(
                                                                            "GPUDBG: non-square GPU viewport failed");
                                                                    }
                                                                }

																// ==========================================
																// Release temporary DMA vertex buffer
																// ==========================================

																if (safeToRelease) {
																	dmaPool.Release(uvPage);
																}
															}
														}
                                                    }
                                                }
                                                if (!sampleContext || (persistentSamplerSourceSafe && sampleGpu.DestroyContext())) {
                                                    dmaPool.Release(sampleBacking);
                                                }
                                            }
                                        }
										bool vertexReleased = !gpu3d.ProbeVertexCreated() || gpu3d.DestroyProbeVertex();

										if (vertexPage != null && vertexReleased) {
											dmaPool.Release(vertexPage);
										}

										bool scanoutSelected =
											gpu3d.ScanoutTexture(0);
                                        if (scanoutSelected) {
                                            bool flushed = gpu3d.FlushTexture(
                                                0, 0, 64, 64);
                                            bool disabled =
                                                gpu3d.DisableScanout(0);
                                            virglScanoutProbe =
                                                flushed && disabled;
                                        }
                                    }
                                }
                                probeSurface.Destroy();
                            }
                            bool contextDestroyed = gpu3d.DestroyContext();
                            virglProbe = virglProbe && contextDestroyed;
                        }
                    }
                }
                int gpuError = gpuControl.LastError();
                gpuControl.Close();
                if (gpuBacking != 0) { PhysicalPages.Free(bootInfo, gpuBacking); }
                if (probeTexture != null) { dmaPool.Release(probeTexture); }
                if (gpuOk) { output.WriteLine("VirtIO-GPU 2D probe passed"); }
                else {
                    output.WriteText("VirtIO-GPU 2D probe failed ");
                    output.WriteByte(48 + gpuError / 10 % 10);
                    output.WriteByte(48 + gpuError % 10);
                    output.WriteByte(13); output.WriteByte(10);
                }
                if (virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL context probe passed");
                }
                if (virglTextureProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL texture probe passed");
                }
                if (virglSubmissionProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL submission probe passed");
                }
                if (virglSurfaceUploadProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL surface upload/readback passed");
                }
                if (virglClearSubmitted && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL clear submitted");
                }
                if (virglDownloaded && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL texture downloaded");
                }
                if (virglClearProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL clear/readback passed");
                }
                if (virglScanoutProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL scanout probe passed");
                }
                if (virglBlendStateProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL blend state probe passed");
                }
                if (virglPostFboClearProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL post-FBO texture clear passed");
                }
                if (virglShaderStateProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL shader state probe passed");
                }
				if (virglSamplerStateProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL sampler state probe passed");
				}
                if (virglAlphaDrawProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL alpha draw/readback passed");
                }
                if (virglTexturedAlphaProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL textured alpha draw/readback passed");
                }
				if (virglUvShaderProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL UV shader linkage passed");
				}
				if (virglUvVertexProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL UV vertex layout passed");
				}
				if (virglUvPixelsProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL UV pixels/readback passed");
				}
				if (virglUvPositionedProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL positioned UV rectangle passed");
				}
				if (virglUvOffsetProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL arbitrary UV rectangle passed");
				}
				if (virglUvMultiRectangleProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL multi-rectangle composition passed");
				}
				if (virglUvOverlapProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL overlapping alpha composition passed");
				}
				if (virglPersistentVertexProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL persistent vertex lifecycle passed");
				}
				if (virglPersistentReuseProbe && virglProbe) {
					output.WriteLine("VirtIO-GPU VirGL persistent vertex reuse passed");
				}
                if (virglTwoSourceProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL independent window textures passed");
                }
                if (virglPersistentSamplerProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL persistent sampler lifecycle passed");
                }
                if (virglPersistentSamplerDrawProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL persistent sampler drawing passed");
                }
                if (virglFrameComposerProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL frame composer passed");
                }
                if (virglNonSquareViewportProbe && virglProbe) {
                    output.WriteLine("VirtIO-GPU VirGL non-square viewport passed");
                }
            }
            Australis.Kernel.Graphics.NativeVirtioGpuBackend nativeGpu = null;
            Australis.Kernel.Graphics.IDisplayBackend nativeDisplay = null;
            if (gpuBdf >= 0) {
                nativeGpu = new Australis.Kernel.Graphics.NativeVirtioGpuBackend(
                    bootInfo, gpuPci, gpuBdf, dmaPool);
                nativeDisplay = nativeGpu;
            }
            Australis.Kernel.Graphics.IDisplayBackend gopDisplay = new Australis.Kernel.Graphics.GopDisplayBackend(framebuffer.Mode(), new Australis.Kernel.Graphics.NativeFramebufferPixelWriter());
            Australis.Kernel.Graphics.DisplayDevice display = new Australis.Kernel.Graphics.DisplayDevice(new Australis.Kernel.Graphics.AdaptiveDisplayBackend(nativeDisplay, gopDisplay), output);
            if (nativeGpu != null) {
                display.AttachGpuComposer(nativeGpu);
            }
            if (display.BackendKind() == 2) {
                output.WriteLine("VirtIO-GPU native display active");
                if (display.HardwareCursor()) {
                    output.WriteLine("VirtIO-GPU scanout cursor active");
                }
                if (nativeGpu != null &&
                    nativeGpu.AccelerationAvailable()) {
                    output.WriteLine("VirtIO-GPU VirGL context active");
                    bool gpuPresentationPassed = nativeGpu.ProbeGpuScanoutRoundTrip();
                    if (gpuPresentationPassed) {
                        output.WriteLine("VirtIO-GPU VirGL full-frame scanout passed");
                    } else {
                        output.WriteLine("VirtIO-GPU VirGL full-frame scanout failed");
                    }
                    bool initialTargetCorrect = nativeGpu.RenderTargetMatchesDisplay();
                    bool composerReadyBeforeReset = nativeGpu.GpuWindowComposerReady();
                    if (nativeGpu.Recover() && nativeGpu.AccelerationAvailable()) {
                        if (initialTargetCorrect && nativeGpu.RenderTargetMatchesDisplay()) {
                            output.WriteLine("VirtIO-GPU VirGL display-sized target passed");
                        }
                        if (composerReadyBeforeReset && nativeGpu.GpuWindowComposerReady()) {
                            output.WriteLine("VirtIO-GPU VirGL native composer setup passed");
                        }
                        output.WriteLine("VirtIO-GPU 2D/3D device reset recovery passed");
                    } else {
                        output.WriteLine("VirtIO-GPU 2D/3D device reset recovery failed");
                    }

                    bool composerReady = nativeGpu.GpuWindowComposerReady();

                    bool ownedWindowPassed = false;

                    if (composerReady) {
                        ownedWindowPassed = nativeGpu.ProbeOwnedWindowComposition();
                    }

                    if (ownedWindowPassed) {
                        output.WriteLine("VirtIO-GPU VirGL owned window composition passed");
                        output.WriteLine("VirtIO-GPU VirGL solid rectangles passed");
                        if (nativeGpu.ProbeComposedFrameScanoutRoundTrip()) {
                            output.WriteLine("VirtIO-GPU VirGL composed frame scanout passed");
                        } else {
                            output.WriteLine("VirtIO-GPU VirGL composed frame scanout failed");
                        }
                    } else {
                        output.WriteLine("VirtIO-GPU VirGL owned window composition failed");
                        if (!nativeGpu.OwnedWindowDestroyedA()) {
                            output.WriteLine("GPUDBG: window A cleanup failed");
                        }

                        if (!nativeGpu.OwnedWindowDestroyedB()) {
                            output.WriteLine("GPUDBG: window B cleanup failed");
                        }
                        if (!composerReady) {
                            output.WriteLine("GPUDBG: native window composer not ready");
                        } else {
                            output.WriteText("GPUDBG: owned window failure stage ");
                            output.WriteByte(48 + nativeGpu.OwnedWindowProbeStage());
                            output.WriteByte(13);
                            output.WriteByte(10);
                            int pixel = nativeGpu.OwnedWindowProbePixel();
                            if (pixel >= 0) {
                                WriteUvPixel(output, "owned window last pixel", pixel);
                            }
                        }
                    }


                }
            } else {
                output.WriteLine("GOP display fallback active");
                if (nativeGpu != null) {
                    output.WriteText("VirtIO-GPU native init code ");
                    output.WriteByte(48 + nativeGpu.LastError() / 10 % 10);
                    output.WriteByte(48 + nativeGpu.LastError() % 10);
                    output.WriteByte(13); output.WriteByte(10);
                }
            }
            display.AttachFrameClock(
                new Australis.Kernel.Graphics.NativeFrameClock(bootInfo));
            display.SetFramePacing(16);
            Australis.Kernel.Console.IConsoleInput shellInput = serial;
            if (usbKeyboardReady && usbKeyboard.IsKeyboard()) {
                Australis.Kernel.Console.ConsoleInputMux mux =
                    new Australis.Kernel.Console.ConsoleInputMux(serial, usbKeyboard);
                display.AttachInputMux(mux);
                shellInput = mux;
            }
            int bootMode = System.Kernel.Memory.Read32(bootInfo + 3472);
            if (bootMode != 1 && bootMode != 3) {
                Australis.Kernel.Console.ConsoleEventQueue userEvents =
                    new Australis.Kernel.Console.ConsoleEventQueue();
                Australis.Kernel.Console.SerialKeyDecoder userDecoder =
                    new Australis.Kernel.Console.SerialKeyDecoder(shellInput, userEvents);
                Australis.User.NativeUserTerminal userTerminal =
                    new Australis.User.NativeUserTerminal(shellInput, output,
                        userEvents, userDecoder, usbKeyboard);
                Australis.Kernel.Vfs.VfsNamespace userMounts =
                    new Australis.Kernel.Vfs.VfsNamespace(vfs, removableVfs, dataVfs);
                Australis.User.NativeUserRuntime nativeRuntime =
                    new Australis.User.NativeUserRuntime(bootInfo);
                Australis.User.NativeUserProgramHost userHost =
                    new Australis.User.NativeUserProgramHost(userMounts, userTerminal,
                        bootInfo, nativeRuntime, display, usbKeyboard,
                        nativeGpu);
                PhysicalPages.BeginTransientRegion(bootInfo);
                Australis.User.UserProgramResult systemResult = userHost.Run("/System/Core/System.exec");
                if (systemResult.State() == Australis.User.UserProgramState.Faulted() &&
                    systemResult.Fault() == Australis.User.UserFault.InvalidImage()) {
                    output.WriteLine("System executable unavailable; entering KMon.");
                } else if (systemResult.State() == Australis.User.UserProgramState.Exited() &&
                    systemResult.ExitCode() == 0) {
                    output.WriteLine("System session ended; entering KMon.");
                } else {
                    output.WriteLine("System failed; entering KMon.");
                }
            }
            Australis.Kernel.Console.ConsoleShell shell = new Australis.Kernel.Console.ConsoleShell(shellInput, output, vfs, removableVfs, dataVfs, usbKeyboard, bootInfo);
            shell.Run();
        }
        while (true) { System.Kernel.Cpu.Halt(); }
        return 0;
    }

	private static void WriteUvPixel(
		Australis.Kernel.Console.ConsoleWriter output,
		string label, int pixel) {

		output.WriteText("UVDBG: ");
		output.WriteText(label);
		output.WriteText(" = #");

		// Print RGB as six hexadecimal digits.
		int divisor = 1048576;

		while (divisor > 0) {
			int nibble = pixel / divisor % 16;
			int ascii = 48 + nibble;

			if (nibble >= 10) {
				ascii = 55 + nibble;
			}

			output.WriteByte(ascii);
			divisor = divisor / 16;
		}

		output.WriteByte(13);
		output.WriteByte(10);
	}

	private static bool UvNearColor(
		int pixel, int red, int green, int blue) {

		int r = pixel / 65536 % 256;
		int g = pixel / 256 % 256;
		int b = pixel % 256;

		return r >= red - 8 && r <= red + 8 &&
			g >= green - 8 && g <= green + 8 &&
			b >= blue - 8 && b <= blue + 8;
	}

}

public class KernelCounter {
    private int value;

    public KernelCounter(int initial) { value = initial; }
    public int Value() { return value; }
}
