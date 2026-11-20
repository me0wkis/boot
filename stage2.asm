; ============================================================================
;  BootLock — stage2. Загружается stage1 в 1000:0400 (конфиг — в 1000:0000,
;  копия исходного MBR — в 1000:0200). DS = CS = 0x1000.
;
;  Последовательность: Space Invaders (N секунд) → пароль → меню ОС →
;  активация выбранного раздела (флаг 0x80 в MBR, запись на диск) →
;  загрузка VBR раздела в 0000:7C00 и передача управления
;  (DL = диск, DS:SI → запись таблицы разделов — стандартный протокол MBR).
; ============================================================================
bits 16
cpu 386
%include "config.inc"
org STAGE2_OFF

entry:
        cli
        mov ax, cs
        mov ds, ax
        sti
        cld
        mov [boot_drive], dl
        call serial_init
        mov si, s_log_start2
        call serial_puts
        push es                         ; адрес шрифта 8×8 из BIOS (для режима 13h)
        push bp
        mov ax, 0x1130
        mov bh, 0x03
        int 0x10
        mov [font_off], bp
        mov [font_seg], es
        pop bp
        pop es
        call get_ticks
        or ax, 1
        mov [rng], ax

        cmp word [CFG_GAME_SECS], 0
        je .nogame
        call game
.nogame:
        call set_text_mode
        test word [CFG_FLAGS], FLAG_PASSWORD
        jz .menu
        call password
.menu:  call menu                       ; bl = номер раздела или 0xFF
        cmp bl, 0xFF
        je reboot
        call chainload                  ; возвращается только при ошибке
        jmp .menu

reboot:
        mov si, s_log_reboot
        call serial_puts
        mov al, 0xFE                    ; сброс через контроллер клавиатуры
        out 0x64, al
        int 0x19

; ---------------------------------------------------------------- пароль
password:
        mov al, [CFG_ATTEMPTS]
        test al, al
        jnz .t
        mov al, 3
.t:     mov [tries], al
.again: mov si, s_pw_help
        call draw_frame
        mov dh, 8
        mov dl, 18
        mov bh, 9
        mov bl, 44
        mov ah, 0x1F
        call draw_box
        mov dh, 10
        mov dl, 22
        mov si, s_pw_title
        call print_at
        mov dh, 12
        mov cx, 36
        mov al, ' '
        mov ah, 0x70
        call fill_at
        mov dh, 14
        mov ah, 0x1B
        mov si, s_pw_tries
        call print_at
        movzx eax, byte [tries]
        call num_to_str
        mov ah, 0x1B
        mov dl, 38
        call print_at
        xor cx, cx                      ; длина введённого
.k:     xor ah, ah
        int 0x16
        cmp al, 13
        je .enter
        cmp al, 8
        je .bs
        cmp al, 27
        je .esc
        cmp al, 32
        jb .k
        cmp al, 126
        ja .k
        cmp cx, 32
        jae .k
        mov di, cx
        mov [pw_buf + di], al
        inc cx
        mov al, '*'
        call .echo
        jmp .k
.bs:    jcxz .k
        mov al, ' '
        call .echo
        dec cx
        jmp .k
.esc:   jcxz .k
        mov al, ' '
        call .echo
        dec cx
        jmp .esc
.echo:  push cx                         ; символ al в позиции cx поля ввода
        mov dh, 12
        mov dl, 22
        add dl, cl
        mov ah, 0x70
        mov cx, 1
        call fill_at
        pop cx
        ret
.enter: mov dh, 15
        mov dl, 22
        mov ah, 0x1E
        mov si, s_pw_check
        call print_at
        call check_password
        pushf
        mov di, pw_buf                  ; стереть пароль из памяти
        mov cx, 32
        xor al, al
        push es
        push ds
        pop es
        rep stosb
        pop es
        popf
        jz .ok
        mov si, s_log_pwbad
        call serial_puts
        dec byte [tries]
        jz .locked
        mov dh, 15
        mov dl, 22
        mov ah, 0x4F
        mov si, s_pw_denied
        call print_at
        inc byte [fails]                ; задержка растёт с каждой ошибкой
        movzx ax, byte [fails]
        shl ax, 1
        call delay_sec
        call kbd_flush
        jmp .again
.ok:    mov si, s_log_pwok
        call serial_puts
        ret
.locked:
        mov ah, 0x4F
        call cls
        mov dh, 10
        mov dl, 20
        mov si, s_locked1
        call print_at
        mov dh, 12
        mov si, s_locked2
        call print_at
        mov si, s_log_locked
        call serial_puts
