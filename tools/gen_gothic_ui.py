"""Generate a procedural gothic UI kit (panels in three decoration tiers, buttons with states, tabs, header,
divider, slot, scroll bar, progress bar) as 9-slice-ready PNGs for Velo.

    python tools/gen_gothic_ui.py <out dir> [--scale 2] [--palette crimson|royal|emerald|bone] [--check]

Everything is drawn from shapes (supersampled 4x, then downscaled), so it is crisp at any --scale and costs
nothing to regenerate in another palette. Next to the PNGs it writes .meta files (filter linear) and
`ui_kit.json`: per piece its size, 9-slice borders and the ornament span to keep unstretched, i.e. what a Sprite
needs:

    Sprite { texture = @asset("ui/gothic/panel_ornate.png")  draw_mode = "sliced"  size = [520, 360]
             border_left = 64  border_top = 72  border_right = 64  border_bottom = 64
             ornament_x = [104, 152] }

Tiers: panel_simple (double gold line, cut corners), panel_medium (+ corner brackets, edge diamonds, inner
line), panel_ornate (+ arched crest with a gem, corner filigree, studs). Buttons: button_<primary|secondary|gold>
with _hover (brighter + rim light), _pressed (darker, light from below) and _disabled (desaturated); the plate is
centred in the image (no drop shadow baked in), so text centred on the button is centred on the plate.

--check verifies every piece: the stretchable bands are the same along their stretch direction (so 9-slicing
never smears the art), the plate is centred, and the ornament span lies inside the centre band.
"""

import argparse
import json
import math
import pathlib

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4  # supersampling

PALETTES = {
    "crimson": {"plate": [(120, 24, 32), (62, 10, 18)], "panel": [(34, 24, 36), (16, 11, 20)],
                "gold": [(255, 236, 170), (214, 168, 80), (120, 78, 30)], "gem": (200, 30, 60),
                "secondary": [(64, 58, 78), (30, 26, 40)], "accent": (150, 30, 40)},
    "royal": {"plate": [(40, 60, 140), (16, 22, 64)], "panel": [(24, 26, 44), (10, 11, 22)],
              "gold": [(255, 238, 180), (210, 170, 90), (110, 76, 34)], "gem": (60, 110, 230),
              "secondary": [(60, 64, 80), (28, 30, 40)], "accent": (50, 80, 170)},
    "emerald": {"plate": [(26, 110, 70), (8, 48, 30)], "panel": [(18, 30, 26), (8, 14, 12)],
                "gold": [(250, 236, 176), (206, 170, 92), (112, 80, 36)], "gem": (40, 200, 120),
                "secondary": [(54, 66, 62), (24, 30, 28)], "accent": (30, 120, 80)},
    "bone": {"plate": [(176, 160, 132), (96, 84, 66)], "panel": [(54, 48, 44), (26, 23, 21)],
             "gold": [(250, 240, 210), (190, 170, 130), (96, 82, 62)], "gem": (170, 40, 40),
             "secondary": [(80, 74, 70), (40, 36, 34)], "accent": (120, 40, 36)},
}


# ---------- drawing helpers (all coordinates in final pixels; drawn at SS x) ----------

class Canvas:
    def __init__(self, w, h, k):
        self.k = k * SS  # final scale * supersampling
        self.W, self.H = int(round(w * k)), int(round(h * k))
        self.img = Image.new("RGBA", (self.W * SS, self.H * SS), (0, 0, 0, 0))

    def s(self, v):
        return v * self.k

    def pts(self, pts):
        return [(x * self.k, y * self.k) for x, y in pts]

    def mask(self):
        return Image.new("L", self.img.size, 0)

    def poly_mask(self, pts):
        m = self.mask()
        ImageDraw.Draw(m).polygon(self.pts(pts), fill=255)
        return m

    def fill(self, mask, colors, vertical=True):
        """fill `mask` with a gradient through `colors` (top -> bottom)"""
        g = gradient(self.img.size, colors, vertical)
        self.img.paste(g, (0, 0), mask)

    def line(self, pts, color, width, closed=True):
        d = ImageDraw.Draw(self.img)
        p = self.pts(pts)
        if closed:
            p = p + [p[0]]
        d.line(p, fill=color, width=max(1, int(round(self.s(width)))), joint="curve")

    def ellipse(self, cx, cy, r, color):
        d = ImageDraw.Draw(self.img)
        d.ellipse([self.s(cx - r), self.s(cy - r), self.s(cx + r), self.s(cy + r)], fill=color)

    def poly(self, pts, color):
        ImageDraw.Draw(self.img).polygon(self.pts(pts), fill=color)

    def glow(self, mask, color, radius):
        blur = mask.filter(ImageFilter.GaussianBlur(self.s(radius)))
        layer = Image.new("RGBA", self.img.size, color[:3] + (0,))
        layer.putalpha(blur.point(lambda v: int(v * color[3] / 255)))
        self.img = Image.alpha_composite(layer, self.img)

    def done(self):
        return self.img.resize((self.W, self.H), Image.LANCZOS)


