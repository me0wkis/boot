; Формат сектора конфигурации (LBA 1). Должен совпадать с tools/bootcfg.py
CFG_MAGIC       equ 0           ; 'BLCF'
CFG_VERSION     equ 4           ; word
CFG_S2_SECTORS  equ 6           ; word  — размер stage2 в секторах
CFG_GAME_SECS   equ 8           ; word  — сколько секунд играть (0 = без игры)
CFG_FLAGS       equ 10          ; word  — бит0: пароль включён, бит1: отладка в COM1
CFG_ITERATIONS  equ 12          ; dword — число итераций SHA-256
CFG_SALT        equ 16          ; 16 байт
CFG_HASH        equ 32          ; 32 байта
CFG_NAMES       equ 64          ; 4 × 24 байта, ASCIIZ
CFG_NAME_LEN    equ 24
CFG_HIDDEN      equ 160         ; byte, битовая маска скрытых разделов
CFG_DEFAULT     equ 161         ; byte, 0..3 или 0xFF = активный раздел
CFG_ATTEMPTS    equ 162         ; byte, число попыток ввода пароля

FLAG_PASSWORD   equ 1
FLAG_DEBUG      equ 2

STAGE_SEG       equ 0x1000      ; сюда загружаются конфиг (0), бэкап MBR (0x200), stage2 (0x400)
STAGE2_OFF      equ 0x0400
BACKBUF_SEG     equ 0x2000      ; задний буфер кадра 320×200
MBR_COPY        equ 0x0600      ; stage1 перемещает MBR сюда
PART_TABLE      equ 0x07BE