.h:     sti
        hlt
        jmp .h

; ---------------------------------------------------------------- меню ОС
menu:
        push es
        push word 0
        pop es
        xor cx, cx                      ; число пунктов
        xor bx, bx
.b:     mov si, bx
        shl si, 4
        add si, PART_TABLE
        mov al, [es:si + 4]
        test al, al
        jz .skip
        cmp al, 0x05                    ; расширенные разделы — не ОС
        je .skip
        cmp al, 0x0F
        je .skip
        cmp al, 0x85
        je .skip
        movzx ax, byte [CFG_HIDDEN]
        bt ax, bx
        jc .skip
        mov di, cx
        mov [list + di], bl
        inc cx
.skip:  inc bx
        cmp bx, 4
        jb .b
        mov di, cx
        mov byte [list + di], 0xFF      ; последний пункт — перезагрузка
        inc cx
        mov [count], cx
        ; выбор по умолчанию: из конфига или активный раздел
        mov word [sel], 0
        mov al, [CFG_DEFAULT]
        cmp al, 4
        jb .find
        xor bx, bx                      ; ищем активный
.act:   mov si, bx
        shl si, 4
        cmp byte [es:si + PART_TABLE], 0x80
        je .fa
        inc bx
        cmp bx, 4
        jb .act
        jmp .draw
.fa:    mov al, bl
.find:  xor di, di
.f:     cmp [list + di], al
        je .fs
        inc di
        cmp di, [count]
        jb .f
        jmp .draw
.fs:    mov [sel], di

.draw:  mov si, s_menu_help
        call draw_frame
        mov dh, 3
        mov dl, 4
        mov ah, 0x0F
        mov si, s_menu_title
        call print_at
        mov ax, [count]
        shl ax, 1
        add ax, 3
        mov bh, al
        mov bl, 74
        mov dh, 5
        mov dl, 3
        mov ah, 0x07
        call draw_box
        mov dh, 5
        mov dl, 8
        mov si, s_menu_cols
        mov ah, 0x08
        call print_at
        xor bp, bp                      ; k
.item:  mov ax, bp
        shl al, 1
        add al, 7
        mov dh, al
        mov dl, 5
        mov ah, 0x07
        cmp bp, [sel]
        jne .attr
        mov ah, 0x70
.attr:  mov [cur_attr], ah
        mov [cur_row], dh
        mov cx, 70
        mov al, ' '
        call fill_at
        mov ax, bp                      ; «N.»
        add al, '1'
        mov [numtmp], al
        mov byte [numtmp + 1], '.'
        mov byte [numtmp + 2], 0
        mov si, numtmp
        mov dl, 6
        mov ah, [cur_attr]
        call print_at
        mov di, bp                      ; [bp+..] адресует SS — берём di
        movzx bx, byte [list + di]
        cmp bl, 0xFF
        jne .part
        mov si, s_reboot
        mov dl, 10
        call print_at
        jmp .inext
.part:  mov si, bx                      ; имя из конфига (bx*24)
        imul si, si, CFG_NAME_LEN
        add si, CFG_NAMES
        cmp byte [si], 0
        jne .nm
        mov di, bx
        shl di, 4
        mov al, [es:di + PART_TABLE + 4]
        call type_desc
.nm:    mov dl, 10
        mov ah, [cur_attr]
        call print_at
        mov di, bx
        shl di, 4
        mov al, [es:di + PART_TABLE + 4]
        call type_desc
        mov dl, 40
        call print_at
        mov eax, [es:di + PART_TABLE + 12]
        shr eax, 11                     ; секторы → МиБ
        call num_to_str
        mov ah, [cur_attr]
        mov dx, numbuf + 11             ; выравнивание числа вправо (до столбца 61)
        sub dx, si
        neg dl
        add dl, 62
        mov dh, [cur_row]
        call print_at
        mov si, s_mib
        mov dl, 63
        call print_at
        cmp byte [es:di + PART_TABLE], 0x80
        jne .inext
        mov si, s_active
        mov dl, 67
        call print_at
.inext: inc bp
        cmp bp, [count]
        jb .item
        ; клавиши
.key:   xor ah, ah
        int 0x16
        cmp ah, 0x48                    ; ↑
        je .up
        cmp ah, 0x50                    ; ↓
        je .down
        cmp al, 13
        je .go
        cmp al, '1'
        jb .key
        sub al, '1'
        movzx ax, al
        cmp ax, [count]
        jae .key
        mov [sel], ax
        jmp .go
