"""Формат Microsoft Virtual Hard Disk (VHD), спецификация 1.0.

Поддерживаются fixed и dynamic (sparse) диски: чтение, запись, создание.
Differencing-диски (с родителем) открываются только на чтение без родителя
не имеют смысла — выдаётся ошибка.

Структура fixed VHD:   [данные диска][footer 512 байт]
Структура dynamic VHD: [копия footer][dynamic header 1024][BAT]
                       [блок: битмап секторов + данные]...[footer]
"""
import os
import struct
import time
import uuid

from .blockdev import BlockDevice, DiskImageError

FOOTER_FMT = ">8sIIQI4sI4sQQIII16sB427s"  # 512 байт
DYN_FMT = ">8sQQIIII16sI4s512s192s256s"   # 1024 байт
VHD_EPOCH = 946684800                    # 2000-01-01 00:00:00 UTC
TYPE_FIXED, TYPE_DYNAMIC, TYPE_DIFF = 2, 3, 4
UNUSED = 0xFFFFFFFF
assert struct.calcsize(FOOTER_FMT) == 512 and struct.calcsize(DYN_FMT) == 1024


def _checksum(buf: bytes, csum_off: int) -> int:
    b = bytearray(buf)
    b[csum_off:csum_off + 4] = b"\0\0\0\0"
    return (~sum(b)) & 0xFFFFFFFF


