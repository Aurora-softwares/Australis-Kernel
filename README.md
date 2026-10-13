# Kernel completion criteria

The kernel retains a small recovery monitor, KMon. Pressing `R` in the UEFI
boot window enters it at a `rescue>` prompt before controller, GPT, HyFS, USB,
or AUEX startup. The current monitor shares its bounded command implementation
with the `kmon>` kernel shell while ordinary commands move to userland.
Automatic fallback after a future PID 1 failure remains to be implemented.

This checklist was audited against the freestanding kernel sources, the
documented `KernelBootInfo` ABI, the hosted subsystem tests, and the AHCI/NVMe
QEMU integration matrix.

Status key: `✅` implemented and exercised, `[~]` partially implemented, and
`⬜` not implemented.

Current assessment:

- Stage 1: 9 complete. A real page fault is covered in QEMU and produces the
  same allocation-free diagnostic on COM1 and the framebuffer before halting.
- Stage 2: Storage, filesystems, USB, console, interrupts, and kernel memory
  ownership have live QEMU coverage. Native
  ring-3 execution, hardware context switching, preemptive threads, user time
  services, and CPU privilege separation remain open.
- QEMU coverage is substantial, but physical-machine validation remains a
  separate release requirement.

## CLI Commands to require

### Kernel information

| Command | Purpose |
| --- | --- |
| `help` | Display available kernel commands |
| `version` | Display kernel version and build information |
| `status` | Display kernel subsystem status |
| `uptime` | Display time since kernel initialisation |
| `bootinfo` | Display information passed by the bootloader |
| `log` | Display kernel messages |
| `clear` | Clear the monitor display |

### Memory management

| Command | Purpose |
| --- | --- |
| `mem` | Display memory usage |
| `memmap` | Display the boot memory map |
| `pages` | Display physical memory page statistics |
| `heap` | Display kernel heap statistics |
| `vmm` | Inspect virtual memory mappings |
| `peek` | Read memory at a specified address |
| `poke` | Modify memory at a specified address |

### Hardware and interrupts

| Command | Purpose |
| --- | --- |
| `cpu` | Display processor information |
| `cpuid` | Inspect CPU features |
| `pci` | List detected PCI devices |
| `devices` | List initialised hardware devices |
| `drivers` | List registered kernel drivers |
| `irq` | Display interrupt information |
| `gdt` | Inspect the Global Descriptor Table |
| `idt` | Inspect the Interrupt Descriptor Table |
| `timer` | Display kernel timer information |

### Filesystems and processes

| Command | Purpose |
| --- | --- |
| `fs` | Display registered filesystems |
| `mounts` | Display mounted volumes |
| `ls` | List files on a mounted volume |
| `cat` | Display a text file |
| `tasks` | List kernel tasks |
| `processes` | Display process information |
| `stack` | Display a kernel stack trace |

### Recovery and debugging

| Command | Purpose |
| --- | --- |
| `continue` | Resume normal execution |
| `reboot` | Restart the computer |
| `halt` | Halt the processor |
| `trace` | Display diagnostic trace information |
| `panic` | Trigger a deliberate kernel panic for testing |
| `registers` | Display saved processor registers |

## Stage 1 - Minimum Viable Kernel

| Done | Requirement | Description |
| --- | --- | --- |
| ✅ | Kernel entry | Receive execution from the bootloader. |
| ✅ | Boot information | Read the information supplied by the bootloader. |
| ✅ | Console output | Print text using the framebuffer or serial output. |
| ✅ | CPU initialization | Configure essential processor state. |
| ✅ | Memory map | Understand usable and reserved physical memory. |
| ✅ | Exception handling | Catch CPU exceptions rather than silently crashing. |
| ✅ | Panic handling | Fatal exceptions print the CPU frame and register state to COM1 and the framebuffer, then halt. |
| ✅ | Basic memory allocation | Allocate memory for initial kernel structures. |
| ✅ | Kernel idle | Remain operational after initialization. |

## Stage 2 - Feature Complete Kernel

### A. CPU and interrupt management

| Done | Requirement | Description |
| --- | --- | --- |
| [~] | CPU initialization | Essential x86-64, APIC, interrupt, and timer state is initialized; broader feature policy is still needed. |
| ✅ | GDT | Configure the Global Descriptor Table on x86-64. |
| ✅ | IDT | Configure the Interrupt Descriptor Table. |
| ✅ | Exceptions | Handle processor exceptions. |
| ✅ | Hardware interrupts | Receive and dispatch device interrupts. |
| ✅ | Timer | Support periodic or one-shot timer interrupts. |
| [~] | CPU identification | Required paging and APIC capabilities are detected; a reusable CPU feature inventory is still needed. |
| ✅ | Kernel panic | Fatal CPU exceptions print a complete allocation-free register report, retain the frame, and halt. |

