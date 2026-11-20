"""bootcfg — программа установки и настройки загрузчика BootLock.

  install   DISK    установить загрузчик (с сохранением таблицы разделов)
  passwd    DISK    задать / сменить / отключить пароль
  set       DISK    длительность игры, имена ОС, скрытые разделы, раздел по умолчанию
  show      DISK    показать настройки и разделы
  verify    DISK    проверить пароль офлайн
  uninstall DISK    вернуть исходный MBR
  mkdemo    DISK    создать демонстрационный диск с несколькими «ОС»

DISK — файл образа (.img, .vhd fixed/dynamic) или блочное устройство (/dev/sdX).
"""
import argparse
import getpass
import hashlib
import os
import struct
import subprocess
import sys

from . import vhd
from .blockdev import BlockDevice, DiskImageError

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")

# --- формат конфига (см. src/config.inc) ---
MAGIC = b"BLCF"
VERSION = 1
FLAG_PASSWORD, FLAG_DEBUG = 1, 2
NAME_LEN = 24
CFG_LBA, BACKUP_LBA, STAGE2_LBA = 1, 2, 3

PTYPES = {0x01: "FAT12", 0x04: "FAT16", 0x06: "FAT16", 0x0E: "FAT16 LBA", 0x0B: "FAT32",
          0x0C: "FAT32 LBA", 0x07: "NTFS", 0x17: "NTFS (hidden)", 0x27: "Windows RE",
          0x83: "Linux", 0x82: "Linux swap", 0x8E: "Linux LVM", 0x05: "Extended",
          0x0F: "Extended LBA", 0xEE: "GPT protective", 0xEF: "EFI", 0xA5: "FreeBSD"}


class BootCfgError(DiskImageError):
    pass


# ============================================================ устройство
class RawDevice(BlockDevice):
    """Файл образа или блочное устройство (размер берётся через seek)."""

    def __init__(self, path, writable):
        self.path, self.writable = path, writable
        self.f = open(path, "r+b" if writable else "rb")
        self.f.seek(0, 2)
        self.size = self.f.tell()

    def read(self, off, n):
        self.f.seek(off)
        d = self.f.read(n)
        return d + bytes(n - len(d))

    def write(self, off, data):
        self.f.seek(off)
        self.f.write(data)

    def flush(self):
        if self.writable:
            self.f.flush()
            os.fsync(self.f.fileno())

    def close(self):
        if not self.f.closed:
            self.flush()
            self.f.close()


def open_disk(path, writable=False):
    if not os.path.exists(path):
        raise BootCfgError(f"не найден: {path}")
    if os.path.isfile(path) and vhd.is_vhd(path):
        return vhd.VhdDevice(path, writable)
    return RawDevice(path, writable)


def sector(dev, lba, n=1):
    return dev.read(lba * 512, n * 512)


def wsector(dev, lba, data):
    assert len(data) % 512 == 0
    dev.write(lba * 512, data)


# ============================================================ бинарники
def binaries():
    need = [os.path.join(BUILD, n) for n in ("stage1.bin", "stage2.bin", "demo_os.bin")]
    if not all(os.path.exists(p) for p in need):
        r = subprocess.run(["make", "-C", ROOT], capture_output=True, text=True)
        if r.returncode:
            raise BootCfgError("не удалось собрать загрузчик (нужен nasm):\n" + r.stdout + r.stderr)
    s1, s2, demo = (open(p, "rb").read() for p in need)
    if len(s1) != 440:
        raise BootCfgError("stage1.bin должен быть ровно 440 байт")
    s2 += bytes((-len(s2)) % 512)
    return s1, s2, demo


# ============================================================ конфиг
class Config:
    def __init__(self):
        self.s2_sectors = 0
        self.game_secs = 60
        self.flags = 0
        self.iterations = 5000
        self.salt = bytes(16)
        self.hash = bytes(32)
        self.names = [""] * 4
        self.hidden = 0
        self.default = 0xFF
        self.attempts = 3

    @classmethod
    def parse(cls, raw):
        if raw[:4] != MAGIC:
            return None
        c = cls()
        (_, c.s2_sectors, c.game_secs, c.flags, c.iterations) = struct.unpack("<HHHHI", raw[4:16])
        c.salt, c.hash = raw[16:32], raw[32:64]
        c.names = [raw[64 + i * NAME_LEN:64 + (i + 1) * NAME_LEN].split(b"\0")[0].decode("ascii", "replace")
                   for i in range(4)]
        c.hidden, c.default, c.attempts = raw[160], raw[161], raw[162]
        return c

    def pack(self):
        b = bytearray(512)
        b[:4] = MAGIC
        struct.pack_into("<HHHHI", b, 4, VERSION, self.s2_sectors, self.game_secs,
                         self.flags, self.iterations)
        b[16:32], b[32:64] = self.salt, self.hash
        for i, n in enumerate(self.names):
            e = n.encode("ascii")[:NAME_LEN - 1]
            b[64 + i * NAME_LEN:64 + i * NAME_LEN + len(e)] = e
        b[160], b[161], b[162] = self.hidden, self.default, self.attempts
        return bytes(b)

    def set_password(self, pw):
        check_password_text(pw)
        self.salt = os.urandom(16)
        self.hash = kdf(pw.encode("ascii"), self.salt, self.iterations)
        self.flags |= FLAG_PASSWORD


