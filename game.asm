; ============================================================================
;  Space Invaders — VGA 13h (320×200×256), двойная буферизация.
;  Свой обработчик IRQ1 (INT 9) хранит состояние клавиш → плавное управление.
;  Чтобы пройти дальше, нужно провести в игре CFG_GAME_SECS секунд.
;  Потеря всех жизней или прорыв захватчиков — таймер начинается заново.
; ============================================================================

INV_ROWS   equ 5
INV_COLS   equ 8
INV_DX     equ 24
INV_DY     equ 14
PLAYER_Y   equ 182
GROUND_Y   equ 193
MAX_BOMBS  equ 6
K_ESC      equ 0x01
K_SPACE    equ 0x39
K_LEFT     equ 0x4B
K_RIGHT    equ 0x4D
K_A        equ 0x1E
K_D        equ 0x20

game:
        pusha
        call kb_hook
        mov ax, 0x0013
        int 0x10
        ; need_ticks = секунды × 18.2065
        movzx eax, word [CFG_GAME_SECS]
        imul eax, eax, 18207
        xor edx, edx
        mov ecx, 1000
        div ecx
        mov [need_ticks], eax
        call title_screen
.new:   call reset_game
.frame: call update_time
        mov eax, [elapsed]
        cmp eax, [need_ticks]
        jae .won
        call do_input
        call do_bullet
        call do_invaders
        call do_bombs
        call render
        call present
        cmp byte [dead], 0
        je .wait
        call player_died
        cmp byte [lives], 0
        jne .wait
        call game_over
        jmp .new
.wait:  xor cx, cx
        mov dx, 30000                   ; ~33 кадра/с
        call delay_us
        jmp .frame
.won:   call render
        mov si, s_g_won
        mov bx, 92
        mov dx, 92
        mov al, 14
        call draw_text_box
        call present
        mov si, s_log_won
        call serial_puts
        mov ax, 2
        call delay_sec
        call kb_unhook
        call kbd_flush
        popa
        ret

; ---------------------------------------------------------------- состояние
reset_game:
        mov byte [lives], 3
        mov dword [score], 0
        mov dword [elapsed], 0
        mov byte [wave], 0
        mov word [px], 152
        call get_ticks
        mov [last_tick], eax
        call new_wave
        ret

new_wave:
        pusha
        mov word [gx], 40
        movzx ax, byte [wave]
        and ax, 3
        imul ax, ax, 8
        add ax, 24
        mov [gy], ax
        mov word [gdir], 2
        mov word [step_cnt], 0
        mov byte [anim], 0
        mov di, alive
        mov cx, INV_ROWS * INV_COLS
        mov al, 1
        rep stosb
        mov word [alive_cnt], INV_ROWS * INV_COLS
        mov byte [bul_on], 0
        mov byte [dead], 0
        mov di, bomb_on
        mov cx, MAX_BOMBS
        xor al, al
        rep stosb
        popa
        ret

update_time:
        call get_ticks
        mov edx, eax
        sub eax, [last_tick]
        mov [last_tick], edx
        cmp eax, 20                     ; полночь или пауза — не считаем
        ja .x
        add [elapsed], eax
.x:     ret

resync_time:
        push eax
        call get_ticks
        mov [last_tick], eax
        pop eax
        ret

; ---------------------------------------------------------------- ввод
do_input:
        mov al, [keys + K_LEFT]
        or al, [keys + K_A]
        jz .r
        cmp word [px], 4
        jbe .r
        sub word [px], 3
.r:     mov al, [keys + K_RIGHT]
        or al, [keys + K_D]
        jz .f
        cmp word [px], 300
        jae .f
        add word [px], 3
.f:     cmp byte [keys + K_SPACE], 0
        je .x
        cmp byte [bul_on], 0
        jne .x
        mov byte [bul_on], 1
        mov ax, [px]
        add ax, 7
        mov [bul_x], ax
        mov word [bul_y], PLAYER_Y - 5
.x:     ret

; ---------------------------------------------------------------- пуля игрока
do_bullet:
        cmp byte [bul_on], 0
        je .x
        sub word [bul_y], 6
        cmp word [bul_y], 14
        jg .hit
        mov byte [bul_on], 0
        ret
.hit:   xor si, si                      ; индекс захватчика
.l:     cmp byte [alive + si], 0
        je .n
        call inv_pos                    ; → bx=x, dx=y
        mov ax, [bul_x]
        add bx, 2                       ; видимая часть спрайта ≈ x+2 .. x+14
        cmp ax, bx
        jl .n
        add bx, 12
        cmp ax, bx
        jge .n
        mov ax, [bul_y]
        add dx, 8
        cmp ax, dx
        jge .n
        sub dx, 12
        cmp ax, dx
        jl .n
        mov byte [alive + si], 0        ; попадание
        mov byte [bul_on], 0
        dec word [alive_cnt]
        mov ax, si
        mov bl, INV_COLS
        div bl                          ; al = ряд
        mov ah, 5
        sub ah, al
        movzx eax, ah
        imul eax, eax, 10
        add [score], eax
        cmp word [alive_cnt], 0
        jne .x
        inc byte [wave]
        call new_wave
        ret
