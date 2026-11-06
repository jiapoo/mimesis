"""Builds the Mimesis app icon ("Echo M, trail ×3, faded") for iOS and Mac.

Writes Design/AppIcon.svg (iOS, full-bleed square) and Design/AppIcon-mac.svg (macOS rounded square with
margin and shadow), then renders the PNGs into iOS/ and Mac/ Assets.xcassets. Needs `cairosvg` on PATH.
Run: python3 Design/make_icon.py
"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CRIMSON_TOP, CRIMSON_BOTTOM = "#EC3A55", "#A3102D"  # around the family crimson #DD1B3F
M = "M 250 760 L 250 290 L 512 600 L 774 290 L 774 760"
STROKE = 'fill="none" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"'
# (offset, opacity at top, opacity at bottom) for each echo, farthest first
ECHOES = [(108, 0.25, 0.0), (72, 0.40, 0.02), (36, 0.65, 0.05)]
# Moves M plus trail so the whole mark sits at the optical centre.
CENTER = "translate(-54 -62)"


def defs():
    out = [f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
           f'<stop offset="0" stop-color="{CRIMSON_TOP}"/><stop offset="1" stop-color="{CRIMSON_BOTTOM}"/></linearGradient>']
    for i, (d, a0, a1) in enumerate(ECHOES):
        out.append(f'<linearGradient id="e{i}" gradientUnits="userSpaceOnUse" x1="0" y1="{280 + d}" x2="0" y2="{780 + d}">'
                   f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="{a0}"/>'
                   f'<stop offset="1" stop-color="#FFFFFF" stop-opacity="{a1}"/></linearGradient>')
    return "".join(out)


def mark():
    echoes = "".join(f'<path d="{M}" transform="translate({d} {d})" {STROKE} stroke="url(#e{i})"/>'
                     for i, (d, _, _) in enumerate(ECHOES))
    return f'<g transform="{CENTER}">{echoes}<path d="{M}" {STROKE} stroke="#FFFFFF"/></g>'


def ios_svg():
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs()}</defs><rect width="1024" height="1024" fill="url(#bg)"/>{mark()}</svg>\n')


def mac_svg():
    # macOS grid: 824×824 body inset 100, corner radius ~185, soft shadow below.
    shadow = "".join(f'<rect x="{100 - s}" y="{112 - s + 2 * s // 3}" width="{824 + 2 * s}" height="{824 + 2 * s}" '
                     f'rx="{185 + s}" fill="#000" fill-opacity="0.035"/>' for s in range(2, 20, 3))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs()}<clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs>'
            f'{shadow}<g clip-path="url(#body)"><rect width="1024" height="1024" fill="url(#bg)"/>'
            f'<g transform="translate(100 100) scale({824 / 1024})">{mark()}</g></g></svg>\n')


def render(svg_path, png_path, size):
    os.makedirs(os.path.dirname(png_path), exist_ok=True)
    subprocess.run(["cairosvg", svg_path, "--output-width", str(size), "--output-height", str(size), "-o", png_path], check=True)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


ios = os.path.join(HERE, "AppIcon.svg")
mac = os.path.join(HERE, "AppIcon-mac.svg")
write(ios, ios_svg())
write(mac, mac_svg())

CATALOG = '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'

ios_set = os.path.join(ROOT, "iOS/Assets.xcassets/AppIcon.appiconset")
write(os.path.join(ROOT, "iOS/Assets.xcassets/Contents.json"), CATALOG)
ios_png = os.path.join(ios_set, "AppIcon.png")
render(ios, ios_png, 1024)
# The App Store rejects iOS icons with an alpha channel: round-trip through JPEG to drop it.
tmp = ios_png + ".jpg"
subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", ios_png, "--out", tmp], check=True, capture_output=True)
subprocess.run(["sips", "-s", "format", "png", tmp, "--out", ios_png], check=True, capture_output=True)
os.remove(tmp)
write(os.path.join(ios_set, "Contents.json"),
      '{\n  "images" : [\n    {\n      "filename" : "AppIcon.png",\n      "idiom" : "universal",\n'
      '      "platform" : "ios",\n      "size" : "1024x1024"\n    }\n  ],\n'
      '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')

mac_set = os.path.join(ROOT, "Mac/Assets.xcassets/AppIcon.appiconset")
write(os.path.join(ROOT, "Mac/Assets.xcassets/Contents.json"), CATALOG)
for px in (16, 32, 64, 128, 256, 512, 1024):
    render(mac, os.path.join(mac_set, f"mac-{px}.png"), px)
entries = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        entries.append(f'    {{\n      "filename" : "mac-{pt * scale}.png",\n      "idiom" : "mac",\n'
                       f'      "scale" : "{scale}x",\n      "size" : "{pt}x{pt}"\n    }}')
write(os.path.join(mac_set, "Contents.json"),
      '{\n  "images" : [\n' + ",\n".join(entries) + '\n  ],\n'
      '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
print("ok")