def gradient(size, colors, vertical=True):
    w, h = size
    n = h if vertical else w
    strip = Image.new("RGBA", (1, n) if vertical else (n, 1))
    px = strip.load()
    for i in range(n):
        t = i / max(1, n - 1) * (len(colors) - 1)
        a = int(min(t, len(colors) - 2))
        f = t - a
        c = tuple(int(colors[a][j] + (colors[a + 1][j] - colors[a][j]) * f) for j in range(3)) + (255,)
        if vertical:
            px[0, i] = c
        else:
            px[i, 0] = c
    return strip.resize((w, h), Image.NEAREST)


def octagon(x0, y0, x1, y1, c):
    """a rectangle with its corners cut by c"""
    return [(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), (x0 + c, y1), (x0, y1 - c), (x0, y0 + c)]


def lozenge(x0, y0, x1, y1, p):
    """a plate with pointed left / right ends (p = point depth)"""
    my = (y0 + y1) / 2
    return [(x0 + p, y0), (x1 - p, y0), (x1, my), (x1 - p, y1), (x0 + p, y1), (x0, my)]


def diamond(cx, cy, r):
    return [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]


def ring(cv, outer, inner):
    m = cv.poly_mask(outer)
    m2 = cv.poly_mask(inner)
    return ImageChops.subtract(m, m2)


def darker(c, k):
    return tuple(int(v * k) for v in c[:3])


# ---------- pieces ----------

