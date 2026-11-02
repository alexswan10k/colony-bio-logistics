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

def em_hunt(d, px):
    for sgn in (-1, 1):                                            # antlers
        d.line(S(px / 2 + sgn * 4, 40, px / 2 + sgn * 16, 22), fill=(220, 210, 190, 255), width=3 * SS)
        d.line(S(px / 2 + sgn * 10, 31, px / 2 + sgn * 20, 30), fill=(220, 210, 190, 255), width=3 * SS)
        d.line(S(px / 2 + sgn * 14, 26, px / 2 + sgn * 22, 19), fill=(220, 210, 190, 255), width=3 * SS)

def boar(px=64):
    img, d = canvas(px, px)
    shadow(d, (8, px * .78, px - 8, px - 6))
    outline_rect(d, (14, 26, px - 14, 46), (120, 90, 60, 255))       # body
    for x in (18, 30, 40, 50):                                      # legs
        outline_rect(d, (x, 44, x + 5, px - 10), (95, 70, 45, 255), w=2)
    d.ellipse(S(px - 26, 20, px - 6, 40), fill=(130, 100, 70, 255), outline=(30, 25, 20, 255), width=2 * SS)  # head
    d.ellipse(S(px - 6, 28, px - 1, 34), fill=(90, 60, 45, 255))    # snout
    d.line(S(px - 22, 18, px - 18, 10), fill=(220, 210, 190, 255), width=2 * SS)   # tusk
    save(img, "boar.png", px, px)
    Image.open(os.path.join(OUT, "boar.png")).resize((64, 64), Image.LANCZOS).save(
        os.path.join(OUT, "icon-boar.png"))

def icon_rifle():
    img, d = canvas(64, 64)
    d.line(S(10, 50, 54, 18), fill=(120, 80, 45, 255), width=5 * SS)            # stock
    d.line(S(26, 38, 50, 20), fill=(90, 95, 105, 255), width=5 * SS)           # barrel
    d.line(S(30, 34, 36, 44), fill=(70, 70, 75, 255), width=4 * SS)            # trigger guard
    save(img, "icon-rifle.png", 64, 64)

def icon_meat():
    img, d = canvas(64, 64)
    d.ellipse(S(12, 18, 48, 50), fill=(190, 70, 70, 255), outline=(90, 30, 30, 255), width=2 * SS)
    d.ellipse(S(22, 26, 40, 42), fill=(225, 120, 110, 255))
    d.line(S(44, 14, 56, 22), fill=(240, 235, 220, 255), width=4 * SS)          # bone
    save(img, "icon-meat.png", 64, 64)

def em_fish(d, px):
    d.ellipse(S(px / 2 - 18, 36, px / 2 + 12, 56), fill=(120, 165, 205, 255), outline=(30, 25, 20, 255), width=2 * SS)
    d.polygon(S(px / 2 + 10, 40, px / 2 + 22, 46, px / 2 + 10, 52), fill=(120, 165, 205, 255),
              outline=(30, 25, 20, 255), width=2 * SS)

def icon_rod():
    img, d = canvas(64, 64)
    d.line(S(14, 54, 50, 12), fill=(150, 110, 60, 255), width=4 * SS)            # rod
    d.line(S(50, 12, 50, 40), fill=(210, 210, 220, 255), width=1 * SS)           # line
    d.ellipse(S(46, 40, 54, 48), fill=(210, 210, 220, 255))                      # hook bob
    d.line(S(18, 50, 26, 44), fill=(70, 70, 75, 255), width=4 * SS)              # handle
    save(img, "icon-rod.png", 64, 64)

def icon_fish():
    img, d = canvas(64, 64)
    d.ellipse(S(10, 20, 46, 46), fill=(150, 190, 225, 255), outline=(40, 70, 100, 255), width=2 * SS)
    d.polygon(S(44, 24, 58, 33, 44, 42), fill=(150, 190, 225, 255), outline=(40, 70, 100, 255), width=2 * SS)
    d.ellipse(S(18, 28, 23, 33), fill=(25, 30, 40, 255))                          # eye
    save(img, "icon-fish.png", 64, 64)