.n:     inc si
        cmp si, INV_ROWS * INV_COLS
        jb .l
.x:     ret

; si = индекс → bx = x, dx = y  (сохраняет ax, cx)
inv_pos:
        push ax
        push cx
        mov ax, si
        mov cl, INV_COLS
        div cl                          ; al = ряд, ah = столбец
        movzx bx, ah
        imul bx, bx, INV_DX
        add bx, [gx]
        movzx dx, al
        imul dx, dx, INV_DY
        add dx, [gy]
        pop cx
        pop ax
        ret

; ---------------------------------------------------------------- захватчики
do_invaders:
        inc word [step_cnt]
        mov ax, [alive_cnt]             ; задержка шага: чем меньше врагов, тем быстрее
        shr ax, 2
        inc ax
        movzx cx, byte [wave]
        sub ax, cx
        jg .d
        mov ax, 1
.d:     cmp [step_cnt], ax
        jb .x
        mov word [step_cnt], 0
        xor byte [anim], 1
        ; границы: самый левый и самый правый живые столбцы
        mov word [minx], 999
        mov word [maxx], 0
        mov word [maxy], 0
        xor si, si
.l:     cmp byte [alive + si], 0
        je .n
        call inv_pos
        cmp bx, [minx]
        jae .a
        mov [minx], bx
.a:     add bx, 16
        cmp bx, [maxx]
        jbe .b
        mov [maxx], bx
.b:     add dx, 8
        cmp dx, [maxy]
        jbe .n
        mov [maxy], dx
.n:     inc si
        cmp si, INV_ROWS * INV_COLS
        jb .l
        mov ax, [gdir]
        test ax, ax
        js .left
        mov bx, [maxx]
        add bx, ax
        cmp bx, 316
        jbe .move
        jmp .turn
.left:  mov bx, [minx]
        add bx, ax
        cmp bx, 4
        jge .move
.turn:  neg word [gdir]
        add word [gy], 6
        add word [maxy], 6
        jmp .chk
.move:  add [gx], ax
.chk:   cmp word [maxy], PLAYER_Y       ; захватчики дошли до игрока
        jb .x
        mov byte [lives], 1
        mov byte [dead], 1
.x:     ret

; ---------------------------------------------------------------- бомбы
do_bombs:
        ; появление новой бомбы
        call rand
        and ax, 63                      ; вероятность (wave+2)/64 за кадр ≈ 1 бомба/с
        movzx cx, byte [wave]
        add cx, 2
        cmp ax, cx
        jae .move
        xor bx, bx
.free:  cmp byte [bomb_on + bx], 0
        je .spawn
        inc bx
        cmp bx, MAX_BOMBS
        jb .free
        jmp .move
.spawn: call rand
        and ax, INV_COLS - 1            ; случайный столбец
        mov si, (INV_ROWS - 1) * INV_COLS
        add si, ax
.up:    cmp byte [alive + si], 0        ; нижний живой в столбце
        jne .got
        sub si, INV_COLS
        jns .up
        jmp .move
.got:   push bx
        call inv_pos
        mov ax, bx
        pop bx
        add ax, 6
        shl bx, 1
        mov [bomb_x + bx], ax
        add dx, 8
        mov [bomb_y + bx], dx
        shr bx, 1
        mov byte [bomb_on + bx], 1
        ; движение и попадания
.move:  xor bx, bx
.m:     cmp byte [bomb_on + bx], 0
        je .mn
        mov di, bx
        shl di, 1
        add word [bomb_y + di], 3
        cmp word [bomb_y + di], GROUND_Y - 4
        jb .hit
        mov byte [bomb_on + bx], 0
        jmp .mn
.hit:   mov ax, [bomb_x + di]
        mov cx, [px]
        cmp ax, cx
        jl .mn
        add cx, 15
        cmp ax, cx
        jge .mn
        mov ax, [bomb_y + di]
        add ax, 4
        cmp ax, PLAYER_Y
        jl .mn
        mov byte [bomb_on + bx], 0
        mov byte [dead], 1
.mn:    inc bx
        cmp bx, MAX_BOMBS
        jb .m
        ret

player_died:
        dec byte [lives]
        call render
        mov si, spr_boom
        mov bx, [px]
        mov dx, PLAYER_Y
        mov al, 12
        call draw_sprite
        call present
        mov ax, 1
        call delay_sec
        mov byte [dead], 0
        mov byte [bul_on], 0
        mov di, bomb_on
        mov cx, MAX_BOMBS
        xor al, al
        rep stosb
        call resync_time               ; пауза не засчитывается
        ret

