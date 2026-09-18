"""A device frame that takes dp and emits pixels.

One layout, three densities. Renderers work entirely in logical dp — the
same numbers a Flutter widget would use — and the frame multiplies on the
way to the bitmap, so a phone at 1080x1920 and a 10-inch tablet at
2560x1440 are the same code and not two drawings that have to be kept
agreeing with each other by hand.
"""
import math
from PIL import Image, ImageDraw, ImageFilter
import ui
from ui import (ACCENT, ACCENT_DK, ACCENT_SOFT, BG, CARD, BORDER, BORDER_SOFT,
                INK, INK2, INK3, SUCCESS, WARNING, DANGER, INFO, VIOLET, SOFT, blend)

# The bottom bar the app actually builds: the five destinations flagged
# `primary: true` in app_shell.dart, then More.
BAR = [('Dashboard', 'dashboard'), ('Sales', 'receipt'), ('Contacts', 'people'),
       ('CRM', 'trending'), ('Ask', 'sparkle'), ('More', 'more')]

# The rail on a tablet shows more of the same list.
RAIL = [('Dashboard', 'dashboard'), ('Sales', 'receipt'), ('Purchases', 'bag'),
        ('Contacts', 'people'), ('Items', 'box'), ('CRM', 'trending'),
        ('Reports', 'chart'), ('e-Invoice', 'check'), ('Payroll', 'money'),
        ('Ask', 'sparkle'), ('Settings', 'gear')]


