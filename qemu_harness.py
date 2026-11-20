"""Управление QEMU для автотестов: монитор HMP (sendkey, screendump) + лог COM1."""
import os
import socket
import subprocess
import time


class Qemu:
    def __init__(self, disk, workdir, fmt="raw"):
        self.workdir = workdir
        self.serial = os.path.join(workdir, "serial.log")
        self.sock = os.path.join(workdir, "mon.sock")
        for p in (self.serial, self.sock):
            if os.path.exists(p):
                os.unlink(p)
        self.proc = subprocess.Popen(
            ["qemu-system-i386", "-m", "32", "-display", "none", "-no-reboot",
             "-drive", f"file={disk},format={fmt},if=ide",
             "-serial", f"file:{self.serial}",
             "-monitor", f"unix:{self.sock},server,nowait"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            if os.path.exists(self.sock):
                break
            time.sleep(0.05)
        self.mon = socket.socket(socket.AF_UNIX)
        self.mon.connect(self.sock)
        self.mon.settimeout(2)
        self._drain()

    def _drain(self):
        time.sleep(0.1)
        try:
            while self.mon.recv(65536):
                pass
        except socket.timeout:
            pass

    def cmd(self, c):
        self.mon.sendall((c + "\n").encode())
        time.sleep(0.05)
        try:
            return self.mon.recv(65536).decode(errors="replace")
        except socket.timeout:
            return ""

    def key(self, k, hold_ms=None):
        self.cmd(f"sendkey {k}" + (f" {hold_ms}" if hold_ms else ""))
        time.sleep((hold_ms or 100) / 1000 + 0.05)

    def type(self, text):
        names = {" ": "spc", "#": "shift-3", "!": "shift-1", "@": "shift-2", "_": "shift-minus",
                 "-": "minus", ".": "dot", ",": "comma", "/": "slash"}
        for ch in text:
            if ch.isupper():
                k = "shift-" + ch.lower()
            elif ch in names:
                k = names[ch]
            else:
                k = ch
            self.key(k)

    def log(self):
        try:
            with open(self.serial, "rb") as f:
                return f.read().decode(errors="replace")
        except FileNotFoundError:
            return ""

    def wait_log(self, text, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.log():
                return True
            if self.proc.poll() is not None:
                break
            time.sleep(0.1)
        raise TimeoutError(f"нет '{text}' в COM1 за {timeout}s. Лог:\n{self.log()}")

    def screenshot(self, png):
        ppm = png[:-4] + ".ppm"
        self.cmd(f"screendump {ppm}")
        for _ in range(50):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 100:
                break
            time.sleep(0.05)
        time.sleep(0.2)
        subprocess.run(["convert", ppm, "-scale", "200%", png], check=False)
        os.unlink(ppm)
        return png

    def close(self):
        try:
            self.cmd("quit")
        except OSError:
            pass
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