game_over:
        mov si, s_g_over
        mov bx, 64
        mov dx, 86
        mov al, 12
        call draw_text_box
        mov si, s_g_reset
        mov bx, 64
        mov dx, 104
        mov al, 15
        call draw_text_box
        call present
        mov si, s_log_over
        call serial_puts
        mov ax, 3
        call delay_sec
        ret

; ---------------------------------------------------------------- титульный экран
title_screen:
        push es
        push word BACKBUF_SEG
        pop es
        call clear_buf
        mov si, s_t1
        mov bx, 104
        mov dx, 20
        mov al, 10
        call draw_text
        mov si, s_t2
        mov bx, 68
        mov dx, 36
        mov al, 15
        call draw_text
        ; «ПРОДЕРЖИТЕСЬ NN СЕКУНД»
        mov si, s_t3
        mov bx, 60
        mov dx, 60
        mov al, 14
        call draw_text
        movzx eax, word [CFG_GAME_SECS]
        call num_to_str                 ; draw_text сдвигает bx — печатаем следом
        mov al, 14
        call draw_text
        mov si, s_t3b
        mov al, 14
        call draw_text
        mov si, s_t4
        mov bx, 56
        mov dx, 84
        mov al, 7
        call draw_text
        mov si, s_t5
        mov bx, 44
        mov dx, 96
        mov al, 7
        call draw_text
        ; витрина захватчиков
        mov si, spr_squid1
        mov bx, 100
        mov dx, 124
        mov al, 13
        call draw_sprite
        mov si, spr_crab1
        mov bx, 152
        mov al, 11
        call draw_sprite
        mov si, spr_octo1
        mov bx, 204
        mov al, 10
        call draw_sprite
        mov si, s_t6
        mov bx, 80
        mov dx, 164
        mov al, 15
        call draw_text
        pop es
        call present
        mov si, s_log_title
        call serial_puts
.w:     cmp byte [keys + K_SPACE], 0    ; ждём SPACE …
        je .w
.r:     cmp byte [keys + K_SPACE], 0    ; … и отпускание
        jne .r
        mov si, s_log_start
        call serial_puts
        ret

; ---------------------------------------------------------------- отрисовка кадра
render:
        pusha
        push es
        push word BACKBUF_SEG
        pop es
        call clear_buf
        ; HUD
        mov si, s_h_time
        mov bx, 4
        mov dx, 2
        mov al, 15
        call draw_text
        mov eax, [need_ticks]           ; оставшиеся секунды (вверх)
        sub eax, [elapsed]
        jae .pos
        xor eax, eax
.pos:   imul eax, eax, 1000
        add eax, 18206
        xor edx, edx
        mov ecx, 18207
        div ecx                         ; div портит edx → восстанавливаем y
        call num_to_str
        mov dx, 2
        mov bx, 44
        mov al, 14
        call draw_text
        mov si, s_h_score
        mov bx, 112
        mov al, 15
        call draw_text
        mov eax, [score]
        call num_to_str
        mov bx, 160
        mov al, 14
        call draw_text
        mov si, s_h_lives
        mov bx, 236
        mov al, 15
        call draw_text
        movzx eax, byte [lives]
        call num_to_str
        mov bx, 284
        mov al, 14
        call draw_text
        ; полоса прогресса
        mov eax, [elapsed]
        imul eax, eax, 312
        xor edx, edx
        div dword [need_ticks]
        cmp eax, 312
        jbe .bar
        mov eax, 312
.bar:   mov cx, ax
        mov bx, 4
        mov dx, 12
        mov al, 9
        mov bp, 2
        call fill_rect
        ; захватчики
        xor si, si
.inv:   cmp byte [alive + si], 0
        je .in
        push si
        call inv_pos
        mov ax, si
        mov cl, INV_COLS
        div cl                          ; al = ряд
        mov di, spr_squid1
        mov cl, 13
        cmp al, 0
        je .sel
        mov di, spr_crab1
        mov cl, 11
        cmp al, 2
        jbe .sel
        mov di, spr_octo1
        mov cl, 10
.sel:   cmp byte [anim], 0
        je .dr
        add di, 16                      ; второй кадр анимации идёт следом
.dr:    mov si, di
        mov al, cl
        call draw_sprite
        pop si
.in:    inc si
        cmp si, INV_ROWS * INV_COLS
        jb .inv
        ; игрок
        mov si, spr_player
        mov bx, [px]
        mov dx, PLAYER_Y
        mov al, 14
        call draw_sprite
        ; пуля
        cmp byte [bul_on], 0
        je .nb
        mov bx, [bul_x]
        mov dx, [bul_y]
        mov cx, 1
        mov bp, 5
        mov al, 15
        call fill_rect
