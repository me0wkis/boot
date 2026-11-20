; ============================================================================
;  SHA-256 (FIPS 180-4) для реального режима на 386+ (32-битные регистры).
;  Обрабатывается одно сообщение длиной ≤ 55 байт (один блок 512 бит) —
;  этого достаточно для соль(16)+пароль(≤32) и хеш(32)+соль(16).
;  Вход:  si = сообщение, cx = длина.   Выход: sha_out (32 байта, big-endian).
; ============================================================================

%macro BSWAP_EAX 0                      ; bswap есть только с 486 — эмулируем
        xchg al, ah
        rol eax, 16
        xchg al, ah
%endmacro

sha256:
        pushad
        push es
        push ds
        pop es
        cld
        ; --- формирование блока: сообщение | 0x80 | нули | длина в битах ---
        mov bx, cx
        mov di, sha_block
        rep movsb
        mov al, 0x80
        stosb
        mov cx, sha_block + 64
        sub cx, di
        xor al, al
        rep stosb
        mov ax, bx
        shl ax, 3
        xchg al, ah
        mov [sha_block + 62], ax
        ; --- W[0..15] ---
        xor bx, bx
.w1:    mov eax, [sha_block + bx]
        BSWAP_EAX
        mov [sha_w + bx], eax
        add bx, 4
        cmp bx, 64
        jb .w1
        ; --- W[16..63] ---
.w2:    mov eax, [sha_w + bx - 60]      ; W[i-15]
        mov edx, eax
        ror edx, 7
        mov ecx, eax
        ror ecx, 18
        xor edx, ecx
        shr eax, 3
        xor edx, eax                    ; σ0
        mov eax, [sha_w + bx - 8]       ; W[i-2]
        mov ecx, eax
        ror ecx, 17
        mov edi, eax
        ror edi, 19
        xor ecx, edi
        shr eax, 10
        xor ecx, eax                    ; σ1
        add edx, ecx
        add edx, [sha_w + bx - 64]      ; W[i-16]
        add edx, [sha_w + bx - 28]      ; W[i-7]
        mov [sha_w + bx], edx
        add bx, 4
        cmp bx, 256
        jb .w2
        ; --- состояние a..h = IV ---
        mov si, sha_iv
        mov di, sha_st
        mov cx, 8
        rep movsd
        ; --- 64 раунда ---
        xor bx, bx
.r:     mov eax, [sha_st + 16]          ; e
        mov edx, eax
        ror edx, 6
        mov ecx, eax
        ror ecx, 11
        xor edx, ecx
        ror ecx, 14                     ; 11+14 = 25
        xor edx, ecx                    ; Σ1
        mov ecx, eax
        and ecx, [sha_st + 20]          ; e & f
        not eax
        and eax, [sha_st + 24]          ; ~e & g
        xor ecx, eax                    ; Ch
        add edx, ecx
        add edx, [sha_st + 28]          ; + h
        add edx, [sha_k + bx]
        add edx, [sha_w + bx]           ; edx = T1
        mov eax, [sha_st + 0]           ; a
        mov ecx, eax
        ror ecx, 2
        mov edi, eax
        ror edi, 13
        xor ecx, edi
        ror edi, 9                      ; 13+9 = 22
        xor ecx, edi                    ; Σ0
        mov edi, [sha_st + 4]           ; b
        mov esi, edi
        or edi, [sha_st + 8]            ; b | c
        and edi, eax                    ; a & (b|c)
        and esi, [sha_st + 8]           ; b & c
        or edi, esi                     ; Maj
        add ecx, edi                    ; ecx = T2
        mov eax, [sha_st + 24]
        mov [sha_st + 28], eax          ; h = g
        mov eax, [sha_st + 20]
        mov [sha_st + 24], eax          ; g = f
        mov eax, [sha_st + 16]
        mov [sha_st + 20], eax          ; f = e
        mov eax, [sha_st + 12]
        add eax, edx
        mov [sha_st + 16], eax          ; e = d + T1
        mov eax, [sha_st + 8]
        mov [sha_st + 12], eax          ; d = c
        mov eax, [sha_st + 4]
        mov [sha_st + 8], eax           ; c = b
        mov eax, [sha_st + 0]
        mov [sha_st + 4], eax           ; b = a
        add edx, ecx
        mov [sha_st + 0], edx           ; a = T1 + T2
        add bx, 4
        cmp bx, 256
        jb .r
        ; --- результат = IV + состояние, big-endian ---
        xor bx, bx
.o:     mov eax, [sha_st + bx]
        add eax, [sha_iv + bx]
        BSWAP_EAX
        mov [sha_out + bx], eax
        add bx, 4
        cmp bx, 32
        jb .o
        pop es
        popad
        ret

; ----------------------------------------------------------------------------
;  Проверка пароля. pw_buf/cx = введённый пароль.
;  h = SHA256(salt || pw);  повторить (iter-1) раз: h = SHA256(h || salt)
;  Возврат: ZF=1 — пароль верный. Сравнение без раннего выхода.
; ----------------------------------------------------------------------------
check_password:
        pushad
        push es
        push ds
        pop es
        cld
        mov bx, cx
        mov si, CFG_SALT
        mov di, sha_msg
        mov cx, 16
        rep movsb
        mov si, pw_buf
        mov cx, bx
        rep movsb
        mov si, sha_msg
        lea cx, [bx + 16]
        call sha256
        mov ecx, [CFG_ITERATIONS]
        dec ecx
        jz .cmp
.it:    push ecx
        mov si, sha_out
        mov di, sha_msg
        mov cx, 8
        rep movsd
        mov si, CFG_SALT
        mov cx, 4
        rep movsd
        mov si, sha_msg
        mov cx, 48
        call sha256
        pop ecx
        dec ecx
        jnz .it
.cmp:   test word [CFG_FLAGS], FLAG_DEBUG
        jz .nodbg
        mov si, sha_out                 ; отладка: вывести хеш в COM1
        mov cx, 32
.hx:    lodsb
        call serial_hex8
        loop .hx
        mov si, s_empty
        call serial_puts
.nodbg: xor al, al
        mov si, sha_out
        mov di, CFG_HASH
        mov cx, 32
.c:     mov ah, [si]
        xor ah, [di]
        or al, ah
        inc si
        inc di
        loop .c
        ; затираем следы
        mov di, sha_msg
        mov cx, 64
        mov ah, al
        xor al, al
        rep stosb
        mov al, ah
        test al, al                     ; ZF=1 ⇔ все байты совпали
        pop es
        popad
        ret