def em_smoke(d, px):
    d.line(S(px / 2 - 18, 54, px / 2 + 18, 54), fill=(120, 90, 60, 255), width=4 * SS)   # rack
    d.ellipse(S(px / 2 - 8, 40, px / 2 + 8, 52), fill=(170, 90, 70, 255), outline=(60, 30, 25, 255), width=2 * SS)
    for i, x in enumerate((px / 2 - 6, px / 2, px / 2 + 6)):                             # smoke
        d.arc(S(x - 5, 18 + i * 3, x + 5, 32 + i * 3), 200, 340, fill=(225, 225, 225, 220), width=2 * SS)

def em_kitchen(d, px):
    d.polygon(S(px / 2 - 16, 38, px / 2 + 16, 38, px / 2 + 12, 54, px / 2 - 12, 54), fill=(80, 80, 90, 255), outline=(30, 25, 20, 255), width=2 * SS)
    d.arc(S(px / 2 - 10, 22, px / 2 - 2, 38), 180, 360, fill=(230, 230, 240, 200), width=2 * SS)
    d.arc(S(px / 2 + 2, 20, px / 2 + 10, 36), 180, 360, fill=(230, 230, 240, 200), width=2 * SS)

def icon_bread():
    img, d = canvas(64, 64)
    d.ellipse(S(10, 22, 54, 46), fill=(205, 140, 70, 255), outline=(50, 30, 15, 255), width=2 * SS)
    for x in (22, 32, 42):
        d.line(S(x - 3, 26, x + 3, 40), fill=(235, 185, 115, 255), width=2 * SS)
    save(img, "icon-bread.png", 64, 64)

def salt_pan(px=128):
    img, d = canvas(px, px)
    shadow(d, (10, px * .8, px - 10, px - 6))
    outline_rect(d, (18, 54, px - 18, px - 22), (110, 105, 95, 255))          # frame
    d.rectangle(S(26, 62, px - 26, px - 30), fill=(90, 140, 175, 255))       # brine
    for x, y in ((40, 74), (56, 78), (72, 72), (88, 78), (60, 92), (82, 90), (46, 88), (94, 66)):
        d.rectangle(S(x, y, x + 6, y + 5), fill=(240, 240, 235, 255))        # salt crystals
    save(img, "salt-pan.png", px, px)
    Image.open(os.path.join(OUT, "salt-pan.png")).resize((64, 64), Image.LANCZOS).save(
        os.path.join(OUT, "icon-salt-pan.png"))

def icon_salt():
    img, d = canvas(64, 64)
    for x, y in ((20, 26), (32, 22), (44, 28), (26, 38), (40, 40), (32, 32)):
        d.rectangle(S(x, y, x + 9, y + 8), fill=(245, 245, 240, 255), outline=(150, 150, 145, 255), width=2 * SS)
    save(img, "icon-salt.png", 64, 64)

def icon_preserved(name, meat_colour):
    img, d = canvas(64, 64)
    d.ellipse(S(12, 22, 48, 46), fill=meat_colour, outline=(60, 35, 30, 255), width=2 * SS)
    d.line(S(14, 24, 46, 44), fill=(240, 235, 220, 255), width=2 * SS)       # curing string
    d.line(S(14, 44, 46, 24), fill=(240, 235, 220, 255), width=2 * SS)
    save(img, name, 64, 64)

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


def em_out(d, px):
    d.rectangle(S(px / 2 - 6, 78, px / 2 + 6, 102), fill=(90, 190, 90, 255), outline=(30, 70, 30, 255), width=2 * SS)
    d.polygon(S(px / 2 - 18, 80, px / 2 + 18, 80, px / 2, 56), fill=(90, 190, 90, 255), outline=(30, 70, 30, 255), width=2 * SS)

