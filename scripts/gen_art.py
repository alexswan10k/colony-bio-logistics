#!/usr/bin/env python3
"""Generate the mod's sprites and icons into mod/graphics (Pillow only; see scripts/artlib.py).

Style target: Factorio's 3/4 top-down view - light from the top-left, soft shadow to the lower right, grain,
bevelled and darkened (not black-outlined) edges, warm grimy palette. Re-run after editing:
    python3 scripts/gen_art.py [name-substring]
"""
import math
import os
import sys

from artlib import (Art, View, FZ, brick, combine, logs, mix, mul, planks_h, planks_v, shingle, shingle_p,
                    speckle, stone, thatch, thatch_p, tin, weave)

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
HAY = (206, 174, 86)
PLASTER = (214, 202, 178)
WHITE = (236, 232, 220)
SLATE = (88, 100, 110)
THATCH = (176, 152, 92)
COPPER = (76, 148, 128)
ORE = (122, 92, 74)

SHADOW = "proj"          # separate projected-shadow layer (name-shadow.png, draw_as_shadow)
ICON_SHADOW = "bake"
REGISTRY = {}


def asset(fn):
    REGISTRY[fn.__name__] = fn
    return fn


def path(name):
    return os.path.join(OUT, name + ".png")


def icon_of(name, icon_name=None):
    """building icon: crop the sprite to its ink and fit it to the slot, so a 3x3/4x4 building is not a
    tiny speck in the crafting grid"""
    from PIL import Image
    from PIL import ImageFilter
    im = Image.open(path(name)).convert("RGBA")
    bb = im.getbbox()
    if bb:
        im = im.crop(bb)
    k = min(58.0 / max(1, im.width), 58.0 / max(1, im.height))
    im = im.resize((max(1, int(im.width * k)), max(1, int(im.height * k))), Image.LANCZOS)
    x, y = (64 - im.width) // 2, (64 - im.height) // 2
    sh = Image.new("L", (64, 64), 0); sh.paste(im.getchannel("A"), (x + 1, y + 2))
    out = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    layer = Image.new("RGBA", (64, 64), (8, 6, 4, 0)); layer.putalpha(sh.filter(ImageFilter.GaussianBlur(1.2)).point(lambda v: int(v * .5)))
    out.alpha_composite(layer); out.alpha_composite(im, (x, y))
    out.save(path(icon_name or "icon-" + name))


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


def em_frost(a, cx, cy):
    """a six-spoked snowflake badge for cold-chain buildings"""
    import math
    col = (204, 232, 250)
    for deg in (0, 60, 120):
        dx, dy = math.cos(deg * math.pi / 180), math.sin(deg * math.pi / 180)
        a.line([(cx - dx * 13, cy - dy * 13), (cx + dx * 13, cy + dy * 13)], 2.4, col)
        for end in (-0.62, -0.88, 0.62, 0.88):
            ex, ey = cx + dx * 13 * end, cy + dy * 13 * end
            tx, ty = -dy * 4.2, dx * 4.2
            a.line([(ex - tx, ey - ty), (ex + tx, ey + ty)], 1.8, col)


def em_can(a, cx, cy):
    """a sealed tin can: the emblem of the cannery"""
    col = (176, 188, 198)
    dark = (120, 132, 142)
    a.ell(cx - 9, cy - 11, cx + 9, cy, col, shade=.28)
    a.rect(cx - 9, cy - 5, cx + 9, cy + 9, col, shade=.22)
    a.ell(cx - 9, cy + 4, cx + 9, cy + 9, col, shade=.34)
    a.ell(cx - 6, cy - 7, cx + 6, cy - 3, dark, shade=.35)

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


def em_mug(a, cx, cy):
    a.rect(cx - 6, cy - 4, cx + 4, cy + 8, (236, 180, 70), r=1, shade=.2)
    a.ell(cx - 6, cy - 6, cx + 4, cy - 1, (250, 246, 232), shade=.15, edge=.3)
    a.arc(cx + 6, cy + 2, 4, 4, 270, 90, 2, (236, 180, 70))


def em_sapling(a, cx, cy):
    """Forester's Hut (#97): a young tree, stem and three leaves."""
    a.line([(cx, cy + 9), (cx, cy - 3)], 2.2, (124, 88, 52))
    a.ell(cx - 9, cy - 3, cx + 1, cy + 5, (92, 150, 68), shade=.28, edge=.4)
    a.ell(cx - 1, cy - 3, cx + 9, cy + 5, (104, 160, 76), shade=.28, edge=.4)
    a.ell(cx - 5, cy - 11, cx + 5, cy - 1, (116, 172, 84), shade=.25, edge=.4)
    a.ell(cx - 9, cy + 1, cx - 4, cy + 9, (78, 62, 44), shade=.2)   # soil, half-buried root ball


# buildings -------------------------------------------------------------------------------------------------
# Every building is drawn in a real 3/4 top-down projection (artlib.View): the ground footprint is a
# screen-aligned square, height is foreshortened (1 tile high = 16 screen px at scale 0.5), and a slight
# one-point perspective narrows the back edge so roofs are trapezoids and the side walls show.  The sprite
# canvas is taller than the footprint and the prototype shift (art_manifest.lua) keeps the footprint on the
# entity box, so tall buildings stand *up* instead of being squashed into a flat facade.
BUILDINGS = {}


def register(name, width, height, scale=.5, shift=(0.0, 0.0)):
    BUILDINGS[name] = {"width": width, "height": height, "scale": scale, "shift": shift}


def building(wt, dt, pad=18, top=110, bottom=12, persp=.18):
    a = Art(wt * 64 + 2 * pad, dt * 64 + top + bottom)
    return a, View(a, wt, dt, pad=pad, bottom=bottom, persp=persp)


def finish(a, b, name, wt, dt, icon=True):
    fp = wt * 64
    shift_y = -(a.h / 2 - b.bottom - fp / 2) * .5 / 32
    register(name, a.w, a.h, .5, (0.0, round(shift_y, 6)))
    a.save(path(name), shadow=SHADOW, ground=b.base)
    if icon:
        icon_of(name)


def site(b, inset=.12, front=.12):
    m = inset * 64
    return m, m, b.W - m, b.D - front * 64


# ---- shared parts -----------------------------------------------------------------------------------------
def plinth(b, x0, y0, x1, y1, z0=0, z1=.18, col=STONE):
    b.box(x0 - 3, y0 - 3, x1 + 3, y1 + 3, z0, z1, col, top=mul(col, .86), top_tex=stone(9))


def walls(b, x0, y0, x1, y1, wh, wall, tex=None, z0=.18, lit=.94, shade=.68):
    b.face([(x0, y1, z0), (x0, y0, z0), (x0, y0, wh), (x0, y1, wh)], mul(wall, lit), tex=tex)
    b.face([(x1, y0, z0), (x1, y1, z0), (x1, y1, wh), (x1, y0, wh)], mul(wall, shade), tex=tex)
    b.face([(x0, y1, z0), (x1, y1, z0), (x1, y1, wh), (x0, y1, wh)], wall, tex=tex)
    # corner boards and a top plate: they give the flat front a frame and a sense of thickness
    for x in (x0, x1 - 2):
        b.face([(x, y1, z0), (x + 2, y1, z0), (x + 2, y1, wh), (x, y1, wh)], mul(wall, .52))
    b.face([(x0, y1, wh - .1), (x1, y1, wh - .1), (x1, y1, wh), (x0, y1, wh)], mul(wall, .58))


def dormer(a, b, x, y, z, w=18, d=12, h=.55, wall=WHITE, roof=RED_ROOF):
    """a small gabled window box breaking the front roof slope"""
    b.box(x - w / 2, y - d / 2, x + w / 2, y + d / 2, z, z + h, wall,
          top=mul(wall, 1.02), top_tex=planks_h(4))
    b.face([(x - w / 2 - 3, y + d / 2, z + h), (x + w / 2 + 3, y + d / 2, z + h), (x, y + d / 2, z + h + .35)],
           mul(roof, 1.02), tex=shingle_p(6, 4))
    b.face([(x - w / 2 - 3, y - d / 2, z + h), (x + w / 2 + 3, y - d / 2, z + h), (x, y - d / 2, z + h + .35)],
           mul(roof, .78), tex=shingle_p(6, 4))
    b.face([(x - w / 2 - 3, y - d / 2, z + h), (x - w / 2 - 3, y + d / 2, z + h), (x, y + d / 2, z + h + .35),
            (x, y - d / 2, z + h + .35)], mul(roof, 1.02), tex=shingle_p(6, 4))
    b.face([(x + w / 2 + 3, y - d / 2, z + h), (x + w / 2 + 3, y + d / 2, z + h), (x, y + d / 2, z + h + .35),
            (x, y - d / 2, z + h + .35)], mul(roof, .78), tex=shingle_p(6, 4))
    window(a, b, x - 5, y + d / 2, 10, .3, z + .14, lit=True)


def eave_shadow(a, b, x0, x1, y1, z, drop=.16):
    a.shade([b.p(x0, y1, z), b.p(x1, y1, z), b.p(x1, y1, z - drop), b.p(x0, y1, z - drop)], .42)


def hip_roof(b, x0, y0, x1, y1, eave, ridge, ov, col, tex, hipf=.28, cap=True):
    ym = (y0 + y1) / 2
    rx0, rx1, ry0, ry1 = x0 - ov, x1 + ov, y0 - ov, y1 + ov
    hip = (rx1 - rx0) * hipf
    b.face([(rx0, ry0, eave), (rx1, ry0, eave), (rx1 - hip, ym, ridge), (rx0 + hip, ym, ridge)],
           mul(col, .76), tex=tex)
    b.face([(rx0, ry0, eave), (rx0, ry1, eave), (rx0 + hip, ym, ridge)], mul(col, .9), tex=tex)
    b.face([(rx1, ry1, eave), (rx1, ry0, eave), (rx1 - hip, ym, ridge)], mul(col, .62), tex=tex)
    b.face([(rx0 + hip, ym, ridge), (rx1 - hip, ym, ridge), (rx1, ry1, eave), (rx0, ry1, eave)],
           mul(col, 1.05), tex=tex)
    if cap:
        b.line((rx0 + hip, ym, ridge), (rx1 - hip, ym, ridge), 4, mul(col, .48))
        b.line((rx0 + hip, ym + 2, ridge - .03), (rx1 - hip, ym + 2, ridge - .03), 1.5, mul(col, 1.18))
    b.face([(rx0, ry1, eave), (rx1, ry1, eave), (rx1, ry1, eave - .07), (rx0, ry1, eave - .07)], mul(col, .45))


def gable_roof(b, x0, y0, x1, y1, eave, ridge, ov, col, tex, gable=None, ridge_at=.5, cap=True):
    ym = y0 + (y1 - y0) * ridge_at
    rx0, rx1, ry0, ry1 = x0 - ov, x1 + ov, y0 - ov, y1 + ov
    if gable:
        b.face([(x0, ry0, eave), (x0, ry1, eave), (x0, ym, ridge)], mul(gable, .9))
        b.face([(x1, ry1, eave), (x1, ry0, eave), (x1, ym, ridge)], mul(gable, .66))
    b.face([(rx0, ry0, eave), (rx1, ry0, eave), (rx1, ym, ridge), (rx0, ym, ridge)],
           mul(col, .78), tex=tex)
    b.face([(rx0, ym, ridge), (rx1, ym, ridge), (rx1, ry1, eave), (rx0, ry1, eave)],
           mul(col, 1.05), tex=tex)
    if cap:
        b.line((rx0, ym, ridge), (rx1, ym, ridge), 4, mul(col, .48))
        b.line((rx0, ym + 2, ridge - .03), (rx1, ym + 2, ridge - .03), 1.5, mul(col, 1.18))
    b.face([(rx0, ry1, eave), (rx1, ry1, eave), (rx1, ry1, eave - .07), (rx0, ry1, eave - .07)], mul(col, .45))


def shed_roof(b, x0, y0, x1, y1, z_back, z_front, ov, col, tex):
    rx0, rx1, ry0, ry1 = x0 - ov, x1 + ov, y0 - ov, y1 + ov
    b.face([(rx0, ry0, z_back), (rx1, ry0, z_back), (rx1, ry1, z_front), (rx0, ry1, z_front)], col, tex=tex)
    b.line((rx0, ry0, z_back), (rx1, ry0, z_back), 3, mul(col, .5))
    b.face([(rx0, ry1, z_front), (rx1, ry1, z_front), (rx1, ry1, z_front - .07), (rx0, ry1, z_front - .07)],
           mul(col, .45))


def flat_roof(b, x0, y0, x1, y1, z, col, par=.14, tex=None):
    b.face([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], col, tex=tex)
    t = 2.0
    for pts in (
        [(x0, y0, z + par), (x1, y0, z + par), (x1, y0 + t, z + par), (x0, y0 + t, z + par)],
        [(x0, y1 - t, z + par), (x1, y1 - t, z + par), (x1, y1, z + par), (x0, y1, z + par)],
        [(x0, y0, z + par), (x0 + t, y0, z + par), (x0 + t, y1, z + par), (x0, y1, z + par)],
        [(x1 - t, y0, z + par), (x1, y0, z + par), (x1, y1, z + par), (x1 - t, y1, z + par)],
    ):
        b.face(pts, mul(col, 1.1))
    b.face([(x0, y1, z), (x1, y1, z), (x1, y1, z + par), (x0, y1, z + par)], mul(col, .78))
    b.face([(x0, y0, z), (x0, y1, z), (x0, y1, z + par), (x0, y0, z + par)], mul(col, .94))
    b.face([(x1, y0, z), (x1, y1, z), (x1, y1, z + par), (x1, y0, z + par)], mul(col, .64))


def chimney(b, x, y, w, d, z0, z1, col=BRICK):
    b.box(x - w / 2, y - d / 2, x + w / 2, y + d / 2, z0, z1, col, top=mul(col, .72), top_tex=brick(7, 4))
    b.face([(x - w / 2 + 2, y - d / 2 + 2, z1 + .01), (x + w / 2 - 2, y - d / 2 + 2, z1 + .01),
            (x + w / 2 - 2, y + d / 2 - 2, z1 + .01), (x - w / 2 + 2, y + d / 2 - 2, z1 + .01)], (22, 16, 12))


def door(a, b, x, y1, w, h, z0=.18, col=DARKWOOD, step=True):
    x0s, x1s = b.sx(x, y1), b.sx(x + w, y1)
    yb, yt = b.sy(y1, z0), b.sy(y1, z0 + h)
    a.rect(x0s - 2, yt - 3, x1s + 2, yb, mul(col, 1.45), shade=.15)
    a.rect(x0s, yt, x1s, yb, col, tex=planks_v(5), shade=.25)
    a.rect(x0s + 3, yt + 3, x1s - 3, yt + (yb - yt) * .42, mul(col, 1.12), shade=.1, edge=.3)
    a.ell(x1s - 6, (yt + yb) / 2 - 1.5, x1s - 3, (yt + yb) / 2 + 1.5, STEEL, edge=.3, hi=.2)
    if step:
        b.box(x - 4, y1 + 1, x + w + 4, y1 + 6, 0, z0 + .04, STONE_L,
              top=mul(STONE_L, 1.05), top_tex=stone(5))


def window(a, b, x, y1, w, h, z0, lit=False, frame=DARKWOOD, shutters=False):
    x0s, x1s = b.sx(x, y1), b.sx(x + w, y1)
    yb, yt = b.sy(y1, z0), b.sy(y1, z0 + h)
    a.rect(x0s - 2, yt - 2, x1s + 2, yb + 2, frame, shade=.2)
    a.rect(x0s, yt, x1s, yb, GLASS_LIT if lit else GLASS, shade=.28, grain=4)
    a.glint(x0s + 1, yt + 1, (x0s + x1s) / 2, (yt + yb) / 2, .4)
    cx, cy = (x0s + x1s) / 2, (yt + yb) / 2
    a.rect(cx - .8, yt, cx + .8, yb, frame, edge=0, hi=0, shade=0)
    a.rect(x0s, cy - .8, x1s, cy + .8, frame, edge=0, hi=0, shade=0)
    if lit:
        a.glint(x0s + 1, yt + 1, x1s - 1, yb - 1, .18, (255, 210, 120))
    if shutters:
        a.rect(x0s - 7, yt, x0s - 2, yb, mul(frame, 1.1), tex=planks_v(3), shade=.2)
        a.rect(x1s + 2, yt, x1s + 7, yb, mul(frame, .8), tex=planks_v(3), shade=.2)


