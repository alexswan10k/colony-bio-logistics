#!/usr/bin/env python3
"""Generate the mod's sprites and icons into mod/graphics (Pillow only; see scripts/artlib.py).

Style target: Factorio's 3/4 top-down view - light from the top-left, soft shadow to the lower right, grain,
bevelled and darkened (not black-outlined) edges, warm grimy palette. Re-run after editing:
    python3 scripts/gen_art.py [name-substring]
"""
import math
import os
import sys

from artlib import (Art, brick, combine, logs, mix, mul, planks_h, planks_v, shingle, speckle, stone, thatch, tin)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "graphics")
os.makedirs(OUT, exist_ok=True)

# palette ---------------------------------------------------------------------------------------------------
WOOD = (150, 104, 62)
WOOD_D = (104, 70, 42)
WOOD_L = (186, 140, 88)
PLANK = (170, 124, 76)
DARKWOOD = (74, 50, 32)
STONE = (136, 130, 120)
STONE_L = (190, 182, 166)
BRICK = (158, 88, 64)
IRON = (118, 122, 128)
IRON_D = (70, 74, 80)
STEEL = (196, 200, 206)
YELLOW = (226, 180, 52)
RED_ROOF = (156, 66, 46)
GLASS = (84, 112, 128)
GLASS_LIT = (238, 206, 112)
SKIN = (226, 180, 140)
GREEN = (96, 140, 68)
SOIL = (112, 78, 50)

SHADOW = "proj"          # separate projected-shadow layer (name-shadow.png, draw_as_shadow)
ICON_SHADOW = "bake"
REGISTRY = {}


def asset(fn):
    REGISTRY[fn.__name__] = fn
    return fn


def path(name):
    return os.path.join(OUT, name + ".png")


def icon_of(name, icon_name=None):
    """building icon = the sprite downsampled to 64 px"""
    from PIL import Image
    from PIL import ImageFilter
    im = Image.open(path(name)).convert("RGBA").resize((64, 64), Image.LANCZOS)
    sh = Image.new("L", (64, 64), 0); sh.paste(im.getchannel("A"), (2, 2))
    out = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    layer = Image.new("RGBA", (64, 64), (8, 6, 4, 0)); layer.putalpha(sh.filter(ImageFilter.GaussianBlur(1.4)).point(lambda v: int(v * .5)))
    out.alpha_composite(layer); out.alpha_composite(im)
    out.save(path(icon_name or "icon-" + name))


# parts -----------------------------------------------------------------------------------------------------
def door(a, x0, y0, x1, y1, col=DARKWOOD):
    a.rect(x0 - 2, y0 - 2, x1 + 2, y1, mul(col, 1.5), shade=.15)
    a.rect(x0, y0, x1, y1, col, tex=planks_v(5), shade=.25)
    a.ell(x1 - 6, (y0 + y1) / 2 - 1, x1 - 3, (y0 + y1) / 2 + 2, STEEL, edge=.3, hi=.2)


def window(a, x0, y0, x1, y1, lit=False, frame=WOOD_D):
    a.rect(x0 - 2, y0 - 2, x1 + 2, y1 + 2, frame, shade=.2)
    a.rect(x0, y0, x1, y1, GLASS_LIT if lit else GLASS, shade=.28, grain=4)
    a.glint(x0 + 1, y0 + 1, (x0 + x1) / 2, (y0 + y1) / 2, .4)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a.rect(cx - .8, y0, cx + .8, y1, frame, edge=0, hi=0, shade=0)
    a.rect(x0, cy - .8, x1, cy + .8, frame, edge=0, hi=0, shade=0)


def house(a, x0, x1, y1, wh, depth, wall, roof, wall_tex=None, roof_tex=None, ov=5, rk=.55, found=True, ridge=True):
    """gabled building seen from the front/above; returns (eave_y, ridge_y, top_y)"""
    wall_tex = wall_tex or planks_h(8)
    roof_tex = roof_tex or shingle(10, 6)
    a.rect(x0, y1 - wh, x1, y1, wall, tex=wall_tex, shade=.18)
    if found:
        a.rect(x0 - 1, y1 - 7, x1 + 1, y1, STONE, tex=stone(8), shade=.2)
    yf = y1 - wh
    rd = depth * rk
    yr = yf - rd / 2
    yt = yf - rd
    a.shade([(x0, yf), (x1, yf), (x1, yf + 9), (x0, yf + 9)], .4)                                  # eave shadow on wall
    a.poly([(x0 - ov + 4, yt), (x1 + ov - 4, yt), (x1 + ov, yr), (x0 - ov, yr)], mul(roof, 1.14), tex=roof_tex, shade=.14)
    a.poly([(x0 - ov, yr), (x1 + ov, yr), (x1 + ov, yf + 3), (x0 - ov, yf + 3)], mul(roof, .86), tex=roof_tex, shade=.2)
    if ridge:
        a.line([(x0 - ov, yr), (x1 + ov, yr)], 3, mul(roof, .62), shade=.2)
    return yf, yr, yt


def chimney(a, x, y_base, h=26, w=11, col=STONE):
    a.rect(x, y_base - h, x + w, y_base, col, tex=stone(6), shade=.2)
    a.rect(x - 2, y_base - h - 3, x + w + 2, y_base - h + 2, mul(col, .8), shade=.15)
    a.rect(x + 2, y_base - h - 1, x + w - 2, y_base - h + 1, (20, 14, 10), edge=0, hi=0, shade=0)


def smoke(a, x, y, n=3, a0=.5):
    for i in range(n):
        r = 4 + i * 2
        a.ell(x - r + i * 2, y - i * 8 - r, x + r + i * 2, y - i * 8 + r, (214, 210, 204), shade=.1, grain=0, edge=0, hi=.0, alpha=a0 - i * .12)


def plaque(a, cx, cy, w=26, h=24):
    a.rect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, WOOD_L, r=3, tex=planks_v(6), shade=.2)
    a.ell(cx - w / 2 + 1.5, cy - h / 2 + 1.5, cx - w / 2 + 3.5, cy - h / 2 + 3.5, IRON_D, edge=0, hi=0)
    a.ell(cx + w / 2 - 3.5, cy - h / 2 + 1.5, cx + w / 2 - 1.5, cy - h / 2 + 3.5, IRON_D, edge=0, hi=0)


# emblems (drawn on a plaque, radius ~10) -----------------------------------------------------------------------
def em_basket(a, cx, cy):
    a.ell(cx - 9, cy - 3, cx + 9, cy + 9, (190, 140, 66), tex=speckle(.6), shade=.25)
    a.arc(cx, cy - 1, 8, 8, 180, 360, 2, (130, 88, 44))
    for dx, dy in ((-4, -4), (1, -6), (5, -3)):
        a.ell(cx + dx - 3, cy + dy - 3, cx + dx + 3, cy + dy + 3, (190, 36, 84), shade=.3, edge=.4)


def em_log(a, cx, cy):
    for dx, dy in ((-6, 3), (6, 3), (0, -5)):
        a.ell(cx + dx - 6, cy + dy - 6, cx + dx + 6, cy + dy + 6, (138, 94, 56), shade=.2)
        a.ell(cx + dx - 3.5, cy + dy - 3.5, cx + dx + 3.5, cy + dy + 3.5, (210, 170, 112), shade=.1, edge=.3, hi=0)


