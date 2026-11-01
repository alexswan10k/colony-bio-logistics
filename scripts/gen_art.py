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
    Image.open(os.path.join(OUT, "cabin.png")).resize((192, 192), Image.LANCZOS).save(os.path.join(OUT, "cabin.png"))   # 3x3 tiles

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

def hut(name, roof, wall, emblem, px=128):
    img, d = canvas(px, px)
    shadow(d, (8, px * .8, px - 8, px - 4))
    outline_rect(d, (18, 58, px - 18, px - 20), wall)
    d.polygon(S(8, 62, px / 2, 16, px - 8, 62), fill=roof, outline=(30, 25, 20, 255), width=3 * SS)
    outline_rect(d, (px / 2 - 12, px - 52, px / 2 + 12, px - 20), (70, 48, 32, 255), w=2)
    emblem(d, px)
    save(img, name + ".png", px, px)
    Image.open(os.path.join(OUT, name + ".png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-" + name + ".png"))

def em_basket(d, px):
    d.ellipse(S(px / 2 - 14, 36, px / 2 + 14, 56), fill=(200, 150, 70, 255), outline=(30, 25, 20, 255), width=2 * SS)
    d.ellipse(S(px / 2 - 5, 28, px / 2 + 5, 38), fill=(190, 40, 90, 255))
def em_log(d, px):
    for i in range(3):
        d.ellipse(S(px / 2 - 22 + i * 14, 40, px / 2 - 6 + i * 14, 58), fill=(140, 95, 55, 255), outline=(30, 25, 20, 255), width=2 * SS)
def em_pick(d, px):
    d.line(S(px / 2 - 10, 58, px / 2 + 10, 34), fill=(110, 75, 40, 255), width=4 * SS)
    d.arc(S(px / 2 - 18, 26, px / 2 + 18, 50), 200, 340, fill=(210, 210, 220, 255), width=4 * SS)

def em_crop(d, px):
    for x in (px / 2 - 16, px / 2, px / 2 + 16):
        d.line(S(x, 58, x, 32), fill=(90, 150, 60, 255), width=3 * SS)
        d.ellipse(S(x - 5, 24, x + 5, 38), fill=(230, 190, 60, 255), outline=(30, 25, 20, 255), width=2 * SS)

def farm_plots(px=64):
    def soil(d):
        d.rectangle(S(2, 2, px - 2, px - 2), fill=(120, 85, 55, 255), outline=(70, 50, 30, 255), width=2 * SS)
        for y in (14, 26, 38, 50):
            d.line(S(6, y, px - 6, y), fill=(95, 66, 42, 255), width=3 * SS)
    img, d = canvas(px, px); soil(d)
    save(img, "farm-plot-fallow.png", px, px)
    img, d = canvas(px, px); soil(d)
    for (x, y) in ((16, 24), (32, 20), (48, 26), (20, 44), (36, 46), (50, 42)):
        d.line(S(x, y + 10, x, y), fill=(80, 150, 60, 255), width=2 * SS)
        d.ellipse(S(x - 4, y - 4, x + 4, y + 3), fill=(110, 180, 70, 255))
    save(img, "farm-plot-growing.png", px, px)
    img, d = canvas(px, px); soil(d)
    for (x, y) in ((16, 22), (32, 18), (48, 24), (20, 42), (36, 44), (50, 40)):
        d.line(S(x, y + 14, x, y), fill=(150, 170, 60, 255), width=3 * SS)
        d.ellipse(S(x - 5, y - 6, x + 5, y + 4), fill=(235, 195, 60, 255), outline=(120, 90, 30, 255), width=2 * SS)
    save(img, "farm-plot-ripe.png", px, px)

def icon_hoe():
    img, d = canvas(64, 64)
    d.line(S(18, 56, 42, 16), fill=(130, 90, 50, 255), width=5 * SS)
    d.line(S(36, 14, 54, 20), fill=(190, 190, 200, 255), width=5 * SS)
    d.polygon(S(50, 20, 58, 34, 46, 30), fill=(190, 190, 200, 255), outline=(30, 25, 20, 255), width=2 * SS)
    save(img, "icon-hoe.png", 64, 64)