def panel(tier, pal, k):
    W, H = 192, 192
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    cut = {"simple": 10, "medium": 14, "ornate": 16}[tier]
    top = 14 if tier == "ornate" else 4  # room for the crest
    o = (4, top, W - 4, H - 4)
    rim = 4 if tier == "simple" else 5
    outer = octagon(*o, cut)
    inner = octagon(o[0] + rim, o[1] + rim, o[2] - rim, o[3] - rim, max(2, cut - rim * 0.6))
    cv.fill(cv.poly_mask(inner), pal["panel"])
    cv.fill(ring(cv, outer, inner), gold)
    cv.line(outer, darker(gold[2], 0.6) + (255,), 1)
    # second, thin inner line
    g2 = rim + (5 if tier == "simple" else 9)
    inner2 = octagon(o[0] + g2, o[1] + g2, o[2] - g2, o[3] - g2, max(2, cut - g2 * 0.5))
    cv.line(inner2, gold[1] + (200,), 1.2)
    orn_x = None
    if tier in ("medium", "ornate"):
        g3 = g2 + 4
        inner3 = octagon(o[0] + g3, o[1] + g3, o[2] - g3, o[3] - g3, max(2, cut - g3 * 0.5))
        cv.line(inner3, pal["accent"] + (170,), 1)
        # corner brackets
        for sx, sy in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
            x = o[0] if sx > 0 else o[2]
            y = o[1] if sy > 0 else o[3]
            b = [(x + sx * 6, y + sy * (cut + 14)), (x + sx * 6, y + sy * 6), (x + sx * (cut + 14), y + sy * 6),
                 (x + sx * (cut + 14), y + sy * 10), (x + sx * 10, y + sy * 10), (x + sx * 10, y + sy * (cut + 14))]
            cv.poly(b, gold[0] + (255,))
            cv.line(b, darker(gold[2], 0.7) + (255,), 0.8)
            cv.poly(diamond(x + sx * 8, y + sy * 8, 3.2), pal["gem"] + (255,))
        # edge diamonds: an ornament in the middle of each edge (kept unstretched)
        for cx, cy in ((W / 2, o[1] + rim / 2), (W / 2, o[3] - rim / 2), (o[0] + rim / 2, (o[1] + o[3]) / 2),
                       (o[2] - rim / 2, (o[1] + o[3]) / 2)):
            if tier == "ornate" and cy < H / 2 and abs(cx - W / 2) < 1:
                continue  # the crest replaces the top diamond
            cv.poly(diamond(cx, cy, 7), gold[0] + (255,))
            cv.line(diamond(cx, cy, 7), darker(gold[2], 0.6) + (255,), 0.8)
            cv.poly(diamond(cx, cy, 3), pal["gem"] + (255,))
        orn_x = [W / 2 - 10, W / 2 + 10]
    if tier == "ornate":
        # arched crest with a gem, over the top edge
        cx = W / 2
        arch = []
        for i in range(21):
            t = i / 20
            a = math.pi * t
            arch.append((cx - 22 * math.cos(a), o[1] + 4 - 18 * math.sin(a) ** 0.8))
        crest = [(cx - 26, o[1] + 6)] + arch + [(cx + 26, o[1] + 6), (cx + 14, o[1] + 12), (cx, o[1] + 16), (cx - 14, o[1] + 12)]
        cv.poly(crest, gold[1] + (255,))
        cv.line(crest, darker(gold[2], 0.6) + (255,), 1)
        cv.poly([(cx, o[1] - 13), (cx + 7, o[1] - 2), (cx, o[1] + 9), (cx - 7, o[1] - 2)], pal["gem"] + (255,))
        cv.ellipse(cx - 2, o[1] - 3, 1.6, (255, 255, 255, 170))
        cv.poly([(cx, o[1] - 19), (cx + 2.5, o[1] - 13), (cx - 2.5, o[1] - 13)], gold[0] + (255,))
        # filigree in the corners: two curls
        for sx, sy in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
            x = o[0] if sx > 0 else o[2]
            y = o[1] if sy > 0 else o[3]
            pts = []
            for i in range(24):
                t = i / 23
                a = t * math.pi * 1.5
                r = 4 + 10 * (1 - t)
                pts.append((x + sx * (22 + r * math.cos(a)), y + sy * (22 + r * math.sin(a))))
            cv.line(pts, gold[1] + (230,), 1.4, closed=False)
            cv.ellipse(x + sx * 22, y + sy * 22, 2, gold[0] + (255,))
        # studs along the bottom corners
        for sx in (1, -1):
            x = o[0] + 34 if sx > 0 else o[2] - 34
            cv.ellipse(x, o[3] - rim / 2, 2.2, gold[0] + (255,))
        orn_x = [W / 2 - 28, W / 2 + 28]
    img = cv.done()
    b = {"simple": (28, 28), "medium": (40, 40), "ornate": (52, 56)}[tier]
    border = {"left": b[0], "right": b[0], "top": b[1] + (top - 4), "bottom": b[0]}
    info = {"size": [W, H], **border}
    if orn_x:
        info["ornament_x"] = [round(orn_x[0]), round(orn_x[1])]
        cy = (o[1] + o[3]) / 2  # the side diamonds
        info["ornament_y"] = [round(cy - 10), round(cy + 10)]
    return img, info