### B. Memory management

| Done | Requirement | Description |
| --- | --- | --- |
| ✅ | Physical memory manager | Track available and allocated RAM pages. |
| ✅ | Virtual memory manager | Manage virtual address spaces and page tables. |
| ✅ | Kernel heap | Support dynamic memory allocation. |
| ✅ | Page allocation | Allocate and release memory pages. |
| [~] | Memory protection | Null-page removal and NX data mappings are active; native user/kernel page permissions remain. |
| ✅ | Page faults | Detect and handle invalid memory accesses. |
| [~] | Process isolation | AUEX code and data are checked in software; separate hardware-protected address spaces remain. |

### C. Process and thread management

| Done | Requirement | Description |
| --- | --- | --- |
| [~] | Process creation | Checked AUEX bytecode processes can be loaded and started; native processes remain. |
| ✅ | Process termination | AUEX exit and fault paths close descriptors and reclaim command allocations. |
| [~] | Process isolation | AUEX processes use checked code/data regions; hardware isolation remains. |
| ⬜ | Thread support | Support independent native execution contexts. |
| [~] | Scheduler | A bounded cooperative AUEX scheduler exists; runnable queues and preemption remain. |
| ⬜ | Context switching | Switch between native CPU execution contexts. |
| ⬜ | User mode | Execute applications outside kernel privilege. |
| [~] | System calls | A checked AUEX syscall boundary exists; a native ring-3 entry path remains. |
| [~] | Idle thread | The kernel has an interrupt-enabled idle loop; it is not yet a schedulable thread. |

### D. Filesystem management

| Done | Requirement | Description |
| --- | --- | --- |
| ✅ | Block devices | Read sectors from supported storage devices. |
| ✅ | Partition discovery | Discover partitions, including GPT. |
| ✅ | Filesystem interface | Provide a consistent interface for filesystem implementations. |
| ✅ | HyFS support | Mount and read HyFS volumes. |
| [~] | File operations | Open, read, close, and transactional HyFS 2 mutations work on `/data` by default; the boot root and USB mount remain read-only. Broader physical failure coverage remains. |
| ✅ | Directory operations | Canonical namespace traversal and listing work on the default HyFS 2 tree; HyFS 1 compatibility volumes remain flat. |
| ✅ | File descriptors | Provide process-specific file handles. |
| ✅ | Mount management | Mount and unmount supported filesystems. |
| ✅ | Error handling | Handle invalid or corrupted filesystem structures. |

### E. Device management

| Done | Requirement | Description |
| --- | --- | --- |
| ✅ | Device discovery | Discover supported hardware devices. |
| ✅ | Driver interface | Provide consistent interfaces for drivers. |
| ✅ | Storage drivers | Access supported storage controllers. |
| ✅ | Display output | Write to an initialized framebuffer. |
| ✅ | Keyboard input | Receive keyboard events. |
| ✅ | Timer devices | Provide timekeeping and scheduling. |
| ✅ | Interrupt routing | Associate device interrupts with handlers. |
| ✅ | PCI discovery | Enumerate PCI devices where supported. |

### G. Program execution

| Done | Category | Example operations |
| --- | --- | --- |
| [~] | Processes | Foreground AUEX spawn, wait, PID, exit, and fault results work; concurrent process control remains. |
| [~] | Memory | Kernel map, unmap, allocation, and release work; user memory syscalls remain. |
| [~] | Files | Checked and portable AUEX file reads and writes work on `/data`; broader dynamic mutation APIs and process permissions remain. |
| [~] | Directories | The shell lists mounts and files and reports its directory; directory changes remain. |
| ⬜ | Time | Expose time and sleep services to programs. |
| ✅ | Input/output | Read and write terminal streams through descriptors 0, 1, and 2. |
| [~] | System information | AUEX has versioned read-only ABI and PID queries; broader device, memory, and time inventory remains. |

### H. Kernel stability and security

| Done | Requirement | Description |
| --- | --- | --- |
| [~] | Memory protection | AUEX cannot address kernel memory; hardware-enforced user protection remains. |
| ⬜ | Privilege separation | Applications execute with restricted CPU privileges. |
| ✅ | Resource cleanup | Process termination releases its descriptors and temporary allocations. |
| ✅ | Error handling | Invalid system calls don't crash the kernel. |
| ✅ | Fault containment | Faulty AUEX programs terminate without taking down the shell. |
| ✅ | Kernel logging | Record useful diagnostic information. |
| ✅ | Kernel panic | Fatal CPU state is recorded and rendered on both kernel terminals before the system halts. |
| ✅ | Input validation | Validate user-provided pointers, lengths and arguments. |
| [~] | Synchronization | IRQ queues, ownership, and memory fences are bounded; general locks and multicore support remain. |
| ✅ | Automated testing | Test essential kernel functionality. |