def smoke(a, x, y, n=3, a0=.5):
    for i in range(n):
        r = 4 + i * 2
        a.ell(x - r + i * 2, y - i * 8 - r, x + r + i * 2, y - i * 8 + r, (214, 210, 204),
              shade=.1, grain=0, edge=0, hi=0, alpha=a0 - i * .12)


def barrel(a, b, x, y, r=.22, h=.55, col=WOOD):
    cx, cy, top = b.sx(x, y), b.sy(y, 0), b.sy(y, h)
    rx, ry = r * 64, r * 32
    a.rect(cx - rx, top, cx + rx, cy, col, tex=planks_v(4), shade=.28)
    a.ell(cx - rx, top - ry, cx + rx, top + ry, mul(col, 1.1), shade=.2)
    a.ell(cx - rx * .8, top - ry * .7, cx + rx * .8, top + ry * .7, mul(col, .72), shade=.2)
    for t in (.25, .55, .85):
        yy = top + (cy - top) * t
        a.rect(cx - rx, yy - 1, cx + rx, yy + 1, IRON_D, edge=0, hi=0, shade=.1)


def crate(a, b, x, y, s=.42, z=0, col=WOOD_L):
    h = s * .9
    b.box(x - s * 32, y - s * 32, x + s * 32, y + s * 32, z, z + h, col,
          top=mul(col, 1.08), top_tex=planks_h(5))
    for dx, dy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        cx, cy = x + dx * s * 26, y + dy * s * 26
        b.box(cx - 2, cy - 2, cx + 2, cy + 2, z + h - .02, z + h + .01, IRON, top=IRON)


def logs_pile(a, b, x, y, n=4, r=.13):
    for i in range(n):
        yy = y + i * r * 42
        cx, cy = b.sx(x, yy), b.sy(yy, .06 + i * r * 1.15)
        rx, ry = r * 64, r * 22
        a.rect(cx - rx, cy - ry, cx + rx, cy + ry, mul(WOOD_D, 1.1), tex=logs(6), shade=.2)
        a.ell(cx - rx, cy - ry, cx - rx + 7, cy + ry, mul(WOOD, 1.12), shade=.2)
        a.ell(cx + rx - 7, cy - ry, cx + rx, cy + ry, mul(WOOD, .78), shade=.2)


def hay_bale(a, b, x, y, r=.3):
    cx, cy = b.sx(x, y), b.sy(y, r)
    rx, ry = r * 64, r * 34
    a.rect(cx - rx, cy - ry, cx + rx, cy + ry, HAY, tex=speckle(1.2, 40), shade=.25)
    a.ell(cx - rx, cy - ry, cx - rx + 8, cy + ry, mul(HAY, 1.12), shade=.2)
    a.ell(cx + rx - 8, cy - ry, cx + rx, cy + ry, mul(HAY, .75), shade=.2)
    for k in (-.5, 0, .5):
        a.line([(cx + k * rx, cy - ry + 2), (cx + k * rx, cy + ry - 2)], 1, mul(HAY, .7), hi=0)


def lamp(a, b, x, y, z=1.5):
    cx, cy = b.sx(x, y), b.sy(y, 0)
    top = b.sy(y, z)
    a.line([(cx, cy), (cx, top)], 3, IRON_D, shade=.2)
    a.rect(cx - 5, top - 8, cx + 5, top, GLASS_LIT, r=1, shade=.2)
    a.rect(cx - 7, top - 10, cx + 7, top - 7, IRON_D, shade=.2)
    a.glint(cx - 4, top - 7, cx + 4, top - 1, .35, (255, 220, 140))


def awning(a, b, x0, x1, y1, z, h=.35, cols=((196, 60, 52), (240, 232, 214))):
    n = 6
    w = (x1 - x0) / n
    for i in range(n):
        xa, xb = x0 + i * w, x0 + (i + 1) * w
        b.face([(xa, y1, z + h), (xb, y1, z + h), (xb, y1 + 10, z), (xa, y1 + 10, z)],
               cols[i % 2], shade=.12, hi=.2)
    b.line((x0, y1 + 10, z), (x1, y1 + 10, z), 2, mul(cols[0], .7))


def sign(a, b, x, y1, z, emblem=None, w=22, h=20):
    sx, sy = b.sx(x, y1), b.sy(y1, z)
    a.line([(sx, sy), (sx, sy + 8)], 2, IRON_D)
    a.rect(sx - w / 2, sy + 6, sx + w / 2, sy + 6 + h, WOOD_L, r=2, tex=planks_v(5), shade=.2)
    if emblem:
        emblem(a, sx, sy + 6 + h / 2)


def porch(a, b, x0, x1, y1, z=1.3, depth=22, col=RED_ROOF):
    for x in (x0 + 2, x1 - 6):
        b.face([(x, y1 + depth, 0), (x + 4, y1 + depth, 0), (x + 4, y1 + depth, z - .2), (x, y1 + depth, z - .2)],
               DARKWOOD, shade=.25)
    b.face([(x0 - 4, y1, z + .25), (x1 + 4, y1, z + .25), (x1 + 4, y1 + depth, z), (x0 - 4, y1 + depth, z)],
           col, tex=shingle_p(9, 5))
    b.face([(x0 - 4, y1 + depth, z), (x1 + 4, y1 + depth, z), (x1 + 4, y1 + depth, z - .08),
            (x0 - 4, y1 + depth, z - .08)], mul(col, .5))


# ---- housing ----------------------------------------------------------------------------------------------
@asset
def tent():
    """ridge tent, ridge front-to-back, big laced entrance, seams, guy ropes, bedroll and campfire"""
    a, b = building(2, 2, top=110, persp=.16)
    x0, y0, x1, y1 = site(b, .14, .14)
    canvas, stitch = (178, 158, 112), (90, 70, 44)
    rz = 1.55
    xm = (x0 + x1) / 2
    b.ground(x0 - 4, y0 - 4, x1 + 4, y1 + 6, (20, 14, 8), .35)
    # guy ropes and pegs
    for (px, py, qx, qy) in ((x0 - 8, y0 + 10, x0 - 20, y0 + 2), (x1 + 8, y0 + 10, x1 + 20, y0 + 2),
                             (x0 - 8, y1 - 10, x0 - 20, y1 - 18), (x1 + 8, y1 - 10, x1 + 20, y1 - 18)):
        a.line([b.p(px, py, .02), b.p(qx, qy, .02)], 1.2, (206, 190, 150), shade=0, hi=0, edge=.2)
    # canvas slopes
    b.face([(x0, y0, .02), (x0, y1, .02), (xm, y1, rz), (xm, y0, rz)], canvas,
           tex=combine(weave(3), speckle(.4, 40)), shade=.12, grain=7)
    b.face([(xm, y0, rz), (xm, y1, rz), (x1, y1, .02), (x1, y0, .02)], mul(canvas, .72),
           tex=combine(weave(3), speckle(.4, 50)), shade=.12, grain=7)
    # seams and folds
    for k in (.2, .4, .6, .8):
        yy = y0 + (y1 - y0) * k
        b.line((xm, yy, rz), (x0, yy, .02), 1.3, mul(canvas, .78), shade=.1, hi=0, edge=.18)
        b.line((xm, yy, rz), (x1, yy, .02), 1.3, mul(canvas, .58), shade=.1, hi=0, edge=.18)
    for k in (.28, .52, .74):
        yy = y0 + (y1 - y0) * k
        b.line((xm - 18, yy - 6, rz * .55), (xm - 26, yy + 8, .08), 1.2, mul(canvas, .86), shade=.1, hi=0, edge=.14)
        b.line((xm + 16, yy - 4, rz * .55), (xm + 26, yy + 10, .08), 1.2, mul(canvas, .62), shade=.1, hi=0, edge=.14)
    # ridge pole with a front fork
    b.line((xm, y0 - 4, rz + .05), (xm, y1 + 10, rz + .05), 2.8, WOOD, shade=.25)
    b.line((xm, y1 + 10, rz + .05), (xm - 11, y1 + 16, rz - .12), 1.4, WOOD_D)
    b.line((xm, y1 + 10, rz + .05), (xm + 11, y1 + 16, rz - .12), 1.4, WOOD_D)
    # front gable
    b.face([(x0 + 3, y1, .02), (x1 - 3, y1, .02), (xm, y1, rz - .1)], mul(canvas, .99),
           tex=weave(3), shade=.1)
    # big laced entrance: dark interior, a bedroll inside, then the flaps
    b.face([(xm - 42, y1 + 1, .02), (xm + 42, y1 + 1, .02), (xm + 18, y1 + 1, rz - .3),
            (xm - 18, y1 + 1, rz - .3)], (24, 18, 14), shade=.2, grain=5)
    b.box(xm - 22, y1 + 1, xm + 22, y1 + 5, .02, .13, (150, 86, 70),
          top=mul((150, 86, 70), 1.12), top_tex=thatch(1))
    a.rect(b.sx(xm - 18, y1 + 1), b.sy(y1 + 1, .16), b.sx(xm - 6, y1 + 1), b.sy(y1 + 1, .13),
           (220, 200, 170), shade=.1, edge=.2)
    # lantern hanging from the ridge
    a.ell(b.sx(xm, y1 - 12) - 4, b.sy(y1 - 12, rz - .35) - 5, b.sx(xm, y1 - 12) + 4,
          b.sy(y1 - 12, rz - .35) + 5, (255, 206, 110), shade=.1, edge=0, hi=.2, alpha=.9)
    b.face([(xm - 46, y1 + 1, .02), (xm - 6, y1 + 1, .02), (xm - 12, y1 + 1, rz - .26),
            (xm - 54, y1 + 1, rz - .4)], mul(canvas, 1.08), tex=weave(3), shade=.12)
    b.face([(xm + 46, y1 + 1, .02), (xm + 6, y1 + 1, .02), (xm + 12, y1 + 1, rz - .26),
            (xm + 54, y1 + 1, rz - .4)], mul(canvas, .76), tex=weave(3), shade=.12)
    for k in range(5):
        b.line((xm - 42 + k * 5, y1 + 1, .18 + k * .19), (xm - 42 + k * 5, y1 + 1, rz - .34),
               1.0, stitch, shade=.1, hi=0, edge=.1)
    b.line((xm - 48, y1 + 1, .55), (xm - 2, y1 + 1, .55), 1.3, stitch, shade=.1)
    b.line((xm + 48, y1 + 1, .55), (xm + 2, y1 + 1, .55), 1.3, stitch, shade=.1)
    # pegs
    for px in (x0 + 2, x1 - 2):
        for py in (y0 + 2, y1 - 2):
            a.line([b.p(px, py, .02), b.p(px, py, -.12)], 1.4, WOOD_D, shade=.1)
    # bedroll and campfire outside
    bx, by = x1 - 16, y1 + 3
    b.box(bx - 11, by - 16, bx + 11, by - 2, .02, .12, (150, 86, 70),
          top=mul((150, 86, 70), 1.1), top_tex=thatch(1))
    a.line([b.p(bx - 10, by - 15, .13), b.p(bx + 10, by - 15, .13)], 1.2, (210, 190, 160), shade=.1)
    fx, fy = x0 + 18, y1 + 3
    for i in range(5):
        ang = i * 1.256
        a.line([b.p(fx, fy, .02), b.p(fx + math.cos(ang) * 9, fy + math.sin(ang) * 6, .02)], 3, STONE, shade=.2)
    a.ell(b.sx(fx, fy) - 8, b.sy(fy, .02) - 5, b.sx(fx, fy) + 8, b.sy(fy, .02) + 5, (40, 30, 22), shade=.2)
    for i in range(3):
        a.ell(b.sx(fx, fy) - 4 + i * 2, b.sy(fy, .1) - 12 - i * 3, b.sx(fx, fy) + 4 + i * 2,
              b.sy(fy, .1) - 4 - i * 3, (238, 150, 60), shade=.2, edge=0, hi=.1, alpha=.85 - i * .2)
    finish(a, b, "tent", 2, 2)


@asset
def cabin():
    """log cabin: saltbox roof, stone chimney, covered porch, woodpile"""
    a, b = building(3, 3, top=150, persp=.17)
    x0, y0, x1, y1 = site(b, .10, .34)
    wh, pitch, ov = 2.95, .95, 8
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    walls(b, x0, y0, x1, y1, wh, (150, 100, 58), logs(9))
    gable_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, ov, (96, 70, 52), shingle_p(11, 6),
               gable=(150, 100, 58), ridge_at=.42)
    eave_shadow(a, b, x0, x1, y1, wh, .2)
    dormer(a, b, (x0 + x1) / 2, y0 + (y1 - y0) * .42, wh + pitch * .5, 20, 13, .6,
           (150, 100, 58), (96, 70, 52))
    door(a, b, x0 + 26, y1, 22, 1.15)
    window(a, b, x0 + 60, y1, 18, .55, .55, lit=True, shutters=True)
    window(a, b, x0 + 88, y1, 18, .55, .55, lit=False, shutters=True)
    porch(a, b, x0 + 6, x0 + 56, y1, z=1.35, depth=20, col=(96, 70, 52))
    chimney(b, x0 + 14, y0 + 20, 14, 12, wh - .3, wh + pitch + .7, STONE)
    smoke(a, b.sx(x0 + 14, y0 + 20), b.sy(y0 + 20, wh + pitch + .75), 3, .45)
    logs_pile(a, b, x1 - 10, y1 - 44, 5)
    crate(a, b, x1 - 16, y1 - 16, .34)
    finish(a, b, "cabin", 3, 3)


@asset
def homestead():
    """timber-framed house with a cross-gable wing, porch, chimney and a fenced herb garden"""
    a, b = building(3, 3, top=175, persp=.17)
    x0, y0, x1, y1 = site(b, .10, .30)
    wh, pitch, ov = 3.05, 1.0, 8
    wall, roof = (200, 170, 126), (156, 58, 48)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    walls(b, x0, y0, x1, y1, wh, wall, planks_h(8))
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, ov, roof, shingle_p(10, 6))
    eave_shadow(a, b, x0, x1, y1, wh, .2)
    # cross-gable wing on the right: it projects past the main wall, so the gable faces the street
    wx0, wx1 = x0 + (x1 - x0) * .50, x1
    wy0, wy1 = y0 + (y1 - y0) * .30, y1 + 13
    wx = (wx0 + wx1) / 2
    eave, ridge = wh + .05, wh + pitch + .22
    b.box(wx0 - 2, wy0, wx1 + 2, wy1, .16, wh, wall, top=mul(wall, 1.02), top_tex=planks_h(8))
    b.face([(wx0 - ov, wy1, eave), (wx1 + ov, wy1, eave), (wx, wy1, ridge)], mul(wall, .98))
    b.face([(wx0 - ov, wy0, eave), (wx1 + ov, wy0, eave), (wx, wy0, ridge)], mul(wall, .72))
    b.face([(wx0 - ov, wy0, eave), (wx0 - ov, wy1, eave), (wx, wy1, ridge), (wx, wy0, ridge)],
           mul(roof, 1.02), tex=shingle_p(9, 5))
    b.face([(wx1 + ov, wy0, eave), (wx1 + ov, wy1, eave), (wx, wy1, ridge), (wx, wy0, ridge)],
           mul(roof, .78), tex=shingle_p(9, 5))
    b.line((wx, wy0, ridge), (wx, wy1, ridge), 4, mul(roof, .5))
    window(a, b, wx - 8, wy1, 16, .55, wh - .55, lit=True, shutters=True)
    window(a, b, wx - 8, wy1, 16, .5, wh + .18, lit=True, shutters=True)
    # door, porch and garden
    door(a, b, x0 + 24, y1, 24, 1.2)
    window(a, b, x0 + 10, y1, 16, .55, .6, lit=True, shutters=True)
    porch(a, b, x0 + 4, x0 + 56, y1, z=1.4, depth=18, col=roof)
    chimney(b, x0 + 14, y0 + 18, 14, 12, wh - .3, wh + pitch + .75, BRICK)
    smoke(a, b.sx(x0 + 14, y0 + 18), b.sy(y0 + 18, wh + pitch + .8), 3, .4)
    # herb garden: low fence and green rows in the front-left corner
    gx0, gx1, gy = x0 + 6, x0 + 44, y1 - 8
    for gx in (gx0, gx1):
        b.face([(gx, gy, 0), (gx + 3, gy, 0), (gx + 3, gy, .45), (gx, gy, .45)], WOOD_D, shade=.2)
    b.line((gx0, gy, .38), (gx1, gy, .38), 2, WOOD_D)
    for k in range(4):
        b.face([(gx0 + 4 + k * 9, gy - 3, .05), (gx0 + 9 + k * 9, gy - 3, .05),
                (gx0 + 9 + k * 9, gy + 2, .3), (gx0 + 4 + k * 9, gy + 2, .3)], (92, 150, 68), shade=.2)
    finish(a, b, "homestead", 3, 3)


