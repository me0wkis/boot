"""Абстракция блочного устройства.

Любой источник данных (сырой файл, VHD, раздел внутри диска) предоставляет
одинаковый интерфейс: read(offset, n), write(offset, data), size, flush().
Файловые системы работают поверх этого интерфейса и не знают, где реально
лежат байты.
"""
import os


class DiskImageError(Exception):
    """Базовая ошибка комплекса."""


class BlockDevice:
    sector_size = 512
    size = 0
    writable = False

    def read(self, offset: int, n: int) -> bytes:
        raise NotImplementedError

    def write(self, offset: int, data: bytes) -> None:
        raise NotImplementedError

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.flush()

    # helpers
    def read_sector(self, lba: int, count: int = 1) -> bytes:
        return self.read(lba * self.sector_size, count * self.sector_size)

    def _check(self, offset, n):
        if offset < 0 or offset + n > self.size:
            raise DiskImageError(
                f"выход за границы устройства: off={offset} n={n} size={self.size}")


class FileDevice(BlockDevice):
    """Сырой файл образа (.img, .ima, .iso, .bin)."""

    def __init__(self, path, writable=False, size=None):
        self.path = path
        self.writable = writable
        self.f = open(path, "r+b" if writable else "rb")
        self.size = size if size is not None else os.path.getsize(path)

    def read(self, offset, n):
        self._check(offset, n)
        self.f.seek(offset)
        data = self.f.read(n)
        if len(data) < n:  # «дырявый» хвост файла
            data += b"\0" * (n - len(data))
        return data

    def write(self, offset, data):
        if not self.writable:
            raise DiskImageError("образ открыт только для чтения")
        self._check(offset, len(data))
        self.f.seek(offset)
        self.f.write(data)

    def flush(self):
        if self.writable and not self.f.closed:
            self.f.flush()

    def close(self):
        if not self.f.closed:
            self.flush()
            self.f.close()


class SliceDevice(BlockDevice):
    """Окно в другом устройстве — используется для разделов MBR/GPT."""

    def __init__(self, base: BlockDevice, offset: int, size: int):
        self.base, self.offset, self.size = base, offset, size
        self.writable = base.writable
        self.sector_size = base.sector_size

    def read(self, offset, n):
        self._check(offset, n)
        return self.base.read(self.offset + offset, n)

    def write(self, offset, data):
        self._check(offset, len(data))
        self.base.write(self.offset + offset, data)

    def flush(self):
        self.base.flush()

    def close(self):
        self.base.close()


def copy_device_to_file(dev: BlockDevice, path: str, chunk=1 << 20):
    """Выгрузить устройство в разреженный файл (нулевые блоки пропускаются)."""
    zero = bytes(chunk)
    with open(path, "wb") as f:
        off = 0
        while off < dev.size:
            n = min(chunk, dev.size - off)
            data = dev.read(off, n)
            if data != zero[:n]:
                f.seek(off)
                f.write(data)
            off += n
        f.truncate(dev.size)


def copy_file_to_device(path: str, dev: BlockDevice, chunk=1 << 20, only_changed=True):
    """Записать файл обратно в устройство; пишутся только изменившиеся блоки
    (важно для dynamic VHD, чтобы не раздувать образ)."""
    with open(path, "rb") as f:
        off = 0
        while off < dev.size:
            n = min(chunk, dev.size - off)
            data = f.read(n)
            if len(data) < n:
                data += bytes(n - len(data))
            if not only_changed or dev.read(off, n) != data:
                dev.write(off, data)
            off += n
