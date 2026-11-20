"""Автотесты BootLock: настоящая загрузка в QEMU, клавиатура через монитор,
проверка по логу COM1, скриншотам и содержимому диска после загрузки.

Запуск: python3 -m pytest -v tests/        (нужны nasm, qemu-system-i386)
"""
import hashlib
import os
import shutil
import struct
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(__file__))
from qemu_harness import Qemu  # noqa: E402

from bootcfg.cli import main as bootcfg, kdf, Config, BUILD  # noqa: E402

PW = "Secret#2026"
pytestmark = pytest.mark.skipif(not shutil.which("qemu-system-i386"), reason="нет QEMU")


def mbr_flags(disk):
    with open(disk, "rb") as f:
        mbr = f.read(512)
    return [mbr[446 + 16 * i] for i in range(4)]


@pytest.fixture
def disk(tmp_path):
    d = str(tmp_path / "disk.img")
    assert bootcfg(["mkdemo", d]) == 0
    assert bootcfg(["install", d, "--password", PW, "--game-seconds", "3"]) == 0
    return d


def boot_to_menu(q, password=PW):
    q.wait_log("[BL] game: title screen", 20)
    q.key("spc")
    q.wait_log("[BL] game: passed", 20)
    q.wait_log("[BL] stage2", 1)
    time.sleep(2.5)                      # «CHECK PASSED!» на экране 2 с
    if password is not None:
        q.type(password)
        q.key("ret")
        q.wait_log("[BL] password: ok", 15)
    time.sleep(0.4)


# ---------------------------------------------------------------- сборка
def test_binaries_fit():
    s1 = open(os.path.join(BUILD, "stage1.bin"), "rb").read()
    s2 = open(os.path.join(BUILD, "stage2.bin"), "rb").read()
    assert len(s1) == 440                         # не задевает подпись диска и таблицу
    assert len(s2) < 62 * 512 - 3 * 512           # помещается даже перед разделом на LBA 63


# ---------------------------------------------------------------- полный сценарий
@pytest.mark.parametrize("key,part,name", [("2", 2, "Ubuntu 24.04 (demo)"),
                                           ("3", 3, "FreeDOS (demo)")])
def test_full_boot(disk, tmp_path, key, part, name):
    assert mbr_flags(disk)[0] == 0x80
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q)
        q.key(key)
        q.wait_log(f"[OS] Booted: {name}", 10)
        q.wait_log("[OS] partition flag (DS:SI) = 0x80", 5)
        lba = 2048 + (part - 1) * 30720
        assert f"(DS:SI+8) = 0x{lba:08X}" in q.log()
        assert "boot drive (DL) = 0x80" in q.log()
    finally:
        q.close()
    flags = mbr_flags(disk)                       # выбранный раздел стал активным на диске
    assert flags[part - 1] == 0x80 and flags.count(0x80) == 1


def test_menu_arrows(disk, tmp_path):
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q)
        q.key("up")          # с 1-го (активного) вверх → «Reboot» (5-й) → ещё вверх → 4 → 3
        q.key("up")
        q.key("up")
        q.key("ret")
        q.wait_log("[OS] Booted: FreeDOS (demo)", 10)
    finally:
        q.close()


def test_hash_asm_equals_python(disk, tmp_path):
    bootcfg(["set", disk, "--debug", "on"])
    with open(disk, "rb") as f:
        f.seek(512)
        cfg = Config.parse(f.read(512))
    expect = kdf(PW.encode(), cfg.salt, cfg.iterations).hex().upper()
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q)
        assert expect in q.log()                  # SHA-256 × 5000 на ассемблере == hashlib
    finally:
        q.close()


def test_wrong_then_right_password(disk, tmp_path):
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q, password=None)
        q.type("guess123")
        q.key("ret")
        q.wait_log("[BL] password: wrong", 10)
        time.sleep(2.8)                           # задержка после ошибки (2 с)
        q.type(PW)
        q.key("ret")
        q.wait_log("[BL] password: ok", 10)
    finally:
        q.close()


def test_backspace_and_escape(disk, tmp_path):
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q, password=None)
        q.type("zzz")
        q.key("esc")                              # очистка поля
        q.type(PW + "x")
        q.key("backspace")                        # удаление последнего символа
        q.key("ret")
        q.wait_log("[BL] password: ok", 10)
    finally:
        q.close()


def test_lockout(disk, tmp_path):
    bootcfg(["set", disk, "--attempts", "1"])
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q, password=None)
        q.type("nope")
        q.key("ret")
        q.wait_log("[BL] password: locked", 10)
        time.sleep(0.5)
        shot = q.screenshot(str(tmp_path / "locked.png"))
        assert os.path.getsize(shot) > 0
        q.type(PW)                                # после блокировки ввод игнорируется
        q.key("ret")
        time.sleep(1)
        assert "password: ok" not in q.log()
    finally:
        q.close()


def test_partition_without_os(disk, tmp_path):
    q = Qemu(disk, str(tmp_path))
    try:
        boot_to_menu(q)
        q.key("4")                                # «Data (no OS)» — нет 55AA
        time.sleep(1)
        assert "chainload" not in q.log()
        q.key("ret")                              # «Press any key» → снова меню
        time.sleep(0.5)
        q.key("1")
        q.wait_log("[OS] Booted: Windows 10 (demo)", 10)
    finally:
        q.close()
    assert mbr_flags(disk)[3] == 0                # неудачный выбор не сделал раздел активным


