; ============================================================================
;  BootLock — stage1 (MBR, LBA 0). Ограничение: 440 байт кода
;  (байты 440..511 — подпись диска и таблица разделов — не трогаются).
;
;  1. Перемещает себя 0x7C00 → 0x0600 (место 0x7C00 нужно для VBR ОС).
;  2. Через INT 13h AH=42h (LBA) читает конфиг (LBA 1) и проверяет 'BLCF'.
;  3. Читает бэкап MBR + stage2 (LBA 2 .. 2+N) в 1000:0200.
;  4. Передаёт управление stage2 (1000:0400), DL = загрузочный диск.
; ============================================================================
bits 16
cpu 386
org 0x0600
%include "config.inc"

start:
        cli
        xor ax, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ds, ax
        mov es, ax
        mov si, 0x7C00
        mov di, 0x0600
        mov cx, 256
        cld
        rep movsw
        jmp 0:relocated

relocated:
        sti
        mov [drive], dl
        mov ah, 0x41                    ; есть ли LBA-расширения?
        mov bx, 0x55AA
        int 0x13
        jc .noext
        cmp bx, 0xAA55
        je .ext_ok
.noext: mov si, msg_noext
        jmp fatal
.ext_ok:
        mov word [dap_count], 1         ; конфиг
        mov word [dap_off], 0
        mov dword [dap_lba], 1
        call read
        push STAGE_SEG
        pop es
        cmp dword [es:CFG_MAGIC], 'BLCF'
        je .cfg_ok
        mov si, msg_nocfg
        jmp fatal
.cfg_ok:
        mov ax, [es:CFG_S2_SECTORS]
        inc ax                          ; + бэкап MBR
        mov [dap_count], ax
        mov word [dap_off], 0x0200
        mov dword [dap_lba], 2
        call read
        mov dl, [drive]
        jmp STAGE_SEG:STAGE2_OFF

; чтение по DAP с тремя попытками
read:
        mov bp, 3
.again: mov si, dap
        mov ah, 0x42
        mov dl, [drive]
        int 0x13
        jnc .ok
        xor ah, ah                      ; сброс контроллера
        mov dl, [drive]
        int 0x13
        dec bp
        jnz .again
        mov si, msg_disk
        jmp fatal
.ok:    ret

fatal:
        mov ah, 0x0E
        mov bx, 0x0007
.l:     lodsb
        test al, al
        jz .halt
        int 0x10
        jmp .l
.halt:  sti
        hlt
        jmp .halt

drive   db 0
dap:    db 0x10, 0
dap_count dw 0
dap_off dw 0
        dw STAGE_SEG
dap_lba dq 0

msg_noext db "BootLock: BIOS has no LBA extensions", 0
msg_nocfg db "BootLock: config sector missing", 0
msg_disk  db "BootLock: disk read error", 0

        times 440 - ($ - $$) db 0       ; ошибка сборки, если код > 440 байт