def em_in(d, px):
    d.rectangle(S(px / 2 - 6, 56, px / 2 + 6, 80), fill=(90, 150, 220, 255), outline=(30, 50, 90, 255), width=2 * SS)
    d.polygon(S(px / 2 - 18, 80, px / 2 + 18, 80, px / 2, 104), fill=(90, 150, 220, 255), outline=(30, 50, 90, 255), width=2 * SS)

def crate(name, band, emblem, px=128):
    img, d = canvas(px, px)
    shadow(d, (10, px * .8, px - 10, px - 6))
    outline_rect(d, (16, 34, px - 16, px - 16), (190, 150, 95, 255))            # box
    outline_rect(d, (10, 22, px - 10, 42), (150, 115, 70, 255))                # lid
    d.rectangle(S(14, 32, px - 14, 42), fill=band)                             # colour band
    for x in (30, px // 2, px - 30):                                            # plank seams
        d.line(S(x, 42, x, px - 16), fill=(160, 120, 75, 255), width=2 * SS)
    emblem(d, px)
    save(img, name + ".png", px, px)
    Image.open(os.path.join(OUT, name + ".png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-" + name + ".png"))

def warehouse(px=192):
    img, d = canvas(px, px)
    shadow(d, (14, px * .82, px - 14, px - 8))
    outline_rect(d, (18, 56, px - 18, px - 24), (170, 130, 85, 255))            # shed
    d.polygon(S(10, 60, px / 2, 20, px - 10, 60), fill=(140, 100, 65, 255), outline=(30, 25, 20, 255), width=3 * SS)
    d.rectangle(S(px / 2 - 26, 70, px / 2 + 26, px - 24), fill=(120, 85, 55, 255), outline=(70, 50, 30, 255), width=2 * SS)
    for x in (40, px - 40):
        d.line(S(x, 66, x, px - 26), fill=(140, 100, 65, 255), width=3 * SS)
    for (x, y) in ((px / 2 - 30, 96), (px / 2, 96), (px / 2 - 15, 74)):         # stacked crates
        d.rectangle(S(x, y, x + 28, y + 20), fill=(200, 160, 100, 255), outline=(90, 60, 35, 255), width=2 * SS)
    save(img, "warehouse.png", px, px)
    Image.open(os.path.join(OUT, "warehouse.png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-warehouse.png"))

def compost_bin(px=128):
    img, d = canvas(px, px)
    shadow(d, (10, px * .8, px - 10, px - 6))
    outline_rect(d, (18, 46, px - 18, px - 14), (120, 105, 80, 255))            # bin body
    outline_rect(d, (12, 28, px - 12, 48), (150, 130, 95, 255))                # lid
    d.rectangle(S(14, 40, px - 14, 50), fill=(95, 150, 80, 255))                # green band: compost
    for x in (34, px // 2, px - 34):                                            # slats
        d.line(S(x, 52, x, px - 16), fill=(100, 88, 66, 255), width=2 * SS)
    # sprout: a compost bin that is working has something growing out of it
    d.line(S(px / 2, 30, px / 2, 12), fill=(70, 120, 60, 255), width=3 * SS)
    d.ellipse(S(px / 2 - 16, 8, px / 2, 24), fill=(95, 175, 90, 255), outline=(35, 80, 35, 255), width=2 * SS)
    d.ellipse(S(px / 2, 8, px / 2 + 16, 24), fill=(110, 190, 100, 255), outline=(35, 80, 35, 255), width=2 * SS)
    save(img, "compost-bin.png", px, px)
    Image.open(os.path.join(OUT, "compost-bin.png")).resize((64, 64), Image.LANCZOS).save(
        os.path.join(OUT, "icon-compost-bin.png"))

def icon_fertilizer():
    img, d = canvas(64, 64)
    d.polygon(S(20, 22, 44, 22, 50, 56, 14, 56), fill=(190, 170, 120, 255), outline=(90, 75, 45, 255), width=2 * SS)
    d.line(S(20, 28, 44, 28), fill=(150, 130, 90, 255), width=2 * SS)
    d.ellipse(S(26, 34, 38, 46), fill=(95, 165, 85, 255), outline=(35, 80, 35, 255), width=2 * SS)
    d.line(S(32, 40, 32, 50), fill=(35, 80, 35, 255), width=2 * SS)
    save(img, "icon-fertilizer.png", 64, 64)

def well(px=64):
    img, d = canvas(px, px)
    shadow(d, (6, px * .82, px - 6, px - 2))
    outline_rect(d, (10, 34, px - 10, px - 8), (130, 130, 140, 255))
    for y in (42, 50): d.line(S(10, y, px - 10, y), fill=(90, 90, 100, 255), width=2 * SS)
    d.ellipse(S(14, 32, px - 14, 42), fill=(60, 140, 220, 255), outline=(40, 40, 50, 255), width=2 * SS)
    d.line(S(14, 18, 14, 38), fill=(110, 75, 45, 255), width=3 * SS)
    d.line(S(px - 14, 18, px - 14, 38), fill=(110, 75, 45, 255), width=3 * SS)
    d.line(S(12, 20, px - 12, 20), fill=(110, 75, 45, 255), width=3 * SS)
    d.polygon(S(6, 22, px / 2, 6, px - 6, 22), fill=(140, 90, 55, 255), outline=(30, 25, 20, 255), width=2 * SS)
    d.line(S(px / 2, 20, px / 2, 30), fill=(180, 180, 190, 255), width=2 * SS)
    outline_rect(d, (px / 2 - 5, 28, px / 2 + 5, 36), (120, 80, 45, 255), w=1)
    save(img, "well.png", px, px)
    Image.open(os.path.join(OUT, "well.png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-well.png"))

def homestead(px=192):
    img, d = canvas(px, px)
    shadow(d, (12, px * .82, px - 12, px - 4))
    outline_rect(d, (24, 76, px - 24, px - 24), (180, 115, 75, 255))
    for y in (92, 114, 136): d.line(S(24, y, px - 24, y), fill=(120, 75, 45, 255), width=2 * SS)
    d.polygon(S(14, 80, px / 2, 22, px - 14, 80), fill=(160, 55, 45, 255), outline=(30, 25, 20, 255), width=3 * SS)
    d.rectangle(S(px - 48, 18, px - 34, 46), fill=(125, 60, 50, 255), outline=(30, 25, 20, 255), width=2 * SS)
    d.rectangle(S(36, 32, 48, 56), fill=(125, 60, 50, 255), outline=(30, 25, 20, 255), width=2 * SS)
    outline_rect(d, (40, 96, 68, 122), (180, 230, 250, 255), w=2)
    d.line(S(54, 96, 54, 122), fill=(100, 65, 40, 255), width=2 * SS)
    d.line(S(40, 109, 68, 109), fill=(100, 65, 40, 255), width=2 * SS)
    outline_rect(d, (px - 68, 96, px - 40, 122), (180, 230, 250, 255), w=2)
    d.line(S(px - 54, 96, px - 54, 122), fill=(100, 65, 40, 255), width=2 * SS)
    d.line(S(px - 68, 109, px - 40, 109), fill=(100, 65, 40, 255), width=2 * SS)
    outline_rect(d, (px / 2 - 20, px - 78, px / 2 + 20, px - 24), (80, 50, 32, 255), w=2)
    d.line(S(px / 2, px - 78, px / 2, px - 24), fill=(40, 25, 15, 255), width=2 * SS)
    save(img, "homestead.png", px, px)
    Image.open(os.path.join(OUT, "homestead.png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-homestead.png"))

def apartment(px=256):
    img, d = canvas(px, px)
    shadow(d, (14, px * .88, px - 14, px - 4))
    outline_rect(d, (24, 40, px - 24, px - 24), (165, 95, 80, 255))
    outline_rect(d, (20, 32, px - 20, 44), (120, 65, 55, 255))
    outline_rect(d, (px / 2 - 28, 16, px / 2 + 28, 32), (100, 100, 110, 255))
    for row_y in (58, 104, 150):
        for col_x in (40, 92, 144, 196):
            outline_rect(d, (col_x, row_y, col_x + 28, row_y + 30), (240, 230, 150, 255), outline=(50, 40, 35, 255), w=2)
            d.line(S(col_x + 14, row_y, col_x + 14, row_y + 30), fill=(80, 60, 45, 255), width=2 * SS)
            d.line(S(col_x, row_y + 15, col_x + 28, row_y + 15), fill=(80, 60, 45, 255), width=2 * SS)
    outline_rect(d, (px / 2 - 36, px - 64, px / 2 + 36, px - 56), (60, 65, 75, 255))
    outline_rect(d, (px / 2 - 28, px - 56, px / 2 + 28, px - 24), (50, 80, 110, 255), w=2)
    d.line(S(px / 2, px - 56, px / 2, px - 24), fill=(30, 40, 50, 255), width=2 * SS)
    save(img, "apartment.png", px, px)
    Image.open(os.path.join(OUT, "apartment.png")).resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "icon-apartment.png"))

