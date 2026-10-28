"""PSP.Display.Render's conversions against the former per-pixel code.

  python tests/cores/psp/jit/display_check.py

16-bit formats (565, 5551, 4444): the colour of every pixel value must be the
OR of the colours of its low byte and its high byte (GDisplayLo/GDisplayHi),
checked for all 65536 values. 8888: two pixels converted in one 64-bit word
must be the two converted alone (random words).
"""
import random
import sys


def colour16(f, c):
    # DisplayColour16, as Render converted each pixel before.
    if f == 0:
        r, g, b = c & 0x1F, (c >> 5) & 0x3F, (c >> 11) & 0x1F
        r, g, b = (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)
    elif f == 1:
        r, g, b = c & 0x1F, (c >> 5) & 0x1F, (c >> 10) & 0x1F
        r, g, b = (r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)
    else:
        r, g, b = (c & 0xF) * 17, ((c >> 4) & 0xF) * 17, ((c >> 8) & 0xF) * 17
    return 0xFF000000 | (r << 16) | (g << 8) | b


def colour32(c):
    return 0xFF000000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)


def main():
    bad = 0
    for f in range(3):
        lo = [colour16(f, i) for i in range(256)]
        hi = [colour16(f, i << 8) for i in range(256)]
        bad += sum(colour16(f, c) != (lo[c & 0xFF] | hi[c >> 8]) for c in range(65536))
    rnd = random.Random(1)
    for _ in range(1000000):
        a, b = rnd.getrandbits(32), rnd.getrandbits(32)
        c = a | (b << 32)
        two = (0xFF000000FF000000 | ((c & 0x000000FF000000FF) << 16) | (c & 0x0000FF000000FF00) |
               ((c >> 16) & 0x000000FF000000FF))
        bad += two != (colour32(a) | (colour32(b) << 32))
    print('3 x 65536 16-bit values, 1000000 8888 pairs: %d differences' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