class Frame:
    def __init__(self, px_w, px_h, dp_w, mode='phone'):
        self.w, self.h = px_w, px_h
        self.u = px_w / dp_w
        self.dw, self.dh = dp_w, px_h / self.u
        self.mode = mode
        self.img = Image.new('RGB', (px_w, px_h), BG)
        self.d = ImageDraw.Draw(self.img)

    # --- scaled primitives ------------------------------------------------
    def _b(self, box):
        u = self.u
        return [box[0] * u, box[1] * u, box[2] * u, box[3] * u]

    def rect(self, box, fill=None, outline=None, w=1):
        self.d.rectangle(self._b(box), fill=fill, outline=outline,
                         width=max(1, round(w * self.u)))

    def card(self, box, r=12, fill=CARD, border=BORDER, bw=1):
        self.d.rounded_rectangle(self._b(box), radius=r * self.u, fill=fill,
                                 outline=border, width=max(1, round(bw * self.u)))

    def shadow(self, box, r=12, blur=10, alpha=22, dy=3):
        layer = Image.new('RGBA', self.img.size, (0, 0, 0, 0))
        b = self._b([box[0], box[1] + dy, box[2], box[3] + dy])
        ImageDraw.Draw(layer).rounded_rectangle(b, radius=r * self.u,
                                                fill=(10, 42, 36, alpha))
        layer = layer.filter(ImageFilter.GaussianBlur(blur * self.u))
        self.img.paste(Image.alpha_composite(self.img.convert('RGBA'), layer).convert('RGB'),
                       (0, 0))
        self.d = ImageDraw.Draw(self.img)

    def line(self, a, b, fill=BORDER, w=1):
        u = self.u
        self.d.line([a[0] * u, a[1] * u, b[0] * u, b[1] * u], fill=fill,
                    width=max(1, round(w * u)))

    def hline(self, x0, x1, y, fill=BORDER_SOFT, w=1):
        self.line((x0, y), (x1, y), fill, w)

    def circle(self, box, fill=None, outline=None, w=1):
        self.d.ellipse(self._b(box), fill=fill, outline=outline,
                       width=max(1, round(w * self.u)))

    def text(self, xy, s, px, w='r', fill=INK, anchor='la', max_w=None):
        ui.text(self.d, (xy[0] * self.u, xy[1] * self.u), s, px * self.u, w, fill,
                anchor, max_w * self.u if max_w else None)

    def tw(self, s, px, w='r'):
        return ui.width(self.d, s, px * self.u, w) / self.u

    def para(self, xy, s, px, w='r', fill=INK, max_w=1e6, leading=1.4):
        return ui.paragraph(self.d, (xy[0] * self.u, xy[1] * self.u), s, px * self.u,
                            w, fill, max_w * self.u, leading) / self.u

    def lines(self, s, px, w, max_w, n=2):
        """Up to n wrapped lines, the last one ellipsized if it overruns."""
        import ui as _ui
        out = _ui.wrap(self.d, s, px * self.u, w, max_w * self.u)
        if len(out) > n:
            keep = out[:n]
            keep[-1] = _ui.ellipsize(self.d, ' '.join(out[n - 1:]),
                                     _ui.font(px * self.u, w), max_w * self.u)
            return keep
        return out

    def chip(self, x, y, s, px, tone='grey', h=None, weight='s'):
        return ui.chip(self.d, x * self.u, y * self.u, s, px * self.u, tone,
                       (h or px * 1.9) * self.u) / self.u

    def icon(self, name, box, colour=INK2, w=None):
        ui.icon(self.d, name, self._b(box), colour, w * self.u if w else None)

    def tile(self, box, name, tone='accent', r=10):
        ui.tile(self.d, self._b(box), name, tone, r * self.u)

    def avatar(self, box, initials, seed=0):
        ui.avatar(self.d, self._b(box), initials, seed)

    def progress(self, box, frac, colour=ACCENT, track=(233, 238, 237)):
        ui.progress(self.d, self._b(box), frac, colour, track)

    def spark(self, box, vals, colour=ACCENT, w=2.0, fill=True, dot=True):
        ui.sparkline(self.img, self._b(box), vals, colour, w * self.u, fill, dot)
        self.d = ImageDraw.Draw(self.img)

    def bars(self, box, vals, colour=ACCENT, gap=0.34, r=2.5, highlight=-1, soft=None):
        ui.bars(self.d, self._b(box), vals, colour, soft, gap, r * self.u, highlight)

    def donut(self, box, parts, thickness=0.30):
        ui.donut(self.img, self._b(box), parts, thickness)
        self.d = ImageDraw.Draw(self.img)

    # --- chrome -----------------------------------------------------------
    def status_bar(self, h=26, bg=CARD, fg=INK):
        self.rect([0, 0, self.dw, h], fill=bg)
        self.text((16, h / 2), '9:41', 12, 'b', fg, anchor='lm')
        x = self.dw - 16
        # battery
        self.d.rounded_rectangle(self._b([x - 21, h / 2 - 5, x - 3, h / 2 + 5]),
                                 radius=2.4 * self.u, outline=fg,
                                 width=max(1, round(1.2 * self.u)))
        self.d.rounded_rectangle(self._b([x - 19.2, h / 2 - 3.2, x - 8, h / 2 + 3.2]),
                                 radius=1.2 * self.u, fill=fg)
        self.d.rounded_rectangle(self._b([x - 2.4, h / 2 - 2, x - 0.6, h / 2 + 2]),
                                 radius=1 * self.u, fill=fg)
        # wifi
        for i, r in enumerate((8.4, 5.6, 2.8)):
            self.d.arc(self._b([x - 36 - r + 4.4, h / 2 + 3 - r, x - 36 + r + 4.4,
                                h / 2 + 3 + r]), 215, 325, fill=fg,
                       width=max(1, round(1.7 * self.u)))
        self.d.ellipse(self._b([x - 32.8, h / 2 + 2.2, x - 30.4, h / 2 + 4.6]), fill=fg)
        # signal
        for i in range(4):
            bh = 2.6 + i * 2.4
            self.d.rounded_rectangle(
                self._b([x - 58 + i * 4.2, h / 2 + 5 - bh, x - 55.4 + i * 4.2, h / 2 + 5]),
                radius=0.8 * self.u, fill=fg if i < 3 else blend(fg, bg, .55))
        return h

    def app_bar(self, y, title, actions=('search', 'bell'), back=False, sub=None,
                h=54, bg=CARD, x0=0, x1=None):
        x1 = self.dw if x1 is None else x1
        self.rect([x0, y, x1, y + h], fill=bg)
        tx = x0 + 16
        if back:
            self.icon('back', [tx, y + h / 2 - 9, tx + 18, y + h / 2 + 9], INK, 1.9)
            tx += 30
        if sub:
            self.text((tx, y + h / 2 - 11), title, 17.5, 'x', INK, anchor='lm',
                      max_w=x1 - tx - 40 * len(actions))
            self.text((tx, y + h / 2 + 9), sub, 11.5, 'm', INK3, anchor='lm',
                      max_w=x1 - tx - 40 * len(actions))
        else:
            self.text((tx, y + h / 2), title, 19, 'x', INK, anchor='lm',
                      max_w=x1 - tx - 36 * len(actions) - 12)
        ax = x1 - 16
        for name in reversed(actions):
            self.icon(name, [ax - 20, y + h / 2 - 10, ax, y + h / 2 + 10], INK2, 1.8)
            ax -= 34
        return y + h

    def tabs(self, y, labels, active=0, h=42, bg=CARD, x0=0, x1=None):
        x1 = self.dw if x1 is None else x1
        self.rect([x0, y, x1, y + h], fill=bg)
        self.hline(x0, x1, y + h - 0.5, BORDER, 1)
        x = x0 + 16
        for i, label in enumerate(labels):
            w = self.tw(label, 13.5, 'b' if i == active else 'm')
            self.text((x, y + h / 2 - 2), label, 13.5, 'b' if i == active else 'm',
                      ACCENT if i == active else INK3, anchor='lm')
            if i == active:
                self.d.rounded_rectangle(
                    self._b([x - 2, y + h - 3, x + w + 2, y + h]),
                    radius=1.5 * self.u, fill=ACCENT)
            x += w + 26
        return y + h

    def search(self, y, placeholder='Search', h=38, pad=12, trailing='filter', x0=0, x1=None):
        x1 = self.dw if x1 is None else x1
        self.card([x0 + pad, y, x1 - pad, y + h], r=h / 2, fill=CARD, border=BORDER)
        self.icon('search', [x0 + pad + 12, y + h / 2 - 8, x0 + pad + 28, y + h / 2 + 8],
                  INK3, 1.7)
        self.text((x0 + pad + 36, y + h / 2), placeholder, 13, 'r', INK3, anchor='lm')
        if trailing:
            self.icon(trailing, [x1 - pad - 30, y + h / 2 - 8, x1 - pad - 14, y + h / 2 + 8],
                      INK2, 1.7)
        return y + h

    def filter_chips(self, y, chips, active=0, x0=12, h=28, px=11.5):
        x = x0
        for i, c in enumerate(chips):
            tone = ('accent' if i == active else 'grey')
            w = self.chip(x, y, c, px, tone, h=h)
            x += w + 7
        return y + h

    def bottom_bar(self, active=0, h=62):
        y = self.dh - h
        self.rect([0, y, self.dw, self.dh], fill=CARD)
        self.hline(0, self.dw, y, BORDER, 1)
        step = self.dw / len(BAR)
        for i, (label, ico) in enumerate(BAR):
            cx = step * (i + 0.5)
            on = i == active
            if on:
                self.d.rounded_rectangle(self._b([cx - 16, y + 7, cx + 16, y + 29]),
                                         radius=11 * self.u, fill=ACCENT_SOFT)
            self.icon(ico, [cx - 10, y + 8, cx + 10, y + 28],
                      ACCENT if on else INK3, 1.8)
            self.text((cx, y + 40), label, 10, 'b' if on else 'm',
                      ACCENT if on else INK3, anchor='mm')
        # gesture bar
        self.d.rounded_rectangle(self._b([self.dw / 2 - 45, self.dh - 7,
                                          self.dw / 2 + 45, self.dh - 4.2]),
                                 radius=1.5 * self.u, fill=(200, 208, 206))
        return y

    def fab(self, label=None, ico='plus', bottom=None, right=16):
        b = bottom if bottom is not None else 78
        if label:
            w = self.tw(label, 13.5, 'b') + 56
            box = [self.dw - right - w, self.dh - b - 48, self.dw - right, self.dh - b]
            self.shadow(box, r=16, blur=8, alpha=40, dy=3)
            self.card(box, r=16, fill=ACCENT, border=None)
            self.icon(ico, [box[0] + 16, box[1] + 15, box[0] + 34, box[1] + 33], CARD, 2.1)
            self.text((box[0] + 40, (box[1] + box[3]) / 2), label, 13.5, 'b', CARD,
                      anchor='lm')
        else:
            box = [self.dw - right - 52, self.dh - b - 52, self.dw - right, self.dh - b]
            self.shadow(box, r=16, blur=8, alpha=40, dy=3)
            self.card(box, r=16, fill=ACCENT, border=None)
            self.icon(ico, [box[0] + 16, box[1] + 16, box[2] - 16, box[3] - 16], CARD, 2.3)

    def mark(self, box, colour=ACCENT):
        """The brand mark, drawn from brand/mark.py's own geometry."""
        import mark as M
        b = self._b(box)
        s = min(b[2] - b[0], b[3] - b[1])
        polys = [M.stem_and_bowl(), M.chevron()]
        xs = [p[0] for pl in polys for p in pl] + [M.DOT[0], M.DOT[2]]
        ys = [p[1] for pl in polys for p in pl] + [M.DOT[1], M.DOT[3]]
        bx0, by0, bx1, by1 = min(xs), min(ys), max(xs), max(ys)
        k = s / max(bx1 - bx0, by1 - by0)
        ox = b[0] + (s - (bx1 - bx0) * k) / 2 - bx0 * k
        oy = b[1] + (s - (by1 - by0) * k) / 2 - by0 * k
        T = lambda p: (ox + p[0] * k, oy + p[1] * k)
        ss = 4
        big = Image.new('RGBA', (round(s * ss), round(s * ss)), (0, 0, 0, 0))
        bd = ImageDraw.Draw(big)
        T2 = lambda p: ((ox + p[0] * k - b[0]) * ss, (oy + p[1] * k - b[1]) * ss)
        for poly in polys:
            bd.polygon([T2(p) for p in poly], fill=colour)
        bd.rounded_rectangle([T2((M.DOT[0], M.DOT[1])), T2((M.DOT[2], M.DOT[3]))],
                             radius=6 * k * ss, fill=colour)
        big = big.resize((round(s), round(s)), Image.LANCZOS)
        self.img.paste(big, (round(b[0]), round(b[1])), big)
        self.d = ImageDraw.Draw(self.img)

    def rail(self, active=0, w=196, org='Demo Sdn Bhd', top=0):
        """The tablet navigation rail."""
        self.rect([0, top, w, self.dh], fill=CARD)
        self.line((w, top), (w, self.dh), BORDER, 1)
        self.mark([16, top + 18, 44, top + 46], ACCENT)
        self.text((52, top + 25), 'iAkauntan', 16.5, 'x', INK)
        self.text((52, top + 43), org, 10.5, 'm', INK3, max_w=w - 64)
        y = top + 68
        self.card([12, y, w - 12, y + 32], r=16, fill=BG, border=BORDER_SOFT)
        self.icon('search', [24, y + 9, 38, y + 23], INK3, 1.6)
        self.text((44, y + 16), 'Search', 12, 'r', INK3, anchor='lm')
        y += 46
        # A rail that does not fit scrolls; it does not shrink its icons to
        # eight dp. Show what fits at a real row height, windowed so the
        # destination the screen is actually on is one of them.
        avail = self.dh - y - 52
        step = 32
        n = max(4, min(len(RAIL), int(avail // step)))
        start = 0 if active < n else min(active - n + 2, len(RAIL) - n)
        for i in range(start, start + n):
            label, ico = RAIL[i]
            on = i == active
            if on:
                self.card([10, y + 1, w - 12, y + step - 3], r=9, fill=ACCENT_SOFT,
                          border=None)
            self.icon(ico, [22, y + (step - 4) / 2 - 9, 40, y + (step - 4) / 2 + 9],
                      ACCENT if on else INK2, 1.7)
            self.text((50, y + (step - 4) / 2), label, 12.5, 'b' if on else 'm',
                      ACCENT if on else INK2, anchor='lm')
            y += step
        # account footer
        fy = self.dh - 46
        self.hline(12, w - 12, fy - 6, BORDER_SOFT, 1)
        self.avatar([16, fy, 44, fy + 28], 'NA', 1)
        self.text((52, fy + 9), 'Nurul Aisyah', 12, 'b', INK)
        self.text((52, fy + 22), 'Administrator', 10, 'm', INK3)
        return w
