"""Render colour variants of the Echo M icon and a comparison sheet (needs cairosvg on PATH)."""
import os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "d")
os.makedirs(OUT, exist_ok=True)

M = "M 250 760 L 250 290 L 512 600 L 774 290 L 774 760"

# name, bg top, bg bottom, front stroke, ghost stroke, ghost opacity
VARIANTS = [
    ("1 Mono", "#2A2A2E", "#0E0E10", "#FFFFFF", "#8A8A92", 0.6),
    ("2 Paper", "#FFFFFF", "#E9E9EE", "#111114", "#B8B8C2", 0.8),
    ("3 Court", "#1F6B45", "#0E3B26", "#FFFFFF", "#D7F24A", 0.85),
    ("4 Clay", "#D2643A", "#9E3D1E", "#FFFFFF", "#FFD9B8", 0.6),
    ("5 Royal", "#2E5BFF", "#1532A8", "#FFFFFF", "#7FD4FF", 0.75),
    ("6 Ink", "#14141A", "#050507", "#D7F24A", "#3A3A44", 1),
    ("7 Crimson", "#E5334B", "#9C1530", "#FFFFFF", "#FFB3BF", 0.6),
    ("8 Graphite", "#3A3D44", "#1C1E22", "#FFFFFF", "#C6F03C", 0.9),
    ("9 Sky", "#E8F3FF", "#BFDDFF", "#0F3DB8", "#7FB5FF", 0.7),
    ("10 Night", "#0F1A3A", "#060B1C", "#FFFFFF", "#4F7DFF", 0.8),
]


def icon_svg(top, bottom, front, ghost, ghost_opacity):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<path d="{M}" transform="translate(48 48)" fill="none" stroke="{ghost}" stroke-opacity="{ghost_opacity}" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"/>
<path d="{M}" fill="none" stroke="{front}" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""


tiles = []
for i, (name, top, bottom, front, ghost, go) in enumerate(VARIANTS):
    slug = name.lower().replace(" ", "-")
    svg = os.path.join(OUT, slug + ".svg")
    png = os.path.join(OUT, slug + ".png")
    with open(svg, "w") as f:
        f.write(icon_svg(top, bottom, front, ghost, go))
    subprocess.run(["cairosvg", svg, "-W", "400", "-H", "400", "-o", png], check=True)
    x, y = 40 + (i % 5) * 450, 40 + (i // 5) * 620
    tiles.append(
        f'<g transform="translate({x} {y})"><g clip-path="url(#sq)"><image width="400" height="400" xlink:href="file://{png}"/></g>'
        f'<g transform="translate(162 440)" clip-path="url(#sm)"><image width="76" height="76" xlink:href="file://{png}"/></g>'
        f'<text x="200" y="575">{name}</text></g>'
    )

sheet = os.path.join(OUT, "sheet.svg")
with open(sheet, "w") as f:
    f.write(
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 2290 1240" width="2290" height="1240">'
        '<rect width="2290" height="1240" fill="#F2F2F5"/>'
        '<defs><clipPath id="sq"><rect width="400" height="400" rx="90"/></clipPath><clipPath id="sm"><rect width="76" height="76" rx="17"/></clipPath></defs>'
        '<g font-family="Helvetica" font-size="34" font-weight="bold" fill="#222" text-anchor="middle">'
        + "".join(tiles)
        + "</g></svg>"
    )
subprocess.run(["cairosvg", "--unsafe", sheet, "-o", os.path.join(HERE, "echo-m-colors.png")], check=True)
print("ok")