.nb:    ; бомбы
        xor si, si
.bm:    cmp byte [bomb_on + si], 0
        je .bn
        mov di, si
        shl di, 1
        mov bx, [bomb_x + di]
        mov dx, [bomb_y + di]
        mov cx, 2
        mov bp, 4
        mov al, 12
        call fill_rect
.bn:    inc si
        cmp si, MAX_BOMBS
        jb .bm
        ; земля
        xor bx, bx
        mov dx, GROUND_Y
        mov cx, 320
        mov bp, 1
        mov al, 2
        call fill_rect
        pop es
        popa
        ret

; ---------------------------------------------------------------- графические примитивы
; es = сегмент буфера
clear_buf:
        pusha
        xor di, di
        xor eax, eax
        mov cx, 16000
        rep stosd
        popa
        ret

present:                                ; задний буфер → видеопамять A000
        pusha
        push ds
        push es
        push word 0xA000
        pop es
        push word BACKBUF_SEG
        pop ds
        xor si, si
        xor di, di
        mov cx, 16000
        rep movsd
        pop es
        pop ds
        popa
        ret

; bx=x dx=y → di = y*320+x
_pix_off:
        push dx
        mov di, dx
        shl di, 8
        shl dx, 6
        add di, dx
        add di, bx
        pop dx
        ret

; si=спрайт (8 слов, старший бит — левый пиксель) bx=x dx=y al=цвет; es=буфер
draw_sprite:
        pusha
        call _pix_off
        mov bp, 8
.row:   mov cx, [si]
        add si, 2
        push di
        mov dl, 16
.bit:   shl cx, 1
        jnc .s
        mov [es:di], al
.s:     inc di
        dec dl
        jnz .bit
        pop di
        add di, 320
        dec bp
        jnz .row
        popa
        ret

; bx=x dx=y cx=ширина bp=высота al=цвет
fill_rect:
        pusha
        call _pix_off
.r:     push di
        push cx
        rep stosb
        pop cx
        pop di
        add di, 320
        dec bp
        jnz .r
        popa
        ret

; символ 8×8 из шрифта BIOS. ah=символ bx=x dx=y al=цвет. bx += 8
draw_char:
        push si
        push di
        push cx
        push bp
        push gs
        call _pix_off
        mov gs, [font_seg]
        movzx si, ah
        shl si, 3
        add si, [font_off]
        mov bp, 8
.row:   mov cl, [gs:si]
        inc si
        push di
        mov ch, 8
.bit:   shl cl, 1
        jnc .s
        mov [es:di], al
.s:     inc di
        dec ch
        jnz .bit
        pop di
        add di, 320
        dec bp
        jnz .row
        add bx, 8
        pop gs
        pop bp
        pop cx
        pop di
        pop si
        ret

; si=ASCIIZ bx=x dx=y al=цвет  (bx сдвигается за текст)
draw_text:
        push si
        push ax
.l:     mov ah, [si]
        test ah, ah
        jz .d
        call draw_char
        inc si
        jmp .l
.d:     pop ax
        pop si
        ret

; текст на чёрной плашке поверх кадра (в задний буфер)
draw_text_box:
        pusha
        push es
        push word BACKBUF_SEG
        pop es
        push ax
        push si
        xor cx, cx                      ; длина строки
.len:   cmp byte [si], 0
        je .lg
        inc si
        inc cx
        jmp .len
.lg:    pop si
        shl cx, 3
        add cx, 8
        sub bx, 4
        sub dx, 4
        mov bp, 16
        xor al, al
        call fill_rect
        add bx, 4
        add dx, 4
        pop ax
        call draw_text
        pop es
        popa
        ret

; ---------------------------------------------------------------- клавиатура (IRQ1)
kb_hook:
        pusha
        push es
        mov di, keys
        mov cx, 128
        xor al, al
        rep stosb
        cli
        push word 0
        pop es
        mov eax, [es:9 * 4]
        mov [old_int9], eax
        mov word [es:9 * 4], kb_isr
        mov [es:9 * 4 + 2], cs
        sti
        pop es
        popa
        ret

kb_unhook:
        pusha
        push es
        cli
        push word 0
        pop es
        mov eax, [old_int9]
        mov [es:9 * 4], eax
        sti
        pop es
        popa
        ret

kb_isr:
        push ax
        push bx
        push ds
        push cs
        pop ds
        in al, 0x60
        cmp al, 0xE0                    ; префикс расширенных клавиш — пропускаем
        je .eoi
        movzx bx, al
        and bl, 0x7F
        test al, 0x80
        setz al                         ; 1 = нажата, 0 = отпущена
        mov [keys + bx], al
.eoi:   mov al, 0x20
        out 0x20, al
        pop ds
        pop bx
        pop ax
        iret