def icon_water():
    img, d = canvas(64, 64)
    d.polygon(S(14, 18, 50, 18, 44, 56, 20, 56), fill=(140, 95, 55, 255), outline=(35, 25, 20, 255), width=2 * SS)
    d.line(S(16, 30, 48, 30), fill=(100, 100, 110, 255), width=2 * SS)
    d.line(S(18, 44, 46, 44), fill=(100, 100, 110, 255), width=2 * SS)
    d.ellipse(S(14, 14, 50, 24), fill=(60, 150, 240, 255), outline=(35, 25, 20, 255), width=2 * SS)
    d.arc(S(18, 6, 46, 32), 180, 360, fill=(160, 160, 170, 255), width=2 * SS)
    save(img, "icon-water.png", 64, 64)

def icon_furniture():
    img, d = canvas(64, 64)
    outline_rect(d, (10, 30, 54, 38), (170, 115, 65, 255), w=2)
    d.line(S(16, 38, 16, 56), fill=(120, 80, 45, 255), width=3 * SS)
    d.line(S(48, 38, 48, 56), fill=(120, 80, 45, 255), width=3 * SS)
    outline_rect(d, (26, 12, 38, 30), (140, 90, 50, 255), w=2)
    d.line(S(32, 14, 32, 28), fill=(100, 65, 35, 255), width=2 * SS)
    save(img, "icon-furniture.png", 64, 64)

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
hut("hunting-lodge", (95, 110, 70, 255), (170, 145, 95, 255), em_hunt)
hut("fishing-dock", (60, 95, 120, 255), (150, 130, 95, 255), em_fish)
hut("smokehouse", (70, 65, 60, 255), (165, 140, 110, 255), em_smoke)
hut("kitchen", (180, 85, 55, 255), (205, 175, 130, 255), em_kitchen)
bush(); icon_basket(); watchtower(); farm_plots(); icon_hoe(); icon_produce(); icon_bread()
crate("supply-crate", (90, 190, 90, 255), em_out)
crate("demand-crate", (90, 150, 220, 255), em_in)
warehouse(); compost_bin(); icon_fertilizer(); boar(); icon_rifle(); icon_meat(); icon_rod(); icon_fish()
salt_pan(); icon_salt(); icon_preserved("icon-preserved-meat.png", (150, 75, 70, 255))
icon_preserved("icon-preserved-fish.png", (170, 165, 140, 255))
well(); homestead(); apartment(); icon_water(); icon_furniture()
hall(); tent(); cabin(); rack(); icon_axe(); icon_pick(); icon_forage(); colonist()
icon_building("icon-town-hall.png", "hall"); icon_building("icon-tent.png", "tent")
icon_building("icon-cabin.png", "cabin"); icon_building("icon-tool-rack.png", "rack")
print("wrote", sorted(os.listdir(OUT)))
