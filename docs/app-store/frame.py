# Puts a caption over each App Store screenshot, on the app's dark canvas, at the exact size the App Store
# takes. Run: python3 docs/app-store/frame.py <shots folder> <out folder>
# The shots folder holds raw captures named <platform>_<nn>_<name>.png (mac_, iphone_, ipad_); captions
# come from captions.json (language -> name -> [headline, subline]).
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = {"mac": (2880, 1800), "iphone": (2868, 1320), "ipad": (2752, 2064)}  # landscape (Mimesis on iPhone is landscape)
CANVAS = (14, 14, 18)
ACCENT = (221, 27, 63)
FONTS = {
    "default": ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"],
    "ja": ["/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"],
    "zh-Hans": ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"],
    "zh-Hant": ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"],
    "ko": ["/System/Library/Fonts/AppleSDGothicNeo.ttc"],
}


def font(lang, size, bold=True):
    for path in FONTS.get(lang, []) + FONTS["default"]:
        if os.path.exists(path):
            try:
                f = ImageFont.truetype(path, size)
                if path.endswith("SFNS.ttf"):
                    try:
                        f.set_variation_by_name("Bold" if bold else "Regular")
                    except Exception:
                        pass
                return f
            except OSError:
                continue
    return ImageFont.load_default()


def fit(draw, text, lang, size, width, bold=True):
    while size > 20:
        f = font(lang, size, bold)
        if draw.textlength(text, font=f) <= width:
            return f
        size -= 4
    return font(lang, size, bold)


def frame(shot, platform, headline, subline, lang):
    W, H = SIZES[platform]
    out = Image.new("RGB", (W, H), CANVAS)
    draw = ImageDraw.Draw(out)
    band = int(H * 0.19)
    hf = fit(draw, headline, lang, int(band * 0.42), W * 0.9)
    sf = fit(draw, subline, lang, int(band * 0.22), W * 0.9, bold=False)
    hb = draw.textbbox((0, 0), headline, font=hf)
    sb = draw.textbbox((0, 0), subline, font=sf)
    gap = int(band * 0.08)
    total = (hb[3] - hb[1]) + gap + (sb[3] - sb[1])
    y = (band - total) // 2 + int(band * 0.04)
    draw.text(((W - (hb[2] - hb[0])) / 2 - hb[0], y - hb[1]), headline, font=hf, fill=(255, 255, 255))
    y += (hb[3] - hb[1]) + gap
    draw.text(((W - (sb[2] - sb[0])) / 2 - sb[0], y - sb[1]), subline, font=sf, fill=(170, 170, 180))
    # The screenshot, as large as fits under the caption, with rounded corners and a thin edge.
    img = Image.open(shot).convert("RGB")
    room_w, room_h = int(W * 0.94), H - band - int(H * 0.04)
    scale = min(room_w / img.width, room_h / img.height)
    img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
    radius = int(min(img.size) * 0.025)
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius, fill=255)
    x = (W - img.width) // 2
    top = band + (room_h - img.height) // 2
    edge = Image.new("RGB", (img.width + 6, img.height + 6), (60, 60, 70))
    emask = Image.new("L", edge.size, 0)
    ImageDraw.Draw(emask).rounded_rectangle([0, 0, edge.width - 1, edge.height - 1], radius + 3, fill=255)
    out.paste(edge, (x - 3, top - 3), emask)
    out.paste(img, (x, top), mask)
    return out


def main():
    shots, outdir = sys.argv[1], sys.argv[2]
    captions = json.load(open(os.path.join(HERE, "captions.json")))
    for lang, table in captions.items():
        for name in sorted(os.listdir(shots)):
            if not name.endswith(".png"):
                continue
            parts = name[:-4].split("_", 2)
            if len(parts) != 3:
                continue
            platform, _, key = parts
            if key not in table or platform not in SIZES:
                continue
            headline, subline = table[key]
            target = os.path.join(outdir, lang, f"{name[:-4]}.png")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            frame(os.path.join(shots, name), platform, headline, subline, lang).save(target, optimize=True)
            print(target)


if __name__ == "__main__":
    main()