@asset
def apartment():
    """three-storey brick block: flat roof with water tank and vents, balconies, awning"""
    a, b = building(4, 4, top=225, persp=.14)
    x0, y0, x1, y1 = site(b, .10, .22)
    wh = 4.35
    wall, roof = (164, 92, 72), (130, 124, 116)
    b.ground(x0 - 8, y0 - 8, x1 + 8, b.base + 6, (20, 14, 8), .42)
    plinth(b, x0, y0, x1, y1, z1=.22)
    walls(b, x0, y0, x1, y1, wh, wall, brick(14, 7), z0=.22)
    b.box(x0 - 4, y0 - 4, x1 + 4, y1 + 4, wh - .22, wh, mul(wall, .9), top=mul(roof, 1.06),
          top_tex=speckle(1.0))
    flat_roof(b, x0, y0, x1, y1, wh, roof, par=.16, tex=speckle(1.0))
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    # windows, three storeys
    for row, z in enumerate((.55, 1.55, 2.55, 3.55)):
        for i in range(4):
            wx = x0 + 12 + i * (x1 - x0 - 24) / 4
            window(a, b, wx, y1, 20, .62, z, lit=(row + i) % 3 != 0)
    # balconies on the upper two storeys
    for z in (1.55, 2.55):
        for i in range(4):
            bx = x0 + 8 + i * (x1 - x0 - 24) / 4
            b.box(bx, y1, bx + 26, y1 + 7, z - .08, z - .04, STONE_L, top=mul(STONE_L, 1.1))
            b.line((bx, y1 + 7, z + .38), (bx + 26, y1 + 7, z + .38), 2, IRON_D)
            for k in range(5):
                b.line((bx + k * 6, y1 + 7, z - .04), (bx + k * 6, y1 + 7, z + .38), 1, IRON_D)
    # entrance
    awning(a, b, x0 + 34, x0 + 82, y1, 1.0, .3, ((52, 70, 100), (232, 228, 214)))
    door(a, b, x0 + 48, y1, 26, 1.25, z0=.22, col=(44, 64, 90))
    # roof clutter: stair bulkhead, water tank, skylights, vents and seams
    b.box(x0 + 34, y0 + 26, x0 + 104, y0 + 74, wh + .16, wh + 1.25, (150, 120, 100),
          top=mul((150, 120, 100), 1.02), top_tex=planks_h(5))
    door(a, b, x0 + 50, y0 + 74, 20, .85, z0=wh + .16, step=False)
    b.box(x0 + 30, y0 + 22, x0 + 108, y0 + 78, wh + 1.25, wh + 1.55, (110, 84, 62),
          top=(120, 92, 68), top_tex=shingle(8, 4))
    tank(a, b, x1 - 62, y0 + 50, .42, wh + .16, wh + 1.7, (110, 120, 128))
    for k in range(4):
        b.line((x0 + 12, y0 + 12 + k * 24, wh + .17), (x1 - 12, y0 + 12 + k * 24, wh + .17), 1,
               mul(roof, .82))
    for (sx, sy) in ((x0 + 130, y0 + 36), (x0 + 176, y0 + 64), (x0 + 128, y0 + 96), (x0 + 188, y0 + 110)):
        b.box(sx, sy, sx + 26, sy + 18, wh + .16, wh + .24, GLASS, top=GLASS_LIT, top_tex=speckle(.5))
    for (vx, vy) in ((x1 - 30, y1 - 40), (x1 - 70, y1 - 30), (x0 + 40, y1 - 50)):
        b.box(vx, vy, vx + 8, vy + 8, wh + .16, wh + .6, IRON, top=IRON_D)
    finish(a, b, "apartment", 4, 4)


@asset
def townhouse():
    """two-storey brick-and-iron townhouse: flat zinc roof, iron bands, sash windows, shared brick with the
    apartment tier but a small front footprint (4x3) - the middle rung between the timber homestead and the
    three-storey apartment (#43)."""
    a, b = building(4, 3, top=210, persp=.15)
    x0, y0, x1, y1 = site(b, .10, .24)
    wh = 3.35
    wall, roof = (178, 106, 74), (82, 88, 96)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1, z1=.2)
    walls(b, x0, y0, x1, y1, wh, wall, brick(15, 7), z0=.2)
    # iron bands between the storeys and at the parapet line
    for z in (wh * .5, wh):
        b.face([(x0, y1, z - .09), (x1, y1, z - .09), (x1, y1, z + .07), (x0, y1, z + .07)], IRON, shade=.22)
    flat_roof(b, x0, y0, x1, y1, wh, roof, par=.14, tex=speckle(.6))
    # parapet: brick upstand around the roof edge with an iron coping
    b.box(x0 - 3, y0 - 3, x1 + 3, y1 + 3, wh, wh + .26, mul(wall, .86), top=mul(IRON_D, 1.05))
    eave_shadow(a, b, x0, x1, y1, wh, .16)
    # two storeys of sash windows with iron lintels
    for z in (.62, 1.62):
        for i in range(4):
            wx = x0 + 12 + i * (x1 - x0 - 24) / 4
            window(a, b, wx, y1, 15, .6, z, lit=(i + (1 if z > 1 else 0)) % 3 != 0)
            b.face([(wx - 2, y1, z + .58), (wx + 17, y1, z + .58), (wx + 17, y1, z + .66), (wx - 2, y1, z + .66)],
                   IRON, shade=.25)
    # entrance: iron porch over a half-glazed door
    door(a, b, x0 + (x1 - x0) / 2 - 11, y1, 22, 1.2, z0=.2, col=(58, 74, 96))
    porch(a, b, x0 + (x1 - x0) / 2 - 30, x0 + (x1 - x0) / 2 + 30, y1, z=1.45, depth=16, col=(52, 62, 76))
    chimney(b, x0 + 16, y0 + 16, 12, 10, wh - .25, wh + .8, BRICK)
    finish(a, b, "townhouse", 4, 3)


@asset
def hall():
    """civic hall: hipped roof, central clock tower and flag, double doors, steps and lamps"""
    a, b = building(3, 3, top=230, persp=.16)
    x0, y0, x1, y1 = site(b, .08, .28)
    wh, pitch, ov = 3.15, 1.0, 9
    wall, roof = (196, 158, 104), RED_ROOF
    b.ground(x0 - 8, y0 - 8, x1 + 8, b.base + 6, (20, 14, 8), .45)
    plinth(b, x0, y0, x1, y1, z1=.22)
    walls(b, x0, y0, x1, y1, wh, wall, planks_h(9), z0=.22)
    hip_roof(b, x0, y0, x1, y1, wh + .05, wh + pitch, ov, roof, shingle_p(11, 7), hipf=.24)
    eave_shadow(a, b, x0, x1, y1, wh, .2)
    for dx in (-46, 46):
        dormer(a, b, (x0 + x1) / 2 + dx, y0 + (y1 - y0) * .46, wh + pitch * .48, 18, 12, .55,
               wall, roof)
    # clock tower at the centre-back
    tx, ty = (x0 + x1) / 2, y0 + (y1 - y0) * .38
    tw = 34
    b.box(tx - tw / 2, ty - tw / 2, tx + tw / 2, ty + tw / 2, wh - .1, wh + 2.65, wall,
          top=mul(wall, 1.02), top_tex=planks_h(6))
    for z in (wh + .55, wh + 1.55):
        window(a, b, tx - 6, ty + tw / 2, 12, .5, z, lit=True)
    # tower cap
    hip_roof(b, tx - tw / 2 - 3, ty - tw / 2 - 3, tx + tw / 2 + 3, ty + tw / 2 + 3,
             wh + 2.68, wh + 3.35, 4, roof, shingle_p(7, 4), hipf=.3)
    # clock face
    cs = b.sx(tx, ty + tw / 2)
    cy = b.sy(ty + tw / 2, wh + 1.9)
    a.ell(cs - 9, cy - 9, cs + 9, cy + 9, (240, 236, 226), shade=.2, edge=.45)
    a.line([(cs, cy), (cs, cy - 6)], 1.2, IRON_D, hi=0)
    a.line([(cs, cy), (cs + 5, cy + 2)], 1.2, IRON_D, hi=0)
    # flag
    b.line((tx, ty, wh + 3.35), (tx, ty, wh + 4.4), 2.4, DARKWOOD)
    b.face([(tx, ty, wh + 4.35), (tx + 34, ty + 6, wh + 4.2), (tx, ty + 6, wh + 3.95)], (204, 62, 46),
           tex=speckle(.4))
    # doors, steps, windows, banners, lamps
    b.box(x0 + 46, y1, x0 + 96, y1 + 7, 0, .26, STONE_L, top=mul(STONE_L, 1.05), top_tex=stone(7))
    door(a, b, x0 + 52, y1, 17, 1.25, z0=.22, col=DARKWOOD)
    door(a, b, x0 + 73, y1, 17, 1.25, z0=.22, col=DARKWOOD)
    for wx in (x0 + 16, x1 - 34):
        window(a, b, wx, y1, 18, .7, .55, lit=True, shutters=False)
        window(a, b, wx, y1, 18, .55, .9, lit=True, shutters=False)
    for bx in (x0 + 34, x1 - 40):
        b.face([(bx, y1, wh - .1), (bx + 8, y1, wh - .1), (bx + 8, y1, .3), (bx, y1, .3)], (204, 62, 46),
               tex=speckle(.4))
        b.line((bx + 4, y1, .3), (bx + 4, y1, wh - .1), 1, (226, 190, 90))
    lamp(a, b, x0 + 8, y1 + 4, 1.4)
    lamp(a, b, x1 - 8, y1 + 4, 1.4)
    finish(a, b, "town-hall", 3, 3)




# ---- extra parts ------------------------------------------------------------------------------------------
def front_gable(b, x0, y0, x1, y1, eave, ridge, ov, col, tex, gable):
    """ridge front-to-back: the triangular gable faces the street (tavern, wing, lodge)"""
    xm = (x0 + x1) / 2
    rx0, rx1, ry0, ry1 = x0 - ov, x1 + ov, y0 - ov, y1 + ov
    b.face([(x0, ry1, eave), (x1, ry1, eave), (xm, ry1, ridge)], mul(gable, .98))
    b.face([(x0, ry0, eave), (x1, ry0, eave), (xm, ry0, ridge)], mul(gable, .72))
    b.face([(rx0, ry0, eave), (rx0, ry1, eave), (xm, ry1, ridge), (xm, ry0, ridge)], mul(col, 1.02), tex=tex)
    b.face([(rx1, ry1, eave), (rx1, ry0, eave), (xm, ry0, ridge), (xm, ry1, ridge)], mul(col, .78), tex=tex)
    b.line((xm, ry0, ridge), (xm, ry1, ridge), 4, mul(col, .5))
    b.line((rx0, ry1, eave), (xm, ry1, ridge), 3, mul(col, .62))
    b.line((rx1, ry1, eave), (xm, ry1, ridge), 3, mul(col, .62))


def silo(a, b, x, y, r, z0, z1, col=STONE_L, roof=RED_ROOF):
    cx, top, bot = b.sx(x, y), b.sy(y, z1), b.sy(y, z0)
    rx, ry = r * 64, r * 32
    a.rect(cx - rx, top, cx + rx, bot, col, tex=speckle(.8), shade=.25)
    a.ell(cx - rx, top - ry, cx + rx, top + ry, mul(col, 1.05), shade=.2)
    apex = b.sy(y, z1 + .55)
    a.poly([(cx - rx, top), (cx + rx, top), (cx, apex)], roof, tex=shingle_p(8, 4), shade=.2)
    for t in (.2, .5, .8):
        yy = top + (bot - top) * t
        a.rect(cx - rx, yy - 1, cx + rx, yy + 1, IRON_D, edge=0, hi=0, shade=.1)


def tank(a, b, x, y, r, z0, z1, col=(110, 120, 128)):
    cx, top, bot = b.sx(x, y), b.sy(y, z1), b.sy(y, z0)
    rx, ry = r * 64, r * 32
    a.rect(cx - rx, top, cx + rx, bot, col, tex=speckle(.8), shade=.25)
    a.ell(cx - rx, top - ry, cx + rx, top + ry, mul(col, 1.12), shade=.2)
    a.ell(cx - rx * .82, top - ry * .82, cx + rx * .82, top + ry * .82, mul(col, .86), shade=.2)
    for t in (.18, .5, .82):
        yy = top + (bot - top) * t
        a.rect(cx - rx, yy - 1, cx + rx, yy + 1, IRON_D, edge=0, hi=0, shade=.1)


def rowboat(a, b, x, y):
    cx, cy = b.sx(x, y), b.sy(y, .08)
    a.ell(cx - 18, cy - 7, cx + 18, cy + 7, (120, 82, 48), shade=.3, edge=.4)
    a.ell(cx - 14, cy - 5, cx + 14, cy + 5, (72, 52, 34), shade=.2)
    a.line([(cx - 12, cy), (cx + 12, cy)], 2, WOOD_D)
    a.line([(cx - 16, cy - 3), (cx - 20, cy - 10)], 1.5, WOOD, hi=0)


def cart(a, b, x, y, col=WOOD):
    b.box(x - 16, y - 10, x + 16, y + 10, 0, .35, col, top=mul(col, 1.1), top_tex=planks_h(4))
    for dx in (-10, 10):
        cx, cy = b.sx(x + dx, y + 10), b.sy(y + 10, .12)
        a.ell(cx - 6, cy - 6, cx + 6, cy + 6, IRON_D, shade=.3)


def anvil(a, b, x, y):
    b.box(x - 8, y - 5, x + 8, y + 5, 0, .25, IRON_D, top=IRON)
    b.box(x - 11, y - 4, x + 11, y + 4, .25, .42, IRON, top=STEEL)


def sawhorse(a, b, x, y):
    for dx in (-10, 10):
        for dz in (-6, 6):
            b.line((x + dx, y + dz, 0), (x + dx, y + dz, .55), 2, WOOD_D)
    b.box(x - 14, y - 6, x + 14, y + 6, .52, .64, WOOD, top=mul(WOOD, 1.1), top_tex=planks_h(4))


def drying_rack(a, b, x, y, w=30, h=1.0):
    for dx in (-w / 2, w / 2):
        b.line((x + dx, y, 0), (x + dx, y, h), 2, WOOD_D)
    b.line((x - w / 2, y, h), (x + w / 2, y, h), 2, WOOD_D)
    for k in range(4):
        px = x - w / 2 + 6 + k * (w - 12) / 4
        b.line((px, y, h), (px, y, h - .25), 1, (200, 180, 140))
        a.ell(b.sx(px, y) - 3, b.sy(y, h - .25) - 3, b.sx(px, y) + 3, b.sy(y, h - .25) + 3,
              (180, 40, 80), shade=.3)


def antlers(a, b, x, y, z):
    cx, cy = b.sx(x, y), b.sy(y, z)
    for s in (-1, 1):
        a.line([(cx, cy), (cx + s * 10, cy - 8), (cx + s * 14, cy - 16)], 2, (220, 210, 190), shade=.2)
        a.line([(cx + s * 10, cy - 8), (cx + s * 16, cy - 10)], 1.5, (220, 210, 190))


def oven(a, b, x, y, r=.45, h=1.05):
    col = (158, 88, 64)
    b.box(x - r * 32, y - r * 32, x + r * 32, y + r * 32, 0, h, col, top=mul(col, 1.05), top_tex=brick(8, 4))
    cx, cy = b.sx(x, y), b.sy(y, h)
    a.ell(cx - r * 32, cy - r * 16, cx + r * 32, cy + r * 16, (176, 100, 72), shade=.25)
    a.ell(cx - 8, cy - 2, cx + 8, cy + 8, (30, 20, 14), shade=.2)
    a.ell(cx - 4, cy + 1, cx + 4, cy + 5, (238, 150, 60), shade=.1, edge=0, hi=.2, alpha=.8)


