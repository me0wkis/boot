; ============================================================================
;  Вспомогательные процедуры: текстовый режим, COM1, задержки, числа, ГСЧ
;  Соглашение: DS = CS = STAGE_SEG; процедуры сохраняют регистры (pusha/popa).
; ============================================================================

; ---------- текстовый режим 80×25 ----------
set_text_mode:
        pusha
        mov ax, 0x0003
        int 0x10
        mov ah, 0x01                    ; спрятать курсор
        mov cx, 0x2000
        int 0x10
        popa
        ret

; dh=строка, dl=столбец → di = смещение в B800
_text_off:
        push ax
        push cx
        mov al, dh
        mov cl, 80
        mul cl
        movzx cx, dl
        add ax, cx
        shl ax, 1
        mov di, ax
        pop cx
        pop ax
        ret

; dh=строка dl=столбец ah=атрибут si=ASCIIZ
print_at:
        pusha
        push es
        call _text_off
        push word 0xB800
        pop es
.l:     lodsb
        test al, al
        jz .d
        stosw
        jmp .l
.d:     pop es
        popa
        ret

; dh=строка dl=столбец cx=кол-во al=символ ah=атрибут
fill_at:
        pusha
        push es
        call _text_off
        push word 0xB800
        pop es
        rep stosw
        pop es
        popa
        ret

; ah=атрибут: залить весь экран
cls:
        pusha
        xor dx, dx
        mov cx, 2000
        mov al, ' '
        call fill_at
        popa
        ret

; рамка: dh=верх dl=лево bh=высота bl=ширина ah=атрибут (внутри — пробелы)
draw_box:
        pusha
        movzx cx, bl
        sub cx, 2
        mov al, 0xC9
        call _put1
        inc dl
        mov al, 0xCD
        call fill_at
        add dl, cl
        mov al, 0xBB
        call _put1
        sub dl, cl
        dec dl
        movzx bp, bh
        sub bp, 2
.mid:   inc dh
        mov al, 0xBA
        call _put1
        inc dl
        mov al, ' '
        call fill_at
        add dl, cl
        mov al, 0xBA
        call _put1
        sub dl, cl
        dec dl
        dec bp
        jnz .mid
        inc dh
        mov al, 0xC8
        call _put1
        inc dl
        mov al, 0xCD
        call fill_at
        add dl, cl
        mov al, 0xBC
        call _put1
        popa
        ret
_put1:  push cx
        mov cx, 1
        call fill_at
        pop cx
        ret

; Шапка и подвал экрана; si = текст подсказки внизу
draw_frame:
        pusha
        mov ah, 0x07
        call cls
        xor dx, dx
        mov cx, 80
        mov al, ' '
        mov ah, 0x1F
        call fill_at
        mov si, s_header
        mov dl, 2
        call print_at
        popa
        pusha
        mov dh, 24
        xor dl, dl
        mov cx, 80
        mov al, ' '
        mov ah, 0x70
        call fill_at
        mov dl, 2
        call print_at
        popa
        ret

; ---------- задержки ----------
; cx:dx = микросекунды (INT 15h AH=86h)
delay_us:
        pusha
        mov ah, 0x86
        int 0x15
        popa
        ret

; ax = секунды
delay_sec:
        pusha
        mov bx, ax
        test bx, bx
        jz .d
.l:     mov cx, 0x000F
        mov dx, 0x4240                  ; 1 000 000 мкс
        call delay_us
        dec bx
        jnz .l
.d:     popa
        ret

; очистить буфер клавиатуры BIOS
kbd_flush:
        pusha
.l:     mov ah, 0x01
        int 0x16
        jz .d
        xor ah, ah
        int 0x16
        jmp .l
.d:     popa
        ret

; ---------- последовательный порт COM1 (журнал для отладки/тестов) ----------
COM1 equ 0x3F8
serial_init:
        pusha
        mov dx, COM1 + 1
        xor al, al
        out dx, al
        mov dx, COM1 + 3
        mov al, 0x80
        out dx, al
        mov dx, COM1
        mov al, 1                       ; 115200 бод
        out dx, al
        mov dx, COM1 + 1
        xor al, al
        out dx, al
        mov dx, COM1 + 3
        mov al, 0x03                    ; 8N1
        out dx, al
        mov dx, COM1 + 2
        mov al, 0xC7
        out dx, al
        mov dx, COM1 + 4
        mov al, 0x0B
        out dx, al
        popa
        ret

serial_putc:                            ; al
        pusha
        mov ah, al
        mov cx, 0xFFFF                  ; тайм-аут, если порта нет
        mov dx, COM1 + 5
.w:     in al, dx
        test al, 0x20
        jnz .ok
        loop .w
.ok:    mov al, ah
        mov dx, COM1
        out dx, al
        popa
        ret

serial_puts:                            ; si = ASCIIZ, добавляет \r\n
        pusha
.l:     lodsb
        test al, al
        jz .e
        call serial_putc
        jmp .l
.e:     mov al, 13
        call serial_putc
        mov al, 10
        call serial_putc
        popa
        ret

; ---------- числа ----------
; eax → десятичная строка; si = указатель на неё (внутренний буфер)
num_to_str:
        push eax
        push ebx
        push edx
        push di
        mov di, numbuf + 11
        mov byte [di], 0
        mov ebx, 10
.l:     xor edx, edx
        div ebx
        add dl, '0'
        dec di
        mov [di], dl
        test eax, eax
        jnz .l
        mov si, di
        pop di
        pop edx
        pop ebx
        pop eax
        ret

; al → две hex-цифры в serial (для отладки)
serial_hex8:
        pusha
        mov ah, al
        shr al, 4
        call .nib
        mov al, ah
        and al, 0x0F
        call .nib
        popa
        ret
.nib:   cmp al, 10
        sbb al, 0x69
        das
        call serial_putc
        ret

; ---------- ГСЧ xorshift16 → ax ----------
rand:
        push dx
        mov ax, [rng]
        mov dx, ax
        shl dx, 7
        xor ax, dx
        mov dx, ax
        shr dx, 9
        xor ax, dx
        mov dx, ax
        shl dx, 8
        xor ax, dx
        mov [rng], ax
        pop dx
        ret

; ---------- время BIOS ----------
; eax = счётчик тиков 0040:006C (18.2 Гц)
get_ticks:
        push es
        push word 0
        pop es
        mov eax, [es:0x046C]
        pop es
        ret