def kdf(pw: bytes, salt: bytes, iterations: int) -> bytes:
    """То же, что check_password в sha256.asm."""
    h = hashlib.sha256(salt + pw).digest()
    for _ in range(iterations - 1):
        h = hashlib.sha256(h + salt).digest()
    return h


def check_password_text(pw):
    if not 1 <= len(pw) <= 32:
        raise BootCfgError("пароль: от 1 до 32 символов")
    if not all(32 <= ord(c) <= 126 for c in pw):
        raise BootCfgError("пароль: только печатные ASCII-символы (BIOS вводит в US-раскладке)")


def ask_password(args):
    if getattr(args, "password", None):
        return args.password
    if getattr(args, "password_stdin", False):
        return sys.stdin.readline().rstrip("\n")
    p1 = getpass.getpass("Новый пароль загрузчика: ")
    p2 = getpass.getpass("Повторите пароль: ")
    if p1 != p2:
        raise BootCfgError("пароли не совпадают")
    return p1


# ============================================================ MBR
def partitions(mbr):
    out = []
    for i in range(4):
        e = mbr[446 + 16 * i:462 + 16 * i]
        flag, ptype = e[0], e[4]
        start, cnt = struct.unpack("<II", e[8:16])
        if ptype:
            out.append((i, flag, ptype, start, cnt))
    return out


def load_config(dev):
    cfg = Config.parse(sector(dev, CFG_LBA))
    if not cfg:
        raise BootCfgError("BootLock не установлен на этом диске (нет конфига на LBA 1)")
    return cfg


def save_config(dev, cfg):
    wsector(dev, CFG_LBA, cfg.pack())


# ============================================================ команды
def cmd_install(a):
    s1, s2, _ = binaries()
    dev = open_disk(a.disk, True)
    try:
        mbr = bytearray(sector(dev, 0))
        if mbr[510:512] != b"\x55\xAA":
            if any(mbr) and not a.force:
                raise BootCfgError("в LBA 0 нет MBR (55AA). Это не MBR-диск? --force — перезаписать")
            mbr = bytearray(512)
            mbr[440:444] = os.urandom(4)
            mbr[510:512] = b"\x55\xAA"
        parts = partitions(mbr)
        if any(p[2] == 0xEE for p in parts):
            raise BootCfgError("диск размечен GPT — BootLock работает с MBR/BIOS (Legacy) загрузкой")
        s2_secs = len(s2) // 512
        last = STAGE2_LBA + s2_secs - 1
        for i, _, _, start, _ in parts:
            if start <= last:
                raise BootCfgError(f"раздел #{i + 1} начинается с LBA {start}, а загрузчику нужны "
                                   f"секторы 1..{last}. Нужен зазор перед первым разделом.")
        old = Config.parse(sector(dev, CFG_LBA))
        if not old:
            gap = sector(dev, 1, last)
            if any(gap) and not a.force:
                raise BootCfgError(f"секторы 1..{last} не пусты (там другой загрузчик, напр. GRUB?). "
                                   "--force — перезаписать")
            backup = bytes(mbr)
        else:
            backup = sector(dev, BACKUP_LBA)       # переустановка: сохраняем самый первый бэкап
        cfg = old or Config()
        cfg.s2_sectors = s2_secs
        if a.game_seconds is not None:
            cfg.game_secs = a.game_seconds
        if a.iterations:
            cfg.iterations = a.iterations
        if not a.no_password and not (old and old.flags & FLAG_PASSWORD and not a.password):
            cfg.set_password(ask_password(a))
        elif a.no_password:
            cfg.flags &= ~FLAG_PASSWORD
        wsector(dev, BACKUP_LBA, backup)
        wsector(dev, STAGE2_LBA, s2)
        save_config(dev, cfg)
        mbr[:440] = s1
        wsector(dev, 0, bytes(mbr))
        print(f"BootLock установлен: MBR + {s2_secs} секторов stage2 (LBA {STAGE2_LBA}..{last}).")
        print(f"Игра: {cfg.game_secs} с; пароль: {'включён' if cfg.flags & 1 else 'выключен'}; "
              f"итераций SHA-256: {cfg.iterations}")
    finally:
        dev.close()