def cauldron(a, b, x, y):
    cx, cy = b.sx(x, y), b.sy(y, .35)
    a.ell(cx - 12, cy - 6, cx + 12, cy + 6, (50, 44, 40), shade=.3)
    a.rect(cx - 12, cy - 2, cx + 12, cy + 10, (60, 56, 50), shade=.3)
    a.ell(cx - 12, cy + 2, cx + 12, cy + 14, (40, 36, 32), shade=.2)
    for i in range(3):
        a.ell(cx - 8 + i * 4, cy + 12 - i * 3, cx + 2 + i * 4, cy + 20 - i * 3,
              (238, 150, 60), shade=.2, edge=0, hi=.1, alpha=.8)


def picnic_table(a, b, x, y):
    b.box(x - 16, y - 10, x + 16, y + 10, 0, .4, PLANK, top=mul(PLANK, 1.1), top_tex=planks_h(4))
    for dy in (-16, 16):
        b.box(x - 18, y + dy - 4, x + 18, y + dy + 4, 0, .25, WOOD_L, top=mul(WOOD_L, 1.1), top_tex=planks_h(3))


def pump(a, b, x, y):
    b.box(x - 6, y - 6, x + 6, y + 6, 0, .9, IRON, top=mul(IRON, .9))
    b.box(x - 4, y - 4, x + 4, y + 4, .9, 1.1, (180, 60, 50), top=(200, 80, 60))
    a.line([b.p(x, y, .9), b.p(x + 8, y, .5)], 2, IRON_D)


def car(a, b, x, y, col=(120, 60, 50)):
    b.face([(x - 15, y - 8, .15), (x + 15, y - 8, .15), (x + 15, y + 8, .15), (x - 15, y + 8, .15)],
           col, shade=.2)
    b.face([(x - 8, y - 6, .45), (x + 8, y - 6, .45), (x + 8, y + 6, .45), (x - 8, y + 6, .45)],
           GLASS, shade=.2)
    for dx, dy in ((-9, -9), (9, -9), (-9, 9), (9, 9)):
        cx, cy = b.sx(x + dx, y + dy), b.sy(y + dy, .1)
        a.ell(cx - 4, cy - 3, cx + 4, cy + 3, IRON_D, shade=.3)


def trailer(a, b, x, y):
    b.box(x - 20, y - 10, x + 20, y + 10, 0, .3, WOOD, top=mul(WOOD, 1.1), top_tex=planks_h(4))
    for dx in (-12, 12):
        cx, cy = b.sx(x + dx, y + 10), b.sy(y + 10, .15)
        a.ell(cx - 7, cy - 7, cx + 7, cy + 7, IRON_D, shade=.3)
    b.line((x - 20, y, .5), (x - 20, y + 10, .5), 2, WOOD_D)


def hoist(a, b, x, y, z):
    b.line((x, y, z), (x + 20, y, z), 3, DARKWOOD)
    b.line((x + 20, y, z), (x + 20, y, z - .5), 1.5, IRON_D)
    a.rect(b.sx(x + 20, y) - 2, b.sy(y, z - .5) - 2, b.sx(x + 20, y) + 2, b.sy(y, z - .5) + 2, IRON_D)


def column(a, b, x, y, z0, z1, r=4):
    cx = b.sx(x, y)
    a.rect(cx - r, b.sy(y, z1), cx + r, b.sy(y, z0), (230, 224, 210), shade=.2)
    a.ell(cx - r, b.sy(y, z1) - r * .5, cx + r, b.sy(y, z1) + r * .5, (240, 236, 226), shade=.2)
    a.rect(cx - r - 2, b.sy(y, z1) - 2, cx + r + 2, b.sy(y, z1) + 2, (200, 194, 180), shade=.2)


def dome(a, b, x, y, r, z, col=COPPER):
    cx, cy = b.sx(x, y), b.sy(y, z)
    a.ell(cx - r, cy - r * .8, cx + r, cy + r * .35, col, shade=.35, tex=combine(speckle(.5), tin(9)))
    a.glint(cx - r * .6, cy - r * .5, cx + r * .2, cy - r * .1, .35)
    a.line([(cx, cy - r * .8), (cx, cy - r - 8)], 2, YELLOW)


# ---- labour huts ------------------------------------------------------------------------------------------
@asset
def forager_hut():
    """thatched wattle hut: wide door, lit window, berry sign, drying rack and baskets outside"""
    a, b = building(2, 2, top=145, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .24)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .36)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.9, .68
    wall, roof = (150, 126, 92), THATCH
    walls(b, x0, y0, x1, y1, wh, wall, planks_h(7))
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 8, roof, thatch_p(1), hipf=.3)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    door(a, b, x0 + 28, y1, 28, 1.3, col=DARKWOOD)
    window(a, b, x0 + 8, y1, 14, .5, .7, lit=True)
    # shelves glimpsed through the open door
    for k in range(3):
        a.ell(b.sx(x0 + 34 + k * 7, y1) - 3, b.sy(y1, .95) - 3, b.sx(x0 + 34 + k * 7, y1) + 3,
              b.sy(y1, .95) + 3, (190, 140, 66), shade=.3)
    sign(a, b, x1 - 10, y1, wh - .35, em_basket, 22, 20)
    drying_rack(a, b, x0 + 10, y1 - 8, 26, 1.15)
    crate(a, b, x1 - 14, y1 - 8, .34)
    barrel(a, b, x0 + 8, y1 - 6, .16, .42, WOOD)
    finish(a, b, "forager-hut", 2, 2)

@asset
def woodcutter_hut():
    """log shed: front gable, wide plank door, log pile, sawhorse and an axe stump"""
    a, b = building(2, 2, top=155, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .22)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .36)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.9, .78
    wall, roof = (124, 92, 60), (112, 76, 50)
    walls(b, x0, y0, x1, y1, wh, wall, logs(7))
    front_gable(b, x0, y0, x1, y1, wh + .04, wh + pitch, 8, roof, planks_h(7), wall)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    door(a, b, x0 + 24, y1, 32, 1.35, col=DARKWOOD)
    window(a, b, x0 + 6, y1, 12, .5, .75, lit=True)
    sign(a, b, x1 - 10, y1, wh - .35, em_log, 22, 20)
    logs_pile(a, b, x0 + 14, y1 - 10, 5, .14)
    sawhorse(a, b, x1 - 20, y1 - 12)
    # axe stump
    cx, cy = b.sx(x1 - 10, y1 - 4), b.sy(y1 - 4, 0)
    a.ell(cx - 8, cy - 5, cx + 8, cy + 3, (120, 84, 50), shade=.25)
    a.rect(cx - 8, cy - 2, cx + 8, cy + 8, (100, 70, 42), shade=.25)
    a.line([(cx, cy - 2), (cx + 8, cy - 14)], 2, WOOD_D)
    a.poly([(cx + 6, cy - 14), (cx + 12, cy - 20), (cx + 14, cy - 12), (cx + 8, cy - 10)], STEEL, shade=.3)
    finish(a, b, "woodcutter-hut", 2, 2)

def sapling(a, b, x, y, h=1.0):
    """A young tree standing at plan position (x, y): bare stem with a small crown, in the 3/4 view (#97)."""
    sx, base, top = b.sx(x, y), b.sy(y, 0), b.sy(y, h)
    a.line([(sx, base), (sx, top)], max(1.2, 1.8 * h), (124, 90, 54), shade=.2)
    for dx, dz, r in ((-4, .62, 4.4), (4, .55, 4.0), (0, 1.0, 4.8), (-1, .34, 3.6)):
        cy = b.sy(y, h * dz)
        a.ell(sx + dx - r, cy - r, sx + dx + r, cy + r, (96, 154, 72), shade=.28, edge=.4, hi=.4)

@asset
def forester_hut():
    """tree nursery: plank hut with a mossy green roof, a fenced seedbed of saplings out front and bundles of
    lifted saplings leaning on the wall, ready to go back into the gaps the woodcutter left"""
    a, b = building(2, 2, top=150, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .22)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .36)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.8, .68
    wall, roof = (156, 132, 96), (74, 110, 64)   # mossy green roof: a nursery, not another log shed
    walls(b, x0, y0, x1, y1, wh, wall, planks_h(7))
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 8, roof, shingle_p(8, 5), hipf=.3)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    door(a, b, x0 + 22, y1, 26, 1.25, col=DARKWOOD)
    window(a, b, x0 + 6, y1, 12, .5, .7, lit=True)
    sign(a, b, x1 - 8, y1, wh - .35, em_sapling, 22, 20)
    # fenced seedbed (front-left): dark soil, three rows of saplings, a low rail fence in front of them
    bed0, bed1, bedf = x0 + 4, x0 + 40, y1 - 28
    b.face([(bed0, bedf, .03), (bed1, bedf, .03), (bed1, y1 - 3, .03), (bed0, y1 - 3, .03)],
           SOIL, shade=.12, tex=speckle(.9, 48))
    for row in range(3):
        for col in range(3):
            sapling(a, b, bed0 + 7 + col * 12, bedf + 5 + row * 8, .75)
    for fx in (bed0, bed1):
        b.box(fx - 2, bedf - 2, fx + 2, bedf + 2, .03, .62, DARKWOOD)
        b.box(fx - 2, y1 - 5, fx + 2, y1 - 1, .03, .62, DARKWOOD)
    for ry in (bedf, y1 - 3):
        b.face([(bed0 - 2, ry - 1, .58), (bed1 + 2, ry - 1, .58), (bed1 + 2, ry + 1, .66), (bed0 - 2, ry + 1, .66)],
               WOOD_L, shade=.2)
    # bundles of lifted saplings leaning on the right-hand wall, roots wrapped in sacking
    for dx, tilt in ((2, 3), (10, 1), (18, 4)):
        cx, cy = b.sx(x1 - 22 + dx, y1 - 12), b.sy(y1 - 12, 0)
        a.line([(cx, cy), (cx + tilt, cy - 30)], 2.2, (128, 92, 54), shade=.2)
        for dz, r in ((30, 6.5), (22, 5.2), (15, 4.2)):
            a.ell(cx + tilt - r, cy - dz - r, cx + tilt + r, cy - dz + r,
                  (98, 156, 74), shade=.3, edge=.4, hi=.4)
        a.ell(cx - 4, cy - 5, cx + 4, cy + 3, (188, 168, 128), shade=.3)   # sacking round the root ball
    finish(a, b, "forester-hut", 2, 2)

@asset
def miner_hut():
    """mine adit: stone portal with a dark arch, timber frame, headframe and an ore cart on rails"""
    a, b = building(2, 2, top=128, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .18)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .4)
    # stone retaining wall / portal
    b.box(x0, y0, x1, y1 - 24, 0, 1.5, (128, 122, 112), top=mul((128, 122, 112), .95), top_tex=stone(10))
    # dark adit mouth
    mx = (x0 + x1) / 2
    b.face([(mx - 18, y1 - 24, .02), (mx + 18, y1 - 24, .02), (mx + 18, y1 - 24, 1.15),
            (mx - 18, y1 - 24, 1.15)], (18, 14, 12))
    b.face([(mx - 18, y1 - 24, 1.15), (mx + 18, y1 - 24, 1.15), (mx, y1 - 24, 1.45)], (18, 14, 12))
    for x in (mx - 22, mx + 20):
        b.box(x, y1 - 26, x + 4, y1 - 22, 0, 1.5, DARKWOOD)
    b.box(mx - 24, y1 - 27, mx + 24, y1 - 23, 1.45, 1.58, DARKWOOD)
    # headframe above the adit
    b.line((mx - 16, y0 + 22, 1.5), (mx, y0 + 22, 3.1), 3, WOOD_D)
    b.line((mx + 16, y0 + 22, 1.5), (mx, y0 + 22, 3.1), 3, WOOD_D)
    b.line((mx - 10, y0 + 22, 2.0), (mx + 10, y0 + 22, 2.0), 2, WOOD)
    b.line((mx, y0 + 22, 3.1), (mx, y0 + 22, 1.6), 1.4, IRON_D)
    # rails and ore cart
    for ry in (y1 - 20, y1 - 10):
        b.line((x0 + 4, ry, .04), (x1 - 4, ry, .04), 2, IRON_D)
    cart(a, b, mx, y1 - 12, (110, 84, 64))
    a.ell(b.sx(mx, y1 - 12) - 14, b.sy(y1 - 12, .4) - 6, b.sx(mx, y1 - 12) + 14,
          b.sy(y1 - 12, .4) + 6, (122, 92, 74), shade=.3)
    for i, (rx, ry) in enumerate(((x0 + 2, y1 - 4), (x1 - 8, y1 - 6), (x0 + 12, y1 - 2))):
        a.ell(b.sx(rx, ry) - 5, b.sy(ry, 0) - 4, b.sx(rx, ry) + 5, b.sy(ry, 0) + 3,
              (120, 114, 104), shade=.25)
    finish(a, b, "miner-hut", 2, 2)


@asset
def farm_hut():
    """barn with a gambrel-ish roof, a tall silo, hay bales and a fenced crop patch"""
    a, b = building(2, 2, top=160, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .14)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.9, .62
    walls(b, x0, y0, x1, y1, wh, (176, 98, 66), planks_h(8))
    gable_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 7, (96, 70, 52), shingle_p(10, 5),
               gable=(176, 98, 66), ridge_at=.5)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    dormer(a, b, (x0 + x1) / 2, y0 + (y1 - y0) * .42, wh + pitch * .5, 20, 12, .55,
           (176, 98, 66), (96, 70, 52))
    door(a, b, x0 + 24, y1, 28, 1.2)
    window(a, b, x0 + 64, y1, 16, .5, .55, lit=True)
    silo(a, b, x1 - 14, y0 + 22, .3, 0, 2.55, (196, 190, 176), (120, 60, 44))
    hay_bale(a, b, x0 + 10, y1 - 10, .28)
    hay_bale(a, b, x0 + 10, y1 - 26, .28)
    # weather vane on the barn ridge
    vx, vy = (x0 + x1) / 2, (y0 + y1) / 2
    b.line((vx, vy, wh + pitch), (vx, vy, wh + pitch + .65), 1.5, IRON_D)
    a.line([b.p(vx, vy, wh + pitch + .6), b.p(vx + 10, vy, wh + pitch + .55)], 2, IRON_D)
    # crop rows in the front-left
    for k in range(4):
        b.face([(x0 + 2 + k * 8, y1 - 14, .04), (x0 + 6 + k * 8, y1 - 14, .04),
                (x0 + 6 + k * 8, y1 - 2, .38), (x0 + 2 + k * 8, y1 - 2, .38)], (92, 150, 68), shade=.2)
    finish(a, b, "farm-hut", 2, 2)


@asset
def hunting_lodge():
    """log lodge: steep gable, antlers over the door, pelt drying rack and a woodpile"""
    a, b = building(2, 2, top=155, persp=.18)
    x0, y0, x1, y1 = site(b, .12, .20)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .38)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 3.0, .9
    walls(b, x0, y0, x1, y1, wh, (148, 112, 74), logs(8))
    front_gable(b, x0, y0, x1, y1, wh + .04, wh + pitch, 7, (92, 108, 68), shingle_p(9, 5),
                (148, 112, 74))
    eave_shadow(a, b, x0, x1, y1, wh, .2)
    door(a, b, x0 + 30, y1, 22, 1.15)
    window(a, b, x0 + 8, y1, 15, .5, .6, lit=True)
    window(a, b, x1 - 22, y1, 15, .5, .6, lit=True)
    antlers(a, b, x0 + 41, y1, wh + .35)
    drying_rack(a, b, x0 + 20, y1 - 8, 24, 1.1)
    logs_pile(a, b, x1 - 10, y1 - 34, 4, .13)
    chimney(b, x0 + 10, y0 + 16, 12, 10, wh - .3, wh + pitch + .55, STONE)
    smoke(a, b.sx(x0 + 10, y0 + 16), b.sy(y0 + 16, wh + pitch + .6), 3, .4)
    finish(a, b, "hunting-lodge", 2, 2)


