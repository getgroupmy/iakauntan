"""Drawing primitives for the Play Store asset mockups.

Pillow only. Everything is expressed in logical dp and multiplied by
`S` on the way out, so the same code emits a 1080x1920 phone frame and a
1024x500 banner without two sets of numbers.

The tokens below are lifted from `app/lib/src/core/theme.dart` — seed,
scaffold, the four tone colours — so a mockup drifts from the app only
where the layout drifts, never where the palette does.
"""
import math, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONTS = os.path.join(ROOT, 'app', 'assets', 'fonts')

# --- palette (theme.dart) -------------------------------------------------
ACCENT      = (11, 122, 107)     # AppTheme.seed 0xFF0B7A6B
ACCENT_DK   = (6, 78, 66)
ACCENT_SOFT = (225, 242, 238)
BG          = (246, 248, 248)    # scaffoldBackgroundColor light
CARD        = (255, 255, 255)
BORDER      = (227, 233, 231)
BORDER_SOFT = (238, 242, 241)
INK         = (16, 26, 23)
INK2        = (91, 106, 102)
INK3        = (142, 155, 151)
SUCCESS     = (4, 120, 87)       # AppColors.light.success
WARNING     = (180, 83, 9)
DANGER      = (220, 38, 38)
INFO        = (29, 78, 216)
VIOLET      = (109, 40, 217)
MARK_GREEN  = (11, 208, 11)      # brand/mark.py GREEN

SOFT = {  # tone -> (bg, fg) for chips and icon tiles
    'success': ((222, 242, 235), SUCCESS),
    'warning': ((252, 237, 219), WARNING),
    'danger':  ((253, 228, 228), DANGER),
    'info':    ((224, 232, 253), INFO),
    'violet':  ((237, 229, 253), VIOLET),
    'accent':  (ACCENT_SOFT, ACCENT),
    'grey':    ((238, 242, 241), INK2),
}

_FILES = {
    'r': 'PlusJakartaSans-Regular.ttf',
    'm': 'PlusJakartaSans-Medium.ttf',
    's': 'PlusJakartaSans-SemiBold.ttf',
    'b': 'PlusJakartaSans-Bold.ttf',
    'x': 'PlusJakartaSans-ExtraBold.ttf',
}
_cache = {}


def font(px, w='r'):
    key = (round(px), w)
    if key not in _cache:
        _cache[key] = ImageFont.truetype(os.path.join(FONTS, _FILES[w]), round(px))
    return _cache[key]


def canvas(w, h, bg=CARD):
    img = Image.new('RGB', (w, h), bg)
    return img, ImageDraw.Draw(img)