.up:    mov ax, [sel]
        test ax, ax
        jnz .u1
        mov ax, [count]
.u1:    dec ax
        mov [sel], ax
        jmp .draw
.down:  mov ax, [sel]
        inc ax
        cmp ax, [count]
        jb .d1
        xor ax, ax
.d1:    mov [sel], ax
        jmp .draw
.go:    mov di, [sel]
        mov bl, [list + di]
        pop es
        ret

; al = тип раздела → si = описание
type_desc:
        push bx
        mov bx, type_table
.l:     cmp byte [bx], 0
        je .unk
        cmp [bx], al
        je .f
        add bx, 3
        jmp .l
.f:     mov si, [bx + 1]
        pop bx
        ret
.unk:   mov si, s_t_unknown
        pop bx
        ret

; ---------------------------------------------------------------- активация
; bl = номер раздела: ставим 0x80 только ему и записываем MBR на диск
activate:
        pusha
        push es
        push word 0
        pop es
        xor cx, cx
.l:     mov si, cx
        shl si, 4
        xor al, al
        cmp cl, bl
        jne .s
        mov al, 0x80
.s:     mov [es:si + PART_TABLE], al
        inc cx
        cmp cx, 4
        jb .l
        pop es
        mov word [dap_count], 1
        mov word [dap_off], MBR_COPY
        mov word [dap_seg], 0
        mov dword [dap_lba], 0
        mov dword [dap_lba + 4], 0
        mov si, dap
        mov ax, 0x4300                  ; LBA-запись
        mov dl, [boot_drive]
        int 0x13
        jnc .ok
        mov dh, 22
        mov dl, 4
        mov ah, 0x0E
        mov si, s_wr_fail
        call print_at
        mov ax, 2
        call delay_sec
        jmp .x
.ok:    mov al, '1'
        add al, bl
        mov [s_log_act_n], al
        mov si, s_log_act
        call serial_puts
.x:     popa
        ret

; ---------------------------------------------------------------- загрузка ОС
chainload:
        push es
        push word 0
        pop es
        movzx si, bl
        shl si, 4
        add si, PART_TABLE
        mov eax, [es:si + 8]
        mov [dap_lba], eax
        mov dword [dap_lba + 4], 0
        mov word [dap_count], 1
        mov word [dap_off], 0x7C00
        mov word [dap_seg], 0
        push si
        mov si, dap
        mov ah, 0x42
        mov dl, [boot_drive]
        int 0x13
        pop si
        jc .err
        cmp word [es:0x7DFE], 0xAA55
        jne .nboot
        call activate                   ; ОС загрузочна — делаем раздел активным
        mov al, '1'
        add al, bl
        mov [s_log_boot_n], al
        push si
        mov si, s_log_boot
        call serial_puts
        call set_text_mode
        pop si
        mov dl, [boot_drive]
        cli
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        sti
        jmp 0x0000:0x7C00               ; DL = диск, DS:SI = запись раздела

.err:   mov si, s_rd_fail
        jmp .msg
.nboot: mov si, s_not_boot
.msg:   pop es
        mov dh, 22
        mov dl, 4
        mov ah, 0x0C
        call print_at
        mov dh, 23
        mov si, s_anykey
        mov ah, 0x07
        call print_at
        xor ah, ah
        int 0x16
        ret

%include "util.asm"
%include "sha256.asm"
%include "game.asm"

; ================================================================ данные
s_header     db "BootLock 1.0  |  secure boot manager", 0
s_pw_help    db "Enter - confirm   Backspace - delete   Esc - clear", 0
s_pw_title   db "Enter boot password:", 0
s_pw_tries   db "Attempts left:", 0
s_pw_check   db "Checking...      ", 0
s_pw_denied  db "ACCESS DENIED    ", 0
s_locked1    db "SYSTEM LOCKED: too many wrong passwords.", 0
s_locked2    db "Press Ctrl+Alt+Del to restart.", 0
s_menu_title db "Select an operating system to boot:", 0
s_menu_cols  db "  Name                          Type                Size", 0
s_menu_help  db "Up/Down - select   Enter - boot   1-5 - quick select", 0
s_reboot     db "Reboot computer", 0
s_mib        db "MiB", 0
s_active     db "[active]", 0
s_wr_fail    db "Warning: cannot write MBR (read-only disk?) - booting anyway", 0
s_rd_fail    db "Error: cannot read the partition boot sector", 0
s_not_boot   db "Error: partition is not bootable (no 55AA signature)", 0
s_anykey     db "Press any key...", 0
s_empty      db 0