@asset
def fishing_dock():
    """a narrow plank pier over open water leading to a blue-roofed shed on stilts; nets and a rowboat"""
    a, b = building(2, 2, top=140, persp=.16)
    x0, y0, x1, y1 = site(b, .04, .04)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 6, (20, 14, 8), .2)
    # open water
    b.face([(x0 - 6, y0 - 6, 0), (x1 + 6, y0 - 6, 0), (x1 + 6, y1 + 6, 0), (x0 - 6, y1 + 6, 0)],
           (54, 108, 140), tex=speckle(.8, 30), shade=.2)
    for k in range(7):
        b.line((x0 + 4, y0 + 6 + k * 16, .01), (x1 - 4, y0 + 6 + k * 16, .01), 1, (110, 170, 196))
    # shed on stilts at the back
    sx0, sx1, sy0, sy1 = x0 + 4, x1 - 4, y0 + 4, y0 + 50
    for px in (sx0 + 4, sx1 - 6):
        for py in (sy0 + 4, sy1 - 4):
            b.line((px, py, 0), (px, py, 1.15), 3.4, WOOD_D)
    b.box(sx0, sy0, sx1, sy1, 1.12, 1.3, PLANK, top=mul(PLANK, 1.08), top_tex=planks_h(6))
    b.box(sx0 + 2, sy0 + 2, sx1 - 2, sy1 - 2, 1.3, 2.25, (150, 126, 92),
          top=mul((150, 126, 92), 1.05), top_tex=planks_h(6))
    b.face([(sx0 - 2, sy0 - 2, 2.6), (sx1 + 2, sy0 - 2, 2.6), (sx1 + 2, sy1 + 3, 2.32),
            (sx0 - 2, sy1 + 3, 2.32)], (58, 96, 124), tex=tin(6), shade=.2)
    b.face([(sx0 - 2, sy1 + 3, 2.32), (sx1 + 2, sy1 + 3, 2.32), (sx1 + 2, sy1 + 3, 2.22),
            (sx0 - 2, sy1 + 3, 2.22)], (40, 70, 96))
    door(a, b, sx0 + 26, sy1 - 2, 18, .8, z0=1.3, step=False)
    # pier from the shed to the front
    px0, px1 = x0 + 24, x1 - 24
    b.box(px0, sy1 - 2, px1, y1 - 2, .32, .46, PLANK, top=mul(PLANK, 1.08), top_tex=planks_h(6))
    for py in (sy1 + 8, y1 - 10):
        for px in (px0 + 2, px1 - 2):
            b.line((px, py, 0), (px, py, .32), 3, WOOD_D)
    for py in (sy1 + 4, y1 - 6):
        for px in (px0, px1):
            b.line((px, py, .46), (px, py, .95), 1.6, WOOD_D)
    b.line((px0, sy1 + 4, .92), (px0, y1 - 6, .92), 1.2, WOOD_D)
    b.line((px1, sy1 + 4, .92), (px1, y1 - 6, .92), 1.2, WOOD_D)
    # net rack on the pier
    nx, ny = px1 - 8, sy1 + 22
    b.line((nx, ny, .46), (nx, ny, 1.35), 2, WOOD_D)
    b.line((nx - 12, ny, 1.3), (nx + 12, ny, 1.3), 2, WOOD_D)
    for k in range(5):
        b.line((nx - 10 + k * 5, ny, 1.28), (nx - 10 + k * 5, ny, .55), 1, (190, 190, 170))
    barrel(a, b, px0 + 8, y1 - 10, .16, .4, WOOD)
    rowboat(a, b, x0 + 12, y1 - 14)
    finish(a, b, "fishing-dock", 2, 2)


@asset
def salt_pan():
    """low stone evaporation basin: brine, salt crystal piles, a plank walkway and a rake"""
    a, b = building(2, 2, top=92, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .10)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .3)
    b.box(x0, y0, x1, y1, 0, .22, (126, 118, 106), top=mul((126, 118, 106), .95), top_tex=stone(9))
    b.box(x0 + 8, y0 + 8, x1 - 8, y1 - 8, .22, .24, (92, 138, 168), top=(92, 138, 168), top_tex=speckle(.5, 25))
    for (cx, cy, r) in ((x0 + 30, y1 - 30, 12), (x0 + 52, y1 - 44, 9), (x0 + 44, y1 - 22, 8)):
        a.ell(b.sx(cx, cy) - r, b.sy(cy, .24) - r * .55, b.sx(cx, cy) + r, b.sy(cy, .24) + r * .55,
              (240, 240, 234), tex=speckle(.8, 40), shade=.2, edge=.35)
    # walkway
    b.box(x0 + 6, y1 - 14, x1 - 6, y1 - 4, .24, .3, PLANK, top=mul(PLANK, 1.1), top_tex=planks_h(5))
    # rake leaning on the rim
    a.line([b.p(x1 - 14, y1 - 8, .3), b.p(x1 - 22, y1 - 20, 1.0)], 2, WOOD_D)
    a.line([b.p(x1 - 24, y1 - 22, 1.0), b.p(x1 - 18, y1 - 18, 1.0)], 2, IRON_D)
    finish(a, b, "salt-pan", 2, 2)


@asset
def smokehouse():
    """tall smoke tower with a steep roof and chimney; a lean-to hangs fish and sausage; firewood"""
    a, b = building(2, 2, top=185, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .30)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 3.0, .8
    walls(b, x0, y0, x1, y1, wh, (118, 108, 96), stone(10))
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 6, (74, 68, 64), shingle_p(9, 5), hipf=.26)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    door(a, b, x0 + 26, y1, 22, 1.1, col=DARKWOOD)
    chimney(b, x0 + 14, y0 + 16, 13, 11, wh - .2, wh + pitch + 1.0, STONE)
    smoke(a, b.sx(x0 + 14, y0 + 16), b.sy(y0 + 16, wh + pitch + 1.05), 4, .5)
    # lean-to on the right with hanging food
    lx0, lx1 = x1 - 28, x1 + 2
    b.line((lx0, y1 - 6, 0), (lx0, y1 - 6, 1.25), 2, WOOD_D)
    b.line((lx1, y1 - 6, 0), (lx1, y1 - 6, 1.25), 2, WOOD_D)
    b.face([(lx0 - 2, y1 - 8, 1.4), (lx1 + 2, y1 - 8, 1.4), (lx1 + 2, y1 + 2, 1.15), (lx0 - 2, y1 + 2, 1.15)],
           (112, 76, 50), tex=planks_h(5))
    for k in range(3):
        hx = lx0 + 4 + k * 8
        b.line((hx, y1 - 6, 1.15), (hx, y1 - 6, .75), 1, (210, 200, 170))
        a.ell(b.sx(hx, y1 - 6) - 3, b.sy(y1 - 6, .75) - 5, b.sx(hx, y1 - 6) + 3,
              b.sy(y1 - 6, .75) + 3, (150, 72, 66), shade=.3)
    logs_pile(a, b, x0 + 10, y1 - 10, 3, .12)
    finish(a, b, "smokehouse", 2, 2)


@asset
def kitchen():
    """outdoor kitchen: brick oven with a dome and chimney, cauldron, prep table, striped awning"""
    a, b = building(2, 2, top=128, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .16)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .38)
    b.box(x0, y0, x1, y1 - 20, 0, .2, (150, 132, 112), top=mul((150, 132, 112), .95), top_tex=stone(8))
    # prep table / back counter
    b.box(x0 + 4, y0 + 6, x1 - 30, y0 + 30, .2, .9, (164, 118, 74), top=mul((164, 118, 74), 1.08),
          top_tex=planks_h(5))
    oven(a, b, x1 - 20, y0 + 22, .38, 1.15)
    chimney(b, x1 - 20, y0 + 22, 12, 10, 1.15, 2.1, (158, 88, 64))
    smoke(a, b.sx(x1 - 20, y0 + 22), b.sy(y0 + 22, 2.15), 3, .45)
    cauldron(a, b, x0 + 18, y1 - 16)
    awning(a, b, x0 + 4, x1 - 4, y1 - 20, 1.35, .35, ((180, 88, 56), (240, 232, 214)))
    crate(a, b, x0 + 8, y1 - 8, .32)
    for k, col in enumerate(((210, 90, 60), (120, 160, 70), (220, 190, 80))):
        a.ell(b.sx(x0 + 18 + k * 7, y0 + 18) - 4, b.sy(y0 + 18, .95) - 4,
              b.sx(x0 + 18 + k * 7, y0 + 18) + 4, b.sy(y0 + 18, .95) + 4, col, shade=.3)
    finish(a, b, "kitchen", 2, 2)


@asset
def toolsmith():
    """stone-and-plank forge: shed roof, wide door with a glowing forge, chimney, anvil and tool rack"""
    a, b = building(2, 2, top=165, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .20)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.9, .58
    wall, roof = (112, 104, 96), (84, 88, 96)
    walls(b, x0, y0, x1, y1, wh, wall, stone(9))
    shed_roof(b, x0, y0, x1, y1, wh + pitch, wh + .05, 7, roof, tin(6))
    eave_shadow(a, b, x0, x1, y1, wh, .16)
    door(a, b, x0 + 26, y1, 28, 1.35, col=(58, 42, 30))
    # forge glow in the doorway
    a.glint(b.sx(x0 + 30, y1), b.sy(y1, 1.1), b.sx(x0 + 50, y1), b.sy(y1, .3), .45, (255, 150, 60))
    window(a, b, x0 + 6, y1, 12, .5, .75, lit=True)
    chimney(b, x0 + 12, y0 + 16, 12, 10, wh - .2, wh + pitch + .85, STONE)
    smoke(a, b.sx(x0 + 12, y0 + 16), b.sy(y0 + 16, wh + pitch + .9), 3, .45)
    sign(a, b, x1 - 10, y1, wh - .35, em_pick, 22, 20)
    anvil(a, b, x1 - 22, y1 - 14)
    barrel(a, b, x1 - 8, y1 - 6, .16, .45, WOOD)
    # tool rack and coal
    b.box(x0 + 6, y1 - 12, x0 + 34, y1 - 9, 0, .85, WOOD_D, top=WOOD)
    for k in range(3):
        tx = x0 + 11 + k * 9
        a.line([b.p(tx, y1 - 10, .85), b.p(tx, y1 - 10, .4)], 2, IRON)
        a.ell(b.sx(tx, y1 - 10) - 3, b.sy(y1 - 10, .4) - 3, b.sx(tx, y1 - 10) + 3,
              b.sy(y1 - 10, .4) + 3, STEEL, shade=.2)
    for k in range(5):
        a.ell(b.sx(x0 + 44 + k * 3, y1 - 5) - 3, b.sy(y1 - 5, .08) - 3, b.sx(x0 + 44 + k * 3, y1 - 5) + 3,
              b.sy(y1 - 5, .08) + 3, (38, 34, 32), shade=.2)
    finish(a, b, "toolsmith", 2, 2)

@asset
def tavern():
    """half-timbered tavern: front gable, hanging mug sign, barrels, bench and a warm awning"""
    a, b = building(2, 2, top=180, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .20)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 3.0, 1.0
    wall, roof = (150, 104, 66), (126, 62, 44)
    walls(b, x0, y0, x1, y1, wh, wall, planks_v(7))
    for x in (x0 + 4, x0 + 32, x0 + 60, x1 - 4):
        b.face([(x - 2, y1, .18), (x + 2, y1, .18), (x + 2, y1, wh), (x - 2, y1, wh)], WOOD_D)
    b.face([(x0, y1, wh * .55), (x1, y1, wh * .55), (x1, y1, wh * .55 + .12),
            (x0, y1, wh * .55 + .12)], WOOD_D)
    front_gable(b, x0, y0, x1, y1, wh + .04, wh + pitch, 8, roof, shingle_p(9, 5), wall)
    eave_shadow(a, b, x0, x1, y1, wh, .2)
    door(a, b, x0 + 22, y1, 22, 1.15)
    window(a, b, x0 + 8, y1, 12, .5, .6, lit=True)
    window(a, b, x1 - 22, y1, 14, .5, .6, lit=True)
    window(a, b, x0 + 26, y1, 16, .5, wh + .25, lit=True)
    # hanging sign
    sign(a, b, x1 - 8, y1, wh - .2, em_mug, 24, 22)
    # awning over the door
    awning(a, b, x0 + 14, x0 + 52, y1, 1.25, .3, ((126, 62, 44), (226, 210, 180)))
    barrel(a, b, x1 - 12, y1 - 8, .2, .55, WOOD)
    barrel(a, b, x1 - 26, y1 - 8, .2, .55, WOOD)
    # bench
    b.box(x0 + 2, y1 - 8, x0 + 22, y1 - 3, 0, .3, WOOD_L, top=mul(WOOD_L, 1.1), top_tex=planks_h(3))
    chimney(b, x0 + 10, y0 + 16, 12, 10, wh - .3, wh + pitch + .55, STONE)
    smoke(a, b.sx(x0 + 10, y0 + 16), b.sy(y0 + 16, wh + pitch + .6), 3, .4)
    finish(a, b, "tavern", 2, 2)


@asset
def clinic():
    """whitewashed infirmary: slate hip roof, green-cross board, bell cupola, herb barrels"""
    a, b = building(2, 2, top=155, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .18)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .38)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.65, .8
    walls(b, x0, y0, x1, y1, wh, WHITE, speckle(1.2, 30))
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 7, SLATE, shingle_p(9, 5), hipf=.3)
    eave_shadow(a, b, x0, x1, y1, wh, .16)
    door(a, b, x0 + 26, y1, 20, 1.1)
    window(a, b, x0 + 8, y1, 14, .5, .65, lit=True)
    window(a, b, x1 - 22, y1, 14, .5, .65, lit=True)
    # green cross board above the door
    cx, cy = b.sx(x0 + 36, y1), b.sy(y1, wh - .25)
    a.rect(cx - 8, cy - 7, cx + 8, cy + 7, WHITE, shade=.2, edge=.3)
    a.rect(cx - 2, cy - 6, cx + 2, cy + 6, (58, 150, 72), shade=.1, edge=0, hi=.2)
    a.rect(cx - 6, cy - 2, cx + 6, cy + 2, (58, 150, 72), shade=.1, edge=0, hi=.2)
    # bell cupola on the ridge
    bx, by = (x0 + x1) / 2, (y0 + y1) / 2
    b.box(bx - 7, by - 5, bx + 7, by + 5, wh + pitch - .1, wh + pitch + .45, WHITE, top=mul(WHITE, 1.02))
    b.face([(bx - 10, by - 8, wh + pitch + .5), (bx + 10, by - 8, wh + pitch + .5),
            (bx + 10, by + 8, wh + pitch + .5), (bx - 10, by + 8, wh + pitch + .5)],
           mul(SLATE, .9))
    a.line([b.p(bx, by, wh + pitch + .5), b.p(bx, by, wh + pitch + .85)], 1.4, IRON_D)
    a.ell(b.sx(bx, by) - 3, b.sy(by, wh + pitch + .7) - 3, b.sx(bx, by) + 3,
          b.sy(by, wh + pitch + .7) + 3, (210, 180, 80), shade=.2)
    # herb barrels
    barrel(a, b, x1 - 10, y1 - 8, .18, .45, (96, 150, 72))
    barrel(a, b, x1 - 24, y1 - 8, .18, .45, (96, 150, 72))
    finish(a, b, "clinic", 2, 2)


@asset
def canteen():
    """low mess hall: wide striped awning, serving hatch, picnic tables, chimney"""
    a, b = building(2, 2, top=145, persp=.18)
    x0, y0, x1, y1 = site(b, .10, .30)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .35)
    plinth(b, x0, y0, x1, y1)
    wh, pitch = 2.5, .55
    walls(b, x0, y0, x1, y1, wh, (164, 118, 74), planks_h(7))
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 8, (120, 70, 48), shingle_p(9, 5), hipf=.3)
    eave_shadow(a, b, x0, x1, y1, wh, .16)
    # serving hatch
    a.rect(b.sx(x0 + 18, y1), b.sy(y1, 1.1), b.sx(x0 + 62, y1), b.sy(y1, .55), (46, 30, 20), shade=.1)
    a.rect(b.sx(x0 + 16, y1), b.sy(y1, .58), b.sx(x0 + 64, y1), b.sy(y1, .5), WOOD_L, tex=planks_h(3))
    awning(a, b, x0 + 10, x0 + 70, y1, 1.05, .3, ((196, 60, 52), (240, 232, 214)))
    door(a, b, x0 + 72, y1, 18, 1.0, z0=.18)
    chimney(b, x0 + 12, y0 + 16, 11, 9, wh - .3, wh + pitch + .55, STONE)
    smoke(a, b.sx(x0 + 12, y0 + 16), b.sy(y0 + 16, wh + pitch + .6), 3, .4)
    picnic_table(a, b, x0 + 20, y1 + 8)
    picnic_table(a, b, x0 + 58, y1 + 8)
    finish(a, b, "canteen", 2, 2)




