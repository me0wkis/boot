#!/usr/bin/env python3
"""Генерирует src/data.inc: константы SHA-256 и спрайты игры.
Спрайты нарисованы «ASCII-артом» — удобно править."""
import math
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "src", "data.inc")


def primes(n):
    p, c = [], 2
    while len(p) < n:
        if all(c % q for q in p if q * q <= c):
            p.append(c)
        c += 1
    return p


def frac32(x):
    return int((x - math.floor(x)) * (1 << 32)) & 0xFFFFFFFF


def icbrt_frac(p):
    # точный корень через целочисленную арифметику (float может ошибиться в младших битах)
    lo, hi = 0, 1 << 64
    target = p << 96                      # (p * 2^96)^(1/3) = cbrt(p) * 2^32
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if mid ** 3 <= target:
            lo = mid
        else:
            hi = mid - 1
    return lo & 0xFFFFFFFF


def isqrt_frac(p):
    return math.isqrt(p << 64) & 0xFFFFFFFF


SPRITES = {
    "spr_crab1": """
..X.....X..
...X...X...
..XXXXXXX..
.XX.XXX.XX.
XXXXXXXXXXX
X.XXXXXXX.X
X.X.....X.X
...XX.XX...""",
    "spr_crab2": """
..X.....X..
X..X...X..X
X.XXXXXXX.X
XXX.XXX.XXX
XXXXXXXXXXX
.XXXXXXXXX.
..X.....X..
.X.......X.""",
    "spr_squid1": """
...XX...
..XXXX..
.XXXXXX.
XX.XX.XX
XXXXXXXX
..X..X..
.X.XX.X.
X.X..X.X""",
    "spr_squid2": """
...XX...
..XXXX..
.XXXXXX.
XX.XX.XX
XXXXXXXX
.X.XX.X.
X......X
.X....X.""",
    "spr_octo1": """
....XXXX....
.XXXXXXXXXX.
XXXXXXXXXXXX
XXX..XX..XXX
XXXXXXXXXXXX
...XX..XX...
..XX.XX.XX..
XX........XX""",
    "spr_octo2": """
....XXXX....
.XXXXXXXXXX.
XXXXXXXXXXXX
XXX..XX..XXX
XXXXXXXXXXXX
..XXX..XXX..
.XX..XX..XX.
..XX....XX..""",
    "spr_player": """
......X......
.....XXX.....
.....XXX.....
.XXXXXXXXXXX.
XXXXXXXXXXXXX
XXXXXXXXXXXXX
XXXXXXXXXXXXX
XXXXXXXXXXXXX""",
    "spr_boom": """
X...X...X...X
.X..X...X..X.
..X.......X..
.....XXX.....
XX..XXXXX..XX
.....XXX.....
..X.......X..
.X..X...X..X.""",
}


def sprite_words(art, name):
    rows = [r for r in art.strip("\n").split("\n")]
    assert len(rows) == 8, name
    out = []
    for r in rows:
        w = max(len(rows[0]), 1)
        bits = r.ljust(w, ".")
        pad = (16 - w) // 2            # центрируем в 16 пикселях
        v = int(("." * pad + bits).ljust(16, ".").replace("X", "1").replace(".", "0"), 2)
        out.append(f"0x{v:04X}")
    return out


def main():
    ps = primes(64)
    k = [icbrt_frac(p) for p in ps]
    h = [isqrt_frac(p) for p in ps[:8]]
    assert k[0] == 0x428A2F98 and k[63] == 0xC67178F2 and h[0] == 0x6A09E667
    lines = ["; сгенерировано tools/gen_data.py — не редактировать вручную", "align 4"]
    lines.append("sha_k:")
    for i in range(0, 64, 4):
        lines.append("        dd " + ", ".join(f"0x{x:08X}" for x in k[i:i + 4]))
    lines.append("sha_iv:")
    lines.append("        dd " + ", ".join(f"0x{x:08X}" for x in h))
    for name, art in SPRITES.items():
        lines.append(f"{name}: dw " + ", ".join(sprite_words(art, name)))
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("written", OUT)


if __name__ == "__main__":
    main()