def test_game_cannot_be_skipped(disk, tmp_path):
    bootcfg(["set", disk, "--game-seconds", "6"])
    q = Qemu(disk, str(tmp_path))
    try:
        q.wait_log("[BL] game: title screen", 20)
        for k in ("esc", "ret", "q"):             # на титульном экране — только SPACE
            q.key(k)
        time.sleep(1)
        assert "game: started" not in q.log()
        q.key("spc")
        q.wait_log("[BL] game: started", 5)
        t0 = time.time()
        for k in ("esc", "ret"):
            q.key(k)
        q.wait_log("[BL] game: passed", 30)
        assert time.time() - t0 >= 5              # раньше срока игра не отпускает
    finally:
        q.close()


def test_no_game_no_password(disk, tmp_path):
    bootcfg(["set", disk, "--game-seconds", "0"])
    bootcfg(["passwd", disk, "--disable"])
    q = Qemu(disk, str(tmp_path))
    try:
        q.wait_log("[BL] stage2 started", 10)
        time.sleep(1)
        q.key("ret")                              # сразу меню; Enter → активный раздел 1
        q.wait_log("[OS] Booted: Windows 10 (demo)", 10)
        assert "game" not in q.log()
    finally:
        q.close()


def test_hidden_and_default(disk, tmp_path):
    bootcfg(["set", disk, "--game-seconds", "0", "--hide", "1", "--default", "3"])
    bootcfg(["passwd", disk, "--disable"])
    q = Qemu(disk, str(tmp_path))
    try:
        q.wait_log("[BL] stage2 started", 10)
        time.sleep(1)
        q.key("ret")                              # по умолчанию — раздел 3
        q.wait_log("[OS] Booted: FreeDOS (demo)", 10)
    finally:
        q.close()


def test_vhd_boot(tmp_path):
    d = str(tmp_path / "demo.vhd")
    assert bootcfg(["mkdemo", d]) == 0
    assert bootcfg(["install", d, "--no-password", "--game-seconds", "0"]) == 0
    q = Qemu(d, str(tmp_path), fmt="vpc")
    try:
        q.wait_log("[BL] stage2 started", 10)
        time.sleep(1)
        q.key("2")
        q.wait_log("[OS] Booted: Ubuntu 24.04 (demo)", 10)
    finally:
        q.close()


# ---------------------------------------------------------------- bootcfg
def test_install_uninstall_roundtrip(tmp_path):
    d = str(tmp_path / "d.img")
    bootcfg(["mkdemo", d])
    orig = open(d, "rb").read(512)
    bootcfg(["install", d, "--no-password"])
    mbr = open(d, "rb").read(512)
    assert mbr[440:] == orig[440:]                # подпись и таблица разделов не тронуты
    assert mbr[:440] == open(os.path.join(BUILD, "stage1.bin"), "rb").read()
    bootcfg(["install", d, "--no-password"])      # переустановка не портит бэкап
    assert bootcfg(["uninstall", d]) == 0
    assert open(d, "rb").read(512) == orig
    with open(d, "rb") as f:
        f.seek(512)
        assert not any(f.read(512 * 15))


def test_install_refuses(tmp_path):
    d = str(tmp_path / "gpt.img")
    open(d, "wb").truncate(8 << 20)
    mbr = bytearray(512)
    mbr[446 + 4] = 0xEE
    mbr[446 + 8:446 + 16] = struct.pack("<II", 1, 16383)
    mbr[510:] = b"\x55\xAA"
    with open(d, "r+b") as f:
        f.write(mbr)
    assert bootcfg(["install", d, "--no-password"]) == 1          # GPT
    mbr[446 + 4] = 0x07
    mbr[446 + 8:446 + 12] = struct.pack("<I", 8)                  # раздел в зазоре
    with open(d, "r+b") as f:
        f.write(mbr)
    assert bootcfg(["install", d, "--no-password"]) == 1
    mbr[446 + 8:446 + 12] = struct.pack("<I", 2048)
    with open(d, "r+b") as f:
        f.write(mbr)
        f.seek(5 * 512)
        f.write(b"GRUB")                                          # чужие данные в зазоре
    assert bootcfg(["install", d, "--no-password"]) == 1
    assert bootcfg(["install", d, "--no-password", "--force"]) == 0


def test_password_rules(tmp_path):
    d = str(tmp_path / "d.img")
    bootcfg(["mkdemo", d])
    assert bootcfg(["install", d, "--password", "пароль"]) == 1    # не ASCII
    assert bootcfg(["install", d, "--password", "x" * 33]) == 1
    assert bootcfg(["install", d, "--password", "ok-pass"]) == 0
    assert bootcfg(["verify", d, "--password", "ok-pass"]) == 0
    assert bootcfg(["verify", d, "--password", "bad"]) == 2
    with open(d, "rb") as f:
        f.seek(512)
        raw = f.read(512)
    assert b"ok-pass" not in raw                                  # пароль не хранится
    salt1 = raw[16:32]
    bootcfg(["passwd", d, "--password", "ok-pass"])
    with open(d, "rb") as f:
        f.seek(512 + 16)
        assert f.read(16) != salt1                                # новая соль при смене


def test_kdf_vector():
    salt = bytes(range(16))
    h = hashlib.sha256(salt + b"abc").digest()
    h = hashlib.sha256(h + salt).digest()
    assert kdf(b"abc", salt, 2) == h


def test_game_over_resets_timer(disk, tmp_path):
    """Без игрока бомбы рано или поздно отнимают 3 жизни → таймер сбрасывается."""
    bootcfg(["set", disk, "--game-seconds", "300"])
    q = Qemu(disk, str(tmp_path))
    try:
        q.wait_log("[BL] game: title screen", 20)
        q.key("spc")
        q.wait_log("[BL] game: over, timer reset", 240)
        assert "game: passed" not in q.log()
    finally:
        q.close()
