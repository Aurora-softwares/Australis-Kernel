# Kernel completion criteria

The kernel retains a small recovery monitor, KMon. Pressing `R` in the UEFI
boot window enters it at a `rescue>` prompt before controller, GPT, HyFS, USB,
or AUEX startup. The monitor shares its bounded command implementation with
the `kmon>` fallback shell. Normal boot starts `System.exec` as PID 1, which
launches the userland command shell. A missing or failed PID 1 enters KMon.

This checklist was audited against the freestanding kernel sources, the
documented `KernelBootInfo` ABI, the hosted subsystem tests, and the AHCI/NVMe
QEMU integration matrix.

Status key: `🟢` implemented and exercised, `🟡` partially implemented, and
`🔴` not implemented.

Current assessment:

- Stage 1: 9 complete. A real page fault is covered in QEMU and produces the
  same allocation-free diagnostic on COM1 and the framebuffer before halting.
- Stage 2: Storage, filesystems, USB, console, interrupts, kernel memory
  ownership, and native ring-3 execution with bounded memory have live QEMU coverage.
  Hardware context switching, preemptive threads, broader user time services,
  and full syscall parity remain open.
- QEMU coverage is substantial, but physical-machine validation remains a
  separate release requirement.

## CLI commands to require

`Hardcoded?` means the command is part of the small kernel-resident KMon and
must work without a root filesystem or user process. `No` means an ordinary
command belongs in a userland `.exec` program, or an optional low-level
diagnostic is confined to a development build. The userland shell's `help` is
a shell built-in, while KMon keeps its own `help`. A KMon diagnostic may
coexist with a userland tool.

The status below assesses the **named command in its intended location**, not
the underlying kernel capability. `🟢` means it works there, `🟡` means a
prototype or misplaced implementation exists, and `🔴` means the named command
is absent. Normal boot enters `CommandShell.exec`; `kmon>` remains the recovery
monitor. Debugging commands that inspect or modify raw kernel
state must only be exposed in an explicit debugging mode. The required list
contains 22 commands. The 14 excess standalone commands are recorded below it;
removing a command requirement does not remove its kernel subsystem or tests.

### Kernel information

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| 🟢 | `help` | Yes | KMon lists recovery commands; the userland shell has its own built-in that lists installed programs. |
| 🟡 | `version` | No | KMon and `/System/Bin/version.exec` print fixed versions; the executable does not query kernel/build information. |
| 🔴 | `status` | Yes | No KMon summary of boot and subsystem health. |
| 🔴 | `uptime` | No | No userland command or time query for it. |
| 🔴 | `bootinfo` | Yes | Boot handoff is read internally, but KMon cannot inspect it. |
| 🔴 | `log` | Yes | Kernel diagnostic output exists, but KMon has no retained-message reader. A normal `dmesg` can be external later. |
| 🟢 | `clear` | No | `/System/Bin/clear.exec` clears the terminal through the checked terminal API. |

### Memory management

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| 🟢 | `mem` | No | `/System/Bin/mem.exec` reports available pages and kernel heap usage through read-only system information. |
| 🟢 | `memmap` | Yes | KMon summarizes the EFI map without a filesystem; `D` Debug boot also shows bounded descriptor ranges. |
| 🟢 | `pages` | Yes | KMon reports fresh, recycled, and total available physical pages plus allocator status. |

### Hardware and interrupts

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| 🟢 | `devices` | Yes | KMon reports initialized AHCI/NVMe storage and live USB state; early Rescue reports storage as uninitialized. |
| 🟢 | `drivers` | No | `/System/Bin/drivers.exec` reports active serial, storage, USB, and timer drivers through checked system-information API 4. |

### Filesystems and processes

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| 🟢 | `mounts` | Yes | KMon reports only mounted volumes and states explicitly when none are mounted in early Rescue. |
| 🟢 | `ls` | No | The userland shell starts `/System/Bin/ls.exec`; KMon also resolves it through its recovery `PATH`. |
| 🟢 | `cat` | No | The userland shell starts `/System/Bin/cat.exec` to read files through the checked API. |
| 🟢 | `ps` | No | Bare `ps` resolves `/System/Bin/ps.exec` and reports its live foreground PID and the previous launch. The kernel retains bounded parent/child and exit records; `ps` enumeration of every concurrent child remains open. |

