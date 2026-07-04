import math
import os
from PIL import Image, ImageFilter

SRC_DIR = "/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/store-assets/screenshots/final"
OUT_DIR = "/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/store-assets/play/phone"
os.makedirs(OUT_DIR, exist_ok=True)

MAX_RATIO = 2.0  # Play Store: max dimension can't be more than 2x min dimension

for name in sorted(os.listdir(SRC_DIR)):
    if not name.lower().endswith(".png"):
        continue
    path = os.path.join(SRC_DIR, name)
    img = Image.open(path).convert("RGB")
    w, h = img.size
    ratio = h / w
    if ratio <= MAX_RATIO:
        img.save(os.path.join(OUT_DIR, name))
        print(name, "unchanged", img.size)
        continue

    new_w = math.ceil(h / MAX_RATIO)
    left_pad = (new_w - w) // 2

    # blurred, scaled-up copy of the screenshot itself as the background fill
    scale = new_w / w
    bg = img.resize((new_w, round(h * scale)), Image.LANCZOS)
    bg_top = (bg.height - h) // 2
    bg = bg.crop((0, bg_top, new_w, bg_top + h))
    bg = bg.filter(ImageFilter.GaussianBlur(40))

    canvas = bg
    canvas.paste(img, (left_pad, 0))
    out_path = os.path.join(OUT_DIR, name)
    canvas.save(out_path)
    print(name, "padded ->", canvas.size)
