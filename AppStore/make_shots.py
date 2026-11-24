"""Builds the captioned App Store screenshots and the header banner from the raw captures in raw/."""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RAW, OUT = os.path.join(HERE, "raw"), os.path.join(HERE, "screenshots")
TOP, BOTTOM = (226, 196, 196), (150, 104, 104)        # rose, light to deep (the app's panel color)
INK, SUB = (43, 24, 24), (78, 50, 50)

def font(size, weight="Bold"):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def gradient(w, h):
    g = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return g

def framed(shot, width, bezel_frac=0.028, radius_frac=0.11):
    """The screen in a black device bezel with rounded corners and a soft shadow."""
    s = shot.convert("RGB").resize((width, round(width * shot.height / shot.width)), Image.LANCZOS)
    b = round(width * bezel_frac)
    W, H = s.width + 2 * b, s.height + 2 * b
    r = round(W * radius_frac)
    dev = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(dev).rounded_rectangle((0, 0, W - 1, H - 1), r, fill=(18, 18, 20, 255))
    mask = Image.new("L", s.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s.width - 1, s.height - 1), r - b, fill=255)
    dev.paste(s, (b, b), mask)
    pad = round(W * 0.06)
    shadow = Image.new("RGBA", (W + 2 * pad, H + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad + pad // 3, pad + W, pad + H + pad // 3), r, fill=(40, 10, 10, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(pad / 2.5))
    shadow.alpha_composite(dev, (pad, pad))
    return shadow, pad

def centered(d, y, text, f, fill, W):
    w = d.textlength(text, font=f)
    d.text(((W - w) / 2, y), text, font=f, fill=fill)

def caption_shot(raw, out, W, H, title, sub, screen_frac, radius_frac):
    img = gradient(W, H).convert("RGBA")
    d = ImageDraw.Draw(img)
    tf, sf = font(round(W * 0.064)), font(round(W * 0.034), "Medium")
    y = round(H * 0.055)
    centered(d, y, title, tf, INK, W)
    y += round(W * 0.064 * 1.35)
    centered(d, y, sub, sf, SUB, W)
    top = y + round(W * 0.034 * 2.0)
    dev, pad = framed(Image.open(os.path.join(RAW, raw)), round(W * screen_frac), radius_frac=radius_frac)
    room = H - top - round(H * 0.03)
    if dev.height - 2 * pad > room:                    # shrink to fit under the caption
        k = room / (dev.height - 2 * pad)
        dev, pad = framed(Image.open(os.path.join(RAW, raw)), round(W * screen_frac * k), radius_frac=radius_frac)
    img.alpha_composite(dev, ((W - dev.width) // 2, top - pad))
    img.convert("RGB").save(os.path.join(OUT, out))
    print(out, img.size)

CAPTIONS = [
    ("scores", "Keep score for Mexican Train", "Pick each round's double. The totals add themselves."),
    ("pips",   "Let the camera count the pips", "Touch and hold a player's points and photograph their tiles."),
    ("open",   "Save it and play on later", "A named match saves itself after every round."),
]

for f in os.listdir(OUT):
    if f.endswith(".png"): os.remove(os.path.join(OUT, f))
for i, (key, title, sub) in enumerate(CAPTIONS, 1):
    caption_shot(f"iphone-{key}.png", f"iphone-{i}-{key}.png", 1206, 2622, title, sub, 0.80, 0.115)
    caption_shot(f"ipad-{key}.png",   f"ipad-{i}-{key}.png",   2064, 2752, title, sub, 0.84, 0.045)
    caption_shot(f"ipad-{key}.png",   f"large-{i}-{key}.png",  2007, 2853, title, sub, 0.84, 0.045)

# Header banner, 3840 x 1646: icon and name on the left, two phones on the right.
W, H = 3840, 1646
img = gradient(W, H).convert("RGBA")
d = ImageDraw.Draw(img)
icon = Image.open(os.path.join(HERE, "..", "App", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")).convert("RGBA").resize((560, 560), Image.LANCZOS)
m = Image.new("L", icon.size, 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 559, 559), 126, fill=255)
icon.putalpha(m)
x0 = 640
img.alpha_composite(icon, (x0, 330))
d.text((x0, 960), "Domin-Uno", font=font(230), fill=INK)
d.text((x0 + 6, 1230), "Mexican Train score keeper", font=font(104, "Medium"), fill=SUB)
for raw, x in (("iphone-scores.png", 1980), ("iphone-pips.png", 2700)):
    dev, pad = framed(Image.open(os.path.join(RAW, raw)), 600)
    img.alpha_composite(dev, (x - pad, 150 - pad))
img.convert("RGB").save(os.path.join(OUT, "header-3840x1646.png"))
print("header", img.size)
