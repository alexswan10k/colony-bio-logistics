#!/usr/bin/env python3
"""Generate placeholder art (flat shapes, supersampled) into mod/graphics. Re-run after editing: python3 scripts/gen_art.py"""
import os
from PIL import Image, ImageDraw
OUT = os.path.join(os.path.dirname(__file__), "..", "mod", "graphics")
os.makedirs(OUT, exist_ok=True)
SS = 4

def canvas(w, h):
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)

def save(img, name, w, h):
    img.resize((w, h), Image.LANCZOS).save(os.path.join(OUT, name))

def S(*pts): return [p * SS for p in pts]

def outline_rect(d, box, fill, outline=(30, 25, 20, 255), w=3):
    d.rectangle(S(*box), fill=fill, outline=outline, width=w * SS)

def shadow(d, box):
    d.ellipse(S(*box), fill=(0, 0, 0, 70))

def hall(px=192):
    img, d = canvas(px, px)
    shadow(d, (12, px * .78, px - 12, px - 4))
    outline_rect(d, (20, 70, px - 20, px - 30), (214, 160, 90, 255))                       # walls
    d.polygon(S(10, 76, px / 2, 18, px - 10, 76), fill=(168, 70, 52, 255), outline=(30, 25, 20, 255), width=3 * SS)   # roof
    outline_rect(d, (px / 2 - 16, px - 80, px / 2 + 16, px - 30), (90, 60, 40, 255))        # door
    d.line(S(px / 2, 18, px / 2, -4), fill=(40, 30, 20, 255), width=3 * SS)
    d.polygon(S(px / 2, 0, px / 2 + 26, 8, px / 2, 16), fill=(240, 200, 40, 255))           # flag
    save(img, "town-hall.png", px, px)

def tent(px=128):
    img, d = canvas(px, px)
    shadow(d, (10, px * .76, px - 10, px - 6))
    d.polygon(S(10, px - 22, px / 2, 18, px - 10, px - 22), fill=(110, 170, 80, 255), outline=(30, 25, 20, 255), width=3 * SS)
    d.polygon(S(px / 2 - 18, px - 22, px / 2, 54, px / 2 + 18, px - 22), fill=(40, 60, 30, 255))
    save(img, "tent.png", px, px)

def cabin(px=128):
    img, d = canvas(px, px)
    shadow(d, (8, px * .8, px - 8, px - 4))
    outline_rect(d, (16, 56, px - 16, px - 20), (150, 100, 60, 255))
    for y in (70, 86, 102): d.line(S(16, y, px - 16, y), fill=(100, 65, 40, 255), width=2 * SS)
    d.polygon(S(8, 60, px / 2, 14, px - 8, 60), fill=(90, 60, 45, 255), outline=(30, 25, 20, 255), width=3 * SS)
    outline_rect(d, (px - 48, 74, px - 30, 92), (170, 220, 240, 255), w=2)                   # window
    outline_rect(d, (30, 76, 52, px - 20), (60, 40, 28, 255), w=2)                           # door
    d.rectangle(S(px - 36, 14, px - 24, 36), fill=(110, 110, 110, 255))                      # chimney
    save(img, "cabin.png", px, px)

def rack(px=64):
    img, d = canvas(px, px)
    shadow(d, (4, px * .78, px - 4, px - 2))
    d.rectangle(S(8, 14, 14, px - 8), fill=(110, 75, 40, 255)); d.rectangle(S(px - 14, 14, px - 8, px - 8), fill=(110, 75, 40, 255))
    d.rectangle(S(8, 14, px - 8, 22), fill=(130, 90, 50, 255))
    d.line(S(22, 24, 30, 52), fill=(130, 90, 50, 255), width=3 * SS); d.polygon(S(16, 24, 32, 22, 30, 32), fill=(180, 180, 190, 255))   # axe head
    d.line(S(42, 24, 42, 52), fill=(130, 90, 50, 255), width=3 * SS); d.arc(S(30, 20, 54, 40), 180, 360, fill=(180, 180, 190, 255), width=3 * SS)  # pick
    save(img, "tool-rack.png", px, px)

def icon_axe():
    img, d = canvas(64, 64)
    d.line(S(16, 56, 44, 12), fill=(130, 90, 50, 255), width=6 * SS)
    d.polygon(S(34, 8, 56, 14, 50, 34, 40, 24), fill=(200, 200, 210, 255), outline=(30, 25, 20, 255), width=2 * SS)
    save(img, "icon-axe.png", 64, 64)

def icon_pick():
    img, d = canvas(64, 64)
    d.line(S(14, 56, 40, 14), fill=(130, 90, 50, 255), width=6 * SS)
    d.arc(S(14, 2, 62, 46), 200, 340, fill=(200, 200, 210, 255), width=7 * SS)
    save(img, "icon-pickaxe.png", 64, 64)

def icon_forage():
    img, d = canvas(64, 64)
    for (x, y, c) in ((22, 40, (180, 40, 90)), (38, 44, (200, 60, 110)), (30, 28, (160, 30, 80)), (44, 30, (210, 70, 120))):
        d.ellipse(S(x - 9, y - 9, x + 9, y + 9), fill=c + (255,), outline=(40, 10, 30, 255), width=2 * SS)
    d.polygon(S(30, 14, 38, 8, 40, 18), fill=(80, 160, 70, 255))
    save(img, "icon-forage.png", 64, 64)

def icon_building(name, kind):
    {"hall": hall, "tent": tent, "cabin": cabin, "rack": rack}[kind]  # sprites reused as icons
    Image.open(os.path.join(OUT, {"hall": "town-hall.png", "tent": "tent.png", "cabin": "cabin.png", "rack": "tool-rack.png"}[kind])) \
        .resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, name))

def colonist(px=64):
    img, d = canvas(px, px)
    shadow(d, (16, 48, 48, 60))
    d.rectangle(S(22, 26, 42, 48), fill=(60, 120, 200, 255), outline=(20, 20, 30, 255), width=2 * SS)   # body
    d.ellipse(S(22, 8, 42, 28), fill=(235, 190, 150, 255), outline=(20, 20, 30, 255), width=2 * SS)       # head
    d.rectangle(S(24, 48, 30, 58), fill=(50, 50, 60, 255)); d.rectangle(S(34, 48, 40, 58), fill=(50, 50, 60, 255))
    d.pieslice(S(21, 4, 43, 24), 180, 360, fill=(120, 80, 40, 255))                                       # hair
    save(img, "colonist.png", px, px)

hall(); tent(); cabin(); rack(); icon_axe(); icon_pick(); icon_forage(); colonist()
icon_building("icon-town-hall.png", "hall"); icon_building("icon-tent.png", "tent")
icon_building("icon-cabin.png", "cabin"); icon_building("icon-tool-rack.png", "rack")
print("wrote", sorted(os.listdir(OUT)))
