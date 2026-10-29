# Draws LinuxArch's icons as SVG, after MacArch's (draw.py): RISC OS's
# pointer over a strip of the icon bar with a floppy drive icon ":0", on the
# desktop's grey, in a rounded square as GNOME's icons are; and a symbolic
# (monochrome) one of the pointer.
#
#   python3 Tools/icon/draw-svg.py Apps/LinuxArch/data/icons/hicolor

import os
import sys

S = 1024
out = sys.argv[1]
APP = "com.accidentalfish.LinuxArch"


def rect(x, y, w, h, fill, rx=0, stroke=None, width=0):
    edge = f' stroke="{stroke}" stroke-width="{width:g}"' if stroke else ""
    return f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{rx:g}" fill="{fill}"{edge}/>'


def polygon(points, fill, dx=0, dy=0):
    return f'<polygon points="{" ".join(f"{x + dx:g},{y + dy:g}" for x, y in points)}" fill="{fill}"/>'


def block(cx, cy, rows, u):
    """A character in a blocky system-font style, as rectangles."""
    return [rect(cx + c * u, cy + r * u, u, u, "#000000")
            for r, row in enumerate(rows) for c, ch in enumerate(row) if ch == "#"]


# RISC OS's arrow, angled up and to the left: its light blue edge, and the
# dark blue inside it (draw.py's shapes).
POINTER = [(0, 0), (0, 470), (110, 360), (190, 540), (270, 505), (190, 330), (340, 330)]
POINTER_INNER = [(28, 62), (28, 400), (118, 312), (200, 495), (236, 479), (155, 300), (270, 300)]


def app_icon():
    # MacArch's design (its preview, masked to a rounded square), inset as
    # GNOME's icons are.
    inset = 48
    scale = (S - 2 * inset) / S
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">',
        '<defs><clipPath id="shape">',
        rect(0, 0, S, S, "#000", 230),
        '</clipPath>',
        '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">',
        '<feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity="0.35"/>',
        '</filter></defs>',
        f'<g transform="translate({inset} {inset}) scale({scale:g})">',
        '<g clip-path="url(#shape)">',
        rect(0, 0, S, S, "#777777"),
    ]
    # The icon bar: light grey with a dark rule, along the bottom.
    top = 650
    parts.append('<g filter="url(#shadow)">')
    parts.append(rect(0, top, S, S - top, "#dddddd"))
    parts.append(rect(0, top, S, 14, "#222222"))
    # A floppy drive: its front, with the slot and red light.
    x0, y0, x1, y1 = 120, top + 70, 520, top + 200
    parts.append(rect(x0, y0, x1 - x0, y1 - y0, "#eee8aa", 18, "#222222", 10))
    parts.append(rect(x0 + 40, y0 + 45, x1 - 120 - (x0 + 40), 30, "#222222"))
    parts.append(rect(x1 - 95, y0 + 45, 50, 30, "#d62828"))
    parts.append(rect(x0 + 40, y0 + 90, x1 - 40 - (x0 + 40), 10, "#888888"))
    # ":0" beneath it.
    u = 18
    parts.append('<g shape-rendering="crispEdges">')
    parts += block(255, y1 + 25, ["  ", "##", "##", "  ", "  ", "##", "##"], u)
    parts += block(300, y1 + 25, [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "], u)
    parts.append('</g></g>')
    # The pointer, over it all.
    parts.append('<g filter="url(#shadow)">')
    parts.append(polygon(POINTER, "#8cdcff", 330, 140))
    parts.append(polygon(POINTER_INNER, "#0022aa", 330, 140))
    parts += ['</g>', '</g>', '</g>', '</svg>']
    return "\n".join(parts) + "\n"


def symbolic_icon():
    # 16x16: the pointer, solid.
    scale = 14 / 540
    points = [(1.5 + x * scale * 1.0, 1 + y * scale) for x, y in POINTER]
    return "\n".join([
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">',
        f'<polygon points="{" ".join(f"{x:.2f},{y:.2f}" for x, y in points)}" fill="#222222"/>',
        '</svg>',
    ]) + "\n"


for directory, name, content in (("scalable/apps", f"{APP}.svg", app_icon()),
                                 ("symbolic/apps", f"{APP}-symbolic.svg", symbolic_icon())):
    path = os.path.join(out, directory)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, name), "w") as f:
        f.write(content)