# ---- civic ------------------------------------------------------------------------------------------------
@asset
def town_archive():
    """stone archive: hipped roof, a portico of columns, steps and a scroll board over the door"""
    a, b = building(3, 3, top=195, persp=.16)
    x0, y0, x1, y1 = site(b, .10, .30)
    wh, pitch = 3.0, .8
    wall, roof = STONE_L, (176, 166, 150)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1, z1=.24)
    walls(b, x0, y0, x1, y1, wh, wall, stone(14), z0=.24)
    hip_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 8, roof, stone(9), hipf=.28)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    dormer(a, b, (x0 + x1) / 2, y0 + (y1 - y0) * .44, wh + pitch * .5, 22, 12, .55, wall, roof)
    # portico: entablature and six columns, leaving the middle open for the door
    b.box(x0 + 6, y1 - 4, x1 - 6, y1 + 6, wh - .1, wh + .28, roof, top=mul(roof, 1.04), top_tex=stone(8))
    door(a, b, x0 + 36, y1, 26, 1.3, z0=.24)
    for i in range(6):
        cx = x0 + 14 + i * (x1 - x0 - 28) / 5
        if abs(cx - (x0 + x1) / 2) < 18:
            continue
        column(a, b, cx, y1 + 1, .24, wh - .1)
    # scroll emblem on the entablature
    cx, cy = b.sx((x0 + x1) / 2, y1), b.sy(y1, wh + .1)
    a.ell(cx - 9, cy - 6, cx + 9, cy + 6, (222, 210, 184), shade=.2, edge=.4)
    a.line([(cx - 5, cy - 2), (cx + 5, cy - 2)], 1.4, (110, 92, 64), hi=0)
    a.line([(cx - 5, cy + 2), (cx + 5, cy + 2)], 1.4, (110, 92, 64), hi=0)
    # side windows
    window(a, b, x0 + 14, y1, 15, .55, .7, lit=True)
    window(a, b, x1 - 30, y1, 15, .55, .7, lit=True)
    finish(a, b, "town-archive", 3, 3)


@asset
def university():
    """copper dome over a drum, two low wings, a columned entrance and lit windows"""
    a, b = building(4, 4, top=245, persp=.14)
    x0, y0, x1, y1 = site(b, .08, .22)
    wh = 3.0
    wall, roof = (196, 160, 120), (88, 100, 110)
    b.ground(x0 - 8, y0 - 8, x1 + 8, b.base + 6, (20, 14, 8), .42)
    # wings
    for wx0, wx1 in ((x0, x0 + 78), (x1 - 78, x1)):
        b.box(wx0, y0 + 10, wx1, y1 - 6, 0, wh * .82, wall, top=roof, top_tex=stone(10))
        for k in range(2):
            window(a, b, wx0 + 12 + k * 30, y1 - 6, 18, .6, .55, lit=True)
    # central block
    cx0, cx1 = x0 + 62, x1 - 62
    b.box(cx0, y0 + 4, cx1, y1, 0, wh, wall, top=roof, top_tex=stone(10))
    b.box(cx0 - 3, y0 + 1, cx1 + 3, y1 + 3, wh - .16, wh, mul(wall, .92), top=roof, top_tex=stone(8))
    door(a, b, (cx0 + cx1) / 2 - 15, y1, 30, 1.35, z0=.02)
    for i in range(4):
        cx = cx0 + 12 + i * (cx1 - cx0 - 24) / 3
        column(a, b, cx, y1, 0, wh - .1)
    b.box(cx0 - 4, y1 - 2, cx1 + 4, y1 + 4, wh - .1, wh + .32, roof, top=mul(roof, 1.04), top_tex=stone(8))
    # drum and dome
    dx, dy = (cx0 + cx1) / 2, (y0 + y1) / 2 - 8
    b.box(dx - 34, dy - 30, dx + 34, dy + 30, wh, wh + 1.0, wall, top=mul(wall, 1.02), top_tex=stone(10))
    for k in range(5):
        window(a, b, dx - 28 + k * 12, dy + 30, 8, .38, wh + .22, lit=True)
    b.face([(dx - 36, dy + 30, wh + .78), (dx + 36, dy + 30, wh + .78), (dx + 36, dy + 30, wh + .9),
            (dx - 36, dy + 30, wh + .9)], mul(wall, .8))
    dome(a, b, dx, dy, 34, wh + 1.0)
    finish(a, b, "university", 4, 4)


# ---- industry ---------------------------------------------------------------------------------------------
@asset
def warehouse():
    """bulk store: tin gable roof, a wide loading door with hazard stripes, crates and a wall hoist"""
    a, b = building(3, 3, top=195, persp=.16)
    x0, y0, x1, y1 = site(b, .10, .26)
    wh, pitch = 2.95, .9
    wall, roof = (118, 104, 88), (112, 124, 134)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    walls(b, x0, y0, x1, y1, wh, wall, planks_h(10))
    gable_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 7, roof, tin(6), gable=wall, ridge_at=.5)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    dormer(a, b, (x0 + x1) / 2, y0 + (y1 - y0) * .44, wh + pitch * .5, 24, 14, .6, wall, roof)
    # loading door
    door(a, b, x0 + 32, y1, 48, 1.55, col=DARKWOOD, step=False)
    b.box(x0 + 28, y1, x0 + 84, y1 + 8, 0, .22, STONE_L, top=mul(STONE_L, 1.05), top_tex=stone(6))
    for i in range(6):
        b.face([(x0 + 30 + i * 9, y1 + 8, .23), (x0 + 38 + i * 9, y1 + 8, .23),
                (x0 + 38 + i * 9, y1 + 8, .26), (x0 + 30 + i * 9, y1 + 8, .26)],
               YELLOW if i % 2 == 0 else (40, 38, 34))
    window(a, b, x0 + 10, y1, 15, .5, .75)
    # crates and a hoist
    crate(a, b, x1 - 22, y1 - 18, .45)
    crate(a, b, x1 - 22, y1 - 40, .45)
    crate(a, b, x1 - 46, y1 - 18, .38)
    hoist(a, b, x1 - 14, y0 + 20, wh - .2)
    finish(a, b, "warehouse", 3, 3)

@asset
def cannery():
    """tin canning line: iron box with a loading chute, a cooling rack of tins, a steam stack"""
    a, b = building(2, 2, top=170, persp=.17)
    x0, y0, x1, y1 = site(b, .10, .22)
    wh = 2.45
    wall = (150, 152, 158)
    roof = (96, 102, 112)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .38)
    plinth(b, x0, y0, x1, y1)
    walls(b, x0, y0, x1, y1, wh, wall, tin(9), z0=.18)
    flat_roof(b, x0, y0, x1, y1, wh, roof, par=.2, tex=tin(4))
    # iron banding
    for z in (1.15, 2.05):
        b.face([(x0, y1, z - .06), (x1, y1, z - .06), (x1, y1, z + .05), (x0, y1, z + .05)], IRON, shade=.35)
    door(a, b, x0 + 22, y1, 30, 1.15, col=(58, 52, 46))
    window(a, b, x0 + 10, y1, 12, .5, .7, lit=False)
    window(a, b, x0 + 80, y1, 12, .5, .7, lit=True)
    # steam stack with a safety cap
    chimney(b, x0 + 18, y0 + 18, 12, 10, wh - .2, wh + .85, STONE)
    b.line((b.sx(x0 + 18, y0 + 18), b.sy(y0 + 18, wh + .85)),
           (b.sx(x0 + 18, y0 + 18), b.sy(y0 + 18, wh + 1.15)), 3, IRON)
    smoke(a, b.sx(x0 + 18, y0 + 18), b.sy(y0 + 18, wh + .9), 2, .4)
    # tin cooling rack: rows of cans on the loading apron
    for r in range(3):
        for c in range(4):
            cx, cy = x1 - 8 - c * 7, y1 - 10 - r * 6
            a.ell(b.sx(cx, cy) - 3, b.sy(cy, .35 + r * .16) - 2, b.sx(cx, cy) + 3,
                  b.sy(cy, .35 + r * .16) + 2, (186, 198, 208), shade=.3)
    finish(a, b, "cannery", 2, 2)


@asset
def refrigerated_warehouse():
    """cold store: the warehouse's bones under a steel skin, a freezer door and a snowflake badge"""
    a, b = building(3, 3, top=200, persp=.16)
    x0, y0, x1, y1 = site(b, .10, .24)
    wh, pitch = 2.95, .85
    wall, roof = (128, 148, 168), (96, 112, 128)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1, z1=.22)
    walls(b, x0, y0, x1, y1, wh, wall, tin(10), z0=.22)
    gable_roof(b, x0, y0, x1, y1, wh + .04, wh + pitch, 7, roof, tin(6), gable=wall, ridge_at=.5)
    eave_shadow(a, b, x0, x1, y1, wh, .18)
    # freezer door: dark panelled monolith with bolts
    door(a, b, x0 + 32, y1, 52, 1.65, col=(58, 70, 84), step=False)
    b.face([(x0 + 36, y1, 1.7), (x0 + 80, y1, 1.7), (x0 + 80, y1, 1.78), (x0 + 36, y1, 1.78)], IRON, shade=.3)
    for m in range(4):
        mx = x0 + 40 + m * 12
        a.ell(b.sx(mx, y1) - 2, b.sy(y1, 1.55) - 2, b.sx(mx, y1) + 2, b.sy(y1, 1.55) + 2, IRON, shade=.35)
    window(a, b, x0 + 10, y1, 13, .5, .75, lit=False)
    window(a, b, x1 - 22, y1, 13, .5, .75, lit=True)
    # snowflake badge above the door
    em_frost(a, b.sx((x0 + x1) / 2, y1), b.sy(y1, wh - .35))
    finish(a, b, "refrigerated-warehouse", 3, 3)


@asset
def haul_station():
    """transfer depot: canopy over the back, a small office on the loading deck, freight and a trailer"""
    a, b = building(3, 3, top=185, persp=.16)
    x0, y0, x1, y1 = site(b, .08, .14)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .38)
    b.box(x0, y0, x1, y1, 0, .28, PLANK, top=mul(PLANK, 1.05), top_tex=planks_h(8))
    cy = y0 + (y1 - y0) * .56
    # low side walls frame the deck; the front stays open
    b.box(x0, y0, x1, y0 + 8, 0, 2.3, WOOD, top=mul(WOOD, 1.05), top_tex=planks_h(6))
    b.box(x0, y0, x0 + 8, cy, 0, 1.2, mul(WOOD, 1.02), top=mul(WOOD, 1.02), top_tex=planks_v(6))
    b.box(x1 - 8, y0, x1, cy, 0, 1.2, mul(WOOD, .82), top=mul(WOOD, .82), top_tex=planks_v(6))
    # canopy over the back
    b.face([(x0 - 4, y0 - 4, 2.65), (x1 + 4, y0 - 4, 2.65), (x1 + 4, cy + 4, 2.35),
            (x0 - 4, cy + 4, 2.35)], (96, 112, 92), tex=tin(7), shade=.15)
    b.face([(x0 - 4, cy + 4, 2.35), (x1 + 4, cy + 4, 2.35), (x1 + 4, cy + 4, 2.23),
            (x0 - 4, cy + 4, 2.23)], (70, 84, 68))
    for px in (x0 + 4, x1 - 6):
        for py in (y0 + 8, cy + 2):
            b.line((px, py, .28), (px, py, 2.35), 3, WOOD_D)
    b.line((x0 + 4, cy + 2, 2.3), (x1 - 6, cy + 2, 2.3), 2.6, WOOD_D)
    # shadow under the canopy edge
    b.face([(x0, cy - 2, .3), (x1, cy - 2, .3), (x1, cy + 12, .3), (x0, cy + 12, .3)],
           (20, 14, 8), alpha=.28)
    # office on the open deck, front-left
    ox0, ox1, oy0, oy1 = x0 + 8, x0 + 72, y1 - 54, y1 - 12
    b.box(ox0, oy0, ox1, oy1, .28, 1.95, (150, 126, 92), top=mul((150, 126, 92), 1.05),
          top_tex=planks_h(6))
    b.box(ox0 - 2, oy0 - 2, ox1 + 2, oy1 + 2, 1.95, 2.08, IRON_D, top=mul(IRON_D, 1.1), top_tex=tin(5))
    door(a, b, ox0 + 24, oy1, 18, 1.0, z0=.28)
    window(a, b, ox0 + 8, oy1, 12, .45, .8, lit=True)
    sign(a, b, ox1 - 8, oy1, 1.5, em_basket, 22, 20)
    # rails and sleepers on the right of the deck
    for rx in (x0 + 96, x1 - 34):
        b.line((rx, y1 - 4, .3), (rx, cy + 4, .3), 2.4, IRON_D)
        b.line((rx, y1 - 4, .31), (rx, cy + 4, .31), 1.0, IRON)
        for k in range(7):
            sy = y1 - 10 - k * 11
            b.line((rx - 7, sy, .3), (rx + 7, sy, .3), 1.2, WOOD_D)
    # painted loading line and kerb
    b.face([(x0 + 8, y1 - 12, .32), (x1 - 8, y1 - 12, .32), (x1 - 8, y1 - 8, .32),
            (x0 + 8, y1 - 8, .32)], YELLOW)
    b.box(x0 + 8, y1 - 2, x1 - 8, y1 + 2, 0, .18, STONE_L, top=mul(STONE_L, 1.04), top_tex=stone(5))
    # stacked freight
    crate(a, b, x1 - 24, y1 - 34, .62)
    crate(a, b, x1 - 24, y1 - 50, .5, z=.56)
    crate(a, b, x0 + 86, y1 - 34, .5)
    barrel(a, b, x1 - 10, y1 - 10, .18, .55, WOOD)
    barrel(a, b, x0 + 88, y1 - 10, .18, .55, WOOD)
    trailer(a, b, (x0 + x1) / 2 + 24, y1 - 8)
    finish(a, b, "haul-station", 3, 3)


@asset
def motor_pool():
    """garage: shed roof, two dark bays with rolled-up doors, a fuel pump, tyres and a car"""
    a, b = building(3, 3, top=185, persp=.16)
    x0, y0, x1, y1 = site(b, .08, .20)
    wh, pitch = 2.65, .7
    wall, roof = (128, 112, 96), (84, 88, 96)
    b.ground(x0 - 6, y0 - 6, x1 + 6, b.base + 4, (20, 14, 8), .4)
    plinth(b, x0, y0, x1, y1)
    walls(b, x0, y0, x1, y1, wh, wall, planks_h(10))
    shed_roof(b, x0, y0, x1, y1, wh + pitch, wh + .05, 7, roof, tin(6))
    eave_shadow(a, b, x0, x1, y1, wh, .16)
    # two garage bays
    for bx in (x0 + 14, x0 + 74):
        a.rect(b.sx(bx, y1), b.sy(y1, 1.45), b.sx(bx + 46, y1), b.sy(y1, .2), (38, 34, 30), shade=.1)
        for k in range(6):
            yy = b.sy(y1, 1.4 - k * .18)
            a.line([(b.sx(bx + 2, y1), yy), (b.sx(bx + 44, y1), yy)], 1.4, IRON_D, shade=.2)
        b.face([(bx - 2, y1, 0), (bx + 48, y1, 0), (bx + 48, y1, .2), (bx - 2, y1, .2)], YELLOW)
    # office window and fuel
    window(a, b, x1 - 26, y1, 16, .5, .8)
    pump(a, b, x1 - 12, y1 - 10)
    for k in range(3):
        cx, cy = b.sx(x0 + 12 + k * 12, y1 - 12), b.sy(y1 - 12, .22)
        a.ell(cx - 7, cy - 7, cx + 7, cy + 7, (32, 30, 28), shade=.3)
        a.ell(cx - 3, cy - 3, cx + 3, cy + 3, (70, 68, 64), shade=.2)
    car(a, b, (x0 + x1) / 2 + 6, y1 - 2, (120, 60, 50))
    finish(a, b, "motor-pool", 3, 3)


