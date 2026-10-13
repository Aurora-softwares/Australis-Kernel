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

## CLI commands to require

`Hardcoded?` means the command is part of the small kernel-resident KMon and
must work without a root filesystem or user process. `No` means an ordinary
command belongs in a userland `.exec` program, or an optional low-level
diagnostic is confined to a development build. The userland shell's `help` is
a shell built-in, while KMon keeps its own `help`. A KMon diagnostic may
coexist with a userland tool.

The status below assesses the **named command in its intended location**, not
the underlying kernel capability. `✅` means it works there, `[~]` means a
prototype or misplaced implementation exists, and `⬜` means the named command
is absent. The current `kmon>` shell is transitional; `CommandShell.exec` has
not been implemented. Debugging commands that inspect or modify raw kernel
state must only be exposed in an explicit debugging mode. The required list
contains 22 commands. The 14 excess standalone commands are recorded below it;
removing a command requirement does not remove its kernel subsystem or tests.

### Kernel information

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| ✅ | `help` | Yes | KMon lists its current commands; the future userland shell needs its own built-in. |
| [~] | `version` | No | KMon and `/Bin/version.exec` print fixed versions; the executable does not query kernel/build information. |
| ⬜ | `status` | Yes | No KMon summary of boot and subsystem health. |
| ⬜ | `uptime` | No | No userland command or time query for it. |
| ⬜ | `bootinfo` | Yes | Boot handoff is read internally, but KMon cannot inspect it. |
| ⬜ | `log` | Yes | Kernel diagnostic output exists, but KMon has no retained-message reader. A normal `dmesg` can be external later. |
| ⬜ | `clear` | No | Ctrl+L clears the KMon screen, but there is no `clear` command; `/Bin/clear.exec` currently prints its first argument. |

### Memory management

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| ⬜ | `mem` | No | Ordinary memory-usage tool belongs in userland; no such executable exists. |
| ⬜ | `memmap` | Yes | Boot memory map is consumed internally, but KMon cannot display it. |
| ⬜ | `pages` | Yes | Physical page allocator exists, but KMon exposes no page statistics. |

### Hardware and interrupts

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| [~] | `devices` | Yes | KMon reports USB state, but unconditionally says boot storage is ready, including early Rescue. |
| ⬜ | `drivers` | No | Drivers exist; normal inventory belongs in a userland tool over a checked kernel API. |

### Filesystems and processes

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| [~] | `mounts` | Yes | KMon lists data/USB mounts, but unconditionally reports `/` as mounted in early Rescue. |
| [~] | `ls` | No | Kernel shell lists paths; no `ls.exec` exists yet. |
| [~] | `cat` | No | `/Bin/cat.exec` reads files and passes AHCI/NVMe smoke tests via `run cat`; bare `cat` still selects the kernel handler. |
| [~] | `processes` | No | KMon's `ps` reports only the last program's result; no userland process-list tool or general process table. KMon may retain a recent-fault summary. |

### Recovery and debugging

| Done | Command | Hardcoded? | Assessment |
| --- | --- | --- | --- |
| ✅ | `continue` | Yes | From early `R` Rescue, resets the machine into a fresh normal boot; in normal KMon it reports that boot is already active. |
| ✅ | `reboot` | Yes | Resets through x86 chipset reset control, with an 8042 fallback. |
| ✅ | `halt` | Yes | Disables interrupts and halts the processor without returning to the prompt. |
| ✅ | `trace` | Yes | Displays boot/storage/program diagnostics and the eight most recent KMon commands. |
| ✅ | `panic` | Yes | `D` Debug boot only; triggers the real fatal page-fault handler. The older `panic-test` alias was removed. |
| ✅ | `registers` | Yes | Shows live RIP, RSP, RBP, RFLAGS, and CR3; shows a saved fatal frame if one is available. |

`continue` is a reset from `R` Rescue because that boot mode intentionally
skips controller, MMIO, DMA, and storage bootstrap. It cannot safely resume
those bootloader steps in place. The reset starts a new normal boot when no
recovery key is pressed. `make test-kmon-recovery` checks all six commands in
QEMU; the normal AHCI/NVMe console tests also exercise `trace`, `registers`,
the normal-mode `continue` response, and the `panic` mode guard.

### Excess standalone commands to remove (14)

These names are removed from the required CLI set. They are either redundant
with a retained command or better served by an optional development tool.

| Command | Reason to remove as a separate required command | Use instead |
| --- | --- | --- |
| `heap` | Detailed allocator internals are not needed in the recovery monitor. | `pages` for recovery memory health. |
| `vmm` | Raw page-table inspection is a development task. | Development debugger. |
| `peek` | Arbitrary memory reads are outside the recovery contract. | Development debugger with address checks. |
| `poke` | Arbitrary memory writes are dangerous and unnecessary for recovery. | Development debugger with explicit authorization. |
| `cpu` | A separate CPU command duplicates system information. | Userland `sysinfo`. |
| `cpuid` | Raw feature leaves are too detailed for the normal CLI. | Userland `sysinfo` or development debugger. |
| `pci` | A second hardware inventory duplicates the device list. | Extend `devices` with controller identifiers. |
| `irq` | Raw interrupt routing belongs in development diagnostics. | Development debugger. |
| `gdt` | Table entries are not a user-facing recovery operation. | Development debugger. |
| `idt` | Table entries are not a user-facing recovery operation. | Development debugger. |
| `timer` | A standalone kernel timer view is unnecessary. | Userland `uptime` or `sysinfo`. |
| `fs` | Registered filesystem types are less useful than active volumes. | `mounts`. |
| `tasks` | It duplicates process inspection without an independent task model. | Userland `processes`/`ps`. |
| `stack` | A standalone stack command cannot add to the fatal frame while the kernel is halted. | Panic report or development debugger. |

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
