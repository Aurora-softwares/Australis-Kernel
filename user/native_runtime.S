.intel_syntax noprefix
.section .text

// All entry points use the kernel's current x86-64 register calling convention.
// The read-only code page is copied before mapping and the three pointers at
// the end are patched through its private physical alias before execution.
.global native_setup
.global native_enter
.global native_page_fault
.global native_general_protection
.global native_invalid_opcode
.global native_divide_error
.global native_timer
.global native_int80
.global native_boot_info
.global native_original_page_fault
.global native_original_general_protection
.global native_original_invalid_opcode
.global native_original_divide_error
.global native_original_timer
.global native_original_int80

native_setup:
    sub rsp, 16
    mov word ptr [rsp], 55
    lea rax, [rdi + 512]
    mov qword ptr [rsp + 2], rax
    lgdt [rsp]
    add rsp, 16
    mov ax, 0x28
    ltr ax
    xor eax, eax
    ret

// bootInfo+3544: user CR3, +3640: physical page holding the saved user
// registers and interrupt frame. The return stack survives each time slice.
native_enter:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r10, rdi
    mov qword ptr [r10 + 3520], rsp
    mov rax, cr3
    mov qword ptr [r10 + 3528], rax
    pushfq
    pop rax
    mov qword ptr [r10 + 3632], rax
    mov qword ptr [r10 + 3536], 1
    mov r11, qword ptr [r10 + 3576]
    mov qword ptr [r11 + 4], rsp
    cli
    mov rax, qword ptr [r10 + 3544]
    mov cr3, rax
    mov r10, qword ptr [r10 + 3640]
    push qword ptr [r10 + 152] // SS
    push qword ptr [r10 + 144] // RSP
    push qword ptr [r10 + 136] // RFLAGS
    push qword ptr [r10 + 128] // CS
    push qword ptr [r10 + 120] // RIP
    mov rax, qword ptr [r10]
    mov rbx, qword ptr [r10 + 8]
    mov rcx, qword ptr [r10 + 16]
    mov rdx, qword ptr [r10 + 24]
    mov rbp, qword ptr [r10 + 32]
    mov rsi, qword ptr [r10 + 40]
    mov rdi, qword ptr [r10 + 48]
    mov r8, qword ptr [r10 + 56]
    mov r9, qword ptr [r10 + 64]
    mov r11, qword ptr [r10 + 80]
    mov r12, qword ptr [r10 + 88]
    mov r13, qword ptr [r10 + 96]
    mov r14, qword ptr [r10 + 104]
    mov r15, qword ptr [r10 + 112]
    mov r10, qword ptr [r10 + 72]
    iretq

// Hardware timer vector 0x30. The 15 saved registers followed by the CPU's
// five-word user interrupt frame form the task's 160-byte resume context.
// Kernel-mode timer interrupts continue through the bootloader's handler.
native_timer:
    test byte ptr [rsp + 8], 3
    jz .kernel_timer
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rdi
    push rsi
    push rbp
    push rdx
    push rcx
    push rbx
    push rax
    mov r11, qword ptr [rip + native_boot_info]
    cmp qword ptr [r11 + 3536], 1
    jne .inactive_timer
    mov rdi, qword ptr [r11 + 3640]
    mov rsi, rsp
    mov ecx, 20
    cld
    rep movsq
    inc qword ptr [r11 + 176]
    mov dword ptr [r11 + 184], 48
    cmp dword ptr [r11 + 192], 1
    jne .xapic_eoi
    mov ecx, 2059
    xor eax, eax
    xor edx, edx
    wrmsr
    jmp .timer_done
.xapic_eoi:
    mov r10, qword ptr [r11 + 168]
    mov dword ptr [r10 + 176], 0
.timer_done:
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    mov rax, 1
    jmp native_restore
.inactive_timer:
    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rbp
    pop rsi
    pop rdi
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
.kernel_timer:
    jmp qword ptr [rip + native_original_timer]

// A user page fault returns to the caller of native_enter with -14. Kernel
// faults still enter the pre-existing allocation-free panic reporter.
native_page_fault:
    test byte ptr [rsp + 16], 3
    jz .kernel_page_fault
    mov r11, qword ptr [rip + native_boot_info]
    cmp qword ptr [r11 + 3536], 1
    jne .kernel_page_fault
    mov r10, cr2
    mov qword ptr [r11 + 3592], r10
    mov r10, qword ptr [rsp]
    mov qword ptr [r11 + 3600], r10
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    mov rax, -14
    jmp native_restore
.kernel_page_fault:
    jmp qword ptr [rip + native_original_page_fault]

// A privileged instruction in user mode faults only its native process.
native_general_protection:
    test byte ptr [rsp + 16], 3
    jz .kernel_general_protection
    mov r11, qword ptr [rip + native_boot_info]
    cmp qword ptr [r11 + 3536], 1
    jne .kernel_general_protection
    mov qword ptr [r11 + 3592], 0
    mov r10, qword ptr [rsp]
    mov qword ptr [r11 + 3600], r10
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    mov rax, -13
    jmp native_restore
.kernel_general_protection:
    jmp qword ptr [rip + native_original_general_protection]