def cmd_passwd(a):
    dev = open_disk(a.disk, True)
    try:
        cfg = load_config(dev)
        if a.disable:
            cfg.flags &= ~FLAG_PASSWORD
            cfg.hash = bytes(32)
            print("Пароль отключён.")
        else:
            if a.iterations:
                cfg.iterations = a.iterations
            cfg.set_password(ask_password(a))
            print(f"Пароль установлен (соль 16 байт, SHA-256 × {cfg.iterations}).")
        save_config(dev, cfg)
    finally:
        dev.close()


def cmd_verify(a):
    dev = open_disk(a.disk)
    try:
        cfg = load_config(dev)
        pw = a.password or getpass.getpass("Пароль: ")
        ok = kdf(pw.encode("ascii", "replace"), cfg.salt, cfg.iterations) == cfg.hash
        print("Пароль верный" if ok else "Пароль НЕ верный")
        return 0 if ok else 2
    finally:
        dev.close()


def cmd_set(a):
    dev = open_disk(a.disk, True)
    try:
        cfg = load_config(dev)
        if a.game_seconds is not None:
            if not 0 <= a.game_seconds <= 3600:
                raise BootCfgError("время игры 0..3600 с")
            cfg.game_secs = a.game_seconds
        for item in a.name or []:
            n, _, name = item.partition("=")
            idx = int(n) - 1
            if not 0 <= idx < 4:
                raise BootCfgError("номер раздела 1..4")
            if not all(32 <= ord(c) < 127 for c in name):
                raise BootCfgError("имя ОС — только латиница/ASCII (шрифт BIOS)")
            cfg.names[idx] = name[:NAME_LEN - 1]
        for n in a.hide or []:
            cfg.hidden |= 1 << (n - 1)
        for n in a.unhide or []:
            cfg.hidden &= ~(1 << (n - 1))
        if a.default:
            cfg.default = 0xFF if a.default == "active" else int(a.default) - 1
        if a.attempts:
            cfg.attempts = max(1, min(a.attempts, 9))
        if a.debug:
            cfg.flags = cfg.flags | FLAG_DEBUG if a.debug == "on" else cfg.flags & ~FLAG_DEBUG
        save_config(dev, cfg)
        print("Настройки сохранены.")
    finally:
        dev.close()


def cmd_show(a):
    dev = open_disk(a.disk)
    try:
        mbr = sector(dev, 0)
        cfg = Config.parse(sector(dev, CFG_LBA))
        print(f"Диск: {a.disk}, {dev.size // 1048576} МиБ"
              + (f", VHD {dev.type_name}" if isinstance(dev, vhd.VhdDevice) else ""))
        if not cfg:
            print("BootLock: не установлен")
        else:
            print(f"BootLock: установлен, stage2 = {cfg.s2_sectors} секторов")
            print(f"  Игра Space Invaders : {cfg.game_secs} с" if cfg.game_secs else
                  "  Игра Space Invaders : выключена")
            print(f"  Пароль              : {'включён' if cfg.flags & 1 else 'выключен'}"
                  f" (SHA-256 × {cfg.iterations}, попыток {cfg.attempts})")
            print(f"  По умолчанию        : "
                  f"{'активный раздел' if cfg.default == 0xFF else f'раздел {cfg.default + 1}'}")
            if cfg.flags & FLAG_DEBUG:
                print("  Отладка (хеш в COM1): включена")
        print("\n  #  Акт  Тип                 Начало LBA   Размер     Имя в меню")
        for i, flag, ptype, start, cnt in partitions(mbr):
            name = (cfg.names[i] if cfg else "") or "-"
            hidden = cfg and cfg.hidden & (1 << i)
            print(f"  {i + 1}  {'*' if flag == 0x80 else ' '}    0x{ptype:02X} {PTYPES.get(ptype, '?'):14} "
                  f"{start:>10}   {cnt // 2048:>6} МиБ  {name}{' (скрыт)' if hidden else ''}")
    finally:
        dev.close()