def blend(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


# --- text -----------------------------------------------------------------

def text(d, xy, s, px, w='r', fill=INK, anchor='la', max_w=None, spacing=0):
    f = font(px, w)
    s = str(s)
    if max_w is not None:
        s = ellipsize(d, s, f, max_w)
    if spacing:
        x, y = xy
        for ch in s:
            d.text((x, y), ch, font=f, fill=fill, anchor=anchor)
            x += d.textlength(ch, font=f) + spacing
        return
    d.text(xy, s, font=f, fill=fill, anchor=anchor)


def width(d, s, px, w='r'):
    return d.textlength(str(s), font=font(px, w))


def ellipsize(d, s, f, max_w):
    if d.textlength(s, font=f) <= max_w:
        return s
    while s and d.textlength(s + '…', font=f) > max_w:
        s = s[:-1]
    return s + '…'


def wrap(d, s, px, w, max_w):
    f = font(px, w)
    out, line = [], ''
    for word in s.split():
        t = (line + ' ' + word).strip()
        if d.textlength(t, font=f) <= max_w or not line:
            line = t
        else:
            out.append(line)
            line = word
    if line:
        out.append(line)
    return out


def paragraph(d, xy, s, px, w='r', fill=INK, max_w=1e9, leading=1.35):
    x, y = xy
    for line in wrap(d, s, px, w, max_w):
        d.text((x, y), line, font=font(px, w), fill=fill)
        y += px * leading
    return y


# --- boxes ----------------------------------------------------------------

def card(d, box, r=12, fill=CARD, border=BORDER, bw=1):
    d.rounded_rectangle(box, radius=r, fill=fill,
                        outline=border if border else None, width=bw)


def shadow(img, box, r=12, blur=14, alpha=26, dy=4):
    """A soft drop shadow composited under a rounded box."""
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        [box[0], box[1] + dy, box[2], box[3] + dy], radius=r, fill=(11, 40, 34, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    img.paste(Image.alpha_composite(img.convert('RGBA'), layer).convert('RGB'), (0, 0))


def chip(d, x, y, s, px, tone='grey', h=None, pad=None, weight='s'):
    bg, fg = SOFT[tone] if isinstance(tone, str) else tone
    h = h or px * 1.9
    pad = pad or px * 0.7
    w = d.textlength(str(s), font=font(px, weight)) + pad * 2
    d.rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=bg)
    d.text((x + w / 2, y + h / 2), str(s), font=font(px, weight), fill=fg, anchor='mm')
    return w


def tile(d, box, name, tone='accent', r=10, pad=0.28):
    bg, fg = SOFT[tone] if isinstance(tone, str) else tone
    d.rounded_rectangle(box, radius=r, fill=bg)
    s = min(box[2] - box[0], box[3] - box[1])
    p = s * pad
    icon(d, name, [box[0] + p, box[1] + p, box[2] - p, box[3] - p], fg)


def avatar(d, box, initials, seed=0):
    tones = ['accent', 'info', 'violet', 'warning', 'success']
    bg, fg = SOFT[tones[seed % len(tones)]]
    d.ellipse(box, fill=bg)
    h = box[3] - box[1]
    d.text(((box[0] + box[2]) / 2, (box[1] + box[3]) / 2 + h * 0.02), initials,
           font=font(h * 0.38, 'b'), fill=fg, anchor='mm')


def progress(d, box, frac, colour=ACCENT, track=(233, 238, 237)):
    h = box[3] - box[1]
    d.rounded_rectangle(box, radius=h / 2, fill=track)
    w = (box[2] - box[0]) * max(0.02, min(1, frac))
    d.rounded_rectangle([box[0], box[1], box[0] + w, box[3]], radius=h / 2, fill=colour)


# --- charts ---------------------------------------------------------------

def _smooth(vals, n):
    out = []
    for i in range(n):
        t = i / (n - 1) * (len(vals) - 1)
        a, b = int(t), min(int(t) + 1, len(vals) - 1)
        f = t - a
        f = f * f * (3 - 2 * f)
        out.append(vals[a] + (vals[b] - vals[a]) * f)
    return out


def sparkline(img, box, vals, colour=ACCENT, w=2.5, fill=True, dot=True):
    x0, y0, x1, y1 = box
    pts = _smooth(vals, 96)
    lo, hi = min(pts), max(pts)
    rng = (hi - lo) or 1
    xy = [(x0 + (x1 - x0) * i / (len(pts) - 1), y1 - (pts[i] - lo) / rng * (y1 - y0))
          for i in range(len(pts))]
    if fill:
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(xy + [(x1, y1), (x0, y1)], fill=colour + (46,))
        grad = Image.new('L', img.size, 0)
        gd = ImageDraw.Draw(grad)
        for yy in range(int(y0), int(y1) + 1):
            gd.line([(x0, yy), (x1, yy)], fill=int(255 * (1 - (yy - y0) / max(1, y1 - y0))))
        layer.putalpha(Image.composite(layer.split()[3], Image.new('L', img.size, 0),
                                       Image.new('L', img.size, 255)))
        a = layer.split()[3].point(lambda v: v)
        layer.putalpha(Image.eval(a, lambda v: v))
        base = img.convert('RGBA')
        m = Image.new('RGBA', img.size, (0, 0, 0, 0))
        md = ImageDraw.Draw(m)
        md.polygon(xy + [(x1, y1), (x0, y1)], fill=colour + (255,))
        alpha = Image.composite(grad, Image.new('L', img.size, 0), m.split()[3])
        alpha = alpha.point(lambda v: int(v * 0.30))
        tintpix = Image.new('RGBA', img.size, colour + (255,))
        tintpix.putalpha(alpha)
        img.paste(Image.alpha_composite(base, tintpix).convert('RGB'), (0, 0))
    d = ImageDraw.Draw(img)
    d.line(xy, fill=colour, width=round(w), joint='curve')
    if dot:
        r = w * 1.6
        d.ellipse([xy[-1][0] - r, xy[-1][1] - r, xy[-1][0] + r, xy[-1][1] + r], fill=colour)


def bars(d, box, vals, colour=ACCENT, soft=None, gap=0.34, r=3, highlight=-1):
    x0, y0, x1, y1 = box
    n = len(vals)
    step = (x1 - x0) / n
    bw = step * (1 - gap)
    hi = max(vals) or 1
    for i, v in enumerate(vals):
        h = (y1 - y0) * (v / hi)
        cx = x0 + step * i + (step - bw) / 2
        c = colour if (highlight < 0 or i == highlight) else (soft or blend(colour, CARD, 0.72))
        d.rounded_rectangle([cx, y1 - max(h, r * 2), cx + bw, y1], radius=r, fill=c)


def donut(img, box, parts, thickness=0.30):
    d = ImageDraw.Draw(img)
    total = sum(p[0] for p in parts) or 1
    a = -90
    for v, c in parts:
        sweep = 360 * v / total
        d.pieslice(box, a, a + sweep - 1.2, fill=c)
        a += sweep
    s = (box[2] - box[0]) * thickness
    d.ellipse([box[0] + s, box[1] + s, box[2] - s, box[3] - s], fill=CARD)


# --- icons ----------------------------------------------------------------
# Drawn, not fonted: Material Icons is not on this machine, and a mockup
# with tofu in the tab bar is worse than a mockup with hand-drawn glyphs.

def icon(d, name, box, colour=INK2, w=None):
    x0, y0, x1, y1 = box
    s = min(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    x0, y0, x1, y1 = cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2
    w = w or max(1.6, s * 0.10)
    R = lambda a, b, c, e, **k: d.rounded_rectangle(
        [x0 + s * a, y0 + s * b, x0 + s * c, y0 + s * e], **k)
    L = lambda pts, **k: d.line([(x0 + s * p[0], y0 + s * p[1]) for p in pts],
                                fill=k.get('fill', colour), width=round(k.get('width', w)),
                                joint='curve')
    P = lambda pts, **k: d.polygon([(x0 + s * p[0], y0 + s * p[1]) for p in pts],
                                   fill=k.get('fill', colour))
    E = lambda a, b, c, e, **k: d.ellipse([x0 + s * a, y0 + s * b, x0 + s * c, y0 + s * e], **k)

    if name == 'dashboard':
        for a, b, c, e in ((.10, .10, .45, .55), (.55, .10, .90, .38),
                           (.55, .48, .90, .90), (.10, .65, .45, .90)):
            R(a, b, c, e, radius=s * .07, fill=colour)
    elif name == 'receipt':
        P([(.16, .08), (.84, .08), (.84, .92), (.70, .80), (.56, .92),
           (.42, .80), (.28, .92), (.16, .80)])
        for yy in (.30, .46, .62):
            d.line([(x0 + s * .30, y0 + s * yy), (x0 + s * .70, y0 + s * yy)],
                   fill=CARD, width=round(w * .9))
    elif name == 'bag':
        R(.12, .30, .88, .92, radius=s * .10, fill=colour)
        d.arc([x0 + s * .30, y0 + s * .08, x0 + s * .70, y0 + s * .52],
              180, 360, fill=colour, width=round(w))
    elif name == 'people':
        E(.04, .16, .40, .52, fill=colour)
        E(.54, .22, .84, .52, fill=colour)
        d.pieslice([x0 - s * .02, y0 + s * .52, x0 + s * .46, y0 + s * 1.02],
                   180, 360, fill=colour)
        d.pieslice([x0 + s * .50, y0 + s * .56, x0 + s * .92, y0 + s * 1.0],
                   180, 360, fill=colour)
    elif name == 'person':
        E(.28, .10, .72, .54, fill=colour)
        d.pieslice([x0 + s * .12, y0 + s * .54, x0 + s * .88, y0 + s * 1.16],
                   180, 360, fill=colour)
    elif name == 'trending':
        L([(.10, .72), (.36, .44), (.54, .62), (.90, .22)], width=w * 1.1)
        P([(.92, .16), (.92, .46), (.62, .16)])
    elif name == 'falling':
        L([(.10, .26), (.36, .54), (.54, .36), (.90, .76)], width=w * 1.1)
        P([(.92, .82), (.92, .52), (.62, .82)])
    elif name == 'sparkle':
        for k, (px, py, r) in enumerate(((.46, .46, .30), (.80, .16, .14))):
            P([(px, py - r), (px + r * .28, py - r * .28), (px + r, py),
               (px + r * .28, py + r * .28), (px, py + r),
               (px - r * .28, py + r * .28), (px - r, py),
               (px - r * .28, py - r * .28)])
    elif name == 'search':
        d.ellipse([x0 + s * .10, y0 + s * .10, x0 + s * .70, y0 + s * .70],
                  outline=colour, width=round(w))
        L([(.64, .64), (.90, .90)], width=w * 1.1)
    elif name == 'filter':
        P([(.08, .14), (.92, .14), (.58, .52), (.58, .90), (.42, .80), (.42, .52)])
    elif name == 'plus':
        L([(.5, .14), (.5, .86)], width=w * 1.25)
        L([(.14, .5), (.86, .5)], width=w * 1.25)
    elif name == 'back':
        L([(.60, .14), (.26, .5), (.60, .86)], width=w * 1.15)
    elif name == 'chevron':
        L([(.36, .14), (.70, .5), (.36, .86)], width=w)
    elif name == 'menu':
        for yy in (.22, .5, .78):
            L([(.10, yy), (.90, yy)], width=w * 1.1)
    elif name == 'dots':
        for xx in (.18, .5, .82):
            E(xx - .10, .40, xx + .10, .60, fill=colour)
    elif name == 'more':
        for yy in (.22, .5, .78):
            for xx in (.22, .5, .78):
                E(xx - .09, yy - .09, xx + .09, yy + .09, fill=colour)
    elif name == 'bell':
        d.pieslice([x0 + s * .16, y0 + s * .10, x0 + s * .84, y0 + s * .84],
                   180, 360, fill=colour)
        R(.16, .46, .84, .70, radius=s * .04, fill=colour)
        R(.08, .66, .92, .78, radius=s * .06, fill=colour)
        E(.40, .80, .60, .96, fill=colour)
    elif name == 'refresh':
        d.arc([x0 + s * .12, y0 + s * .12, x0 + s * .88, y0 + s * .88],
              40, 330, fill=colour, width=round(w))
        P([(.86, .06), (.94, .38), (.62, .30)])
    elif name == 'calendar':
        R(.08, .18, .92, .92, radius=s * .10, outline=colour, width=round(w))
        L([(.08, .40), (.92, .40)], width=w)
        L([(.30, .06), (.30, .26)], width=w)
        L([(.70, .06), (.70, .26)], width=w)
        for xx in (.26, .50, .74):
            for yy in (.56, .76):
                E(xx - .06, yy - .06, xx + .06, yy + .06, fill=colour)
    elif name == 'bank':
        P([(.5, .06), (.96, .34), (.04, .34)])
        for xx in (.18, .42, .66):
            R(xx, .40, xx + .16, .78, fill=colour)
        R(.04, .82, .96, .94, radius=s * .04, fill=colour)
    elif name == 'check':
        L([(.16, .52), (.40, .76), (.84, .24)], width=w * 1.35)
    elif name == 'checkcircle':
        E(.04, .04, .96, .96, fill=colour)
        d.line([(x0 + s * .26, y0 + s * .52), (x0 + s * .44, y0 + s * .70),
                (x0 + s * .76, y0 + s * .32)], fill=CARD, width=round(w * 1.3), joint='curve')
    elif name == 'clock':
        E(.06, .06, .94, .94, outline=colour, width=round(w))
        L([(.5, .28), (.5, .54), (.72, .66)], width=w)
    elif name == 'doc':
        P([(.16, .06), (.62, .06), (.86, .30), (.86, .94), (.16, .94)])
        d.polygon([(x0 + s * .62, y0 + s * .06), (x0 + s * .86, y0 + s * .30),
                   (x0 + s * .62, y0 + s * .30)], fill=CARD)
        for yy in (.48, .64, .80):
            d.line([(x0 + s * .30, y0 + s * yy), (x0 + s * .72, y0 + s * yy)],
                   fill=CARD, width=round(w * .85))
    elif name == 'box':
        P([(.5, .06), (.94, .30), (.5, .54), (.06, .30)])
        P([(.06, .34), (.5, .58), (.5, .96), (.06, .72)])
        d.polygon([(x0 + s * .94, y0 + s * .34), (x0 + s * .5, y0 + s * .58),
                   (x0 + s * .5, y0 + s * .96), (x0 + s * .94, y0 + s * .72)],
                  fill=blend(colour, CARD, .30))
    elif name == 'card':
        R(.06, .20, .94, .80, radius=s * .10, fill=colour)
        d.rectangle([x0 + s * .06, y0 + s * .34, x0 + s * .94, y0 + s * .46], fill=CARD)
        R(.16, .58, .44, .68, radius=s * .03, fill=CARD)
    elif name == 'money':
        R(.04, .22, .96, .78, radius=s * .08, fill=colour)
        E(.38, .34, .62, .66, fill=CARD)
    elif name == 'wallet':
        R(.06, .18, .94, .86, radius=s * .12, fill=colour)
        R(.58, .42, .98, .62, radius=s * .08, fill=blend(colour, CARD, .55))
    elif name == 'chart':
        L([(.10, .90), (.90, .90)], width=w)
        for i, h in enumerate((.34, .56, .24, .70)):
            R(.14 + i * .20, .90 - h, .14 + i * .20 + .12, .90, radius=s * .03, fill=colour)
    elif name == 'pie':
        d.pieslice([x0 + s * .06, y0 + s * .06, x0 + s * .94, y0 + s * .94],
                   -90, 150, fill=colour)
        d.pieslice([x0 + s * .06, y0 + s * .06, x0 + s * .94, y0 + s * .94],
                   150, 270, fill=blend(colour, CARD, .55))
    elif name == 'shield':
        P([(.5, .04), (.90, .20), (.90, .52), (.5, .96), (.10, .52), (.10, .20)])
        d.line([(x0 + s * .30, y0 + s * .48), (x0 + s * .45, y0 + s * .64),
                (x0 + s * .72, y0 + s * .34)], fill=CARD, width=round(w * 1.2), joint='curve')
    elif name == 'lock':
        d.arc([x0 + s * .24, y0 + s * .08, x0 + s * .76, y0 + s * .62],
              180, 360, fill=colour, width=round(w * 1.1))
        R(.12, .42, .88, .94, radius=s * .10, fill=colour)
        E(.43, .60, .57, .74, fill=CARD)
    elif name == 'mail':
        R(.04, .18, .96, .82, radius=s * .08, fill=colour)
        d.line([(x0 + s * .08, y0 + s * .24), (x0 + s * .5, y0 + s * .56),
                (x0 + s * .92, y0 + s * .24)], fill=CARD, width=round(w), joint='curve')
    elif name == 'chat':
        R(.04, .10, .96, .74, radius=s * .14, fill=colour)
        P([(.24, .70), (.46, .70), (.26, .96)])
    elif name == 'phone':
        P([(.10, .16), (.34, .06), (.48, .32), (.34, .44), (.56, .66), (.68, .52),
           (.94, .66), (.84, .90), (.60, .90), (.28, .66), (.10, .38)])
    elif name == 'truck':
        R(.04, .28, .58, .72, radius=s * .06, fill=colour)
        P([(.60, .40), (.80, .40), (.96, .56), (.96, .72), (.60, .72)])
        E(.14, .66, .36, .90, fill=colour)
        E(.66, .66, .88, .90, fill=colour)
    elif name == 'cart':
        L([(.04, .14), (.20, .14), (.34, .64), (.86, .64)], width=w)
        L([(.24, .30), (.94, .30), (.86, .64)], width=w)
        E(.30, .78, .46, .94, fill=colour)
        E(.70, .78, .86, .94, fill=colour)
    elif name == 'tag':
        P([(.06, .06), (.52, .06), (.94, .48), (.48, .94), (.06, .52)])
        E(.20, .20, .34, .34, fill=CARD)
    elif name == 'gear':
        for a in range(0, 360, 45):
            rad = math.radians(a)
            d.rounded_rectangle(
                [cx - s * .10, cy - s * .50, cx + s * .10, cy - s * .28],
                radius=s * .04, fill=colour) if a == 0 else None
        E(.10, .10, .90, .90, fill=colour)
        E(.34, .34, .66, .66, fill=CARD)
        for a in range(0, 360, 45):
            rad = math.radians(a)
            px, py = cx + math.cos(rad) * s * .46, cy + math.sin(rad) * s * .46
            d.ellipse([px - s * .11, py - s * .11, px + s * .11, py + s * .11], fill=colour)
    elif name == 'upload':
        L([(.5, .86), (.5, .18)], width=w * 1.1)
        P([(.5, .06), (.76, .36), (.24, .36)])
        L([(.12, .94), (.88, .94)], width=w * 1.1)
    elif name == 'download':
        L([(.5, .10), (.5, .76)], width=w * 1.1)
        P([(.5, .90), (.76, .58), (.24, .58)])
    elif name == 'scale':
        L([(.5, .10), (.5, .90)], width=w)
        L([(.14, .28), (.86, .28)], width=w)
        d.arc([x0 + s * .00, y0 + s * .28, x0 + s * .40, y0 + s * .68], 0, 180,
              fill=colour, width=round(w))
        d.arc([x0 + s * .60, y0 + s * .28, x0 + s * 1.0, y0 + s * .68], 0, 180,
              fill=colour, width=round(w))
    elif name == 'warning':
        P([(.5, .06), (.98, .92), (.02, .92)])
        d.line([(cx, y0 + s * .40), (cx, y0 + s * .66)], fill=CARD, width=round(w * 1.2))
        d.ellipse([cx - s * .06, y0 + s * .74, cx + s * .06, y0 + s * .86], fill=CARD)
    elif name == 'star':
        pts = []
        for i in range(10):
            r = .48 if i % 2 == 0 else .21
            a = math.radians(-90 + i * 36)
            pts.append((.5 + math.cos(a) * r, .5 + math.sin(a) * r))
        P(pts)
    elif name == 'building':
        R(.10, .10, .62, .94, radius=s * .04, fill=colour)
        R(.62, .40, .92, .94, radius=s * .04, fill=blend(colour, CARD, .35))
        for yy in (.24, .42, .60):
            for xx in (.20, .40):
                d.rectangle([x0 + s * xx, y0 + s * yy, x0 + s * (xx + .10),
                             y0 + s * (yy + .10)], fill=CARD)
    elif name == 'key':
        E(.04, .28, .48, .72, outline=colour, width=round(w * 1.1))
        L([(.44, .50), (.96, .50)], width=w)
        L([(.74, .50), (.74, .74)], width=w)
        L([(.90, .50), (.90, .70)], width=w)
    elif name == 'clipboard':
        R(.14, .12, .86, .94, radius=s * .10, outline=colour, width=round(w))
        R(.34, .04, .66, .22, radius=s * .05, fill=colour)
        for yy in (.44, .62, .78):
            L([(.30, yy), (.70, yy)], width=w * .85)
    else:  # fallback
        R(.10, .10, .90, .90, radius=s * .18, outline=colour, width=round(w))
    return box
