"""Снимает скриншоты всех этапов для README: python3 tests/screenshots.py docs/"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from qemu_harness import Qemu  # noqa: E402
from bootcfg.cli import main as bootcfg  # noqa: E402

out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "docs")
os.makedirs(out, exist_ok=True)
w = tempfile.mkdtemp()
disk = os.path.join(w, "demo.img")
bootcfg(["mkdemo", disk])
bootcfg(["install", disk, "--password", "Secret#2026", "--game-seconds", "12"])
bootcfg(["set", disk, "--name", "1=Windows 10", "--name", "2=Ubuntu 24.04"])
q = Qemu(disk, w)
try:
    q.wait_log("[BL] game: title screen", 20)
    time.sleep(0.3)
    q.screenshot(f"{out}/1_title.png")
    q.key("spc")
    for i in range(16):
        q.key("spc", 60)
        q.key("left" if (i // 4) % 2 else "right", 140)
    q.screenshot(f"{out}/2_game.png")
    q.wait_log("[BL] game: passed", 40)
    time.sleep(2.6)
    q.type("Secret")
    q.screenshot(f"{out}/3_password.png")
    q.type("#2026")
    q.key("ret")
    q.wait_log("[BL] password: ok", 10)
    time.sleep(0.4)
    q.key("down")
    time.sleep(0.3)
    q.screenshot(f"{out}/4_menu.png")
    q.key("ret")
    q.wait_log("[OS] partition flag", 10)
    time.sleep(0.3)
    q.screenshot(f"{out}/5_os.png")
finally:
    q.close()
print("screenshots in", out)
