# Draws MacArch's icon layers (1024x1024 PNGs) for
# Apps/MacArch/Resources/AppIcon.icon: a RISC OS-style pointer over a
# strip of the icon bar with a floppy drive icon ":0". Also a flat preview.
#
#   python3 Tools/icon/draw.py OUTDIR

import sys
from PIL import Image, ImageDraw

S = 1024
out = sys.argv[1]

# The icon bar: light grey with a dark rule, along the bottom.
BAR_TOP = 650
bar = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(bar)
d.rectangle([0, BAR_TOP, S, S], fill=(221, 221, 221, 255))
d.rectangle([0, BAR_TOP, S, BAR_TOP + 14], fill=(34, 34, 34, 255))
# A floppy drive icon: the drive front with its slot and red light.
x0, y0, x1, y1 = 120, BAR_TOP + 70, 520, BAR_TOP + 200
d.rounded_rectangle([x0, y0, x1, y1], radius=18, fill=(238, 232, 170, 255), outline=(34, 34, 34, 255), width=10)
d.rectangle([x0 + 40, y0 + 45, x1 - 120, y0 + 75], fill=(34, 34, 34, 255))
d.rectangle([x1 - 95, y0 + 45, x1 - 45, y0 + 75], fill=(214, 40, 40, 255))
d.rectangle([x0 + 40, y0 + 90, x1 - 40, y0 + 100], fill=(136, 136, 136, 255))
# ":0" beneath it, in a blocky system-font style.
U = 18
def block(cx, cy, rows):
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            if ch == "#":
                d.rectangle([cx + c * U, cy + r * U, cx + c * U + U - 1, cy + r * U + U - 1], fill=(0, 0, 0, 255))
colon = ["  ", "##", "##", "  ", "  ", "##", "##"]
zero = [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "]
block(255, y1 + 25, colon)
block(300, y1 + 25, zero)
bar.save(f"{out}/iconbar.png")

# The pointer: RISC OS's arrow, dark blue with a light blue edge, angled
# up and to the left, larger than life.
pointer = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(pointer)
tip = (330, 140)
shape = [(0, 0), (0, 470), (110, 360), (190, 540), (270, 505), (190, 330), (340, 330)]
pts = [(tip[0] + x, tip[1] + y) for x, y in shape]
d.polygon(pts, fill=(140, 220, 255, 255))
inner = [(28, 62), (28, 400), (118, 312), (200, 495), (236, 479), (155, 300), (270, 300)]
d.polygon([(tip[0] + x, tip[1] + y) for x, y in inner], fill=(0, 34, 170, 255))
pointer.save(f"{out}/pointer.png")

# A flat preview on the desktop grey.
preview = Image.new("RGBA", (S, S), (119, 119, 119, 255))
preview.alpha_composite(bar)
preview.alpha_composite(pointer)
preview.save(f"{out}/preview.png")
