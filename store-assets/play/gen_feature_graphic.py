from PIL import Image, ImageDraw, ImageFont

W, H = 1024, 500
BG = (251, 246, 239)      # #FBF6EF cream
TEXT = (28, 20, 16)       # #1C1410
ACCENT = (228, 87, 46)    # #E4572E
SUB = (107, 93, 79)       # #6B5D4F

img = Image.new("RGB", (W, H), BG)
draw = ImageDraw.Draw(img)

FONT_DIR = "/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/assets/fonts"
title_font = ImageFont.truetype(f"{FONT_DIR}/Inter-Bold.ttf", 52)
sub_font = ImageFont.truetype(f"{FONT_DIR}/Inter-Medium.ttf", 24)

# App icon on the left
icon = Image.open("/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/store-assets/play/icon-512.png").convert("RGBA")
icon_size = 260
icon = icon.resize((icon_size, icon_size), Image.LANCZOS)
icon_x, icon_y = 56, (H - icon_size) // 2
img.paste(icon, (icon_x, icon_y), icon)

# Text block to the right of the icon
text_x = icon_x + icon_size + 48
title = "Command.Crew"
draw.text((text_x, 185), title, font=title_font, fill=TEXT)
subtitle = "Table-side order taking\nfor restaurant waiters"
draw.multiline_text((text_x, 255), subtitle, font=sub_font, fill=SUB, spacing=10)

# Accent underline
draw.rectangle([text_x, 245, text_x + 70, 250], fill=ACCENT)

img.save("/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/store-assets/play/feature-graphic.png")
print("saved", img.size)