def cmd_uninstall(a):
    dev = open_disk(a.disk, True)
    try:
        cfg = load_config(dev)
        backup = sector(dev, BACKUP_LBA)
        mbr = bytearray(sector(dev, 0))
        mbr[:440] = backup[:440]                 # таблицу разделов оставляем текущей
        wsector(dev, 0, bytes(mbr))
        wsector(dev, 1, bytes(512 * (2 + cfg.s2_sectors)))
        print("BootLock удалён, исходный код MBR восстановлен.")
    finally:
        dev.close()


def cmd_mkdemo(a):
    """Диск с тремя «ОС» и одним разделом без загрузочного сектора."""
    _, _, demo = binaries()
    size = parse_size(a.size)
    if os.path.exists(a.disk):
        raise BootCfgError(f"файл уже существует: {a.disk}")
    if a.disk.lower().endswith(".vhd"):
        size = vhd.create_vhd(a.disk, size, dynamic=True)
    else:
        with open(a.disk, "wb") as f:
            f.truncate(size)
    dev = open_disk(a.disk, True)
    try:
        total = dev.size // 512
        layout = [(0x07, "Windows 10 (demo)", True), (0x83, "Ubuntu 24.04 (demo)", True),
                  (0x0C, "FreeDOS (demo)", True), (0x0E, "Data (no OS)", False)]
        part_len = (total - 2048) // 4 // 2048 * 2048
        mbr = bytearray(512)
        mbr[440:444] = os.urandom(4)
        for i, (ptype, name, bootable) in enumerate(layout):
            start = 2048 + i * part_len
            mbr[446 + 16 * i:462 + 16 * i] = bytes([0x80 if i == 0 else 0, 0xFE, 0xFF, 0xFF, ptype,
                                                    0xFE, 0xFF, 0xFF]) + struct.pack("<II", start, part_len)
            if bootable:
                vbr = bytearray(demo)
                vbr[0x180:0x180 + len(name)] = name.encode()
                wsector(dev, start, bytes(vbr))
        mbr[510:512] = b"\x55\xAA"
        wsector(dev, 0, bytes(mbr))
    finally:
        dev.close()
    print(f"Создан демо-диск {a.disk}: 4 раздела (3 демо-ОС + раздел данных без ОС).")


def parse_size(s):
    s = s.upper().rstrip("B").rstrip("I")
    mult = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}.get(s[-1:], 1)
    return int(float(s.rstrip("KMG")) * mult)


def build_parser():
    p = argparse.ArgumentParser(prog="bootcfg", description="Настройка загрузчика BootLock")
    sub = p.add_subparsers(dest="cmd", required=True)

    def c(name, help_, func):
        s = sub.add_parser(name, help=help_)
        s.add_argument("disk", help="образ диска или устройство")
        s.set_defaults(func=func)
        return s

    def pw_opts(s):
        s.add_argument("--password", help="пароль в командной строке (небезопасно, для скриптов)")
        s.add_argument("--password-stdin", action="store_true", help="прочитать пароль из stdin")
        s.add_argument("--iterations", type=int, help="итераций SHA-256 (по умолчанию 5000)")

    s = c("install", "установить загрузчик", cmd_install)
    pw_opts(s)
    s.add_argument("--no-password", action="store_true", help="без пароля")
    s.add_argument("--game-seconds", type=int, help="длительность игры (по умолчанию 60)")
    s.add_argument("--force", action="store_true", help="перезаписать непустой зазор/не-MBR")
    s = c("passwd", "задать/сменить пароль", cmd_passwd)
    pw_opts(s)
    s.add_argument("--disable", action="store_true", help="отключить пароль")
    s = c("verify", "проверить пароль", cmd_verify)
    s.add_argument("--password")
    s = c("set", "настройки", cmd_set)
    s.add_argument("--game-seconds", type=int)
    s.add_argument("--name", action="append", metavar="N=ИМЯ", help="имя ОС в меню, напр. 1='Windows 10'")
    s.add_argument("--hide", type=int, action="append", metavar="N", help="скрыть раздел из меню")
    s.add_argument("--unhide", type=int, action="append", metavar="N")
    s.add_argument("--default", help="раздел по умолчанию: 1..4 или active")
    s.add_argument("--attempts", type=int, help="попыток ввода пароля (1..9)")
    s.add_argument("--debug", choices=["on", "off"], help="вывод хеша пароля в COM1")
    c("show", "показать настройки", cmd_show)
    c("uninstall", "удалить загрузчик", cmd_uninstall)
    s = c("mkdemo", "создать демонстрационный диск", cmd_mkdemo)
    s.add_argument("--size", default="64M")
    return p


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        return a.func(a) or 0
    except (DiskImageError, OSError) as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