### Recovery and debugging

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| 🟢 | `continue` | Yes | From early `R` Rescue, resets the machine into a fresh normal boot; in normal KMon it reports that boot is already active. |
| 🟢 | `reboot` | Yes | Resets through x86 chipset reset control, with an 8042 fallback. |
| 🟢 | `halt` | Yes | Disables interrupts and halts the processor without returning to the prompt. |
| 🟢 | `trace` | Yes | Displays boot/storage/program diagnostics and the eight most recent KMon commands. |
| 🟢 | `panic` | Yes | `D` Debug boot only; triggers the real fatal page-fault handler. The older `panic-test` alias was removed. |
| 🟢 | `registers` | Yes | Shows live RIP, RSP, RBP, RFLAGS, and CR3; shows a saved fatal frame if one is available. |

`continue` is a reset from `R` Rescue because that boot mode intentionally
skips controller, MMIO, DMA, and storage bootstrap. It cannot safely resume
those bootloader steps in place. The reset starts a new normal boot when no
recovery key is pressed. `make test-kmon-recovery` checks all six commands in
QEMU; the normal AHCI/NVMe console tests also exercise `trace`, `registers`,
the normal-mode `continue` response, and the `panic` mode guard.

## Stage 1 - Minimum Viable Kernel

| Done | Requirement | Description |
| --- | --- | --- |
| 🟢 | Kernel entry | Receive execution from the bootloader. |
| 🟢 | Boot information | Read the information supplied by the bootloader. |
| 🟢 | Console output | Print text using the framebuffer or serial output. |
| 🟢 | CPU initialization | Configure essential processor state. |
| 🟢 | Memory map | Understand usable and reserved physical memory. |
| 🟢 | Exception handling | Catch CPU exceptions rather than silently crashing. |
| 🟢 | Panic handling | Fatal exceptions print the CPU frame and register state to COM1 and the framebuffer, then halt. |
| 🟢 | Basic memory allocation | Allocate memory for initial kernel structures. |
| 🟢 | Kernel idle | Remain operational after initialization. |

## Stage 2 - Feature Complete Kernel

### A. CPU and interrupt management

| Done | Requirement | Description |
| --- | --- | --- |
| 🟡 | CPU initialization | Essential x86-64, APIC, interrupt, and timer state is initialized; broader feature policy is still needed. |
| 🟢 | GDT | Configure the Global Descriptor Table on x86-64. |
| 🟢 | IDT | Configure the Interrupt Descriptor Table. |
| 🟢 | Exceptions | Handle processor exceptions. |
| 🟢 | Hardware interrupts | Receive and dispatch device interrupts. |
| 🟢 | Timer | Support periodic or one-shot timer interrupts. |
| 🟡 | CPU identification | Required paging and APIC capabilities are detected; a reusable CPU feature inventory is still needed. |
| 🟢 | Kernel panic | Fatal CPU exceptions print a complete allocation-free register report, retain the frame, and halt. |

### B. Memory management

| Done | Requirement | Description |
| --- | --- | --- |
| 🟢 | Physical memory manager | Track available and allocated RAM pages. |
| 🟢 | Virtual memory manager | Manage virtual address spaces and page tables. |
| 🟢 | Kernel heap | Support dynamic memory allocation. |
| 🟢 | Page allocation | Allocate and release memory pages. |
| 🟡 | Memory protection | Null-page removal, NX data, and private user page tables protect AUN1 children; broader process and permission policy remains. |
| 🟢 | Page faults | Detect and handle invalid memory accesses. |
| 🟡 | Process isolation | AUEX code and data are checked in software; AUN1 children have bounded memory and separate hardware-protected address spaces. |

### C. Process and thread management

