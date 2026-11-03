"""Tiny shaded-sprite toolkit (Pillow only) for scripts/gen_art.py.

Aims at Factorio's look: 3/4 top-down view, light from the top-left, soft cast shadow to the lower right,
grain, bevelled edges that are darkened rather than black-outlined, warm desaturated palette.
Everything is drawn at SS x resolution and downsampled.
"""
import math
import random
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4


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

    def save(self, path, size=None, shadow=(5, 4, 3, .45)):
        img = self.render(shadow)
        w, h = size or (self.w, self.h)
        img.resize((w, h), Image.LANCZOS).save(path)