def em_pick(a, cx, cy):
    a.line([(cx - 7, cy + 9), (cx + 4, cy - 7)], 3, WOOD_D)
    a.arc(cx + 1, cy + 1, 11, 9, 200, 340, 3.4, STEEL)


def em_crop(a, cx, cy):
    for dx in (-6, 0, 6):
        a.line([(cx + dx, cy + 10), (cx + dx, cy - 3)], 1.8, (96, 140, 56))
        a.ell(cx + dx - 3, cy - 9, cx + dx + 3, cy + 1, (232, 192, 64), shade=.25)


def em_hunt(a, cx, cy):
    for s in (-1, 1):
        a.line([(cx + s * 2, cy + 8), (cx + s * 5, cy), (cx + s * 8, cy - 8)], 2.2, (226, 216, 190))
        a.line([(cx + s * 5, cy), (cx + s * 10, cy - 2)], 2, (226, 216, 190))


def em_fish(a, cx, cy):
    a.ell(cx - 10, cy - 5, cx + 5, cy + 5, (120, 170, 210), shade=.25)
    a.poly([(cx + 3, cy), (cx + 11, cy - 6), (cx + 11, cy + 6)], (120, 170, 210))
    a.ell(cx - 7, cy - 2, cx - 5, cy, (20, 28, 40), edge=0, hi=0)


def em_smoke(a, cx, cy):
    a.ell(cx - 7, cy - 1, cx + 7, cy + 9, (170, 84, 64), shade=.25)
    a.line([(cx - 9, cy - 5), (cx + 9, cy - 5)], 2, WOOD_D)
    a.arc(cx, cy - 7, 4, 3, 200, 340, 1.6, (230, 230, 230))


def em_kitchen(a, cx, cy):
    a.rect(cx - 9, cy - 1, cx + 9, cy + 9, IRON, r=3, shade=.3)
    a.line([(cx - 11, cy + 1), (cx - 9, cy + 1)], 2, IRON_D)
    a.arc(cx - 3, cy - 6, 3, 4, 180, 360, 1.4, (232, 232, 240))
    a.arc(cx + 4, cy - 7, 3, 4, 180, 360, 1.4, (232, 232, 240))


# buildings -------------------------------------------------------------------------------------------------
def hut(name, roof, wall, emblem, px=128, chim=None, deco=None):
    a = Art(px, px)
    a.ao(10, 84, px - 4, px - 4, .5, 4)
    yf, yr, yt = house(a, 14, 114, 114, 28, 76, wall, roof, rk=.8)
    if chim is not None:
        chimney(a, chim, yr + 2, 20)
    door(a, 26, 94, 46, 114)
    window(a, 54, 96, 64, 106, lit=True)
    plaque(a, 90, 101, 24, 22)
    emblem(a, 90, 101)
    if deco:
        deco(a)
    a.save(path(name), shadow=SHADOW)
    icon_of(name)


@asset
def huts():
    hut("forager-hut", (84, 134, 66), (176, 142, 92), em_basket)
    hut("woodcutter-hut", (112, 76, 50), (160, 116, 72), em_log, chim=88)
    hut("miner-hut", (104, 106, 114), (146, 142, 136), em_pick)
    hut("farm-hut", (166, 130, 62), (196, 164, 108), em_crop)
    hut("hunting-lodge", (92, 108, 68), (148, 112, 74), em_hunt)
    hut("fishing-dock", (58, 96, 124), (150, 126, 92), em_fish)
    hut("smokehouse", (74, 68, 64), (150, 122, 92), em_smoke, chim=84, deco=lambda a: smoke(a, 90, 32, 3))
    hut("kitchen", (180, 88, 56), (200, 168, 124), em_kitchen, chim=86, deco=lambda a: smoke(a, 92, 32, 3, .4))


@asset
def tent():
    """ridge tent from above: ridge runs front-to-back, two canvas panels, open gable at the front"""
    a = Art(128, 128)
    a.ao(8, 70, 122, 122, .5, 5)
    canvas = (178, 158, 112)
    stitch = (90, 70, 44)
    # guy ropes + pegs behind the tent
    for (x0, y0, x1, y1) in ((30, 44, 12, 34), (98, 44, 116, 34)):
        a.line([(x0, y0), (x1, y1)], 1.2, (206, 190, 150), shade=0, hi=0, edge=.2)
        a.line([(x1, y1 - 2), (x1, y1 + 3)], 2.4, WOOD_D)
    # side panels (left lit, right shaded) meeting at the ridge
    a.poly([(64, 22), (30, 42), (20, 108), (64, 84)], canvas, tex=combine(thatch(1), speckle(.5, 40)), shade=.12, grain=9)
    a.poly([(64, 22), (98, 42), (108, 108), (64, 84)], mul(canvas, .72), tex=combine(thatch(1), speckle(.5, 50)), shade=.12, grain=9)
    # patches and stitching
    a.poly([(34, 56), (52, 48), (54, 66), (36, 72)], mul(canvas, .9), tex=speckle(.4, 30), shade=.1, edge=.3, hi=.15, ecol=stitch)
    a.poly([(76, 60), (94, 56), (96, 74), (78, 78)], mul(canvas, .62), shade=.1, edge=.3, hi=0, ecol=stitch)
    for k in range(5):
        a.line([(26 + k * 2.6, 52 + k * 11), (30 + k * 2.6, 52 + k * 11)], 1, stitch, shade=0, hi=0, edge=0)
    # ridge pole + rope ties
    a.line([(64, 20), (64, 86)], 3.2, WOOD, shade=.25)
    for y in (36, 56, 74):
        a.line([(61.5, y), (66.5, y)], 1.6, (200, 180, 130), shade=0, hi=0, edge=.3)
    # open front gable: dark interior with tied-back flaps
    a.poly([(20, 108), (108, 108), (64, 84)], (30, 24, 18), shade=.3, grain=5)
    a.poly([(30, 108), (98, 108), (64, 92)], (58, 46, 34), shade=.15, grain=5, edge=.2, hi=0)
    a.poly([(20, 108), (47, 108), (64, 84), (56, 96)], mul(canvas, 1.05), shade=.15, tex=speckle(.4, 30))
    a.poly([(108, 108), (82, 108), (64, 84), (72, 96)], mul(canvas, .8), shade=.15, tex=speckle(.4, 30))
    a.line([(64, 82), (64, 118)], 3.4, WOOD, shade=.25)                                    # front pole
    a.rect(58, 114, 70, 118, WOOD_D, shade=.2)
    for x in (18, 110):
        a.line([(x, 108), (x + (-10 if x < 64 else 10), 118)], 1.2, (206, 190, 150), shade=0, hi=0, edge=.2)
        a.line([(x + (-12 if x < 64 else 10), 116), (x + (-9 if x < 64 else 13), 121)], 2.4, WOOD_D)
    a.line([(64, 22), (64, 10)], 1.4, DARKWOOD)
    a.poly([(64, 10), (80, 14), (64, 18)], (200, 66, 48), tex=speckle(.3, 30))
    a.save(path("tent"), shadow=SHADOW)
    icon_of("tent")