# ---- transport --------------------------------------------------------------------------------------------
@asset
def passenger_platform():
    """raised plank platform: stone kerb, yellow edge, a canopy over the back half, bench, clock and lamp"""
    a, b = building(2, 2, top=120, persp=.14)
    x0, y0, x1, y1 = site(b, .04, .06)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .3)
    b.box(x0, y0, x1, y1, 0, .3, PLANK, top=mul(PLANK, 1.05), top_tex=planks_h(7))
    b.face([(x0, y1, .3), (x1, y1, .3), (x1, y1, .26), (x0, y1, .26)], YELLOW)
    b.face([(x0, y1, 0), (x1, y1, 0), (x1, y1, .3), (x0, y1, .3)], STONE, tex=stone(9))
    for px in (x0 + 4, x1 - 8):
        for py in (y0 + 6, y0 + 58):
            b.line((px, py, .3), (px, py, 1.95), 3, WOOD_D)
    b.face([(x0 - 2, y0 - 2, 2.15), (x1 + 2, y0 - 2, 2.15), (x1 + 2, y0 + 64, 1.98),
            (x0 - 2, y0 + 64, 1.98)], (96, 112, 92), tex=tin(6), shade=.14)
    b.face([(x0 - 2, y0 + 64, 1.98), (x1 + 2, y0 + 64, 1.98), (x1 + 2, y0 + 64, 1.86),
            (x0 - 2, y0 + 64, 1.86)], (70, 84, 68))
    # bench
    b.box(x0 + 8, y0 + 40, x1 - 10, y0 + 48, .3, .55, WOOD_L, top=mul(WOOD_L, 1.08), top_tex=planks_h(4))
    b.face([(x0 + 8, y0 + 40, .55), (x1 - 10, y0 + 40, .55), (x1 - 10, y0 + 40, .95),
            (x0 + 8, y0 + 40, .95)], WOOD_D)
    # clock under the fascia
    cx, cy = b.sx((x0 + x1) / 2, y0 + 64), b.sy(y0 + 64, 1.75)
    a.ell(cx - 7, cy - 7, cx + 7, cy + 7, (240, 236, 226), shade=.22, edge=.45)
    a.line([(cx, cy), (cx, cy - 4)], 1, IRON_D, hi=0)
    a.line([(cx, cy), (cx + 3, cy + 1)], 1, IRON_D, hi=0)
    # lamp at the open end
    lamp(a, b, x1 - 10, y1 - 8, 1.7)
    # luggage
    b.box(x0 + 8, y1 - 18, x0 + 24, y1 - 8, .3, .58, (150, 96, 60), top=mul((150, 96, 60), 1.08),
          top_tex=planks_h(3))
    finish(a, b, "passenger-platform", 2, 2)


# ---- ground features --------------------------------------------------------------------------------------
@asset
def watchtower():
    """timber tower: four splayed legs, braced, a railed platform, a shingle roof and a flag"""
    a, b = building(2, 2, top=190, persp=.14)
    x0, y0, x1, y1 = site(b, .26, .26)
    b.ground(x0 - 8, y0 - 8, x1 + 8, b.base + 6, (20, 14, 8), .45)
    # legs (rear pair first)
    for px, py in ((x0 + 4, y0 + 6), (x1 - 4, y0 + 6), (x0 - 2, y1 - 2), (x1 + 2, y1 - 2)):
        b.line((px, py, 0), (px, py, 3.0), 5, WOOD_D)
    b.line((x0 + 4, y0 + 6, 1.1), (x1 - 4, y1 - 2, 1.9), 2.4, WOOD)
    b.line((x1 - 4, y0 + 6, 1.1), (x0 - 2, y1 - 2, 1.9), 2.4, WOOD)
    # platform and rail
    b.box(x0 - 4, y0 + 2, x1 + 4, y1 + 2, 2.95, 3.12, PLANK, top=mul(PLANK, 1.06), top_tex=planks_h(6))
    for px in (x0 - 4, x1, x0 + 16, x1 - 16):
        b.line((px, y1 + 2, 3.12), (px, y1 + 2, 3.7), 2.2, WOOD)
    b.line((x0 - 4, y1 + 2, 3.68), (x1 + 4, y1 + 2, 3.68), 2.4, WOOD)
    # roof
    hip_roof(b, x0 - 6, y0, x1 + 6, y1 + 4, 3.95, 4.35, 5, (120, 78, 58), shingle_p(8, 4), hipf=.32)
    b.line(((x0 + x1) / 2, (y0 + y1) / 2, 4.35), ((x0 + x1) / 2, (y0 + y1) / 2, 5.15), 2.2, DARKWOOD)
    b.face([((x0 + x1) / 2, (y0 + y1) / 2, 5.1), ((x0 + x1) / 2 + 26, (y0 + y1) / 2 + 4, 5.0),
            ((x0 + x1) / 2, (y0 + y1) / 2 + 4, 4.85)], (214, 62, 46), tex=speckle(.4))
    # ladder and a stone footing
    for py in (y1 - 4, y1 - 1):
        b.line((x0 + 8, py, 0), (x0 + 8, py, 2.95), 2, WOOD_D)
    for k in range(7):
        b.line((x0 + 8, y1 - 4, .3 + k * .38), (x0 + 8, y1 - 1, .3 + k * .38), 1.4, WOOD)
    b.box(x0 - 2, y1 - 6, x0 + 16, y1 + 6, 0, .5, STONE, top=mul(STONE, .95), top_tex=stone(6))
    finish(a, b, "watchtower", 2, 2)


@asset
def cemetery():
    """walled graveyard: grass, a gravel path, rows of headstones and a wooden cross"""
    a, b = building(2, 2, top=92, persp=.12)
    x0, y0, x1, y1 = site(b, .04, .04)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .32)
    b.face([(x0 + 8, y0 + 8, .01), (x1 - 8, y0 + 8, .01), (x1 - 8, y1 - 8, .01), (x0 + 8, y1 - 8, .01)],
           (84, 118, 60), tex=speckle(1.2, 50), shade=.2)
    b.face([(x0 + 30, y0 + 8, .02), (x0 + 38, y0 + 8, .02), (x0 + 38, y1 - 8, .02), (x0 + 30, y1 - 8, .02)],
           (176, 166, 146), tex=speckle(1.4, 40), shade=.12)
    # walls with a gate gap at the front
    for (ax, ay, bx, by) in ((x0, y0, x1, y0 + 7), (x0, y0, x0 + 7, y1), (x1 - 7, y0, x1, y1),
                             (x0, y1 - 7, x0 + 28, y1), (x0 + 40, y1 - 7, x1, y1)):
        b.box(ax, ay, bx, by, 0, .55, STONE, top=mul(STONE, 1.06), top_tex=stone(7))
    for px in (x0 + 28, x0 + 36):
        b.box(px, y1 - 9, px + 4, y1 + 1, 0, .85, STONE_L, top=mul(STONE_L, 1.05), top_tex=stone(5))
    # headstones
    for row, ry in enumerate((y0 + 22, y0 + 42, y0 + 62)):
        for col, rx in enumerate((x0 + 14, x0 + 26, x0 + 46, x0 + 58)):
            b.box(rx, ry, rx + 7, ry + 4, 0, .45, (168, 164, 158), top=(182, 178, 172))
            a.ell(b.sx(rx, ry + 2) - 1, b.sy(ry + 2, .45) - 3, b.sx(rx + 7, ry + 2) + 1,
                  b.sy(ry + 2, .45) + 3, (182, 178, 172), shade=.2)
    # wooden cross
    cx, cy = x0 + 50, y0 + 78
    b.line((cx, cy, 0), (cx, cy, 1.05), 2.2, WOOD_D)
    b.line((cx - 5, cy, .8), (cx + 5, cy, .8), 2, WOOD_D)
    finish(a, b, "cemetery", 2, 2)


@asset
def grave():
    """single grave: a grey headstone with a low mound of earth"""
    a, b = building(1, 1, top=70, persp=.12)
    x0, y0, x1, y1 = site(b, .18, .18)
    b.ground(x0 - 2, y0 - 2, x1 + 2, b.base + 2, (20, 14, 8), .4)
    b.box(x0 + 12, y0 + 10, x0 + 30, y0 + 18, 0, .1, (142, 116, 84), top=(150, 124, 90), top_tex=speckle(1.2))
    b.box(x0 + 14, y0 + 2, x0 + 28, y0 + 10, 0, .55, (168, 164, 158), top=(182, 178, 172), top_tex=stone(6))
    a.ell(b.sx(x0 + 14, y0 + 6) - 1, b.sy(y0 + 6, .55) - 5, b.sx(x0 + 28, y0 + 6) + 1,
          b.sy(y0 + 6, .55) + 5, (182, 178, 172), shade=.2)
    a.line([b.p(x0 + 21, y0 + 10, .35), b.p(x0 + 21, y0 + 10, .5)], 1.2, (120, 116, 110), hi=0)
    finish(a, b, "grave", 1, 1)


@asset
def crates():
    def crate(name, band, arrow):
        a, b = building(2, 2, top=110, persp=.16)
        x0, y0, x1, y1 = site(b, .14, .14)
        b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .4)
        b.box(x0, y0, x1, y1, 0, 1.7, PLANK, top=WOOD_L, top_tex=planks_h(8))
        # frame and diagonal brace
        for ax, ay, bx, by in ((x0, y1, x1, y1), (x0, y0, x0, y1), (x1, y0, x1, y1)):
            b.face([(ax, ay, 0), (bx, by, 0), (bx, by, 1.7), (ax, ay, 1.7)], mul(PLANK, .82))
        b.face([(x0, y1, .25), (x1, y1, .25), (x1, y1, .42), (x0, y1, .42)], WOOD_D)
        b.face([(x0, y1, 1.3), (x1, y1, 1.3), (x1, y1, 1.47), (x0, y1, 1.47)], WOOD_D)
        b.line((x0 + 2, y1, .25), (x1 - 2, y1, 1.47), 3.4, WOOD_D)
        b.face([(x0 + 8, y1, .7), (x1 - 8, y1, .7), (x1 - 8, y1, 1.05), (x0 + 8, y1, 1.05)], band,
               tex=speckle(.5, 30))
        # lid frame and seam, so the top face reads as a lid rather than a board
        b.face([(x0 + 3, y0 + 3, 1.71), (x1 - 3, y0 + 3, 1.71), (x1 - 3, y1 - 3, 1.71),
                (x0 + 3, y1 - 3, 1.71)], mul(PLANK, 1.08))
        b.face([(x0 + 7, y0 + 7, 1.72), (x1 - 7, y0 + 7, 1.72), (x1 - 7, y1 - 7, 1.72),
                (x0 + 7, y1 - 7, 1.72)], mul(PLANK, .93))
        b.line((x0 + 5, (y0 + y1) / 2, 1.73), (x1 - 5, (y0 + y1) / 2, 1.73), 1.6, WOOD_D)
        arrow(a, b, (x0 + x1) / 2, y1)
        for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
            b.box(x0 + dx * (x1 - x0 - 8), y1 - 2, x0 + dx * (x1 - x0 - 8) + 8, y1 + 1, 1.55, 1.65, IRON)
        finish(a, b, name, 2, 2)

    def up(a, b, x, y):
        cx, cy = b.sx(x, y), b.sy(y, .9)
        a.poly([(cx, cy - 9), (cx + 12, cy + 2), (cx + 4, cy + 2), (cx + 4, cy + 9),
                (cx - 4, cy + 9), (cx - 4, cy + 2), (cx - 12, cy + 2)], (236, 250, 230), edge=.4, shade=.1)

    def down(a, b, x, y):
        cx, cy = b.sx(x, y), b.sy(y, .9)
        a.poly([(cx, cy + 9), (cx + 12, cy - 2), (cx + 4, cy - 2), (cx + 4, cy - 9),
                (cx - 4, cy - 9), (cx - 4, cy - 2), (cx - 12, cy - 2)], (230, 242, 252), edge=.4, shade=.1)

    crate("supply-crate", (74, 150, 70), up)
    crate("demand-crate", (66, 112, 176), down)


@asset
def compost_bin():
    """slatted compost bin with a steaming heap and leaves"""
    a, b = building(2, 2, top=104, persp=.16)
    x0, y0, x1, y1 = site(b, .12, .12)
    b.ground(x0 - 4, y0 - 4, x1 + 4, b.base + 4, (20, 14, 8), .38)
    b.box(x0, y0, x1, y1, 0, 1.3, (124, 96, 64), top=mul((124, 96, 64), .82), top_tex=planks_h(6))
    # heap above the rim
    b.ell(x0 + 8, y0 + 8, x1 - 8, y1 - 8, 1.31, (62, 44, 30), tex=speckle(2.2, 90), shade=.3, grain=12)
    b.ell(x0 + 16, y0 + 14, x1 - 20, y1 - 18, 1.5, (74, 54, 38), tex=speckle(2.2, 90), shade=.25, grain=10)
    # slats and posts
    for x in (x0, x1 - 6):
        b.box(x, y0, x + 6, y1, 0, 1.35, WOOD_D, top=mul(WOOD_D, 1.1))
    for k in range(4):
        b.face([(x0 + 8, y1, .12 + k * .3), (x1 - 8, y1, .12 + k * .3), (x1 - 8, y1, .27 + k * .3),
                (x0 + 8, y1, .27 + k * .3)], mul(PLANK, .9))
    # leaves and steam
    for (lx, ly, lc) in ((x0 + 6, y1 - 6, (110, 184, 96)), (x1 - 10, y1 - 2, (140, 170, 80)),
                         (x0 + 30, y1 + 1, (96, 168, 84))):
        a.ell(b.sx(lx, ly) - 5, b.sy(ly, .1) - 3, b.sx(lx, ly) + 5, b.sy(ly, .1) + 3, lc, shade=.3)
    smoke(a, b.sx((x0 + x1) / 2, (y0 + y1) / 2), b.sy((y0 + y1) / 2, 1.6), 2, .3)
    finish(a, b, "compost-bin", 2, 2)


@asset
def well():
    """stone well: ring, two posts, a shingle roof and a bucket on a rope"""
    a, b = building(1, 1, top=90, persp=.12)
    x0, y0, x1, y1 = site(b, .10, .10)
    b.ground(x0 - 2, y0 - 2, x1 + 2, b.base + 2, (20, 14, 8), .42)
    b.box(x0, y0, x1, y1, 0, .8, (136, 132, 124), top=(150, 146, 136), top_tex=stone(7))
    b.ell(x0 + 7, y0 + 7, x1 - 7, y1 - 7, .81, (52, 120, 190), shade=.4, grain=5)
    b.ell(x0 + 10, y0 + 10, x1 - 10, y1 - 10, .82, (66, 138, 204), shade=.3, grain=5)
    for x in (x0 + 4, x1 - 8):
        b.line((x, y0 + 8, .8), (x, y0 + 8, 2.0), 2.6, WOOD_D)
        b.line((x, y1 - 8, .8), (x, y1 - 8, 2.0), 2.6, WOOD_D)
    b.face([(x0 - 4, y0 + 2, 2.25), (x1 + 4, y0 + 2, 2.25), (x1 + 4, y1 - 2, 1.98),
            (x0 - 4, y1 - 2, 1.98)], (120, 80, 56), tex=shingle_p(6, 4), shade=.2)
    b.line((x0 + 6, y0 + 8, 1.9), (x1 - 6, y0 + 8, 1.9), 1.6, IRON_D)
    b.line((x0 + 6, y1 - 8, 1.9), (x1 - 6, y1 - 8, 1.9), 1.6, IRON_D)
    b.line(((x0 + x1) / 2, y0 + 8, 1.9), ((x0 + x1) / 2, y0 + 8, 1.15), 1, (200, 190, 160), shade=0)
    b.box((x0 + x1) / 2 - 4, y0 + 6, (x0 + x1) / 2 + 4, y0 + 11, .95, 1.15, WOOD, top=mul(WOOD, 1.1))
    finish(a, b, "well", 1, 1)


