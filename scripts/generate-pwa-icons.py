from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "public" / "icons"
ORANGE = "#ff650a"
NAVY = "#071d33"


def icon(size, maskable=False):
    scale = 4
    s = size * scale
    im = Image.new("RGB", (s, s), ORANGE if maskable else "#ffffff")
    draw = ImageDraw.Draw(im)
    if not maskable:
        draw.rounded_rectangle((5 * scale, 5 * scale, s - 5 * scale, s - 5 * scale), radius=size * .22 * scale, fill="#ffffff", outline="#e7ebef", width=max(1, 2 * scale))
    color = "#ffffff" if maskable else ORANGE
    cx = s / 2
    pin_y = s * .37
    pin_r = s * .145
    draw.ellipse((cx - pin_r, pin_y - pin_r, cx + pin_r, pin_y + pin_r), fill=color)
    draw.polygon([(cx - pin_r * .72, pin_y + pin_r * .63), (cx + pin_r * .72, pin_y + pin_r * .63), (cx, s * .675)], fill=color)
    hole = pin_r * .42
    draw.ellipse((cx - hole, pin_y - hole, cx + hole, pin_y + hole), fill=ORANGE if maskable else "#ffffff")
    width = max(6, round(s * .055))
    box = (s * .205, s * .545, s * .795, s * .91)
    draw.arc(box, start=20, end=160, fill=color, width=width)
    return im.resize((size, size), Image.Resampling.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    icon(180).save(OUT / "apple-touch-icon.png", optimize=True)
    icon(192).save(OUT / "yavoi-192.png", optimize=True)
    icon(512).save(OUT / "yavoi-512.png", optimize=True)
    icon(512, maskable=True).save(OUT / "yavoi-maskable-512.png", optimize=True)


if __name__ == "__main__":
    main()
