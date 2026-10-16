.intel_syntax noprefix
.section .text

// All entry points use the kernel's current x86-64 register calling convention.
// The read-only code page is copied before mapping and the three pointers at
// the end are patched through its private physical alias before execution.
.global native_setup
.global native_enter
.global native_page_fault
.global native_general_protection
.global native_int80
.global native_boot_info
.global native_original_page_fault
.global native_original_general_protection
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

// bootInfo+3544: user CR3, +3552: RIP, +3560: stack, +3568: argument.
// The kernel return stack is preserved across the privilege transition.
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
    mov qword ptr [r10 + 3536], 1
    mov r11, qword ptr [r10 + 3576]
    mov qword ptr [r11 + 4], rsp
    cli
    mov rax, qword ptr [r10 + 3544]
    mov cr3, rax
    mov rdi, qword ptr [r10 + 3568]
    mov rsi, qword ptr [r10 + 3552]
    mov rdx, qword ptr [r10 + 3560]
    push 0x23
    push rdx
    pushfq
    pop rax
    or rax, 0x200
    push rax
    push 0x1b
    push rsi
    xor eax, eax
    xor ebx, ebx
    xor ebp, ebp
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d
    iretq

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

// int 0x80 uses RAX=1 (exit), RDI=exit status; RAX=2 returns the PID.
// Other numbers return -38 to ring 3 without terminating the process.
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
    mov rax, -38
    pop r11
    iretq
.getpid_call:
    mov rax, qword ptr [r11 + 3624]
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
    sti
    ret

.balign 8
native_boot_info:
    .quad 0
native_original_page_fault:
    .quad 0
native_original_general_protection:
    .quad 0
native_original_int80:
    .quad 0
