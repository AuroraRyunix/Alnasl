"""Draws rel/windows/Alnasl.ico from the mark in priv/logo/mark.svg.

The mark is seven squares on a 24-unit grid; they are redrawn here rather
than rendered from the SVG, because that needs a renderer nobody has
installed and seven rectangles do not. If the mark changes, the squares
below change with it - the script checks that the SVG still holds the ones
it knows, and stops when it does not.

    python rel/windows/build_icon.py

Needs Pillow. The .ico is committed: the launcher's resource script and
`vpk pack --icon` both want a file, and CI should not need Python to make a
release.
"""

import re
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
MARK = HERE.parent.parent / "priv" / "logo" / "mark.svg"

INK = (27, 27, 26, 255)
ACCENT = (122, 46, 30, 255)
PAPER = (255, 255, 255, 255)

# (x, y) of each 6x6 square, in the SVG's own units.
DARK = [(2, 2), (9, 2), (9, 9), (16, 9), (16, 16), (2, 16)]
LIGHT = [(16, 2)]


def check_mark():
    svg = MARK.read_text(encoding="utf-8")
    found = {(int(x), int(y)) for x, y in re.findall(r'<rect x="(\d+)" y="(\d+)" width="6"', svg)}
    if found != set(DARK + LIGHT):
        raise SystemExit(f"{MARK} no longer has the squares this script draws: {sorted(found)}")


def draw(size):
    # Drawn large and scaled down: the small sizes get their edges from the
    # resampling, not from rounding a 0.67-pixel gap to nothing.
    scale = 16
    side = 28 * scale
    image = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    pen.rounded_rectangle((0, 0, side - 1, side - 1), radius=4 * scale, fill=PAPER)

    for squares, colour in ((DARK, INK), (LIGHT, ACCENT)):
        for x, y in squares:
            left, top = (x + 2) * scale, (y + 2) * scale
            pen.rectangle((left, top, left + 6 * scale - 1, top + 6 * scale - 1), fill=colour)

    return image.resize((size, size), Image.LANCZOS)


def main():
    check_mark()
    sizes = [256, 128, 64, 48, 32, 24, 16]
    draw(256).save(HERE / "Alnasl.ico", format="ICO", sizes=[(s, s) for s in sizes])
    print(f"wrote {HERE / 'Alnasl.ico'}")


if __name__ == "__main__":
    main()