def button(kind, state, pal, k):
    W, H = 160, 56
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    base = {"primary": pal["plate"], "secondary": pal["secondary"], "gold": [gold[1], gold[2]]}[kind]
    if state == "hover":
        base = [tuple(min(255, int(v * 1.25 + 14)) for v in c) for c in base]
    elif state == "pressed":
        base = [darker(base[1], 1.0), darker(base[0], 0.85)]  # light from below
    elif state == "disabled":
        base = [tuple(int(sum(c) / 3 * 0.8) for _ in range(3)) for c in base]
    rim_c = gold if state != "disabled" else [(170, 168, 160), (120, 118, 112), (70, 68, 64)]
    o = (4, 4, W - 4, H - 4)
    p = 14
    outer = lozenge(*o, p)
    inner = lozenge(o[0] + 4, o[1] + 4, o[2] - 4, o[3] - 4, p - 2.5)
    if state == "hover":
        cv.glow(cv.poly_mask(outer), rim_c[0] + (150,), 3)
    cv.fill(cv.poly_mask(inner), base)
    if kind == "gold":
        rim_c = [(255, 250, 220), (180, 130, 50), (90, 60, 20)]
    cv.fill(ring(cv, outer, inner), rim_c)
    cv.line(outer, darker(rim_c[2], 0.6) + (255,), 1)
    # glossy band (top half) or inner shadow (pressed)
    hl = lozenge(o[0] + 7, o[1] + 6, o[2] - 7, (o[1] + o[3]) / 2, p - 5)
    if state == "pressed":
        cv.line(lozenge(o[0] + 5, o[1] + 5, o[2] - 5, o[3] - 5, p - 3), (0, 0, 0, 110), 2)
    elif state != "disabled":
        m = cv.poly_mask(hl)
        cv.img.paste(Image.new("RGBA", cv.img.size, (255, 255, 255, 34 if state == "normal" else 52)), (0, 0), m)
    # small studs at the points
    for x in (o[0] + 7, o[2] - 7):
        cv.poly(diamond(x, H / 2, 3), (rim_c[0] if kind != "gold" else pal["gem"]) + (255,))
    img = cv.done()
    # pointed ends and the gloss band must not stretch vertically: top + bottom cover the whole height, so
    # a taller button scales uniformly instead
    return img, {"size": [W, H], "left": 26, "right": 26, "top": H // 2, "bottom": H - H // 2}


def tab(active, pal, k):
    W, H = 120, 48
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    o = (4, 4, W - 4, H)
    outer = [(o[0], o[3]), (o[0], o[1] + 12), (o[0] + 12, o[1]), (o[2] - 12, o[1]), (o[2], o[1] + 12), (o[2], o[3])]
    inner = [(o[0] + 4, o[3]), (o[0] + 4, o[1] + 14), (o[0] + 14, o[1] + 4), (o[2] - 14, o[1] + 4), (o[2] - 4, o[1] + 14), (o[2] - 4, o[3])]
    cv.fill(cv.poly_mask(inner), pal["plate"] if active else pal["secondary"])
    cv.fill(ring(cv, outer, inner), gold if active else [darker(c, 0.75) for c in gold])
    if active:
        cv.poly(diamond(W / 2, o[1] + 2, 4), pal["gem"] + (255,))
    img = cv.done()
    return img, {"size": [W, H], "left": 20, "right": 20, "top": 18, "bottom": 6,
                 **({"ornament_x": [W // 2 - 6, W // 2 + 6]} if active else {})}


def header(pal, k):
    W, H = 320, 72
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    o = (2, 8, W - 2, H - 8)
    tail = 26
    outer = [(o[0], o[1]), (o[2], o[1]), (o[2] - tail, (o[1] + o[3]) / 2), (o[2], o[3]), (o[0], o[3]), (o[0] + tail, (o[1] + o[3]) / 2)]
    inner = [(o[0] + 12, o[1] + 4), (o[2] - 12, o[1] + 4), (o[2] - tail - 3, (o[1] + o[3]) / 2), (o[2] - 12, o[3] - 4),
             (o[0] + 12, o[3] - 4), (o[0] + tail + 3, (o[1] + o[3]) / 2)]
    cv.fill(cv.poly_mask(inner), pal["plate"])
    cv.fill(ring(cv, outer, inner), gold)
    cv.line(outer, darker(gold[2], 0.6) + (255,), 1)
    cx = W / 2
    cv.poly(diamond(cx, o[1], 9), gold[0] + (255,))
    cv.poly(diamond(cx, o[1], 4), pal["gem"] + (255,))
    cv.poly(diamond(cx, o[3], 6), gold[0] + (255,))
    img = cv.done()
    return img, {"size": [W, H], "left": 48, "right": 48, "top": H // 2, "bottom": H - H // 2, "ornament_x": [round(cx - 12), round(cx + 12)]}


def divider(pal, k):
    W, H = 240, 20
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    cy = H / 2
    cv.line([(8, cy), (W - 8, cy)], gold[1] + (255,), 1.5, closed=False)
    cv.poly(diamond(W / 2, cy, 7), gold[0] + (255,))
    cv.poly(diamond(W / 2, cy, 3), pal["gem"] + (255,))
    for x in (6, W - 6):
        cv.poly(diamond(x, cy, 3.5), gold[0] + (255,))
    img = cv.done()
    return img, {"size": [W, H], "left": 12, "right": 12, "top": H // 2, "bottom": H - H // 2, "ornament_x": [round(W / 2 - 9), round(W / 2 + 9)]}


def slot(pal, k):
    W = H = 72
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    outer = octagon(3, 3, W - 3, H - 3, 8)
    inner = octagon(7, 7, W - 7, H - 7, 6)
    cv.fill(cv.poly_mask(inner), [darker(pal["panel"][1], 0.8), pal["panel"][0]])
    cv.fill(ring(cv, outer, inner), gold)
    img = cv.done()
    return img, {"size": [W, H], "left": 14, "right": 14, "top": 14, "bottom": 14}


def bar(kind, pal, k):
    W, H = 160, 28
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    if kind == "frame":
        outer = octagon(2, 2, W - 2, H - 2, 6)
        inner = octagon(5, 5, W - 5, H - 5, 4)
        cv.fill(cv.poly_mask(inner), [(10, 8, 12), (24, 18, 26)])
        cv.fill(ring(cv, outer, inner), gold)
        info = {"left": 12, "right": 12, "top": 9, "bottom": 9}
    else:
        col = {"fill_hp": [(240, 80, 70), (150, 20, 24)], "fill_mana": [(110, 150, 255), (30, 50, 150)],
               "fill_xp": [(250, 220, 110), (170, 120, 30)]}[kind]
        cv.fill(cv.poly_mask(octagon(5, 5, W - 5, H - 5, 4)), col)
        m = cv.poly_mask(octagon(7, 6, W - 7, H / 2, 3))
        cv.img.paste(Image.new("RGBA", cv.img.size, (255, 255, 255, 50)), (0, 0), m)
        info = {"left": 10, "right": 10, "top": H // 2, "bottom": H - H // 2}
    return cv.done(), {"size": [W, H], **info}


def scroll(kind, pal, k):
    W, H = 14, 64
    cv = Canvas(W, H, k)
    gold = pal["gold"]
    if kind == "track":
        cv.fill(cv.poly_mask(octagon(4, 2, W - 4, H - 2, 3)), [(10, 8, 12), (22, 18, 24)])
        cv.line(octagon(4, 2, W - 4, H - 2, 3), darker(gold[2], 0.9) + (255,), 1)
    else:
        cv.fill(cv.poly_mask(octagon(2, 2, W - 2, H - 2, 5)), [gold[2], gold[0], gold[1], gold[2]], vertical=False)
        cv.poly(diamond(W / 2, H / 2, 3), pal["gem"] + (255,))
    return cv.done(), {"size": [W, H], "left": W // 2, "right": W - W // 2, "top": 10, "bottom": 10,
                       **({"ornament_y": [H // 2 - 5, H // 2 + 5]} if kind == "thumb" else {})}


# ---------- checks ----------

def band_ok(img, info, k):
    """the stretchable bands must change only smoothly along their stretch direction (a gradient is fine,
    a detail is not: it would be smeared), outside the ornament span"""
    src = img.convert("RGBA").load()
    w, h = img.size

    class _PM:  # premultiplied colour: what is seen (an invisible pixel's rgb does not matter)
        def __getitem__(self, xy):
            r, g, b, a = src[xy]
            return (r * a // 255, g * a // 255, b * a // 255, a)

    px = _PM()
    sc = lambda v: int(round(v * k))
    l, r, t, b = sc(info["left"]), sc(info["right"]), sc(info["top"]), sc(info["bottom"])
    ox = [sc(v) for v in info.get("ornament_x", [0, 0])]
    oy = [sc(v) for v in info.get("ornament_y", [0, 0])]
    worst = 0
    where = ""
    # horizontal bands (top / bottom edges and centre rows): columns between l and w - r should match
    for y in range(h):
        ref = None
        for x in range(l + 1, w - r - 1):
            if ox[1] > ox[0] and ox[0] - 2 <= x <= ox[1] + 2:
                continue
            c = px[x, y]
            if ref is not None:
                d = max(abs(c[i] - ref[i]) for i in range(4))
                if d > worst:
                    worst, where = d, f"row y={y / k:.0f} at x={x / k:.0f}"
            ref = c
    for x in range(w):
        ref = None
        for y in range(t + 1, h - b - 1):
            if oy[1] > oy[0] and oy[0] - 2 <= y <= oy[1] + 2:
                continue
            c = px[x, y]
            if ref is not None:
                d = max(abs(c[i] - ref[i]) for i in range(4))
                if d > worst:
                    worst, where = d, f"column x={x / k:.0f} at y={y / k:.0f}"
            ref = c
    return worst, where


def check(img, info, k, name):
    bad = []
    worst, where = band_ok(img, info, k)
    if worst > 24:
        bad.append(f"stretch band has a detail ({worst}) at {where}")
    a = img.split()[3].point(lambda v: 255 if v > 128 else 0)
    bb = a.getbbox()
    if bb and not name.startswith(("panel_ornate", "tab", "header")):
        w, h = img.size
        dx, dy = (bb[0] + bb[2]) / 2 - w / 2, (bb[1] + bb[3]) / 2 - h / 2
        if abs(dx) > 1.5 * k or abs(dy) > 1.5 * k:
            bad.append(f"plate off centre by {dx / k:+.1f}, {dy / k:+.1f}")
    for ax, lo, hi in (("ornament_x", info["left"], info["size"][0] - info["right"]),
                       ("ornament_y", info["top"], info["size"][1] - info["bottom"])):
        if ax in info and not (lo <= info[ax][0] < info[ax][1] <= hi):
            bad.append(f"{ax} {info[ax]} outside the centre band [{lo}, {hi}]")
    return worst, bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--scale", type=float, default=2, help="pixels per design unit (2 = crisp at 1080p)")
    ap.add_argument("--palette", default="crimson", choices=sorted(PALETTES))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    pal = PALETTES[a.palette]
    k = a.scale
    pieces = {}
    for tier in ("simple", "medium", "ornate"):
        pieces[f"panel_{tier}"] = panel(tier, pal, k)
    for kind in ("primary", "secondary", "gold"):
        for state in ("normal", "hover", "pressed", "disabled"):
            pieces[f"button_{kind}" + ("" if state == "normal" else f"_{state}")] = button(kind, state, pal, k)
    pieces["tab_active"] = tab(True, pal, k)
    pieces["tab_inactive"] = tab(False, pal, k)
    pieces["header"] = header(pal, k)
    pieces["divider"] = divider(pal, k)
    pieces["slot"] = slot(pal, k)
    for kind in ("frame", "fill_hp", "fill_mana", "fill_xp"):
        pieces[f"bar_{kind}"] = bar(kind, pal, k)
    pieces["scroll_track"] = scroll("track", pal, k)
    pieces["scroll_thumb"] = scroll("thumb", pal, k)
    manifest = {"scale": k, "palette": a.palette, "pieces": {}}
    problems = 0
    for name, (img, info) in pieces.items():
        img.save(out / f"{name}.png", optimize=True)
        meta = out / f"{name}.png.meta"
        if not meta.exists():  # keep ids stable across regenerations
            import random
            meta.write_text(f"id: {random.getrandbits(32):08x}\nkind: texture\nversion: 1\nfilter: linear\n")
        # borders / spans in texture pixels at this scale
        px = {key: ([round(v * k) for v in val] if isinstance(val, list) else round(val * k))
              for key, val in info.items() if key != "size"}
        px["size"] = list(img.size)
        manifest["pieces"][name] = px
        if a.check:
            worst, bad = check(img, info, k, name)
            problems += len(bad)
            print(f"{name:26s} {img.size[0]:4d}x{img.size[1]:<4d} band variation {worst:3d}  " + ("OK" if not bad else "; ".join(bad)))
    (out / "ui_kit.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    print(f"{len(pieces)} pieces -> {out} (palette {a.palette}, scale {k:g})" + (f", {problems} problem(s)" if a.check else ""))


if __name__ == "__main__":
    main()