// Faults without an error code have CS at [rsp+8]. Keep invalid opcodes and
// divide errors in the child instead of passing them to the kernel panic path.
native_invalid_opcode:
    test byte ptr [rsp + 8], 3
    jz .kernel_invalid_opcode
    mov r11, qword ptr [rip + native_boot_info]
    cmp qword ptr [r11 + 3536], 1
    jne .kernel_invalid_opcode
    mov qword ptr [r11 + 3592], 0
    mov qword ptr [r11 + 3600], 0
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    mov rax, -13
    jmp native_restore
.kernel_invalid_opcode:
    jmp qword ptr [rip + native_original_invalid_opcode]

native_divide_error:
    test byte ptr [rsp + 8], 3
    jz .kernel_divide_error
    mov r11, qword ptr [rip + native_boot_info]
    cmp qword ptr [r11 + 3536], 1
    jne .kernel_divide_error
    mov qword ptr [r11 + 3592], 0
    mov qword ptr [r11 + 3600], 0
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    mov rax, -8
    jmp native_restore
.kernel_divide_error:
    jmp qword ptr [rip + native_original_divide_error]

// int 0x80: 1 exits, 2 returns the PID, 3 writes to serial, 4 reports ABI
// version 1. Calls 5-16 yield a saved context for checked IPC/VFS dispatch.
// The serial write validates a single mapped user page before reading it.
native_int80:
    push r11
    test byte ptr [rsp + 16], 3
    jz .kernel_int80
    mov r11, qword ptr [rip + native_boot_info]
    cmp qword ptr [r11 + 3536], 1
    jne .kernel_int80
    cmp rax, 1
    je .exit_call
    cmp rax, 2
    je .getpid_call
    cmp rax, 3
    je .write_call
    cmp rax, 4
    je .abi_version
    cmp rax, 5
    jb .unknown_call
    cmp rax, 16
    jbe .managed_call
.unknown_call:
    mov rax, -38
    pop r11
    iretq
.abi_version:
    mov eax, 1
    pop r11
    iretq
.managed_call:
    pop r11
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rdi
    push rsi
    push rbp
    push rdx
    push rcx
    push rbx
    push rax
    mov r11, qword ptr [rip + native_boot_info]
    mov rdi, qword ptr [r11 + 3640]
    mov rsi, rsp
    mov ecx, 20
    cld
    rep movsq
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    mov rax, 2
    jmp native_restore
.getpid_call:
    mov rax, qword ptr [r11 + 3624]
    pop r11
    iretq
.write_call:
    push r10
    cmp rsi, 256
    ja .write_bad_length
    test rsi, rsi
    jz .write_empty
    mov r10, qword ptr [r11 + 3552] // mapped code page
    cmp rdi, r10
    jb .write_data
    lea rax, [r10 + 4096]
    cmp rdi, rax
    jae .write_data
    sub rax, rdi
    cmp rsi, rax
    ja .write_bad_pointer
    jmp .write_checked
.write_data:
    lea rax, [r10 + 4096] // AUSP data page
    cmp rdi, rax
    jb .write_stack
    lea rax, [r10 + 8192]
    cmp rdi, rax
    jae .write_stack
    sub rax, rdi
    cmp rsi, rax
    ja .write_bad_pointer
    jmp .write_checked
.write_stack:
    lea rax, [r10 + 12288] // page 4; page 3 is a guard
    cmp rdi, rax
    jb .write_bad_pointer
    lea rax, [r10 + 16384]
    cmp rdi, rax
    jae .write_bad_pointer
    sub rax, rdi
    cmp rsi, rax
    ja .write_bad_pointer
.write_checked:
    push rdx
    xor ecx, ecx
.write_next:
    cmp rcx, rsi
    jae .write_complete
    mov dx, 0x3fd
    mov r10d, 1000000
.write_wait:
    in al, dx
    test al, 32
    jnz .write_ready
    pause
    dec r10d
    jnz .write_wait
    mov rax, -5
    jmp .write_done
.write_ready:
    mov dx, 0x3f8
    mov al, byte ptr [rdi + rcx]
    out dx, al
    inc rcx
    jmp .write_next
.write_complete:
    mov rax, rsi
.write_done:
    pop rdx
    pop r10
    pop r11
    iretq
.write_bad_length:
    mov rax, -22
    pop r10
    pop r11
    iretq
.write_bad_pointer:
    mov rax, -14
    pop r10
    pop r11
    iretq
.write_empty:
    xor eax, eax
    pop r10
    pop r11
    iretq
.exit_call:
    mov qword ptr [r11 + 3584], rdi
    mov qword ptr [r11 + 3536], 0
    mov r10, qword ptr [r11 + 3528]
    mov cr3, r10
    mov rsp, qword ptr [r11 + 3520]
    xor eax, eax
    jmp native_restore
.kernel_int80:
    pop r11
    jmp qword ptr [rip + native_original_int80]

native_restore:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    cld
    mov r11, qword ptr [rip + native_boot_info]
    push qword ptr [r11 + 3632]
    popfq
    ret

.balign 8
native_boot_info:
    .quad 0
native_original_page_fault:
    .quad 0
native_original_general_protection:
    .quad 0
native_original_invalid_opcode:
    .quad 0
native_original_divide_error:
    .quad 0
native_original_timer:
    .quad 0
native_original_int80:
    .quad 0