@asset
def ledger():
    """Circuit Ledger (#92): a plank notice board on two posts, pinned stock sheets and a green signal lamp
    on top - the colony's numbers, readable by any wire"""
    a, b = building(1, 1, top=100, persp=.12)
    x0, y0, x1, y1 = site(b, .16, .16)
    b.ground(x0 - 2, y0 - 2, x1 + 2, b.base + 2, (20, 14, 8), .4)
    # two posts holding the board up (same depth band as the board, so the legs sit under it)
    for px in (x0 + 9, x1 - 9):
        b.box(px - 3, y0 + 8, px + 3, y0 + 16, 0, 1.08, WOOD_D, top=mul(WOOD_D, 1.12))
    # the board itself: a thick plank standing between the posts, with a darker frame rail around it
    b.box(x0 + 2, y0 + 8, x1 - 2, y0 + 16, 1.0, 1.06, WOOD_D)
    b.box(x0 + 4, y0 + 10, x1 - 4, y0 + 16, 1.06, 1.86, WOOD, top=mul(WOOD, 1.14), top_tex=planks_h(6))
    # pinned stock sheets, drawn on the front face of the board
    def note(nx0, nx1, col):
        b.face([(nx0, y0 + 16, 1.20), (nx1, y0 + 16, 1.20), (nx1, y0 + 16, 1.74), (nx0, y0 + 16, 1.74)],
               col, shade=.10, edge=.25, grain=3)
        for row in range(3):
            z = 1.62 - row * .13
            b.line((nx0 + 2, y0 + 16.1, z), (nx1 - 2, y0 + 16.1, z), 1, (86, 82, 74))
    note(x0 + 6, x0 + 17, (236, 232, 216))
    note(x0 + 20, x1 - 6, (226, 220, 198), )
    # nailed-on signature plate at the bottom rail
    a.rect(b.sx(x0 + 10, y0 + 16) , b.sy(y0 + 16, 1.02) - 1, b.sx(x1 - 10, y0 + 16), b.sy(y0 + 16, 1.02) + 2,
           IRON_D, edge=.2, hi=.15)
    # signal lamp on a short mast, with the wire running off to the right
    cx = x1 - 22
    b.line((cx, y0 + 12, 1.86), (cx, y0 + 12, 2.62), 2.2, IRON_D)
    a.ell(b.sx(cx, y0 + 12) - 5, b.sy(y0 + 12, 2.62) - 5, b.sx(cx, y0 + 12) + 5,
          b.sy(y0 + 12, 2.62) + 5, (108, 214, 122), shade=.18, edge=.35, hi=.65)
    a.glint(b.sx(cx, y0 + 12) - 4, b.sy(y0 + 12, 2.62) - 4, b.sx(cx, y0 + 12) + 1,
            b.sy(y0 + 12, 2.62) + 1, .5)
    a.line([(b.sx(cx, y0 + 12) + 5, b.sy(y0 + 12, 2.62)), (a.w - 6, b.sy(y0 + 12, 2.62) + 10),
            (a.w - 4, b.sy(y0 + 12, 2.62) + 26)], 1.4, (54, 44, 34))
    finish(a, b, "ledger", 1, 1)


@asset
def tool_rack():
    """a board of tools leaning against a wall"""
    a, b = building(1, 1, top=80, persp=.12)
    x0, y0, x1, y1 = site(b, .14, .14)
    b.ground(x0 - 2, y0 - 2, x1 + 2, b.base + 2, (20, 14, 8), .4)
    b.box(x0 + 2, y0 + 4, x1 - 2, y0 + 12, 0, 1.25, (132, 96, 60), top=mul((132, 96, 60), 1.1),
          top_tex=planks_h(5))
    b.box(x0 + 2, y0 + 4, x0 + 6, y0 + 12, 0, 1.35, WOOD_D)
    b.box(x1 - 6, y0 + 4, x1 - 2, y0 + 12, 0, 1.35, WOOD_D)
    # axe and pick
    b.line((x0 + 14, y0 + 8, .2), (x0 + 18, y0 + 8, 1.2), 2.4, WOOD_D)
    b.face([(x0 + 10, y0 + 8, 1.15), (x0 + 20, y0 + 8, 1.15), (x0 + 20, y0 + 8, 1.35),
            (x0 + 10, y0 + 8, 1.35)], STEEL, shade=.3)
    b.line((x0 + 30, y0 + 8, .2), (x0 + 30, y0 + 8, 1.2), 2.4, WOOD_D)
    a.arc(b.sx(x0 + 30, y0 + 8), b.sy(y0 + 8, 1.15), 9, 5, 200, 340, 2.6, STEEL)
    finish(a, b, "tool-rack", 1, 1)


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
        register(name, 64, 64, .5, (0.0, 0.0))

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
    a.save(path("bush"), shadow=SHADOW, ground=a.h - 4)
    register("bush", 64, 64, .7, (0.0, 0.0))


@asset
def colonist():
    def figure(a, ox, sw, bob):
        a.ao(ox + 16, 50, ox + 48, 61, .6, 2)
        a.line([(ox + 27, 40 + bob), (ox + 27, 49 + sw)], 6, (62, 66, 80))
        a.line([(ox + 37, 40 + bob), (ox + 37, 49 - sw)], 6, (62, 66, 80))
        a.ell(ox + 23, 47 + sw, ox + 31, 55 + sw, (90, 62, 40), shade=.3)
        a.ell(ox + 33, 47 - sw, ox + 41, 55 - sw, (90, 62, 40), shade=.3)
        a.line([(ox + 21, 29 + bob), (ox + 18, 38 + bob - sw)], 5, (96, 112, 70))
        a.line([(ox + 43, 29 + bob), (ox + 46, 38 + bob + sw)], 5, (96, 112, 70))
        a.ell(ox + 15.5, 36 + bob - sw, ox + 21, 41 + bob - sw, SKIN, shade=.2)
        a.ell(ox + 43, 36 + bob + sw, ox + 48.5, 41 + bob + sw, SKIN, shade=.2)
        a.rect(ox + 21, 24 + bob, ox + 43, 45 + bob, (100, 118, 72), r=4, tex=thatch(1), shade=.25)
        a.rect(ox + 21, 40 + bob, ox + 43, 44 + bob, (74, 52, 34), edge=.3, hi=0)
        a.line([(ox + 26, 25 + bob), (ox + 26, 43 + bob)], 2.4, (176, 132, 70))
        a.line([(ox + 38, 25 + bob), (ox + 38, 43 + bob)], 2.4, (176, 132, 70))
        a.ell(ox + 24, 9 + bob, ox + 40, 28 + bob, SKIN, shade=.2)
        a.ell(ox + 28.5, 19 + bob, ox + 30.5, 21 + bob, (30, 22, 18), edge=0, hi=0)
        a.ell(ox + 33.5, 19 + bob, ox + 35.5, 21 + bob, (30, 22, 18), edge=0, hi=0)
        a.ell(ox + 19, 9 + bob, ox + 45, 22 + bob, (120, 84, 48), shade=.3, tex=speckle(.5, 40))
        a.ell(ox + 25, 3 + bob, ox + 39, 16 + bob, (146, 104, 60), shade=.3)

    a = Art(64, 64)
    figure(a, 0, 0, 0)
    a.save(path("colonist"), shadow=SHADOW, ground=a.h - 4)
    register("colonist", 64, 64, .5, (0.0, 0.0))
    sheet = Art(64 * 8, 64)
    for i in range(8):
        ph = math.sin(i / 8 * math.tau)
        figure(sheet, i * 64, int(round(ph * 5)), -abs(ph) * 1.6)
    sheet.save(path("colonist-run"), shadow=SHADOW, frames=8, ground=sheet.h - 4)
    register("colonist-run", 512, 64, .5, (0.0, 0.0))


@asset
def boar():
    a = Art(64, 64)
    a.ao(6, 44, 60, 62, .6, 3)
    for x in (14, 22, 36, 44):
        a.line([(x, 38), (x + (1 if x % 2 else -1), 52)], 4.4, (66, 50, 40))
        a.ell(x - 3, 50, x + 3, 55, (30, 24, 20), shade=.2)
    a.poly([(10, 34), (14, 22), (22, 16), (34, 15), (44, 20), (48, 30), (46, 44), (34, 48), (18, 46)],
           (98, 80, 64), tex=combine(speckle(2.2, 80), thatch(1)), shade=.3, grain=10)
    a.line([(16, 20), (24, 15), (34, 14), (42, 18)], 3, (50, 38, 30), hi=0)
    a.line([(10, 30), (6, 26), (8, 22)], 1.6, (74, 56, 46), hi=0)
    a.ell(42, 22, 60, 44, (116, 92, 72), tex=speckle(1.6, 70), shade=.3, grain=10)
    a.ell(54, 30, 63, 40, (176, 130, 120), shade=.3)
    a.poly([(52, 41), (56, 49), (50, 43)], (236, 230, 210), edge=.4, hi=0)
    a.poly([(44, 22), (47, 12), (52, 22)], (80, 62, 50), shade=.2)
    a.ell(50, 27, 53, 30, (16, 12, 10), edge=0, hi=0)
    a.save(path("boar"), shadow=SHADOW, ground=a.h - 4)
    register("boar", 64, 64, .5, (0.0, 0.0))
    icon_of("boar")


@asset
def passenger_coach():
    """icon only: a small green passenger carriage in side view"""
    a = Art(64, 64)
    a.rect(6, 22, 58, 46, (92, 164, 92), r=3, tex=speckle(.5, 30), shade=.3)
    a.rect(4, 14, 60, 23, (56, 108, 58), r=2, shade=.25)
    a.rect(6, 38, 58, 41, (230, 212, 130), shade=.2)
    for x in (12, 26, 40):
        a.rect(x, 26, x + 9, 35, GLASS_LIT, shade=.2)
    a.ell(10, 42, 22, 54, IRON_D, shade=.3)
    a.ell(42, 42, 54, 54, IRON_D, shade=.3)
    done(a, "icon-passenger-coach")
    register("icon-passenger-coach", 64, 64, .5, (0.0, 0.0))


@asset
def herbal_medicine():
    """icon only: a corked bottle of green tincture with a label and a sprig"""
    a = Art(64, 64)
    a.rect(28, 14, 36, 26, (150, 170, 160), shade=.25)
    a.rect(26, 8, 38, 16, (176, 128, 80), tex=planks_v(3), shade=.3, r=2)
    a.ell(16, 24, 48, 58, (74, 150, 84), shade=.35, edge=.55)
    a.rect(23, 38, 41, 50, (236, 226, 200), shade=.15, r=1)
    a.line([(26, 43), (38, 43)], 1.5, (110, 96, 74), shade=0, hi=0)
    a.line([(26, 47), (36, 47)], 1.5, (110, 96, 74), shade=0, hi=0)
    a.glint(20, 30, 25, 50, .5)
    a.line([(38, 22), (52, 10)], 2, (60, 112, 50), shade=.2, hi=0)
    a.poly([(46, 14), (56, 4), (60, 14), (50, 18)], (96, 166, 74), shade=.3)
    a.poly([(40, 18), (48, 10), (50, 20), (42, 24)], (84, 158, 66), shade=.3)
    done(a, "icon-herbal-medicine")
    register("icon-herbal-medicine", 64, 64, .5, (0.0, 0.0))


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
    a = Art(64, 64)                                                                                     # steel axe
    a.line([(14, 56), (42, 14)], 6, (94, 64, 42), shade=.25)
    a.poly([(30, 8), (56, 12), (52, 36), (42, 24)], (188, 198, 208), shade=.32, tex=speckle(.5, 40))
    a.glint(34, 12, 50, 26, .45)
    done(a, "icon-steel-axe")
    a = Art(64, 64)                                                                                     # steel pickaxe
    a.line([(14, 56), (40, 12)], 6, (94, 64, 42), shade=.25)
    a.arc(34, 30, 24, 22, 205, 335, 7, (188, 198, 208), shade=.32)
    a.glint(22, 12, 44, 20, .4)
    done(a, "icon-steel-pickaxe")
    a = Art(64, 64)                                                                                     # steel hoe
    a.line([(16, 56), (42, 18)], 5, (94, 64, 42), shade=.25)
    a.poly([(36, 14), (56, 20), (52, 36), (44, 28), (34, 24)], (188, 198, 208), shade=.32)
    a.glint(40, 18, 52, 28, .4)
    done(a, "icon-steel-hoe")
    a = Art(64, 64)                                                                                     # wooden trailer
    a.rect(8, 24, 56, 44, PLANK, tex=planks_h(5), shade=.2)
    a.rect(6, 20, 58, 26, WOOD_D, shade=.2)
    a.line([(8, 44), (56, 44)], 3, WOOD_D, shade=.2)
    a.line([(12, 24), (12, 44)], 2, WOOD_D, hi=0)
    a.line([(52, 24), (52, 44)], 2, WOOD_D, hi=0)
    a.ell(10, 40, 26, 56, IRON_D, shade=.3)
    a.ell(38, 40, 54, 56, IRON_D, shade=.3)
    a.ell(15, 45, 21, 51, IRON, shade=.2)
    a.ell(43, 45, 49, 51, IRON, shade=.2)
    a.line([(8, 30), (2, 30)], 2.5, IRON_D, shade=.2)
    done(a, "icon-wooden-trailer")
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
    a = Art(64, 64)                                                                                     # spade
    a.line([(20, 8), (20, 30)], 5, WOOD, shade=.25)                                                    # shaft
    a.line([(12, 8), (28, 8)], 4, WOOD_D, shade=.2)                                                    # T-grip
    a.poly([(10, 30), (30, 30), (28, 46), (20, 56), (12, 46)], STEEL, shade=.32, tex=speckle(.5, 40))
    a.glint(13, 32, 22, 44, .35)
    a.line([(20, 28), (20, 32)], 4, IRON_D, shade=.2)                                                  # socket
    done(a, "icon-spade")
    a = Art(64, 64)                                                                                     # bow
    a.arc(26, 32, 22, 26, 275, 85, 5, WOOD, shade=.25)
    a.line([(24, 8), (24, 56)], 1.5, (224, 224, 230), shade=0, edge=.2)
    a.line([(10, 32), (52, 32)], 2.5, WOOD_L, shade=.2)
    a.poly([(52, 28), (62, 32), (52, 36)], STEEL, shade=.3)
    a.poly([(10, 28), (16, 32), (10, 32)], (220, 220, 225))
    a.poly([(10, 36), (16, 32), (10, 32)], (220, 220, 225))
    done(a, "icon-bow")
    a = Art(64, 64)                                                                                     # arrow
    a.line([(12, 52), (48, 16)], 3, WOOD, shade=.2)
    a.poly([(46, 12), (56, 8), (52, 18), (44, 20)], STEEL, shade=.3)
    a.poly([(10, 54), (18, 54), (20, 44), (12, 44)], (230, 230, 235), shade=.1)
    a.poly([(8, 48), (8, 56), (18, 46)], (210, 210, 215), shade=.1)
    done(a, "icon-arrow")


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


def write_manifest():
    """Sprite geometry (source size, scale and the shift that keeps the footprint on the entity box).
    buildings.lua reads this, so art and prototypes can never disagree about a building's perspective."""
    path_ = os.path.join(os.path.dirname(OUT), "prototypes", "art_manifest.lua")
    lines = ["-- Generated by scripts/gen_art.py. Do not edit by hand.",
             "-- width/height are source px; scale is the engine scale; shift is in tiles.",
             "return {"]
    for name in sorted(BUILDINGS):
        m = BUILDINGS[name]
        sx, sy = m["shift"]
        lines.append('  ["%s"] = {width = %d, height = %d, scale = %s, shift = {%.6g, %.6g}},'
                     % (name, m["width"], m["height"], m["scale"], sx, sy))
    lines.append("}")
    with open(path_, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", path_)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    for name, fn in REGISTRY.items():
        if only in name:
            fn()
    if only:
        # A filtered run only knows the assets it drew; writing the manifest now would drop every other
        # entry and make buildings.lua assert at load. Full runs own the manifest.
        print("filtered run: art_manifest.lua left unchanged (run without a filter to update it)")
    else:
        write_manifest()
    print("wrote", len(os.listdir(OUT)), "files in", OUT)


if __name__ == "__main__":
    main()
