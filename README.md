# Kernel completion criteria

This checklist was audited against the freestanding kernel sources, the
documented `KernelBootInfo` ABI, the hosted subsystem tests, and the AHCI/NVMe
QEMU integration matrix.

Status key: `[x]` implemented and exercised, `[~]` partially implemented, and
`[ ]` not implemented.

Current assessment:

- Stage 1: 9 complete. A real page fault is covered in QEMU and produces the
  same allocation-free diagnostic on COM1 and the framebuffer before halting.
- Stage 2: 35 complete, 18 partial, 5 open. Storage, filesystems, USB, console,
  interrupts, and kernel memory ownership have live QEMU coverage. Native
  ring-3 execution, hardware context switching, preemptive threads, user time
  services, and CPU privilege separation remain open.
- QEMU coverage is substantial, but physical-machine validation remains a
  separate release requirement.

## Stage 1 - Minimum Viable Kernel

| Done | Requirement | Description |
| --- | --- | --- |
| [x] | Kernel entry | Receive execution from the bootloader. |
| [x] | Boot information | Read the information supplied by the bootloader. |
| [x] | Console output | Print text using the framebuffer or serial output. |
| [x] | CPU initialization | Configure essential processor state. |
| [x] | Memory map | Understand usable and reserved physical memory. |
| [x] | Exception handling | Catch CPU exceptions rather than silently crashing. |
| [x] | Panic handling | Fatal exceptions print the CPU frame and register state to COM1 and the framebuffer, then halt. |
| [x] | Basic memory allocation | Allocate memory for initial kernel structures. |
| [x] | Kernel idle | Remain operational after initialization. |

## Stage 2 - Feature Complete Kernel

### A. CPU and interrupt management

| Done | Requirement | Description |
| --- | --- | --- |
| [~] | CPU initialization | Essential x86-64, APIC, interrupt, and timer state is initialized; broader feature policy is still needed. |
| [x] | GDT | Configure the Global Descriptor Table on x86-64. |
| [x] | IDT | Configure the Interrupt Descriptor Table. |
| [x] | Exceptions | Handle processor exceptions. |
| [x] | Hardware interrupts | Receive and dispatch device interrupts. |
| [x] | Timer | Support periodic or one-shot timer interrupts. |
| [~] | CPU identification | Required paging and APIC capabilities are detected; a reusable CPU feature inventory is still needed. |
| [x] | Kernel panic | Fatal CPU exceptions print a complete allocation-free register report, retain the frame, and halt. |

### B. Memory management

| Done | Requirement | Description |
| --- | --- | --- |
| [x] | Physical memory manager | Track available and allocated RAM pages. |
| [x] | Virtual memory manager | Manage virtual address spaces and page tables. |
| [x] | Kernel heap | Support dynamic memory allocation. |
| [x] | Page allocation | Allocate and release memory pages. |
| [~] | Memory protection | Null-page removal and NX data mappings are active; native user/kernel page permissions remain. |
| [x] | Page faults | Detect and handle invalid memory accesses. |
| [~] | Process isolation | AUEX code and data are checked in software; separate hardware-protected address spaces remain. |

### C. Process and thread management

| Done | Requirement | Description |
| --- | --- | --- |
| [~] | Process creation | Checked AUEX bytecode processes can be loaded and started; native processes remain. |
| [x] | Process termination | AUEX exit and fault paths close descriptors and reclaim command allocations. |
| [~] | Process isolation | AUEX processes use checked code/data regions; hardware isolation remains. |
| [ ] | Thread support | Support independent native execution contexts. |
| [~] | Scheduler | A bounded cooperative AUEX scheduler exists; runnable queues and preemption remain. |
| [ ] | Context switching | Switch between native CPU execution contexts. |
| [ ] | User mode | Execute applications outside kernel privilege. |
| [~] | System calls | A checked AUEX syscall boundary exists; a native ring-3 entry path remains. |
| [~] | Idle thread | The kernel has an interrupt-enabled idle loop; it is not yet a schedulable thread. |

### D. Filesystem management

| Done | Requirement | Description |
| --- | --- | --- |
| [x] | Block devices | Read sectors from supported storage devices. |
| [x] | Partition discovery | Discover partitions, including GPT. |
| [x] | Filesystem interface | Provide a consistent interface for filesystem implementations. |
| [x] | HyFS support | Mount and read HyFS volumes. |
| [~] | File operations | Open, read, close, and transactional HyFS 2 mutations work through an explicit writable VFS mount; live recovery checks remain before writes become default. |
| [~] | Directory operations | Canonical namespace traversal and listing work; HyFS v1 has no on-disk directory tree. |
| [x] | File descriptors | Provide process-specific file handles. |
| [x] | Mount management | Mount and unmount supported filesystems. |
| [x] | Error handling | Handle invalid or corrupted filesystem structures. |

### E. Device management

| Done | Requirement | Description |
| --- | --- | --- |
| [x] | Device discovery | Discover supported hardware devices. |
| [x] | Driver interface | Provide consistent interfaces for drivers. |
| [x] | Storage drivers | Access supported storage controllers. |
| [x] | Display output | Write to an initialized framebuffer. |
| [x] | Keyboard input | Receive keyboard events. |
| [x] | Timer devices | Provide timekeeping and scheduling. |
| [x] | Interrupt routing | Associate device interrupts with handlers. |
| [x] | PCI discovery | Enumerate PCI devices where supported. |

### G. Program execution

| Done | Category | Example operations |
| --- | --- | --- |
| [~] | Processes | AUEX programs start and exit; waiting and concurrent process control remain. |
| [~] | Memory | Kernel map, unmap, allocation, and release work; user memory syscalls remain. |
| [~] | Files | User programs can open, read, and close; writable files remain. |
| [~] | Directories | The shell lists mounts and files and reports its directory; directory changes remain. |
| [ ] | Time | Expose time and sleep services to programs. |
| [x] | Input/output | Read and write terminal streams through descriptors 0, 1, and 2. |
| [~] | System information | Shell version and process inspection exist; a general program-facing interface remains. |

### H. Kernel stability and security

| Done | Requirement | Description |
| --- | --- | --- |
| [~] | Memory protection | AUEX cannot address kernel memory; hardware-enforced user protection remains. |
| [ ] | Privilege separation | Applications execute with restricted CPU privileges. |
| [x] | Resource cleanup | Process termination releases its descriptors and temporary allocations. |
| [x] | Error handling | Invalid system calls don't crash the kernel. |
| [x] | Fault containment | Faulty AUEX programs terminate without taking down the shell. |
| [x] | Kernel logging | Record useful diagnostic information. |
| [x] | Kernel panic | Fatal CPU state is recorded and rendered on both kernel terminals before the system halts. |
| [x] | Input validation | Validate user-provided pointers, lengths and arguments. |
| [~] | Synchronization | IRQ queues, ownership, and memory fences are bounded; general locks and multicore support remain. |
| [x] | Automated testing | Test essential kernel functionality. |