@asset
def cabin():
    a = Art(192, 192)
    a.ao(10, 130, 186, 186, .5, 5)
    yf, yr, yt = house(a, 20, 172, 176, 44, 126, (150, 100, 58), (96, 70, 52), wall_tex=logs(9), roof_tex=shingle(11, 6), rk=.8)
    chimney(a, 134, yr + 2, 28, 16)
    door(a, 38, 140, 64, 176)
    window(a, 88, 144, 114, 164, lit=True)
    window(a, 130, 144, 156, 164)
    a.rect(30, 170, 74, 180, STONE_L, tex=stone(8), shade=.2)
    a.save(path("cabin"), shadow=SHADOW)
    icon_of("cabin")


@asset
def homestead():
    a = Art(192, 192)
    a.ao(8, 130, 186, 186, .5, 5)
    yf, yr, yt = house(a, 18, 174, 176, 46, 126, (200, 170, 126), (156, 58, 48), wall_tex=planks_h(8), roof_tex=shingle(10, 6), rk=.8)
    chimney(a, 142, yr + 2, 28, 16, BRICK)
    window(a, 36, 142, 62, 164, lit=True)
    window(a, 130, 142, 156, 164, lit=True)
    door(a, 80, 138, 112, 176)
    a.poly([(72, 136), (120, 136), (126, 144), (66, 144)], WOOD_D, tex=planks_h(5))
    a.rect(66, 170, 126, 182, STONE_L, tex=stone(8), shade=.2)
    a.save(path("homestead"), shadow=SHADOW)
    icon_of("homestead")


@asset
def apartment():
    a = Art(256, 256)
    a.ao(8, 190, 250, 250, .5, 6)
    a.rect(24, 112, 232, 238, (164, 92, 72), tex=brick(14, 7), shade=.16)           # front face
    a.rect(20, 20, 236, 116, (130, 124, 116), tex=speckle(1.2), shade=.2)           # flat roof, seen from above
    a.rect(20, 106, 236, 118, STONE, tex=stone(10), shade=.25)                      # cornice
    a.rect(34, 32, 82, 62, IRON, tex=tin(4), shade=.25)                             # roof units
    a.ell(150, 36, 208, 70, IRON_D, shade=.3)
    a.rect(100, 30, 128, 72, (118, 84, 60), tex=planks_v(4))                        # water tank
    a.ell(98, 22, 130, 40, (98, 70, 50), shade=.25)
    a.rect(60, 80, 104, 96, STONE_L, tex=stone(6), shade=.2)
    for ry in (128, 160, 192):
        for cx in (42, 94, 146, 196):
            window(a, cx, ry, cx + 22, ry + 20, lit=(cx + ry) % 3 != 0)
    a.rect(88, 214, 168, 222, (52, 70, 100), shade=.3)                               # awning
    door(a, 100, 222, 156, 238, (44, 64, 90))
    a.save(path("apartment"), shadow=SHADOW)
    icon_of("apartment")


@asset
def hall():
    a = Art(192, 192)
    a.ao(6, 130, 188, 188, .55, 6)
    yf, yr, yt = house(a, 14, 178, 178, 46, 130, (186, 150, 100), RED_ROOF, wall_tex=planks_h(9), roof_tex=shingle(11, 7), ov=7, rk=.8)
    chimney(a, 38, yr + 2, 30, 14)
    a.line([(96, yr), (96, yt - 24)], 3, WOOD_D)
    a.poly([(96, yt - 24), (136, yt - 16), (96, yt - 6)], (204, 62, 46), tex=speckle(.4))
    for x in (30, 140):
        window(a, x, 142, x + 22, 164, lit=True)
    a.rect(70, 132, 122, 178, DARKWOOD, shade=.25)                                   # great doors
    door(a, 76, 138, 94, 178)
    door(a, 98, 138, 116, 178)
    a.rect(60, 174, 132, 188, STONE_L, tex=stone(9), shade=.22)                      # steps
    a.glint(50, 150, 68, 168, .35, (255, 220, 140))
    a.glint(124, 150, 142, 168, .35, (255, 220, 140))
    a.ell(56, 156, 62, 162, (255, 214, 120), shade=.0, edge=0, hi=0)
    a.ell(130, 156, 136, 162, (255, 214, 120), shade=.0, edge=0, hi=0)
    a.save(path("town-hall"), shadow=SHADOW)
    icon_of("town-hall")


@asset
def town_archive():
    a = Art(192, 192)
    a.ao(10, 130, 186, 188, .5, 5)
    yf, yr, yt = house(a, 18, 174, 174, 54, 120, STONE_L, (176, 166, 150), wall_tex=stone(14), roof_tex=stone(9), ov=8, rk=.8, ridge=False)
    for cx in (32, 66, 126, 160):
        a.rect(cx - 7, yf + 2, cx + 7, 172, (230, 224, 210), shade=.3, tex=planks_v(4))
        a.rect(cx - 9, yf, cx + 9, yf + 6, (186, 178, 164))
        a.rect(cx - 9, 168, cx + 9, 176, (186, 178, 164))
    a.rect(82, 132, 110, 174, (48, 34, 24), shade=.3)
    a.line([(96, 132), (96, 174)], 1.6, (24, 16, 10))
    window(a, 40, 136, 54, 160)
    window(a, 138, 136, 152, 160)
    a.rect(24, 174, 168, 186, STONE, tex=stone(10), shade=.2)
    a.save(path("town-archive"), shadow=SHADOW)
    icon_of("town-archive")


@asset
def university():
    a = Art(256, 256)
    a.ao(8, 190, 250, 252, .5, 6)
    a.rect(88, 66, 168, 100, STONE_L, tex=stone(12), shade=.2)                              # drum
    a.ell(84, 6, 172, 92, (76, 148, 128), tex=combine(speckle(.5), tin(9)), shade=.32)       # copper dome
    a.glint(100, 14, 134, 44, .5)
    a.line([(128, 8), (128, 0)], 2.5, (214, 180, 70))
    a.rect(10, 140, 246, 236, (172, 108, 84), tex=brick(14, 7), shade=.16)                  # wings: front face
    a.rect(6, 112, 250, 146, (150, 142, 132), tex=speckle(1.0), shade=.2)                   # wings: flat roof
    a.rect(6, 138, 250, 150, STONE, tex=stone(10), shade=.25)
    yf, yr, yt = house(a, 70, 186, 236, 90, 80, (186, 130, 100), (120, 156, 140), wall_tex=brick(14, 7), roof_tex=tin(8), ov=6, rk=.8, found=False)
    for x in (24, 54, 186, 216):
        window(a, x, 158, x + 20, 180, lit=True)
        window(a, x, 196, x + 20, 218)
    for cx in (84, 108, 148, 172):
        a.rect(cx - 6, yf + 4, cx + 6, 228, (232, 226, 212), tex=planks_v(4), shade=.3)
    a.rect(110, 196, 146, 236, (52, 36, 26), shade=.3)
    a.line([(128, 196), (128, 236)], 1.8, (26, 18, 12))
    a.rect(76, 232, 180, 246, STONE_L, tex=stone(10), shade=.2)
    a.save(path("university"), shadow=SHADOW)
    icon_of("university")


@asset
def warehouse():
    a = Art(192, 192)
    a.ao(8, 130, 186, 188, .5, 5)
    yf, yr, yt = house(a, 12, 180, 178, 42, 130, (118, 104, 88), (112, 124, 134), wall_tex=planks_h(10), roof_tex=tin(6), ov=6, rk=.8)
    a.rect(60, 142, 132, 178, (82, 70, 60), tex=planks_v(7), shade=.3)
    a.rect(58, 138, 134, 146, IRON_D, shade=.3)
    for i in range(6):                                                                    # hazard stripe
        a.poly([(58 + i * 13, 170), (66 + i * 13, 170), (72 + i * 13, 178), (64 + i * 13, 178)], YELLOW if i % 2 == 0 else (40, 38, 34), edge=0, hi=0)
    for (x, y) in ((142, 152), (160, 152), (151, 138)):
        a.rect(x, y, x + 20, y + 24, (190, 146, 90), tex=planks_h(5), shade=.25)
        a.rect(x, y, x + 20, y + 4, WOOD_D, edge=.3)
    window(a, 26, 148, 46, 164)
    a.save(path("warehouse"), shadow=SHADOW)
    icon_of("warehouse")


@asset
def motor_pool():
    a = Art(192, 192)
    a.ao(8, 130, 186, 188, .5, 5)
    yf, yr, yt = house(a, 12, 180, 178, 40, 130, (128, 112, 96), (84, 88, 96), wall_tex=planks_h(10), roof_tex=tin(6), ov=6, rk=.8)
    a.rect(54, 124, 138, 178, (40, 36, 32), shade=.3)                                   # open garage bay
    for y in range(130, 176, 8):
        a.line([(56, y), (136, y)], 1.6, IRON_D, shade=.2)                              # rolled-up door slats
    a.rect(50, 174, 142, 180, YELLOW, shade=.2)                                          # bay threshold stripe
    window(a, 22, 146, 40, 162)
    a.rect(148, 146, 174, 178, (176, 62, 44), shade=.3)                                  # fuel barrel
    a.ell(148, 140, 174, 152, (200, 80, 60), shade=.2)
    a.rect(148, 154, 174, 157, IRON_D, edge=0, hi=0, shade=.1)
    a.rect(148, 168, 174, 171, IRON_D, edge=0, hi=0, shade=.1)
    a.save(path("motor-pool"), shadow=SHADOW)
    icon_of("motor-pool")


@asset
def tavern():
    """timber tavern (#48): half-timbered front, warm lit windows, a hanging sign with a mug"""
    a = Art(128, 128)
    a.ao(10, 84, 124, 124, .5, 4)
    yf, yr, yt = house(a, 14, 114, 114, 28, 76, (150, 104, 66), (126, 62, 44), wall_tex=planks_v(7), rk=.8)
    for x in (14, 40, 66, 92, 112):
        a.rect(x - 2, yf, x + 2, 114, WOOD_D, shade=.2)                                  # timber posts
    a.line([(14, yf + 12), (114, yf + 12)], 3, WOOD_D, shade=.2)                         # timber beam
    chimney(a, 86, yr + 2, 20)
    door(a, 22, 94, 40, 114)
    window(a, 50, 92, 62, 104, lit=True)
    window(a, 70, 92, 82, 104, lit=True)
    a.line([(94, 90), (112, 90)], 2, IRON_D)                                             # sign bracket
    a.line([(99, 90), (99, 96)], 1, IRON_D, hi=0)
    a.line([(107, 90), (107, 96)], 1, IRON_D, hi=0)
    a.rect(97, 96, 109, 110, WOOD_L, r=2, tex=planks_h(3), shade=.25)                    # hanging board
    a.rect(100, 99, 105, 107, (236, 180, 70), r=1, shade=.2)                             # mug body
    a.ell(99, 96, 106, 100, (250, 246, 232), shade=.15, edge=.3)                         # foam
    a.ell(104, 101, 109, 105, (236, 180, 70), shade=.2)                                  # handle
    a.save(path("tavern"), shadow=SHADOW)
    icon_of("tavern")


@asset
def passenger_platform():
    """station platform (#49) in the same 3/4 view as the houses: a raised plank deck with a stone kerb and a
    yellow edge line, a lean-to canopy over the back half (roof seen from above, posts down to the deck), a
    bench in its shade, a clock hung from the fascia and a lamp post at the open end"""
    a = Art(128, 128)
    a.ao(4, 96, 126, 126, .5, 4)
    a.rect(4, 104, 124, 120, STONE, tex=stone(9), shade=.25)                             # kerb: front face
    a.rect(4, 38, 124, 106, PLANK, tex=planks_h(6), shade=.2)                            # deck: top face
    a.rect(4, 98, 124, 104, YELLOW, edge=.2, hi=.2, shade=.15)                           # edge line
    a.shade([(4, 58), (124, 58), (124, 86), (4, 86)], .45)                               # canopy shade on the deck
    a.rect(14, 64, 114, 68, DARKWOOD, shade=.2)                                          # bench back (against the rear)
    a.rect(14, 68, 114, 76, WOOD_L, tex=planks_h(3), shade=.25)                          # bench seat
    for x in (18, 62, 106):
        a.rect(x, 76, x + 4, 82, DARKWOOD, edge=0, hi=0)                                 # bench legs
    a.rect(84, 86, 94, 96, (150, 96, 60), r=1, shade=.3)                                 # luggage
    a.rect(86, 84, 92, 86, DARKWOOD, edge=0, hi=0)
    for x in (10, 116):
        a.rect(x - 2, 56, x + 2, 86, WOOD_D, shade=.25)                                  # canopy posts
    a.poly([(0, 8), (128, 8), (128, 54), (0, 54)], (96, 112, 92), tex=tin(6), shade=.12)   # canopy roof, from above
    a.rect(0, 52, 128, 60, mul((96, 112, 92), .7), shade=.2)                             # fascia board
    a.line([(0, 8), (128, 8)], 2, mul((96, 112, 92), .6), hi=0)                          # back edge
    a.glint(6, 10, 60, 30, .25)
    a.line([(64, 60), (64, 64)], 1.4, IRON_D, hi=0)                                      # clock bracket
    a.ell(57, 63, 71, 77, (240, 236, 226), shade=.25, edge=.45)                          # clock face
    a.line([(64, 70), (64, 66)], 1, IRON_D, hi=0)
    a.line([(64, 70), (67, 71)], 1, IRON_D, hi=0)
    a.line([(110, 102), (110, 76)], 3, IRON_D, shade=.2)                                 # lamp post at the open end
    a.rect(105, 66, 115, 76, GLASS_LIT, r=1, shade=.2)
    a.rect(103, 62, 117, 67, IRON_D, shade=.2)
    a.save(path("passenger-platform"), shadow=SHADOW)
    icon_of("passenger-platform")


@asset
def passenger_coach():
    """icon only (#49): a small green passenger carriage in side view"""
    a = Art(64, 64)
    a.rect(6, 22, 58, 46, (92, 164, 92), r=3, tex=speckle(.5, 30), shade=.3)              # body
    a.rect(4, 14, 60, 23, (56, 108, 58), r=2, shade=.25)                                  # roof
    a.rect(6, 38, 58, 41, (230, 212, 130), shade=.2)                                      # stripe
    for x in (12, 26, 40):
        window(a, x, 26, x + 9, 35, lit=True)
    a.ell(10, 42, 22, 54, IRON_D, shade=.3)                                                # wheels
    a.ell(42, 42, 54, 54, IRON_D, shade=.3)
    done(a, "icon-passenger-coach")


@asset
def cemetery():
    """walled graveyard (#53) in the same 3/4 view: a grassy plot, a stone wall that shows its front face along
    the bottom edge, a gate gap in the front wall between two pillars, two rows of headstones and a wooden cross"""
    GRASS_D = (84, 118, 60)
    EARTH = (142, 116, 84)
    a = Art(128, 128)
    a.ao(6, 102, 122, 128, .5, 4)
    a.rect(16, 34, 112, 108, GRASS_D, tex=speckle(1.2, 50), shade=.2)                  # plot, top face
    a.rect(56, 62, 72, 108, (176, 166, 146), tex=speckle(1.4, 40), shade=.12, edge=.2, hi=0)   # gravel path from the gate
    a.rect(6, 24, 122, 34, STONE_L, tex=stone(9), shade=.1)                              # back wall: top cap
    a.rect(6, 34, 122, 42, STONE, tex=stone(9), shade=.3)                                # back wall: face
    for x0, x1 in ((6, 16), (112, 122)):
        a.rect(x0, 34, x1, 108, STONE, tex=stone(9), shade=.3)                           # side walls
        a.rect(x0, 34, x1, 38, STONE_L, shade=.1)                                        # side tops
    for x0, x1 in ((6, 52), (76, 122)):
        a.rect(x0, 104, x1, 110, STONE_L, shade=.1)                                      # front wall: top cap
        a.rect(x0, 110, x1, 122, STONE, tex=stone(9), shade=.3)                          # front wall: face
    for x0 in (50, 74):
        a.rect(x0, 100, x0 + 8, 124, STONE_L, tex=stone(9), shade=.2)                    # gate pillars
        a.rect(x0 - 1, 98, x0 + 9, 102, STONE_L, shade=.1)
    for (x, y) in ((26, 58), (46, 58), (82, 58), (102, 58), (26, 84), (46, 84), (82, 84), (102, 84)):
        a.ell(x - 7, y + 5, x + 7, y + 15, EARTH, shade=.3, grain=8)                    # grave mound
        a.shade([(x - 5, y + 6), (x + 9, y + 6), (x + 12, y + 9), (x - 2, y + 9)], .3)   # shadow lower right
        a.rect(x - 5, y - 2, x + 5, y + 6, (168, 164, 158), shade=.25)                  # stone body
        a.ell(x - 5, y - 9, x + 5, y + 1, (182, 178, 172), shade=.25)                    # rounded top
        a.rect(x - 5, y + 3, x + 5, y + 6, (112, 108, 102), shade=0, edge=0, hi=0)      # front face
    a.ell(56, 54, 72, 64, EARTH, shade=.3, grain=8)                                      # wooden cross at the head of the path
    a.line([(64, 36), (64, 60)], 4, WOOD_D, shade=.2)
    a.line([(56, 44), (72, 44)], 4, WOOD_D, shade=.2)
    a.save(path("cemetery"), shadow=SHADOW)
    icon_of("cemetery")


@asset
def grave():
    """single grave (#53): a grey headstone with a low mound of earth in front, same 3/4 view"""
    a = Art(64, 64)
    a.ao(14, 42, 52, 54, .5, 3)
    a.shade([(26, 42), (44, 42), (48, 46), (30, 46)], .3)                                # shadow lower right
    a.rect(24, 24, 40, 40, (168, 164, 158), shade=.25)                                   # stone body
    a.ell(24, 15, 40, 31, (182, 178, 172), shade=.25)                                    # rounded top
    a.rect(24, 36, 40, 40, (112, 108, 102), shade=0, edge=0, hi=0)                       # front face
    a.ell(15, 36, 49, 52, (142, 116, 84), shade=.3, grain=8)                             # mound of earth
    a.save(path("grave"), shadow=SHADOW)
    icon_of("grave")


@asset
def watchtower():
    a = Art(128, 128)
    a.ao(12, 98, 122, 126, .55, 5)
    for x1, x2 in ((34, 28), (94, 100)):                                                  # rear + front legs
        a.line([(x1, 62), (x2, 112)], 5, WOOD_D)
    a.line([(36, 66), (92, 104)], 2.6, WOOD)                                              # cross braces
    a.line([(92, 66), (36, 104)], 2.6, WOOD)
    a.rect(26, 56, 102, 72, PLANK, tex=planks_h(5), shade=.25)                           # platform
    a.rect(24, 66, 104, 74, WOOD_D, shade=.25)
    for x in range(30, 100, 14):
        a.line([(x, 66), (x, 46)], 2.6, WOOD)
    a.rect(26, 44, 102, 49, WOOD, shade=.2)
    a.poly([(22, 46), (64, 12), (106, 46)], (120, 78, 58), tex=shingle(8, 5), shade=.2)    # roof
    a.poly([(22, 46), (64, 12), (64, 46)], (140, 92, 66), tex=shingle(8, 5), shade=.16)
    a.line([(64, 14), (64, 2)], 2.4, DARKWOOD)
    a.poly([(64, 2), (84, 7), (64, 12)], (214, 62, 46))
    a.line([(30, 74), (26, 112)], 5, WOOD_D)                                              # front legs (over braces)
    a.line([(98, 74), (102, 112)], 5, WOOD_D)
    a.rect(40, 100, 60, 112, STONE, tex=stone(6))
    a.save(path("watchtower"), shadow=SHADOW)
    icon_of("watchtower")


@asset
def crates():
    def crate(name, band, arrow):
        a = Art(128, 128)
        a.ao(12, 84, 118, 124, .5, 4)
        a.rect(18, 84, 110, 112, PLANK, tex=planks_h(7), shade=.2)                       # front face
        a.line([(22, 108), (106, 80)], 4, WOOD_D)
        a.rect(18, 84, 28, 112, WOOD_D, shade=.25)
        a.rect(100, 84, 110, 112, WOOD_D, shade=.25)
        a.rect(18, 30, 110, 84, WOOD_L, tex=planks_v(8), shade=.18)                      # lid
        a.rect(18, 30, 110, 38, WOOD_D, shade=.2)                                        # frame
        a.rect(18, 76, 110, 84, WOOD_D, shade=.2)
        a.rect(18, 30, 26, 84, WOOD_D, shade=.2)
        a.rect(102, 30, 110, 84, WOOD_D, shade=.2)
        for x, y in ((20, 32), (100, 32), (20, 76), (100, 76), (20, 102), (100, 102)):
            a.rect(x, y, x + 8, y + 8, IRON, shade=.3, tex=speckle(.5))
        a.rect(32, 46, 96, 66, band, r=2, shade=.25, tex=speckle(.5, 30))               # painted band
        arrow(a)
        a.save(path(name), shadow=SHADOW)
        icon_of(name)

    def up(a):
        a.poly([(64, 48), (80, 58), (70, 58), (70, 64), (58, 64), (58, 58), (48, 58)], (236, 250, 230), edge=.4, shade=.1)

    def down(a):
        a.poly([(64, 64), (80, 54), (70, 54), (70, 48), (58, 48), (58, 54), (48, 54)], (230, 242, 252), edge=.4, shade=.1)

    crate("supply-crate", (74, 150, 70), up)
    crate("demand-crate", (66, 112, 176), down)


@asset
def compost_bin():
    a = Art(128, 128)
    a.ao(10, 84, 120, 124, .5, 4)
    a.rect(20, 52, 108, 86, (124, 96, 64), tex=planks_h(6), shade=.2)                   # back wall
    a.ell(22, 40, 106, 84, (62, 44, 30), tex=speckle(2.2, 90), shade=.3, grain=12)        # heap
    a.glint(40, 48, 70, 62, .22, (140, 190, 90))
    a.line([(64, 52), (64, 32)], 2.6, (68, 124, 56))
    a.ell(48, 24, 64, 38, (96, 168, 84), shade=.3)
    a.ell(64, 22, 82, 36, (110, 184, 96), shade=.3)
    a.rect(20, 82, 108, 114, (150, 114, 74), tex=planks_h(6), shade=.2)                 # front slats
    for x in (20, 98):
        a.rect(x, 50, x + 10, 114, WOOD_D, shade=.25)
    a.rect(20, 82, 108, 88, WOOD_D, shade=.2)
    a.save(path("compost-bin"), shadow=SHADOW)
    icon_of("compost-bin")


@asset
def well():
    a = Art(64, 64)
    a.ao(6, 44, 60, 62, .55, 3)
    a.rect(8, 36, 56, 54, (136, 132, 124), tex=stone(7), shade=.22)
    a.ell(8, 24, 56, 48, (150, 146, 136), tex=stone(7), shade=.18)
    a.ell(14, 28, 50, 44, (52, 120, 190), shade=.4, grain=5)
    a.glint(18, 30, 32, 37, .5)
    for x in (13, 51):
        a.line([(x, 42), (x, 12)], 3, WOOD_D)
    a.poly([(5, 17), (32, 4), (59, 17)], (120, 80, 56), tex=shingle(6, 4), shade=.2)
    a.line([(32, 16), (32, 30)], 1, (200, 190, 160), shade=0)
    a.rect(28, 28, 36, 35, WOOD, r=1)
    a.save(path("well"), shadow=SHADOW)
    icon_of("well")


@asset
def salt_pan():
    a = Art(128, 128)
    a.ao(10, 84, 120, 124, .5, 4)
    a.rect(14, 38, 114, 98, (126, 118, 106), tex=stone(10), shade=.2)                    # rim, top face
    a.rect(14, 96, 114, 114, (108, 100, 90), tex=stone(9), shade=.25)                    # rim, front face
    a.rect(22, 46, 106, 90, (92, 138, 168), shade=.35, grain=5, tex=speckle(.4, 25))     # brine
    for (x, y, w, h) in ((30, 62, 22, 14), (62, 54, 20, 12), (72, 72, 26, 14), (40, 78, 16, 8), (84, 52, 14, 8)):
        a.ell(x, y, x + w, y + h, (240, 240, 234), tex=speckle(.8, 40), shade=.2, edge=.35)
    a.glint(26, 48, 58, 58, .4)
    a.save(path("salt-pan"), shadow=SHADOW)
    icon_of("salt-pan")


@asset
def tool_rack():
    a = Art(64, 64)
    a.ao(4, 44, 62, 62, .5, 3)
    a.rect(8, 20, 56, 52, (132, 96, 60), tex=planks_h(5), shade=.2)
    a.rect(6, 14, 58, 22, WOOD, shade=.2)
    for x in (6, 52):
        a.rect(x, 14, x + 6, 56, WOOD_D, shade=.25)
    a.line([(20, 24), (26, 46)], 3, WOOD_D)
    a.poly([(14, 24), (28, 20), (30, 30), (18, 32)], STEEL, shade=.3)
    a.line([(42, 24), (40, 48)], 3, WOOD_D)
    a.arc(40, 30, 10, 8, 190, 350, 3, STEEL)
    a.save(path("tool-rack"), shadow=SHADOW)
    icon_of("tool-rack")


@asset
def farm_plots():
    def soil(a, wet=1.0):
        a.rect(2, 2, 62, 62, mul(SOIL, wet), tex=combine(speckle(1.4, 70)), shade=.12, grain=10, edge=.6)
        for y in (13, 25, 37, 49):
            a.rect(5, y, 59, y + 6, mul(SOIL, .72), r=3, shade=.25, edge=.2, hi=.25, grain=6)

    def plot(name, plants):
        a = Art(64, 64)
        soil(a)
        plants(a)
        a.save(path(name), shadow=None)

    def none(a):
        pass

    def grow(a):
        for (x, y) in ((14, 18), (32, 16), (50, 20), (18, 34), (38, 36), (54, 32), (14, 52), (34, 50), (52, 52)):
            a.line([(x, y + 6), (x, y)], 1.6, (92, 150, 60))
            a.ell(x - 4, y - 4, x + 1, y, (116, 184, 76), shade=.25)
            a.ell(x, y - 5, x + 5, y - 1, (132, 196, 86), shade=.25)

    def ripe(a):
        for (x, y) in ((14, 18), (32, 16), (50, 20), (18, 34), (38, 36), (54, 32), (14, 52), (34, 50), (52, 52)):
            a.line([(x, y + 9), (x, y - 2)], 2, (164, 168, 60))
            a.ell(x - 4, y - 8, x + 4, y + 3, (236, 196, 64), shade=.3, tex=speckle(.5, 40))
            a.line([(x - 5, y - 5), (x - 2, y - 1)], 1, (240, 214, 120), edge=0, hi=0)

    plot("farm-plot-fallow", none)
    plot("farm-plot-growing", grow)
    plot("farm-plot-ripe", ripe)


@asset
def bush():
    a = Art(64, 64)
    a.ao(8, 38, 58, 60, .55, 3)
    for (x, y, r) in ((20, 38, 15), (42, 38, 15), (31, 28, 16), (31, 42, 14)):
        a.ell(x - r, y - r, x + r, y + r, (62, 128, 56), tex=speckle(1.2, 70), shade=.3, grain=10)
    for (x, y) in ((22, 36), (40, 30), (32, 44), (30, 26), (44, 42), (18, 44)):
        a.ell(x - 3.5, y - 3.5, x + 3.5, y + 3.5, (206, 44, 96), shade=.3, edge=.45)
        a.ell(x - 2, y - 2.5, x, y - .5, (255, 190, 210), edge=0, hi=0, shade=0, alpha=.8)
    a.save(path("bush"), shadow=SHADOW)