s_log_start2 db "[BL] stage2 started", 0
s_log_title  db "[BL] game: title screen", 0
s_log_start  db "[BL] game: started", 0
s_log_won    db "[BL] game: passed", 0
s_log_over   db "[BL] game: over, timer reset", 0
s_log_pwok   db "[BL] password: ok", 0
s_log_pwbad  db "[BL] password: wrong", 0
s_log_locked db "[BL] password: locked", 0
s_log_reboot db "[BL] reboot", 0
s_log_act    db "[BL] activated partition "
s_log_act_n  db "0", 0
s_log_boot   db "[BL] chainload partition "
s_log_boot_n db "0", 0

s_t1      db "SPACE INVADERS", 0
s_t2      db "BOOTLOCK SECURITY CHECK", 0
s_t3      db "SURVIVE FOR ", 0
s_t3b     db " SECONDS TO", 0
s_t4      db "UNLOCK THE PASSWORD PROMPT", 0
s_t5      db "ARROWS / A,D-MOVE  SPACE-FIRE", 0
s_t6      db "PRESS SPACE TO START", 0
s_h_time  db "TIME", 0
s_h_score db "SCORE", 0
s_h_lives db "LIVES", 0
s_g_won   db "CHECK PASSED!", 0
s_g_over  db "GAME OVER - TIMER RESET", 0
s_g_reset db "GET READY - RESTARTING...", 0

type_table:
        db 0x01
        dw s_t_fat12
        db 0x04
        dw s_t_fat16
        db 0x06
        dw s_t_fat16
        db 0x0E
        dw s_t_fat16
        db 0x0B
        dw s_t_fat32
        db 0x0C
        dw s_t_fat32
        db 0x07
        dw s_t_ntfs
        db 0x17
        dw s_t_ntfs
        db 0x27
        dw s_t_winre
        db 0x83
        dw s_t_linux
        db 0x8E
        dw s_t_lvm
        db 0xA5
        dw s_t_fbsd
        db 0xA6
        dw s_t_obsd
        db 0xA9
        dw s_t_nbsd
        db 0xEF
        dw s_t_efi
        db 0
s_t_fat12   db "DOS (FAT12)", 0
s_t_fat16   db "DOS/Win (FAT16)", 0
s_t_fat32   db "Windows (FAT32)", 0
s_t_ntfs    db "Windows (NTFS)", 0
s_t_winre   db "Windows RE", 0
s_t_linux   db "Linux", 0
s_t_lvm     db "Linux LVM", 0
s_t_fbsd    db "FreeBSD", 0
s_t_obsd    db "OpenBSD", 0
s_t_nbsd    db "NetBSD", 0
s_t_efi     db "EFI System", 0
s_t_unknown db "Unknown", 0

%include "data.inc"

dap:        db 0x10, 0
dap_count   dw 0
dap_off     dw 0
dap_seg     dw 0
dap_lba     dq 0

stage2_end:

; ================================================================ BSS (не хранится на диске)
absolute stage2_end
alignb 4
boot_drive  resb 1
tries       resb 1
fails       resb 1
cur_attr    resb 1
cur_row     resb 1
font_off    resw 1
font_seg    resw 1
rng         resw 1
count       resw 1
sel         resw 1
list        resb 8
numtmp      resb 4
numbuf      resb 12
pw_buf      resb 33
alignb 4
sha_block   resb 64
sha_msg     resb 64
sha_w       resd 64
sha_st      resd 8
sha_out     resb 32
; игра
need_ticks  resd 1
elapsed     resd 1
last_tick   resd 1
score       resd 1
old_int9    resd 1
gx          resw 1
gy          resw 1
gdir        resw 1
step_cnt    resw 1
alive_cnt   resw 1
minx        resw 1
maxx        resw 1
maxy        resw 1
px          resw 1
bul_x       resw 1
bul_y       resw 1
bomb_x      resw MAX_BOMBS
bomb_y      resw MAX_BOMBS
bomb_on     resb MAX_BOMBS
alive       resb INV_ROWS * INV_COLS
keys        resb 128
lives       resb 1
wave        resb 1
anim        resb 1
dead        resb 1
bul_on      resb 1
bss_end:
