"""Tiny shaded-sprite toolkit (Pillow only) for scripts/gen_art.py.

Aims at Factorio's look: 3/4 top-down view, light from the top-left, soft cast shadow to the lower right,
grain, bevelled edges that are darkened rather than black-outlined, warm desaturated palette.
Everything is drawn at SS x resolution and downsampled.
"""
import math
import random
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4
FZ = 28.8          # art px per tile of *height* (0.45 x 64): 1 tile high = 16 screen px at scale 0.5


def mul(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c[:3])


def mix(a, b, t):
    return tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(3))


# ---- textures: tex(d, w, h, col) draws translucent detail on an RGB layer (sizes in supersampled px) ----

def _rnd(w, h):
    return random.Random(w * 7919 + h)


def planks_h(sp=9):
    def t(d, w, h, col):
        r = _rnd(w, h)
        y, row = 0, 0
        while y < h:
            a = r.randint(0, 40)
            d.rectangle((0, y, w, y + sp * SS), fill=(255, 255, 255, a) if row % 2 else (0, 0, 0, a))
            d.line((0, y, w, y), fill=(0, 0, 0, 90), width=SS)
            d.line((0, y + SS, w, y + SS), fill=(255, 255, 255, 30), width=SS)
            x = r.randint(0, 40 * SS)
            while x < w:
                d.line((x, y, x, y + sp * SS), fill=(0, 0, 0, 80), width=SS)
                x += r.randint(26 * SS, 60 * SS)
            for _ in range(2):
                gx = r.randint(0, max(1, w)); d.line((gx, y + 3 * SS, gx + r.randint(6, 16) * SS, y + 3 * SS), fill=(0, 0, 0, 28), width=SS)
            y += sp * SS; row += 1
    return t


def planks_v(sp=9):
    def t(d, w, h, col):
        r = _rnd(w, h)
        x = 0
        while x < w:
            a = r.randint(0, 36)
            d.rectangle((x, 0, x + sp * SS, h), fill=(255, 255, 255, a) if r.random() < .5 else (0, 0, 0, a))
            d.line((x, 0, x, h), fill=(0, 0, 0, 90), width=SS)
            d.line((x + SS, 0, x + SS, h), fill=(255, 255, 255, 28), width=SS)
            x += sp * SS
    return t


def logs(sp=9):
    def t(d, w, h, col):
        y = 0
        while y < h:
            d.line((0, y + SS, w, y + SS), fill=(255, 235, 190, 55), width=2 * SS)
            d.line((0, y + sp * SS - SS, w, y + sp * SS - SS), fill=(0, 0, 0, 100), width=2 * SS)
            y += sp * SS
    return t


def brick(bw=13, bh=6):
    def t(d, w, h, col):
        r = _rnd(w, h)
        y, row = 0, 0
        while y < h:
            d.line((0, y, w, y), fill=(0, 0, 0, 80), width=SS)
            x = (bw * SS // 2) if row % 2 else 0
            while x < w:
                d.line((x, y, x, y + bh * SS), fill=(0, 0, 0, 70), width=SS)
                d.rectangle((x + SS, y + SS, x + bw * SS, y + bh * SS), fill=(255, 255, 255, r.randint(0, 28)) if r.random() < .5 else (0, 0, 0, r.randint(0, 28)))
                x += bw * SS
            y += bh * SS; row += 1
    return t


def stone(cs=15):
    def t(d, w, h, col):
        r = _rnd(w, h)
        y = 0
        while y < h:
            rh = int(cs * SS * r.uniform(.7, 1.1))
            x = -r.randint(0, cs * SS)
            while x < w:
                cw = int(cs * SS * r.uniform(.8, 1.7))
                d.rectangle((x, y, x + cw, y + rh), fill=(255, 255, 255, r.randint(0, 34)) if r.random() < .5 else (0, 0, 0, r.randint(0, 34)))
                d.rectangle((x, y, x + cw, y + rh), outline=(0, 0, 0, 80), width=SS)
                d.line((x + SS, y + SS, x + cw - SS, y + SS), fill=(255, 255, 255, 40), width=SS)
                x += cw
            y += rh
    return t


def shingle(sw=10, sh=6):
    def t(d, w, h, col):
        r = _rnd(w, h)
        y, row = 0, 0
        while y < h:
            x = (sw * SS // 2) if row % 2 else 0
            while x < w:
                d.rectangle((x, y, x + sw * SS, y + sh * SS), fill=(255, 255, 255, r.randint(0, 26)) if r.random() < .5 else (0, 0, 0, r.randint(0, 30)))
                d.line((x, y, x, y + sh * SS), fill=(0, 0, 0, 80), width=SS)
                x += sw * SS
            d.line((0, y + sh * SS, w, y + sh * SS), fill=(0, 0, 0, 110), width=SS)
            d.line((0, y + sh * SS - SS, w, y + sh * SS - SS), fill=(255, 255, 255, 30), width=SS)
            y += sh * SS; row += 1
    return t


def shingle_p(sp=10, sh=6, grow=1.075):
    """Shingle rows with perspective: rows get taller toward the viewer (bottom of the mask), so a
    roof reads as a receding plane instead of a flat wall."""
    def t(d, w, h, col):
        r = _rnd(w, h)
        y, row, step = 0, 0, sh * SS
        while y < h:
            x = (sp * SS // 2) if row % 2 else 0
            while x < w:
                d.rectangle((x, y, x + sp * SS, y + step), fill=(255, 255, 255, r.randint(0, 26)) if r.random() < .5 else (0, 0, 0, r.randint(0, 30)))
                d.line((x, y, x, y + step), fill=(0, 0, 0, 80), width=SS)
                x += sp * SS
            d.line((0, y + step, w, y + step), fill=(0, 0, 0, 120), width=SS)
            d.line((0, y + step - SS, w, y + step - SS), fill=(255, 255, 255, 40), width=SS)
            y += step; row += 1
            step = min(step * grow, sh * SS * 2.4)
    return t


def thatch_p(n=500, grow=1.08):
    """Thatch rows that tighten toward the far edge, like shingle_p."""
    def t(d, w, h, col):
        r = _rnd(w, h)
        y, step = 0, 7 * SS
        while y < h:
            d.line((0, y, w, y), fill=(0, 0, 0, 45), width=SS)
            x = -r.randint(0, 20 * SS)
            while x < w:
                d.line((x, y, x + r.randint(4, 10) * SS, y + step), fill=(0, 0, 0, 42) if r.random() < .55 else (255, 245, 200, 38), width=SS)
                x += r.randint(5, 11) * SS
            y += step; step = min(step * grow, 7 * SS * 2.2)
    return t


def thatch(n=500):
    def t(d, w, h, col):
        r = _rnd(w, h)
        for _ in range(n * max(1, w * h // (400 * SS * SS))):
            x, y = r.randint(0, w), r.randint(0, h)
            L = r.randint(4, 10) * SS
            d.line((x, y, x + r.randint(-2, 2) * SS, y + L), fill=(0, 0, 0, 55) if r.random() < .5 else (255, 245, 200, 45), width=SS)
    return t


def tin(sp=5):
    def t(d, w, h, col):
        x = 0
        while x < w:
            d.rectangle((x, 0, x + sp * SS // 2, h), fill=(255, 255, 255, 40))
            d.rectangle((x + sp * SS // 2, 0, x + sp * SS, h), fill=(0, 0, 0, 40))
            x += sp * SS
    return t


def weave(sp=4):
    """coarse canvas weave: a crosshatch of warp and weft threads"""
    def t(d, w, h, col):
        for y in range(0, h, sp * SS):
            d.line((0, y, w, y), fill=(0, 0, 0, 34), width=SS)
        for x in range(0, w, sp * SS):
            d.line((x, 0, x, h), fill=(255, 255, 255, 26), width=SS)
    return t


def speckle(n=1.0, dark=60):
    def t(d, w, h, col):
        r = _rnd(w, h)
        for _ in range(int(n * w * h / (30 * SS * SS))):
            x, y = r.randint(0, w), r.randint(0, h)
            s = r.randint(1, 3) * SS
            d.ellipse((x, y, x + s, y + s), fill=(0, 0, 0, dark) if r.random() < .6 else (255, 255, 255, 40))
    return t


def combine(*fs):
    def t(d, w, h, col):
        for f in fs: f(d, w, h, col)
    return t


class View:
    """A 3/4 top-down view of a building standing on a wt x dt tile footprint.

    Plan coordinates: x 0..W (left to right), y 0..D (back to front), z in tiles. The ground plane is
    screen-aligned (Factorio tiles are squares), height is foreshortened by FZ, and a one-point
    perspective makes the back edge `persp` narrower than the front, so roofs are trapezoids and the
    side walls show as thin lit/shaded slivers. This is what makes a sprite read as a volume.
    """

    def __init__(self, art, wt, dt, pad=18, bottom=12, persp=.18):
        self.a = art
        self.W, self.D = wt * 64, dt * 64
        self.pad, self.bottom, self.persp = pad, bottom, persp
        self.base = art.h - bottom
        self.cx = pad + self.W / 2

    def s(self, y):
        return 1 - self.persp * (1 - y / self.D)

    def sx(self, x, y):
        return self.cx + (self.pad + x - self.cx) * self.s(y)

    def sy(self, y, z=0):
        return self.base - (self.D - y) - z * FZ

    def p(self, x, y, z=0):
        return (self.sx(x, y), self.sy(y, z))

    def poly(self, pts, col, **kw):
        self.a.poly([self.p(x, y, z) for x, y, z in pts], col, **kw)

    def face(self, pts, col, **kw):
        self.poly(pts, col, **kw)

    def line(self, p0, p1, w, col, **kw):
        self.a.line([self.p(*p0), self.p(*p1)], w, col, **kw)

    def box(self, x0, y0, x1, y1, z0, z1, col, top=None, west=None, east=None, south=None,
            top_tex=None, **kw):
        top = col if top is None else top
        west = mul(col, .92) if west is None else west
        east = mul(col, .7) if east is None else east
        south = mul(col, .82) if south is None else south
        self.face([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], top, tex=top_tex, **kw)
        self.face([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], west, **kw)
        self.face([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], east, **kw)
        self.face([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], south, **kw)

    def ell(self, x0, y0, x1, y1, z, col, **kw):
        """axis-aligned ellipse in plan, projected to a screen bbox (good enough for tank tops/well mouths)"""
        l = self.p(x0, (y0 + y1) / 2, z)
        r = self.p(x1, (y0 + y1) / 2, z)
        t = self.p((x0 + x1) / 2, y0, z)
        b = self.p((x0 + x1) / 2, y1, z)
        self.a.ell(l[0], t[1], r[0], b[1], col, **kw)

    def ground(self, x0, y0, x1, y1, col, alpha=.5, blur=5):
        """soft contact patch under the whole footprint"""
        pts = [self.p(x0, y0), self.p(x1, y0), self.p(x1, y1), self.p(x0, y1)]
        self.a.poly(pts, col, shade=0, grain=0, edge=0, hi=0, alpha=alpha)


class Art:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.size = (w * SS, h * SS)
        self.im = Image.new("RGBA", self.size, (0, 0, 0, 0))
        self.under = Image.new("RGBA", self.size, (0, 0, 0, 0))

    # ---- masks ----
    def _mask(self, fn):
        m = Image.new("L", self.size, 0)
        fn(ImageDraw.Draw(m))
        return m

    @staticmethod
    def _s(pts):
        return [(x * SS, y * SS) for x, y in pts]

    def paint(self, mask, col, shade=.2, tex=None, grain=8, edge=.55, hi=.5, alpha=1.0, ecol=(22, 14, 8)):
        bb = mask.getbbox()
        if not bb:
            return
        pad = 3 * SS
        x0, y0 = max(bb[0] - pad, 0), max(bb[1] - pad, 0)
        x1, y1 = min(bb[2] + pad, self.size[0]), min(bb[3] + pad, self.size[1])
        m = mask.crop((x0, y0, x1, y1)); w, h = m.size
        grad = Image.linear_gradient("L").resize((w, h))
        layer = Image.composite(Image.new("RGB", (w, h), mul(col, 1 - shade)), Image.new("RGB", (w, h), mul(col, 1 + shade)), grad)
        if tex:
            tex(ImageDraw.Draw(layer, "RGBA"), w, h, col)
        if grain:
            n = Image.effect_noise((max(1, w // SS), max(1, h // SS)), grain * 3).resize((w, h), Image.NEAREST)
            layer = ImageChops.overlay(layer, n.convert("RGB"))
        if edge:
            er = m.filter(ImageFilter.MinFilter(2 * SS + 1))
            e = ImageChops.subtract(m, er).filter(ImageFilter.GaussianBlur(SS * .35))
            layer.paste(ecol, (0, 0), e.point(lambda v: int(v * edge)))
        if hi:
            hl = ImageChops.subtract(m, ImageChops.offset(m, SS, SS)).filter(ImageFilter.GaussianBlur(SS * .3))
            layer.paste(mul(col, 1.7), (0, 0), hl.point(lambda v: int(v * hi)))
        rgba = layer.convert("RGBA")
        rgba.putalpha(m.point(lambda v: int(v * alpha)) if alpha < 1 else m)
        self.im.alpha_composite(rgba, (x0, y0))

    # ---- shapes (coords in final px) ----
    def poly(self, pts, col, **kw):
        self.paint(self._mask(lambda d: d.polygon(self._s(pts), fill=255)), col, **kw)

    def rect(self, x0, y0, x1, y1, col, r=0, **kw):
        box = (x0 * SS, y0 * SS, x1 * SS, y1 * SS)
        if r:
            self.paint(self._mask(lambda d: d.rounded_rectangle(box, radius=r * SS, fill=255)), col, **kw)
        else:
            self.paint(self._mask(lambda d: d.rectangle(box, fill=255)), col, **kw)

    def ell(self, x0, y0, x1, y1, col, **kw):
        self.paint(self._mask(lambda d: d.ellipse((x0 * SS, y0 * SS, x1 * SS, y1 * SS), fill=255)), col, **kw)

    def line(self, pts, w, col, **kw):
        sp = self._s(pts)

        def f(d):
            d.line(sp, fill=255, width=int(w * SS), joint="curve")
            for x, y in (sp[0], sp[-1]):
                d.ellipse((x - w * SS / 2, y - w * SS / 2, x + w * SS / 2, y + w * SS / 2), fill=255)
        kw.setdefault("hi", .35)
        self.paint(self._mask(f), col, **kw)

    def arc(self, cx, cy, rx, ry, a0, a1, w, col, n=24, **kw):
        pts = [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]
        self.line(pts, w, col, **kw)

    def shade(self, poly, a=.35, col=(0, 0, 0)):
        """translucent flat overlay (cast shadows, glow) without edge/bevel"""
        self.poly(poly, col, shade=0, grain=0, edge=0, hi=0, alpha=a)

    def glint(self, x0, y0, x1, y1, a=.7, col=(255, 255, 255)):
        m = self._mask(lambda d: d.ellipse((x0 * SS, y0 * SS, x1 * SS, y1 * SS), fill=255)).filter(ImageFilter.GaussianBlur(SS * .8))
        self.paint(m, col, shade=0, grain=0, edge=0, hi=0, alpha=a)

    def ao(self, x0, y0, x1, y1, a=.55, blur=4):
        """ground contact shadow below the sprite"""
        m = Image.new("L", self.size, 0)
        ImageDraw.Draw(m).ellipse((x0 * SS, y0 * SS, x1 * SS, y1 * SS), fill=int(255 * a))
        m = m.filter(ImageFilter.GaussianBlur(blur * SS))
        layer = Image.new("RGBA", self.size, (8, 6, 4, 0)); layer.putalpha(m)
        self.under.alpha_composite(layer)

    # ---- output ----
    def render(self, shadow=(5, 4, 3, .45)):
        out = self.under.copy()
        if shadow:
            dx, dy, blur, al = shadow
            a = self.im.getchannel("A")
            sh = Image.new("L", self.size, 0)
            sh.paste(a, (int(dx * SS), int(dy * SS)))
            sh = sh.filter(ImageFilter.GaussianBlur(blur * SS)).point(lambda v: int(v * al))
            layer = Image.new("RGBA", self.size, (8, 6, 4, 0)); layer.putalpha(sh)
            out.alpha_composite(layer)
        out.alpha_composite(self.im)
        return out

    def shadow_image(self, frames=1, kx=.55, sy=.42, alpha=112, ground=None):
        """Projected ground shadow as a separate layer (Factorio `draw_as_shadow`): each frame is sheared to
        the right and flattened about the sprite's ground line, on a canvas twice as wide, same centre.
        `ground` is the ground line in *final* art px (the bottom of the footprint), not the bbox bottom:
        props and chimneys would otherwise move it."""
        a = self.im.getchannel("A")
        fw = self.size[0] // frames
        H = self.size[1]
        base = (int(ground * SS) if ground is not None
                else (a.getbbox() or (0, 0, 0, H))[3] - 2 * SS)
        out = Image.new("L", (self.size[0] * 2, H), 0)
        for f in range(frames):
            fr = a.crop((f * fw, 0, (f + 1) * fw, H))
            pad = fw // 2
            k = kx / sy
            sh = Image.new("L", (fw * 2, H), 0)
            sh.paste(fr.transform((fw * 2, H), Image.AFFINE, (1, k, -pad - k * base, 0, 1 / sy, base - base / sy), Image.BILINEAR), (0, 0))
            out.paste(sh, (f * fw * 2, 0))
        out = out.filter(ImageFilter.GaussianBlur(SS * .85)).point(lambda v: min(255, v * alpha // 255))
        img = Image.new("RGBA", out.size, (0, 0, 0, 0)); img.putalpha(out)
        return img

    def save(self, path, shadow="proj", frames=1, size=None, ground=None):
        """main sprite (+ `<name>-shadow.png` when shadow == "proj"; "bake" burns a drop shadow into the sprite)"""
        w, h = size or (self.w, self.h)
        if shadow == "bake":
            out = self.under.copy()
            al = self.im.getchannel("A")
            sh = Image.new("L", self.size, 0); sh.paste(al, (2 * SS, 2 * SS))
            sh = sh.filter(ImageFilter.GaussianBlur(1.6 * SS)).point(lambda v: int(v * .55))
            layer = Image.new("RGBA", self.size, (8, 6, 4, 0)); layer.putalpha(sh)
            out.alpha_composite(layer); out.alpha_composite(self.im)
        else:
            out = self.under.copy(); out.alpha_composite(self.im)
        out.resize((w, h), Image.LANCZOS).save(path)
        if shadow == "proj":
            si = self.shadow_image(frames, ground=ground)
            si.resize((w * 2, h), Image.LANCZOS).save(path[:-4] + "-shadow.png")