@asset
def colonist():
    def figure(a, ox, sw, bob):
        a.ao(ox + 16, 50, ox + 48, 61, .6, 2)
        a.line([(ox + 27, 40 + bob), (ox + 27, 49 + sw)], 6, (62, 66, 80))
        a.line([(ox + 37, 40 + bob), (ox + 37, 49 - sw)], 6, (62, 66, 80))
        a.ell(ox + 23, 47 + sw, ox + 31, 55 + sw, (90, 62, 40), shade=.3)
        a.ell(ox + 33, 47 - sw, ox + 41, 55 - sw, (90, 62, 40), shade=.3)
        a.line([(ox + 21, 29 + bob), (ox + 18, 38 + bob - sw)], 5, (96, 112, 70))              # arms
        a.line([(ox + 43, 29 + bob), (ox + 46, 38 + bob + sw)], 5, (96, 112, 70))
        a.ell(ox + 15.5, 36 + bob - sw, ox + 21, 41 + bob - sw, SKIN, shade=.2)
        a.ell(ox + 43, 36 + bob + sw, ox + 48.5, 41 + bob + sw, SKIN, shade=.2)
        a.rect(ox + 21, 24 + bob, ox + 43, 45 + bob, (100, 118, 72), r=4, tex=thatch(1), shade=.25)  # jacket
        a.rect(ox + 21, 40 + bob, ox + 43, 44 + bob, (74, 52, 34), edge=.3, hi=0)                      # belt
        a.line([(ox + 26, 25 + bob), (ox + 26, 43 + bob)], 2.4, (176, 132, 70))                       # straps
        a.line([(ox + 38, 25 + bob), (ox + 38, 43 + bob)], 2.4, (176, 132, 70))
        a.ell(ox + 24, 9 + bob, ox + 40, 28 + bob, SKIN, shade=.2)                                     # head
        a.ell(ox + 28.5, 19 + bob, ox + 30.5, 21 + bob, (30, 22, 18), edge=0, hi=0)
        a.ell(ox + 33.5, 19 + bob, ox + 35.5, 21 + bob, (30, 22, 18), edge=0, hi=0)
        a.ell(ox + 19, 9 + bob, ox + 45, 22 + bob, (120, 84, 48), shade=.3, tex=speckle(.5, 40))      # hat brim
        a.ell(ox + 25, 3 + bob, ox + 39, 16 + bob, (146, 104, 60), shade=.3)                           # crown

    a = Art(64, 64)
    figure(a, 0, 0, 0)
    a.save(path("colonist"), shadow=SHADOW)
    sheet = Art(64 * 8, 64)                                                                             # run cycle, 8 frames
    for i in range(8):
        ph = math.sin(i / 8 * math.tau)
        figure(sheet, i * 64, int(round(ph * 5)), -abs(ph) * 1.6)
    sheet.save(path("colonist-run"), shadow=SHADOW, frames=8)


@asset
def boar():
    a = Art(64, 64)
    a.ao(6, 44, 60, 62, .6, 3)
    for x in (14, 22, 36, 44):
        a.line([(x, 38), (x + (1 if x % 2 else -1), 52)], 4.4, (66, 50, 40))
        a.ell(x - 3, 50, x + 3, 55, (30, 24, 20), shade=.2)
    a.poly([(10, 34), (14, 22), (22, 16), (34, 15), (44, 20), (48, 30), (46, 44), (34, 48), (18, 46)], (98, 80, 64), tex=combine(speckle(2.2, 80), thatch(1)), shade=.3, grain=10)
    a.line([(16, 20), (24, 15), (34, 14), (42, 18)], 3, (50, 38, 30), hi=0)                         # bristle ridge
    a.line([(10, 30), (6, 26), (8, 22)], 1.6, (74, 56, 46), hi=0)                                  # tail
    a.ell(42, 22, 60, 44, (116, 92, 72), tex=speckle(1.6, 70), shade=.3, grain=10)                  # head
    a.ell(54, 30, 63, 40, (176, 130, 120), shade=.3)                                                # snout
    a.poly([(52, 41), (56, 49), (50, 43)], (236, 230, 210), edge=.4, hi=0)                          # tusk
    a.poly([(44, 22), (47, 12), (52, 22)], (80, 62, 50), shade=.2)                                  # ear
    a.ell(50, 27, 53, 30, (16, 12, 10), edge=0, hi=0)
    a.save(path("boar"), shadow=SHADOW)
    icon_of("boar")


# icons -----------------------------------------------------------------------------------------------------
def icon(name):
    a = Art(64, 64)
    return a


def done(a, name):
    a.save(path(name), shadow=ICON_SHADOW)


@asset
def icons_tools():
    a = Art(64, 64)                                                                                     # axe
    a.line([(14, 56), (42, 14)], 6, WOOD, shade=.25)
    a.poly([(30, 8), (56, 12), (52, 36), (42, 24)], STEEL, shade=.3, tex=speckle(.5, 40))
    done(a, "icon-axe")
    a = Art(64, 64)                                                                                     # pickaxe
    a.line([(14, 56), (40, 12)], 6, WOOD, shade=.25)
    a.arc(34, 30, 24, 22, 205, 335, 7, STEEL, shade=.3)
    done(a, "icon-pickaxe")
    a = Art(64, 64)                                                                                     # hoe
    a.line([(16, 56), (42, 18)], 5, WOOD, shade=.25)
    a.poly([(36, 14), (56, 20), (52, 36), (44, 28), (34, 24)], STEEL, shade=.3)
    done(a, "icon-hoe")
    a = Art(64, 64)                                                                                     # rifle
    a.line([(8, 52), (30, 36)], 9, WOOD, shade=.25)
    a.line([(26, 40), (58, 18)], 5, IRON_D, shade=.3)
    a.line([(30, 36), (36, 46)], 3, IRON_D)
    a.line([(40, 30), (46, 24)], 4, STEEL, shade=.3)
    done(a, "icon-rifle")
    a = Art(64, 64)                                                                                     # fishing rod
    a.line([(12, 56), (54, 10)], 4, (170, 124, 66), shade=.25)
    a.line([(54, 10), (54, 40)], 1.4, (224, 224, 230), shade=0, hi=0, edge=.2)
    a.ell(50, 40, 58, 48, (206, 60, 50), shade=.3)
    a.rect(16, 44, 26, 54, IRON_D, r=2, shade=.3)
    done(a, "icon-rod")


