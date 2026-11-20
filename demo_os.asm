; ============================================================================
;  Демонстрационная «ОС» — загрузочный сектор раздела (VBR).
;  Показывает, что загрузчик передал управление по стандартному протоколу:
;  DL = загрузочный диск, DS:SI → запись в таблице разделов (флаг 0x80, LBA).
;  Имя ОС хранится по смещению 0x180 (его записывает bootcfg mkdemo).
; ============================================================================
bits 16
org 0x7C00

start:
        cli
        xor ax, ax
        mov ss, ax
        mov sp, 0x7C00
        mov es, ax                      ; DS не трогаем: должен быть 0 от загрузчика
        sti
        mov [drive], dl
        mov [part], si
        mov ax, 0x0003
        int 0x10
        call com_init
        mov si, m_title
        call puts
        mov si, osname
        call puts
        call nl
        mov si, m_drive
        call puts
        mov al, [drive]
        call hex8
        call nl
        mov si, m_lba
        call puts
        mov bx, [part]
        mov eax, [bx + 8]
        call hex32
        call nl
        mov si, m_flag
        call puts
        mov bx, [part]
        mov al, [bx]
        call hex8
        call nl
        call nl
        mov si, m_done
        call puts
.h:     hlt
        jmp .h

; вывод на экран (INT 10h) и в COM1 одновременно
putc:   pusha
        mov ah, 0x0E
        mov bx, 0x000A
        int 0x10
        popa
        pusha
        mov ah, al
        mov dx, 0x3FD
.w:     in al, dx
        test al, 0x20
        jz .w
        mov al, ah
        mov dx, 0x3F8
        out dx, al
        popa
        ret
puts:   lodsb
        test al, al
        jz .d
        call putc
        jmp puts
.d:     ret
nl:     mov al, 13
        call putc
        mov al, 10
        jmp putc
hex32:  push eax
        shr eax, 16
        call hex16
        pop eax
hex16:  push ax
        mov al, ah
        call hex8
        pop ax
hex8:   push ax
        shr al, 4
        call .n
        pop ax
        and al, 0x0F
.n:     cmp al, 10
        sbb al, 0x69
        das
        jmp putc
com_init:
        mov dx, 0x3FB
        mov al, 0x80
        out dx, al
        mov dx, 0x3F8
        mov al, 1
        out dx, al
        inc dx
        xor al, al
        out dx, al
        mov dx, 0x3FB
        mov al, 3
        out dx, al
        ret

drive   db 0
part    dw 0
m_title db "[OS] Booted: ", 0
m_drive db "[OS] boot drive (DL) = 0x", 0
m_lba   db "[OS] partition LBA (DS:SI+8) = 0x", 0
m_flag  db "[OS] partition flag (DS:SI) = 0x", 0
m_done  db "Demo OS is running. Press Ctrl+Alt+Del.", 0

        times 0x180 - ($ - $$) db 0
osname: times 48 db 0
        times 510 - ($ - $$) db 0
        dw 0xAA55