| Done | Requirement | Description |
| --- | --- | --- |
| 🟡 | Process creation | AUEX children and AUN1 system-bin children with bounded memory can be loaded and started; general native launch policy remains. |
| 🟡 | Process termination | AUEX exit/fault closes descriptors and native exit/fault releases owned pages; precise reclamation after filesystem mutation remains. |
| 🟡 | Process isolation | AUEX uses checked regions; AUN1 uses a private user page table and guarded stack. |
| 🔴 | Thread support | Support independent native execution contexts. |
| 🟡 | Scheduler | Live AUEX children share bounded instruction rounds with separate descriptor owners, blocking waits, readiness, and timer-backed sleep. Native context switching and interrupt preemption remain. |
| 🔴 | Context switching | Switch between native CPU execution contexts. |
| 🟡 | User mode | Bounded AUN1 system-bin children execute in ring 3; AUEX compatibility programs remain interpreted in the kernel. |
| 🟡 | System calls | AUEX has checked calls; native `int 0x80` supports PID and exit, with remaining APIs to port. |
| 🟡 | Idle thread | The kernel has an interrupt-enabled idle loop; it is not yet a schedulable thread. |

### D. Filesystem management

| Done | Requirement | Description |
| --- | --- | --- |
| 🟢 | Block devices | Read sectors from supported storage devices. |
| 🟢 | Partition discovery | Discover partitions, including GPT. |
| 🟢 | Filesystem interface | Provide a consistent interface for filesystem implementations. |
| 🟢 | HyFS support | Mount and read HyFS volumes. |
| 🟡 | File operations | Open, read, close, and transactional HyFS 2 mutations work on `/data` by default; the boot root and USB mount remain read-only. Broader physical failure coverage remains. |
| 🟢 | Directory operations | Canonical namespace traversal and listing work on the default HyFS 2 tree; HyFS 1 compatibility volumes remain flat. |
| 🟢 | File descriptors | Provide process-specific file handles. |
| 🟢 | Mount management | Mount and unmount supported filesystems. |
| 🟢 | Error handling | Handle invalid or corrupted filesystem structures. |

### E. Device management

| Done | Requirement | Description |
| --- | --- | --- |
| 🟢 | Device discovery | Discover supported hardware devices. |
| 🟢 | Driver interface | Provide consistent interfaces for drivers. |
| 🟢 | Storage drivers | Access supported storage controllers. |
| 🟢 | Display output | Write to an initialized framebuffer. |
| 🟢 | Keyboard input | Receive keyboard events. |
| 🟢 | Timer devices | Provide timekeeping and scheduling. |
| 🟢 | Interrupt routing | Associate device interrupts with handlers. |
| 🟢 | PCI discovery | Enumerate PCI devices where supported. |

### G. Program execution

| Done | Category | Example operations |
| --- | --- | --- |
| 🟡 | Processes | AUEX has spawn/wait/readiness and native children with bounded memory share PID, exit, and fault records; native preemption remains. |
| 🟡 | Memory | Kernel map, unmap, allocation, and release work; user memory syscalls remain. |
| 🟡 | Files | Checked and portable AUEX file reads and writes work on `/data`; broader dynamic mutation APIs and process permissions remain. |
| 🟡 | Directories | The shell lists mounts and files and reports its directory; directory changes remain. |
| 🟡 | Time | AUEX programs can sleep against the kernel clock; a general time query API remains. |
| 🟢 | Input/output | Read and write terminal streams through descriptors 0, 1, and 2. |
| 🟡 | System information | AUEX has versioned read-only ABI and PID queries; broader device, memory, and time inventory remains. |

### H. Kernel stability and security

| Done | Requirement | Description |
| --- | --- | --- |
| 🟡 | Memory protection | AUEX addresses are checked in software; AUN1 code cannot read supervisor mappings and faults only its child. |
| 🟡 | Privilege separation | AUN1 executes in ring 3 and privileged instructions fault; AUEX still runs through the checked interpreter. |
| 🟢 | Resource cleanup | Process termination releases its descriptors and temporary allocations. |
| 🟢 | Error handling | Invalid system calls don't crash the kernel. |
| 🟢 | Fault containment | AUEX faults and AUN1 page or privilege faults terminate without taking down PID 1, the shell, or KMon. |
| 🟢 | Kernel logging | Record useful diagnostic information. |
| 🟢 | Kernel panic | Fatal CPU state is recorded and rendered on both kernel terminals before the system halts. |
| 🟢 | Input validation | Validate user-provided pointers, lengths and arguments. |
| 🟡 | Synchronization | IRQ queues, ownership, and memory fences are bounded; general locks and multicore support remain. |
| 🟢 | Automated testing | Test essential kernel functionality. |