@asset
def icons_food():
    a = Art(64, 64)                                                                                     # forage
    for (x, y, c) in ((22, 40, (176, 36, 88)), (40, 44, (206, 58, 110)), (30, 28, (156, 28, 80)), (46, 30, (214, 72, 122))):
        a.ell(x - 10, y - 10, x + 10, y + 10, c, shade=.35, edge=.55)
        a.ell(x - 6, y - 7, x - 2, y - 3, (255, 214, 226), shade=0, edge=0, hi=0, alpha=.8)
    a.poly([(30, 16), (40, 6), (44, 18), (36, 20)], (84, 158, 66), shade=.3)
    done(a, "icon-forage")
    a = Art(64, 64)                                                                                     # meat
    a.ell(10, 16, 50, 52, (176, 62, 62), tex=speckle(.6, 40), shade=.35)
    a.ell(20, 26, 40, 42, (222, 116, 106), shade=.3, edge=.3)
    a.line([(44, 14), (58, 22)], 5, (240, 234, 214), shade=.2)
    a.ell(54, 16, 62, 26, (240, 234, 214), shade=.2)
    done(a, "icon-meat")
    a = Art(64, 64)                                                                                     # fish
    a.ell(8, 18, 48, 46, (140, 182, 216), shade=.35, tex=speckle(.5, 30))
    a.poly([(44, 22), (60, 32), (44, 42)], (116, 160, 200), shade=.3)
    a.line([(16, 20), (36, 16)], 3, (84, 116, 156), hi=0)
    a.ell(14, 28, 20, 34, (22, 28, 38), edge=0, hi=0)
    a.glint(14, 20, 34, 28, .4)
    done(a, "icon-fish")
    a = Art(64, 64)                                                                                     # bread
    a.ell(8, 20, 56, 50, (204, 138, 68), shade=.32, tex=speckle(.6, 40))
    for x in (20, 31, 42):
        a.line([(x - 3, 26), (x + 3, 42)], 3, (238, 192, 122), hi=0, edge=.3)
    a.glint(14, 22, 36, 32, .3)
    done(a, "icon-bread")
    a = Art(64, 64)                                                                                     # ale (foamy mug)
    a.line([(42, 30), (52, 30), (52, 46), (42, 46)], 4, (206, 142, 46), shade=.3)
    a.rect(12, 22, 42, 56, (206, 142, 46), r=3, shade=.32, tex=speckle(.5, 30))
    a.ell(10, 12, 44, 26, (246, 240, 222), shade=.2, edge=.3)
    a.glint(16, 30, 24, 50, .35)
    done(a, "icon-ale")
    a = Art(64, 64)                                                                                     # produce
    a.poly([(32, 14), (52, 30), (44, 56), (20, 56), (12, 30)], (226, 132, 48), shade=.32)
    for y in (28, 36, 44):
        a.line([(20, y), (44, y)], 1.6, (180, 96, 30), hi=0)
    a.poly([(32, 14), (24, 4), (40, 8)], (90, 160, 70), shade=.3)
    a.glint(18, 22, 30, 34, .35)
    done(a, "icon-produce")
    a = Art(64, 64)                                                                                     # salt
    for (x, y) in ((16, 30), (30, 22), (44, 30), (22, 42), (38, 42), (30, 33)):
        a.rect(x - 2, y - 2, x + 11, y + 10, (240, 240, 236), shade=.22, edge=.45, tex=speckle(.5, 30))
    done(a, "icon-salt")
    for nm, col in (("icon-preserved-meat", (150, 72, 66)), ("icon-preserved-fish", (170, 168, 140))):
        a = Art(64, 64)
        a.ell(10, 20, 50, 48, col, shade=.35, tex=speckle(.6, 40))
        a.line([(14, 22), (46, 46)], 2.4, (240, 234, 216), hi=0, edge=.3)
        a.line([(14, 46), (46, 22)], 2.4, (240, 234, 216), hi=0, edge=.3)
        a.line([(30, 10), (30, 22)], 1.6, (210, 200, 170), hi=0, edge=.2)
        done(a, nm)


@asset
def icons_misc():
    a = Art(64, 64)                                                                                     # basket
    a.arc(32, 30, 20, 20, 180, 360, 4, (130, 90, 46))
    a.poly([(8, 30), (56, 30), (48, 56), (16, 56)], (198, 148, 70), tex=combine(planks_h(4), speckle(.5)), shade=.3)
    done(a, "icon-basket")
    a = Art(64, 64)                                                                                     # fertilizer sack
    a.poly([(18, 20), (46, 20), (54, 56), (10, 56)], (196, 174, 122), tex=speckle(1, 40), shade=.3)
    a.rect(18, 14, 46, 24, (170, 148, 100), shade=.25)
    a.ell(24, 30, 40, 48, (92, 164, 80), shade=.3)
    a.line([(32, 38), (32, 50)], 2, (34, 80, 34), hi=0)
    done(a, "icon-fertilizer")
    a = Art(64, 64)                                                                                     # water bucket
    a.poly([(12, 20), (52, 20), (46, 58), (18, 58)], (142, 96, 54), tex=planks_v(6), shade=.3)
    a.line([(15, 34), (49, 34)], 3, IRON, hi=0)
    a.line([(17, 48), (47, 48)], 3, IRON, hi=0)
    a.ell(12, 14, 52, 28, (58, 150, 238), shade=.4)
    a.glint(18, 16, 34, 22, .5)
    a.arc(32, 22, 20, 20, 190, 350, 2, (170, 170, 180))
    done(a, "icon-water")
    a = Art(64, 64)                                                                                     # furniture
    a.rect(8, 28, 56, 38, (172, 118, 66), tex=planks_h(5), shade=.3)
    a.line([(14, 38), (14, 58)], 4, WOOD_D)
    a.line([(50, 38), (50, 58)], 4, WOOD_D)
    a.rect(24, 8, 40, 30, (142, 92, 50), r=2, tex=planks_v(5), shade=.3)
    done(a, "icon-furniture")
    a = Art(64, 64)                                                                                     # frontier pack (scroll + seal)
    a.poly([(12, 14), (52, 14), (48, 50), (8, 50)], (236, 220, 178), tex=combine(speckle(.5, 25)), shade=.25)
    for y in (24, 32, 40):
        a.line([(14, y), (44, y)], 1.6, (150, 130, 100), hi=0)
    a.ell(34, 36, 52, 54, (190, 38, 34), shade=.35, edge=.55)
    a.ell(38, 40, 48, 50, (222, 70, 58), shade=.2, edge=.3)
    done(a, "icon-frontier-pack")
    a = Art(64, 64)                                                                                     # civic pack (bound treatise)
    a.poly([(12, 12), (48, 8), (56, 50), (18, 56)], (44, 70, 124), shade=.3, tex=speckle(.5, 40))
    a.poly([(18, 56), (56, 50), (54, 54), (16, 60)], (226, 214, 188), shade=.15, edge=.4)
    a.line([(18, 12), (24, 54)], 3, (216, 176, 62), hi=0)
    a.ell(28, 24, 44, 40, (216, 176, 62), shade=.3, edge=.45)
    done(a, "icon-civic-pack")


@asset
def radius_rings():
    """Range rings for `radius_visualisation_specification` (the engine stretches the sprite to the radius):
    a thin bright ring plus a barely-there fill so the terrain underneath stays readable."""
    from PIL import Image, ImageDraw
    N, K = 512, 4
    for name, col in (("radius-green", (96, 214, 110)), ("radius-yellow", (236, 214, 90))):
        im = Image.new("RGBA", (N * K, N * K), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        d.ellipse((0, 0, N * K - 1, N * K - 1), fill=col + (16,))
        d.ellipse((0, 0, N * K - 1, N * K - 1), outline=col + (200,), width=3 * K)
        im.resize((N, N), Image.LANCZOS).save(path(name))


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    for name, fn in REGISTRY.items():
        if only in name:
            fn()
    print("wrote", len(os.listdir(OUT)), "files in", OUT)


if __name__ == "__main__":
    main()