def chs_geometry(total_sectors: int):
    """Расчёт CHS по алгоритму из приложения спецификации VHD."""
    total_sectors = min(total_sectors, 65535 * 16 * 255)
    if total_sectors >= 65535 * 16 * 63:
        spt, heads = 255, 16
        cth = total_sectors // spt
    else:
        spt = 17
        cth = total_sectors // spt
        heads = max((cth + 1023) // 1024, 4)
        if cth >= heads * 1024 or heads > 16:
            spt, heads = 31, 16
            cth = total_sectors // spt
        if cth >= heads * 1024:
            spt, heads = 63, 16
            cth = total_sectors // spt
    return cth // heads, heads, spt


class Footer:
    def __init__(self, raw: bytes):
        (self.cookie, self.features, self.version, self.data_offset, self.timestamp,
         self.creator_app, self.creator_ver, self.creator_os, self.orig_size,
         self.cur_size, self.geometry, self.disk_type, self.checksum, self.uid,
         self.saved, _) = struct.unpack(FOOTER_FMT, raw)
        self.valid_checksum = _checksum(raw, 64) == self.checksum

    @staticmethod
    def build(size, disk_type, data_offset):
        c, h, s = chs_geometry(size // 512)
        geom = (c << 16) | (h << 8) | s
        raw = struct.pack(FOOTER_FMT, b"conectix", 2, 0x00010000, data_offset,
                          (int(time.time()) - VHD_EPOCH) & 0xFFFFFFFF, b"dimg",
                          0x00010000, b"Wi2k", size, size, geom, disk_type, 0,
                          uuid.uuid4().bytes, 0, bytes(427))
        cs = _checksum(raw, 64)
        return raw[:64] + struct.pack(">I", cs) + raw[68:]

    @property
    def chs(self):
        return self.geometry >> 16, (self.geometry >> 8) & 0xFF, self.geometry & 0xFF


def is_vhd(path) -> bool:
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as f:
            if sz >= 512:
                f.seek(sz - 512)
                if f.read(8) == b"conectix":
                    return True
            f.seek(0)
            return f.read(8) == b"conectix"
    except OSError:
        return False


def vhd_size_for(requested: int) -> int:
    """Размер диска, точно выражаемый геометрией CHS (так его увидят
    и Windows, и qemu, независимо от того, чему они доверяют)."""
    c, h, s = chs_geometry(requested // 512)
    return c * h * s * 512


class VhdDevice(BlockDevice):
    def __init__(self, path, writable=False):
        self.path, self.writable = path, writable
        self.f = open(path, "r+b" if writable else "rb")
        fsize = os.path.getsize(path)
        self.f.seek(fsize - 512)
        raw = self.f.read(512)
        if raw[:8] != b"conectix":       # повреждённый хвост — берём копию в начале
            self.f.seek(0)
            raw = self.f.read(512)
            if raw[:8] != b"conectix":
                raise DiskImageError("не найден footer VHD")
        self.footer = Footer(raw)
        self.footer_raw = raw
        self.size = self.footer.cur_size
        self.type = self.footer.disk_type
        if self.type == TYPE_FIXED:
            return
        if self.type == TYPE_DIFF:
            raise DiskImageError("differencing VHD не поддерживается (нужен родительский диск)")
        if self.type != TYPE_DYNAMIC:
            raise DiskImageError(f"неизвестный тип VHD: {self.type}")
        self.f.seek(self.footer.data_offset)
        hdr = self.f.read(1024)
        (cookie, _, self.bat_off, _, self.max_entries, self.block_size, _cs,
         *_rest) = struct.unpack(DYN_FMT, hdr)
        if cookie != b"cxsparse":
            raise DiskImageError("повреждён dynamic header VHD")
        self.f.seek(self.bat_off)
        self.bat = list(struct.unpack(f">{self.max_entries}I",
                                      self.f.read(4 * self.max_entries)))
        self.bitmap_size = ((self.block_size // 512 // 8) + 511) // 512 * 512
        self.bat_dirty = False

    @property
    def type_name(self):
        return {TYPE_FIXED: "fixed", TYPE_DYNAMIC: "dynamic"}.get(self.type, "?")

    # ----- чтение/запись -----
    def read(self, offset, n):
        self._check(offset, n)
        if self.type == TYPE_FIXED:
            self.f.seek(offset)
            return self.f.read(n)
        out = bytearray()
        while n > 0:
            blk, inb = divmod(offset, self.block_size)
            k = min(n, self.block_size - inb)
            entry = self.bat[blk]
            if entry == UNUSED:
                out += bytes(k)
            else:
                self.f.seek(entry * 512 + self.bitmap_size + inb)
                out += self.f.read(k)
            offset += k
            n -= k
        return bytes(out)

    def write(self, offset, data):
        if not self.writable:
            raise DiskImageError("образ открыт только для чтения")
        self._check(offset, len(data))
        if self.type == TYPE_FIXED:
            self.f.seek(offset)
            self.f.write(data)
            return
        mv = memoryview(data)
        pos = 0
        while pos < len(data):
            blk, inb = divmod(offset, self.block_size)
            k = min(len(data) - pos, self.block_size - inb)
            chunk = mv[pos:pos + k]
            if self.bat[blk] == UNUSED:
                if not any(chunk):        # нули в невыделенный блок — ничего не делаем
                    offset += k
                    pos += k
                    continue
                self._alloc_block(blk)
            self.f.seek(self.bat[blk] * 512 + self.bitmap_size + inb)
            self.f.write(chunk)
            offset += k
            pos += k

    def _alloc_block(self, blk):
        """Новый блок пишется на место footer'а, footer переносится в конец."""
        end = os.path.getsize(self.path) - 512
        end = (end + 511) // 512 * 512
        self.f.seek(end)
        self.f.write(b"\xFF" * self.bitmap_size)   # все секторы блока «присутствуют»
        self.f.write(bytes(self.block_size))
        self.f.write(self.footer_raw)
        self.bat[blk] = end // 512
        self.bat_dirty = True

    def flush(self):
        if self.writable and self.type == TYPE_DYNAMIC and self.bat_dirty:
            self.f.seek(self.bat_off)
            self.f.write(struct.pack(f">{self.max_entries}I", *self.bat))
            self.bat_dirty = False
        if self.writable:
            self.f.flush()

    def close(self):
        if not self.f.closed:
            self.flush()
            self.f.close()

    def allocated_bytes(self):
        if self.type == TYPE_FIXED:
            return self.size
        return sum(1 for e in self.bat if e != UNUSED) * self.block_size


def create_vhd(path, size, dynamic=True, block_size=2 * 1024 * 1024):
    size = vhd_size_for(size)
    if size <= 0:
        raise DiskImageError("слишком маленький размер VHD")
    with open(path, "wb") as f:
        if not dynamic:
            f.truncate(size)
            f.seek(size)
            f.write(Footer.build(size, TYPE_FIXED, 0xFFFFFFFFFFFFFFFF))
            return size
        footer = Footer.build(size, TYPE_DYNAMIC, 512)
        entries = (size + block_size - 1) // block_size
        bat_off = 512 + 1024
        hdr = struct.pack(DYN_FMT, b"cxsparse", 0xFFFFFFFFFFFFFFFF, bat_off,
                          0x00010000, entries, block_size, 0, bytes(16), 0,
                          bytes(4), bytes(512), bytes(192), bytes(256))
        hdr = hdr[:36] + struct.pack(">I", _checksum(hdr, 36)) + hdr[40:]
        bat = struct.pack(f">{entries}I", *([UNUSED] * entries))
        bat += b"\xFF" * ((-len(bat)) % 512)
        f.write(footer + hdr + bat + footer)
    return size