def icon_produce():
    img, d = canvas(64, 64)
    d.polygon(S(32, 16, 50, 32, 42, 54, 22, 54, 14, 32), fill=(230, 140, 50, 255), outline=(30, 25, 20, 255), width=2 * SS)
    for y in (28, 36, 44):
        d.line(S(20, y, 44, y), fill=(200, 110, 35, 255), width=2 * SS)
    d.polygon(S(32, 16, 26, 6, 40, 10), fill=(90, 160, 70, 255), outline=(40, 90, 40, 255), width=2 * SS)
    save(img, "icon-produce.png", 64, 64)

def watchtower(px=128):
    img, d = canvas(px, px)
    shadow(d, (14, px * .82, px - 14, px - 6))
    for (x1, x2) in ((36, 28), (px - 36, px - 28)):
        d.line(S(x1, 58, x2, px - 16), fill=(120, 85, 50, 255), width=5 * SS)
    d.line(S(px / 2 - 8, 52, px / 2 - 8, px - 20), fill=(150, 110, 70, 255), width=3 * SS)
    outline_rect(d, (16, 42, px - 16, 60), (170, 130, 85, 255))                              # platform
    for x in range(22, px - 16, 16):                                                          # railing
        d.line(S(x, 42, x, 28), fill=(120, 85, 50, 255), width=3 * SS)
    d.line(S(18, 30, px - 18, 30), fill=(120, 85, 50, 255), width=3 * SS)
    d.polygon(S(10, 32, px / 2, 6, px - 10, 32), fill=(120, 70, 55, 255), outline=(30, 25, 20, 255), width=3 * SS)
    d.line(S(px / 2, 6, px / 2, -8), fill=(40, 30, 20, 255), width=3 * SS)
    d.polygon(S(px / 2, -6, px / 2 + 22, 2, px / 2, 10), fill=(240, 200, 40, 255))            # flag
    save(img, "watchtower.png", px, px)
    Image.open(os.path.join(OUT, "watchtower.png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-watchtower.png"))


def bush(px=64):
    img, d = canvas(px, px)
    shadow(d, (10, 40, 54, 58))
    for (x, y) in ((22, 34), (40, 34), (31, 24)):
        d.ellipse(S(x - 14, y - 12, x + 14, y + 14), fill=(60, 140, 60, 255), outline=(25, 70, 30, 255), width=2 * SS)
    for (x, y) in ((24, 36), (38, 30), (32, 42), (30, 26)):
        d.ellipse(S(x - 4, y - 4, x + 4, y + 4), fill=(210, 50, 100, 255))
    save(img, "bush.png", px, px)

def icon_basket():
    img, d = canvas(64, 64)
    d.arc(S(14, 8, 50, 44), 180, 360, fill=(120, 80, 40, 255), width=4 * SS)
    d.polygon(S(10, 32, 54, 32, 46, 56, 18, 56), fill=(200, 150, 70, 255), outline=(30, 25, 20, 255), width=2 * SS)
    save(img, "icon-basket.png", 64, 64)

hut("forager-hut", (80, 140, 70, 255), (190, 160, 100, 255), em_basket)
hut("woodcutter-hut", (110, 75, 50, 255), (170, 125, 80, 255), em_log)
hut("miner-hut", (100, 100, 110, 255), (150, 150, 155, 255), em_pick)
hut("farm-hut", (150, 120, 60, 255), (205, 175, 115, 255), em_crop)
bush(); icon_basket(); watchtower(); farm_plots(); icon_hoe(); icon_produce()
hall(); tent(); cabin(); rack(); icon_axe(); icon_pick(); icon_forage(); colonist()
icon_building("icon-town-hall.png", "hall"); icon_building("icon-tent.png", "tent")
icon_building("icon-cabin.png", "cabin"); icon_building("icon-tool-rack.png", "rack")
print("wrote", sorted(os.listdir(OUT)))
