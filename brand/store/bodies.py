"""The body of each screen, by archetype.

Every renderer takes a Frame, a spec and a rect in dp, and draws inside
it. Nothing here knows whether it is on a phone or a tablet beyond the
width of the rect it is handed, which is what lets the same eight screens
come out as a phone portrait set and a tablet landscape set.
"""
import content as C
from ui import (ACCENT, ACCENT_SOFT, BG, CARD, BORDER, BORDER_SOFT, INK, INK2, INK3,
                SUCCESS, WARNING, DANGER, INFO, VIOLET, SOFT, blend)

TONE_ICON = {'success': 'checkcircle', 'warning': 'clock', 'danger': 'warning',
             'info': 'doc', 'accent': 'doc', 'grey': 'doc', 'violet': 'star'}


def section(f, x, y, title, action=None, x1=None, px=12.5):
    f.text((x, y), title.upper(), px * 0.86, 'b', INK3)
    if action:
        f.text((x1, y), action, px * 0.92, 'b', ACCENT, anchor='ra')
    return y + px * 1.5


# --- rows ------------------------------------------------------------------

def doc_rows(f, rect, rows, h=64, gap=8, icon='doc'):
    x0, y, x1, y1 = rect
    for r in rows:
        if y + h > y1:
            break
        f.card([x0, y, x1, y + h], r=12)
        tone = r.get('tone', 'grey')
        f.tile([x0 + 12, y + h / 2 - 17, x0 + 46, y + h / 2 + 17],
               r.get('icon', TONE_ICON.get(tone, 'doc')), tone, r=10)
        amount_w = f.tw(r['amount'], 14.5, 'b') if r.get('amount') else 0
        chip_w = (f.tw(r['status'], 10.5, 'b') + 15) if r.get('status') else 0
        right = max(amount_w, chip_w)
        tw = x1 - x0 - 58 - right - 24
        f.text((x0 + 56, y + h / 2 - 13), r['title'], 14, 'b', INK, max_w=tw)
        f.text((x0 + 56, y + h / 2 + 5), r['sub'], 11.5, 'm', INK3, max_w=tw)
        if r.get('amount'):
            f.text((x1 - 14, y + h / 2 - 13), r['amount'], 14.5, 'b',
                   r.get('amount_colour', INK), anchor='ra')
            if r.get('status'):
                w = f.tw(r['status'], 10.5, 'b') + 15
                f.chip(x1 - 14 - w, y + h / 2 + 2, r['status'], 10.5, tone, h=17)
        elif r.get('status'):
            w = f.tw(r['status'], 10.5, 'b') + 15
            f.chip(x1 - 14 - w, y + h / 2 - 8.5, r['status'], 10.5, tone, h=17)
        y += h + gap
    return y


def people_rows(f, rect, rows, h=62, gap=8):
    x0, y, x1, y1 = rect
    for i, r in enumerate(rows):
        if y + h > y1:
            break
        f.card([x0, y, x1, y + h], r=12)
        initials = ''.join(w[0] for w in r['title'].split()[:2]).upper()
        f.avatar([x0 + 12, y + h / 2 - 17, x0 + 46, y + h / 2 + 17], initials, i)
        rw = max((f.tw(r['amount'], 14, 'b') if r.get('amount') else 0),
                 (f.tw(r['status'], 10.5, 'b') + 15) if r.get('status') else 0)
        f.text((x0 + 56, y + h / 2 - 13), r['title'], 14, 'b', INK,
               max_w=x1 - x0 - 80 - rw)
        f.text((x0 + 56, y + h / 2 + 5), r['sub'], 11.5, 'm', INK3,
               max_w=x1 - x0 - 80 - rw)
        if r.get('amount'):
            f.text((x1 - 14, y + h / 2 - 13), r['amount'], 14, 'b',
                   r.get('amount_colour', INK), anchor='ra')
        if r.get('status'):
            w = f.tw(r['status'], 10.5, 'b') + 15
            f.chip(x1 - 14 - w, y + h / 2 + (2 if r.get('amount') else -8.5),
                   r['status'], 10.5, r.get('tone', 'grey'), h=17)
        y += h + gap
    return y


def tile_row(f, box, tiles, ch=76):
    """A row of small labelled figures; two per row where it is narrow."""
    x0, y, x1 = box
    cols = len(tiles) if (x1 - x0) > 520 else 2
    gap = 10
    cw = (x1 - x0 - gap * (cols - 1)) / cols
    for i, (label, value, sub, tone) in enumerate(tiles):
        cx = x0 + (cw + gap) * (i % cols)
        cy = y + (ch + gap) * (i // cols)
        f.card([cx, cy, cx + cw, cy + ch], r=12)
        f.text((cx + 12, cy + 10), label.upper(), 9.5, 'b', INK3, max_w=cw - 24)
        f.text((cx + 12, cy + 25), value, 17, 'x', SOFT[tone][1], max_w=cw - 24)
        f.text((cx + 12, cy + ch - 17), sub, 10, 'm', INK3, max_w=cw - 24)
    return y + ((len(tiles) + cols - 1) // cols) * (ch + gap)


# --- archetypes ------------------------------------------------------------

def dashboard(f, spec, rect):
    x0, y, x1, y1 = rect
    r = C.rng(spec['route'])
    pad = 12
    f.text((x0 + pad, y + 4), 'Selamat pagi', 24, 'x', INK)
    f.text((x0 + pad, y + 34), f"{spec['org']} · 18 Sep 2026", 12, 'm', INK3)
    y += 54
    cols = 2 if (x1 - x0) < 560 else 4
    kpis = [('Revenue', 'RM 486,320', '+17%', 'this month', 'trending', 'success', SUCCESS),
            ('Expenses', 'RM 291,744', '+10%', 'supplier bills', 'falling', 'warning',
             WARNING),
            ('Receivables', 'RM 172,905', '31 unpaid', 'RM 44,120 late', 'receipt',
             'danger', DANGER),
            ('Bank balance', 'RM 613,488', '4 accounts', 'reconciled', 'bank', 'info',
             INFO)]
    gap = 10
    cw = (x1 - x0 - pad * 2 - gap * (cols - 1)) / cols
    ch = 102 if cols == 2 else 126
    for i, (label, value, delta, note, ico, tone, col) in enumerate(kpis):
        cx = x0 + pad + (cw + gap) * (i % cols)
        cy = y + (ch + gap) * (i // cols)
        f.card([cx, cy, cx + cw, cy + ch], r=12)
        f.tile([cx + 11, cy + 10, cx + 34, cy + 33], ico, tone, r=7)
        f.text((cx + 41, cy + 22), label, 11.5, 'b', INK2, anchor='lm', max_w=cw - 52)
        f.text((cx + 11, cy + 40), value, 19 if cols == 2 else 22, 'x', INK, max_w=cw - 22)
        dw = f.tw(delta, 10.5, 'b')
        f.text((cx + 11, cy + 64), delta, 10.5, 'b', col)
        f.text((cx + 11 + dw + 6, cy + 64), note, 10.5, 'm', INK3,
               max_w=cw - 28 - dw)
        f.spark([cx + 11, cy + ch - 26, cx + cw - 11, cy + ch - 7],
                C.walk(r, 9, 100, 0.3 if i != 1 else 0.18), col, 2.0)
    y += (ch + gap) * (len(kpis) // cols)
    if y + 84 > y1:
        return y
    y = section(f, x0 + pad, y + 4, 'Needs attention', 'See all', x1 - pad) + 2
    rows = [dict(title='e-Invoice rejected by LHDN', sub='INV-2026-0412 · code CF321',
                 status='Fix', tone='danger', icon='warning'),
            dict(title='6 invoices overdue past 30 days', sub='RM 44,120.00 outstanding',
                 status='Chase', tone='warning', icon='clock'),
            dict(title='EPF, SOCSO and EIS due 15 Oct', sub='September payroll · 24 employees',
                 status='Pay', tone='info', icon='shield'),
            dict(title='Annual return due 28 Nov', sub='SSM · Demo Sdn Bhd',
                 status='Prepare', tone='accent', icon='building')]
    y = doc_rows(f, [x0 + pad, y, x1 - pad, y1], rows, h=56, gap=8)
    # A 360dp phone ends here. A 6.5-inch phone has a band spare and an iPad
    # has most of a page, so the dashboard keeps going rather than leaving
    # the app looking like it ran out of things to say.
    ch = min(148, y1 - y - 8)
    if ch < 100:
        return y1
    tight = ch < 136
    f.card([x0 + pad, y + 4, x1 - pad, y + 4 + ch], r=12)
    lx = x0 + pad + 14
    f.text((lx, y + 16), 'NET CASH THIS MONTH', 9.5, 'b', INK3)
    # Revenue less expenses from the two tiles above, not a third figure
    # invented alongside them: 486,320 - 291,744.
    f.text((lx, y + 30), 'RM 194,576', 21, 'x', INK)
    months = ['Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep']
    if tight:
        # Short card: the figure and the bars side by side, because six bars
        # squeezed into twenty dp say nothing about which month was better.
        f.text((lx, y + 58), 'money in less out', 10.5, 'm', INK3)
        bx0, by0 = lx + 148, y + 22
    else:
        f.text((lx, y + 58), 'money in less money out · six months to September',
               10.5, 'm', INK3, max_w=x1 - x0 - pad * 2 - 28)
        bx0, by0 = lx, y + 76
    bx1 = x1 - pad - 14
    f.bars([bx0, by0, bx1, y + 4 + ch - 24],
           [142.4, 118.9, 165.2, 131.7, 176.3, 194.6], ACCENT,
           highlight=len(months) - 1)
    step = (bx1 - bx0) / len(months)
    for i, m in enumerate(months):
        f.text((bx0 + step * (i + 0.5), y + 4 + ch - 16), m, 9.5, 'm', INK3, anchor='ma')
    y += ch + 12
    if y1 - y < 120:
        return y1
    y = section(f, x0 + pad, y + 2, 'Recent activity', 'Open log', x1 - pad) + 2
    doc_rows(f, [x0 + pad, y, x1 - pad, y1], ACTIVITY, h=56, gap=8)
    return y1


# What the company did this week. Events, so none of it has to reconcile
# with the figures above it -- and where a figure does appear it is the one
# the screen it came from already shows.
ACTIVITY = [
    dict(title='Payment received · RM 12,380.50',
         sub='Pantai Timur Logistics · INV-2026-0417', status='Matched',
         tone='success', icon='checkcircle'),
    dict(title='Invoice validated by LHDN', sub='INV-2026-0418 · Kilang Serbaguna Sdn Bhd',
         status='Cleared', tone='success', icon='check'),
    dict(title='Payroll locked · September', sub='24 employees · RM 184,206.45 net',
         status='Locked', tone='accent', icon='money'),
    dict(title='Deal won · Bumi Hijau Agro', sub='RM 176,000 · signed 12 Sep',
         status='Won', tone='success', icon='trending'),
    dict(title='Bill approved · BILL-2026-0233', sub='Tenaga Jaya Enterprise · due 30 Sep',
         status='Approved', tone='info', icon='doc'),
    dict(title='Bank feed reconciled', sub='Maybank current 5142 · 86 lines matched',
         status='Done', tone='info', icon='bank'),
    dict(title='Quotation accepted · QUO-2026-0141', sub='Desa Murni Catering · RM 32,400',
         status='Accepted', tone='success', icon='checkcircle'),
    dict(title='Credit note issued · CN-2026-0044', sub='Lim Heng Hardware · RM 940.00',
         status='Sent', tone='warning', icon='receipt'),
    dict(title='Stock take posted · Warehouse A', sub='312 items counted · 4 variances',
         status='Review', tone='warning', icon='box'),
    dict(title='Expense claim approved', sub='Ravi Kumar Suppiah · RM 486.20',
         status='To pay', tone='grey', icon='wallet'),
    dict(title='Annual return drafted', sub='SSM · Demo Sdn Bhd · due 28 Nov',
         status='Draft', tone='grey', icon='building'),
]


def doclist(f, spec, rect):
    x0, y, x1, y1 = rect
    rows = spec['rows']
    if spec.get('totals'):
        pad = 12
        h = 62
        gap = 10
        n = len(spec['totals'])
        cw = (x1 - x0 - pad * 2 - gap * (n - 1)) / n
        for i, (label, value, tone) in enumerate(spec['totals']):
            cx = x0 + pad + (cw + gap) * i
            f.card([cx, y, cx + cw, y + h], r=12)
            f.text((cx + 12, y + 12), label.upper(), 9.5, 'b', INK3, max_w=cw - 24)
            f.text((cx + 12, y + 28), value, 15 if cw > 130 else 13, 'x',
                   SOFT[tone][1], max_w=cw - 20)
        y += h + 12
    return doc_rows(f, [x0 + 12, y, x1 - 12, y1], rows,
                    h=spec.get('row_h', 64), icon=spec.get('row_icon', 'doc'))


def listing(f, spec, rect):
    x0, y, x1, y1 = rect
    return people_rows(f, [x0 + 12, y, x1 - 12, y1], spec['rows'],
                       h=spec.get('row_h', 62))


def board(f, spec, rect):
    x0, y, x1, y1 = rect
    cols = spec['columns']
    pad = 12
    # 130, not 168: a 6.5-inch phone is wide enough for three columns, and
    # three whole ones beat two and a sliver.
    visible = min(len(cols), max(2, int((x1 - x0 - pad) // 130)))
    cw = min(186, (x1 - x0 - pad * 2 - 10 * (visible - 1)) / visible) \
        if visible >= 3 else 158
    x = x0 + pad
    for ci, col in enumerate(cols):
        if x > x1:
            break
        f.card([x, y, x + cw, y1 - 4], r=12, fill=(241, 244, 243), border=BORDER_SOFT)
        # Where the column is too narrow for both, the stage keeps its name
        # and the total goes: 'Qualifi…  RM 242k' tells you less than
        # 'Qualified' does.
        vw = f.tw(col['value'], 11, 'b')
        if f.tw(col['name'], 12.5, 'b') + vw + 30 <= cw:
            f.text((x + cw - 12, y + 12), col['value'], 11, 'b', INK3, anchor='ra')
        else:
            vw = -8
        f.text((x + 12, y + 12), col['name'], 12.5, 'b', INK, max_w=cw - 32 - vw)
        f.d.rounded_rectangle(f._b([x + 12, y + 32, x + cw - 12, y + 34]),
                              radius=1 * f.u, fill=SOFT[col['tone']][1])
        cy = y + 42
        for card in col['cards']:
            ch = 74
            if cy + ch > y1 - 10:
                break
            f.card([x + 8, cy, x + cw - 8, cy + ch], r=10)
            f.text((x + 18, cy + 11), card['title'], 12, 'b', INK, max_w=cw - 36)
            f.text((x + 18, cy + 28), card['sub'], 10.5, 'm', INK3, max_w=cw - 36)
            f.text((x + 18, cy + 48), card['amount'], 13, 'x', INK)
            f.avatar([x + cw - 34, cy + 44, x + cw - 16, cy + 62], card['who'], ci + 1)
            cy += ch + 8
        x += cw + 10
    return y1


def report(f, spec, rect):
    x0, y, x1, y1 = rect
    pad = 12
    # Height of the statement, not of the screen: on an iPad the card would
    # otherwise run a foot past its last line.
    need = 78 + sum(26 if r.get('kind') == 'total' else 24
                    for r in spec['report_rows']) + 16
    y1c = min(y + need, y1 - 4)
    f.card([x0 + pad, y, x1 - pad, y1c], r=12)
    ix0, ix1 = x0 + pad + 14, x1 - pad - 14
    f.text((ix0, y + 14), spec['report_title'], 15, 'x', INK)
    f.text((ix0, y + 34), spec['report_sub'], 11, 'm', INK3)
    if spec.get('cols'):
        cy = y + 56
        w = (ix1 - ix0)
        f.text((ix1 - w * 0.22, cy), spec['cols'][0], 10, 'b', INK3, anchor='ra')
        f.text((ix1, cy), spec['cols'][1], 10, 'b', INK3, anchor='ra')
        f.hline(ix0, ix1, cy + 16, BORDER, 1)
    ry = y + 78
    for row in spec['report_rows']:
        if ry + 22 > y1c - 14:
            break
        kind = row.get('kind', 'line')
        if kind == 'head':
            f.text((ix0, ry + 4), row['label'].upper(), 10, 'b', ACCENT)
            ry += 24
            continue
        bold = kind == 'total'
        if bold:
            f.hline(ix0, ix1, ry - 2, BORDER, 1)
        f.text((ix0 + (0 if bold else 8), ry + 4), row['label'],
               12.5 if bold else 12, 'b' if bold else 'm', INK if bold else INK2,
               max_w=(ix1 - ix0) * 0.55)
        w = (ix1 - ix0)
        if row.get('prev'):
            f.text((ix1 - w * 0.22, ry + 4), row['prev'], 12, 'm', INK3, anchor='ra')
        f.text((ix1, ry + 4), row['value'], 12.5 if bold else 12, 'b' if bold else 'm',
               row.get('colour', INK if bold else INK2), anchor='ra')
        ry += 26 if bold else 24
    if spec.get('report_tiles') and y1 - y1c > 96:
        tile_row(f, [x0 + pad, y1c + 12, x1 - pad], spec['report_tiles'])
    return y1


def stats(f, spec, rect):
    x0, y, x1, y1 = rect
    pad = 12
    hero = spec['hero']
    wide = (x1 - x0) > 480
    hh = 132
    hx1 = x0 + pad + (x1 - x0 - pad * 2) * 0.46 if wide else x1 - pad
    f.card([x0 + pad, y, hx1, y + hh], r=12, fill=ACCENT, border=None)
    f.text((x0 + pad + 16, y + 16), hero['label'].upper(), 10, 'b', (168, 214, 204))
    f.text((x0 + pad + 16, y + 34), hero['value'], 28, 'x', CARD,
           max_w=hx1 - x0 - pad - 32)
    f.text((x0 + pad + 16, y + 74), hero['sub'], 11.5, 'm', (198, 228, 220),
           max_w=hx1 - x0 - pad - 32)
    bx0 = x0 + pad + 16
    bw = (hx1 - x0 - pad - 32)
    f.progress([bx0, y + 96, bx0 + bw, y + 102], hero.get('frac', 0.72),
               colour=CARD, track=(60, 143, 129))
    f.text((bx0, y + 110), hero['note'], 10.5, 'm', (198, 228, 220),
           max_w=hx1 - x0 - pad - 32)
    n = len(spec['tiles'])
    gap = 10
    if wide:
        tx0 = hx1 + gap
        cols = 2
        cw = (x1 - pad - tx0 - gap) / 2
        ch = (hh - gap) / 2
        ty = y
    else:
        tx0 = x0 + pad
        cols = 2
        cw = (x1 - x0 - pad * 2 - gap) / 2
        ch = 76
        ty = y + hh + 12
    for i, (label, value, sub, tone) in enumerate(spec['tiles']):
        cx = tx0 + (cw + gap) * (i % cols)
        cy = ty + (ch + gap) * (i // cols)
        f.card([cx, cy, cx + cw, cy + ch], r=12)
        f.text((cx + 12, cy + 9), label.upper(), 9.5, 'b', INK3, max_w=cw - 24)
        f.text((cx + 12, cy + 23), value, 16 if ch > 70 else 15, 'x', SOFT[tone][1],
               max_w=cw - 20)
        f.text((cx + 12, cy + ch - 16), sub, 10, 'm', INK3, max_w=cw - 20)
    y = (y + hh if wide else ty + ((n + cols - 1) // cols) * (ch + gap)) + 12
    if spec.get('rows') and y + 76 < y1:
        y = section(f, x0 + pad, y, spec.get('rows_title', 'Detail'), None, x1 - pad) + 2
        doc_rows(f, [x0 + pad, y, x1 - pad, y1], spec['rows'], h=58)
    return y1


def ask(f, spec, rect):
    """A conversation sits on the bottom of the screen, not the top.

    Measured first, then laid out upward from the composer, so a long
    answer pushes the start of the thread off the top the way it does in
    the app instead of running under the input bar.
    """
    import ui as _ui
    x0, y0, x1, y1 = rect
    pad = 12
    w = x1 - x0 - pad * 2
    composer_top = y1 - 52
    chips_top = composer_top - 36

    laid = []
    for m in spec['messages']:
        mine = m['who'] == 'user'
        weight = 'm' if mine else 'r'
        bw = min(w * 0.80, f.tw(m['text'], 13.5, weight) + 28) if mine else w * 0.90
        rows = _ui.wrap(f.d, m['text'], 13.5 * f.u, weight, (bw - 28) * f.u)
        h = len(rows) * 13.5 * 1.42 + 24 + (len(m.get('table', [])) * 17 + 12
                                            if m.get('table') else 0)
        laid.append((m, mine, bw, h))

    avail = chips_top - 14 - y0
    while len(laid) > 1 and sum(h for _, _, _, h in laid) + 10 * (len(laid) - 1) > avail:
        laid.pop(0)
    total = sum(h for _, _, _, h in laid) + 10 * (len(laid) - 1)
    y = max(y0, chips_top - 14 - total)
    for m, mine, bw, h in laid:
        if y + h > chips_top - 10:
            break
        if mine:
            f.card([x1 - pad - bw, y, x1 - pad, y + h], r=14, fill=ACCENT, border=None)
            f.para((x1 - pad - bw + 14, y + 11), m['text'], 13.5, 'm', CARD, bw - 28, 1.42)
        else:
            f.card([x0 + pad, y, x0 + pad + bw, y + h], r=14)
            f.para((x0 + pad + 14, y + 12), m['text'], 13.5, 'r', INK, bw - 28, 1.42)
            if m.get('table'):
                ty = y + h - len(m['table']) * 17 - 8
                f.hline(x0 + pad + 14, x0 + pad + bw - 14, ty - 8, BORDER_SOFT, 1)
                for i, (k, v) in enumerate(m['table']):
                    f.text((x0 + pad + 14, ty + i * 17), k, 11.5, 'm', INK2,
                           max_w=bw - 130)
                    f.text((x0 + pad + bw - 14, ty + i * 17), v, 11.5, 'b', INK,
                           anchor='ra')
        y += h + 10

    cx = x0 + pad
    for c in spec.get('chips', []):
        cw = f.tw(c, 11.5, 'm') + 22
        if cx + cw > x1 - pad:
            break
        f.card([cx, chips_top, cx + cw, chips_top + 28], r=14, fill=CARD, border=BORDER)
        f.text((cx + cw / 2, chips_top + 14), c, 11.5, 'm', ACCENT, anchor='mm')
        cx += cw + 7
    f.card([x0 + pad, composer_top, x1 - pad, composer_top + 44], r=22, fill=CARD,
           border=BORDER)
    f.text((x0 + pad + 18, composer_top + 22), 'Ask about your books…', 13, 'r', INK3,
           anchor='lm')
    f.circle([x1 - pad - 40, composer_top + 6, x1 - pad - 8, composer_top + 38],
             fill=ACCENT)
    f.icon('sparkle', [x1 - pad - 32, composer_top + 14, x1 - pad - 16,
                       composer_top + 30], CARD, 1.8)
    return y1


def chat(f, spec, rect):
    return ask(f, spec, rect)


def grid(f, spec, rect):
    """Point of sale: a tile grid with the ticket beside or below it."""
    x0, y, x1, y1 = rect
    pad = 12
    wide = (x1 - x0) > 560
    gx1 = x1 - pad - (250 if wide else 0)
    cols = max(2, int((gx1 - x0 - pad) // 112))
    gap = 10
    cw = (gx1 - x0 - pad * 2 - gap * (cols - 1)) / cols
    ch = 98
    TICKET_H = 172
    tones = ['accent', 'warning', 'info', 'success', 'violet', 'danger']
    gy = y
    for i, (name, price) in enumerate(C.MENU):
        cx = x0 + pad + (cw + gap) * (i % cols)
        cy = gy + (ch + gap) * (i // cols)
        if cy + ch > (y1 - 8 if wide else y1 - TICKET_H - 10):
            break
        f.card([cx, cy, cx + cw, cy + ch], r=12)
        f.tile([cx + 10, cy + 9, cx + 34, cy + 33], 'cart', tones[i % len(tones)], r=8)
        for li, ln in enumerate(f.lines(name, 11, 'b', cw - 20, 2)):
            f.text((cx + 10, cy + 40 + li * 15), ln, 11, 'b', INK)
        f.text((cx + 10, cy + ch - 23), f'RM {price}', 13, 'x', ACCENT)
    # ticket
    if wide:
        tx0 = gx1 + 10
        f.card([tx0, y, x1 - pad, y1 - 4], r=12)
    else:
        tx0 = x0 + pad
        y = y1 - TICKET_H
        f.card([tx0, y, x1 - pad, y1 - 4], r=12)
    ty = y + 12
    f.text((tx0 + 14, ty), 'Table 6 · Dine in', 13, 'x', INK)
    f.text((x1 - pad - 14, ty), '3 items', 11, 'm', INK3, anchor='ra')
    ty += 24
    for name, price, qty in [('Nasi Lemak Ayam', '12.00', 2), ('Teh Tarik', '3.20', 1),
                             ('Cendol Special', '7.00', 1)]:
        f.text((tx0 + 14, ty), f'{qty}×', 11.5, 'b', ACCENT)
        f.text((tx0 + 34, ty), name, 11.5, 'm', INK2, max_w=(x1 - pad) - tx0 - 100)
        f.text((x1 - pad - 14, ty), price, 11.5, 'b', INK, anchor='ra')
        ty += 19
    ty += 4
    f.hline(tx0 + 14, x1 - pad - 14, ty, BORDER, 1)
    ty += 8
    for k, v, b in [('Subtotal', 'RM 34.20', False), ('SST 6%', 'RM 2.05', False),
                    ('Total', 'RM 36.25', True)]:
        f.text((tx0 + 14, ty), k, 12 if b else 11.5, 'b' if b else 'm', INK if b else INK2)
        f.text((x1 - pad - 14, ty), v, 14 if b else 11.5, 'x' if b else 'b', INK,
               anchor='ra')
        ty += 22 if b else 18
    if wide:
        by = y1 - 56
        # A till panel is mostly empty under the ticket; what it is not is
        # empty all the way down to a single button.
        py = by - 86
        f.text((tx0 + 14, py - 18), 'HOW THEY ARE PAYING', 9, 'b', INK3)
        pw = (x1 - pad - 12 - tx0 - 12 - 10) / 2
        for i, (label, ico) in enumerate([('Cash', 'money'), ('Card', 'card'),
                                          ('DuitNow QR', 'phone'), ('e-Wallet', 'wallet')]):
            px = tx0 + 12 + (pw + 10) * (i % 2)
            pyy = py + (i // 2) * 42
            on = i == 2
            f.card([px, pyy, px + pw, pyy + 34], r=10,
                   fill=ACCENT_SOFT if on else CARD, border=BORDER)
            f.icon(ico, [px + 10, pyy + 9, px + 26, pyy + 25],
                   ACCENT if on else INK2, 1.6)
            f.text((px + 32, pyy + 17), label, 11.5, 'b' if on else 'm',
                   ACCENT if on else INK2, anchor='lm')
        f.card([tx0 + 12, by, x1 - pad - 12, by + 40], r=12, fill=ACCENT, border=None)
        f.text(((tx0 + x1 - pad) / 2, by + 20), 'Charge RM 36.25', 13.5, 'b', CARD,
               anchor='mm')
    return y1


def form(f, spec, rect):
    x0, y, x1, y1 = rect
    pad = 12
    for grp in spec['groups']:
        if y + 60 > y1:
            break
        y = section(f, x0 + pad, y + 4, grp['name'], None, x1 - pad) + 2
        h = 4 + len(grp['fields']) * 52
        f.card([x0 + pad, y, x1 - pad, min(y + h, y1 - 4)], r=12)
        fy = y + 4
        for i, fld in enumerate(grp['fields']):
            if fy + 52 > y1:
                break
            if i:
                f.hline(x0 + pad + 14, x1 - pad, fy, BORDER_SOFT, 1)
            f.text((x0 + pad + 14, fy + 12), fld['label'], 11, 'm', INK3)
            f.text((x0 + pad + 14, fy + 28), fld['value'], 13.5, 'b', INK,
                   max_w=x1 - x0 - pad * 2 - 90)
            if fld.get('switch') is not None:
                on = fld['switch']
                sx = x1 - pad - 60
                f.d.rounded_rectangle(f._b([sx, fy + 16, sx + 42, fy + 40]),
                                      radius=12 * f.u,
                                      fill=ACCENT if on else (214, 220, 218))
                f.circle([sx + (21 if on else 3), fy + 19, sx + (39 if on else 21),
                          fy + 37], fill=CARD)
            elif fld.get('chip'):
                w = f.tw(fld['chip'][0], 10.5, 'b') + 16
                f.chip(x1 - pad - 14 - w, fy + 18, fld['chip'][0], 10.5,
                       fld['chip'][1], h=19)
            else:
                f.icon('chevron', [x1 - pad - 30, fy + 19, x1 - pad - 16, fy + 33],
                       INK3, 1.6)
            fy += 52
        y = fy + 10
    return y1


def calendar(f, spec, rect):
    x0, y, x1, y1 = rect
    pad = 12
    r = C.rng(spec['route'])
    ch = 232
    f.card([x0 + pad, y, x1 - pad, y + ch], r=12)
    f.text((x0 + pad + 14, y + 14), spec.get('month', 'September 2026'), 14.5, 'x', INK)
    f.icon('chevron', [x1 - pad - 30, y + 14, x1 - pad - 16, y + 28], INK3, 1.6)
    cw = (x1 - x0 - pad * 2 - 28) / 7
    for i, dname in enumerate(['M', 'T', 'W', 'T', 'F', 'S', 'S']):
        f.text((x0 + pad + 14 + cw * (i + 0.5), y + 44), dname, 10, 'b', INK3, anchor='mm')
    marks = spec.get('marks', {})
    for wk in range(5):
        for dow in range(7):
            day = wk * 7 + dow - 1
            if day < 1 or day > 30:
                continue
            cx = x0 + pad + 14 + cw * (dow + 0.5)
            cy = y + 68 + wk * 30
            m = marks.get(day)
            if m:
                f.circle([cx - 13, cy - 13, cx + 13, cy + 13], fill=SOFT[m[0]][0])
            if day == 18:
                f.circle([cx - 13, cy - 13, cx + 13, cy + 13], fill=ACCENT)
            f.text((cx, cy), str(day), 11.5, 'b' if (m or day == 18) else 'm',
                   CARD if day == 18 else (SOFT[m[0]][1] if m else INK2), anchor='mm')
            if m and day != 18:
                f.circle([cx - 2, cy + 15, cx + 2, cy + 19], fill=SOFT[m[0]][1])
    y += ch + 12
    y = section(f, x0 + pad, y, spec.get('rows_title', 'This week'), None, x1 - pad) + 2
    doc_rows(f, [x0 + pad, y, x1 - pad, y1], spec['rows'], h=58)
    return y1


RENDER = {'dashboard': dashboard, 'doclist': doclist, 'list': listing, 'board': board,
          'report': report, 'stats': stats, 'ask': ask, 'chat': chat, 'grid': grid,
          'form': form, 'calendar': calendar}


def detail_pane(f, spec, rect):
    """The right-hand pane a tablet has room for.

    A list on a phone is a list; on a tablet the app opens the selected
    row beside it, so a tablet screenshot that showed the phone list
    stretched to 2,560px would be advertising a layout the app does not
    have.
    """
    x0, y, x1, y1 = rect
    rows = spec.get('rows') or []
    row = rows[0] if rows else dict(title=spec['title'], sub='', tone='accent')
    f.card([x0, y, x1, y1 - 4], r=12)
    ix0, ix1 = x0 + 16, x1 - 16
    f.text((ix0, y + 16), row['title'], 17, 'x', INK, max_w=ix1 - ix0 - 70)
    if row.get('status'):
        w = f.tw(row['status'], 10.5, 'b') + 18
        f.chip(ix1 - w, y + 17, row['status'], 10.5, row.get('tone', 'grey'), h=20)
    f.text((ix0, y + 40), row.get('sub', ''), 11.5, 'm', INK3, max_w=ix1 - ix0)
    dy = y + 64
    f.hline(ix0, ix1, dy - 8, BORDER_SOFT, 1)
    kind = spec.get('kind')
    if kind in ('list',) and spec['route'].startswith(('/hr', '/team', '/contacts',
                                                       '/customers', '/suppliers',
                                                       '/prospects', '/salespeople',
                                                       '/crm/leads', '/practice')):
        pairs = [('Registration', '202601012345'), ('Tax (TIN)', 'C 2588 4471 0900'),
                 ('Terms', '30 days from invoice'), ('Contact', '+60 12-345 6789')]
        events = [('Invoice INV-2026-0418 issued', '16 Sep 2026, 09:04'),
                  ('Payment RM 12,380.50 received', '12 Sep 2026, 14:22'),
                  ('Statement of account emailed', '1 Sep 2026, 08:00'),
                  ('Credit limit raised to RM 80,000', '12 Aug 2026, 11:36'),
                  ('Account opened', '4 Feb 2024')]
    else:
        pairs = [('Issued', '16 Sep 2026'), ('Due', '16 Oct 2026'),
                 ('LHDN UUID', 'F9K2…8D41'), ('Validated', '16 Sep, 09:12')]
        # The same four timestamps the fields above carry, in the order they
        # happened -- not a second account of the document's life.
        events = [('Drafted by Nurul Aisyah', '15 Sep 2026, 16:40'),
                  ('Issued', '16 Sep 2026, 09:04'),
                  ('Submitted to MyInvois', '16 Sep 2026, 09:11'),
                  ('Validated by LHDN · F9K2…8D41', '16 Sep 2026, 09:12'),
                  ('Emailed to the buyer', '16 Sep 2026, 09:20'),
                  ('Payment due', '16 Oct 2026')]
    for i, (k, v) in enumerate(pairs):
        cx = ix0 + ((ix1 - ix0) / 2) * (i % 2)
        cy = dy + (i // 2) * 38
        f.text((cx, cy), k.upper(), 9, 'b', INK3)
        f.text((cx, cy + 14), v, 12, 'b', INK, max_w=(ix1 - ix0) / 2 - 12)
    dy += ((len(pairs) + 1) // 2) * 38 + 4
    f.hline(ix0, ix1, dy - 6, BORDER_SOFT, 1)
    f.text((ix0, dy + 2), 'LINES', 9, 'b', INK3)
    dy += 20
    lines = [('Cement OPC 50kg', '120 × RM 18.50', 'RM 2,220.00'),
             ('Steel Bar Y10 6m', '80 × RM 32.00', 'RM 2,560.00'),
             ('Delivery to Shah Alam', '1 × RM 480.00', 'RM 480.00'),
             ('Plywood 18mm 8x4', '40 × RM 61.00', 'RM 2,440.00')]
    totals_top = y1 - 148
    for name, qty, amt in lines:
        if dy + 32 > totals_top - 8:
            break
        f.text((ix0, dy), name, 12, 'b', INK, max_w=(ix1 - ix0) - 110)
        f.text((ix0, dy + 15), qty, 10.5, 'm', INK3)
        f.text((ix1, dy + 4), amt, 12, 'b', INK, anchor='ra')
        dy += 32
    # An iPad is tall enough to leave a hand's width of nothing between the
    # last line and the totals. The document's own history goes in it --
    # events, so nothing here has to agree with the arithmetic below.
    if totals_top - dy > 150:
        dy += 6
        f.hline(ix0, ix1, dy - 4, BORDER_SOFT, 1)
        f.text((ix0, dy + 8), 'HISTORY', 9, 'b', INK3)
        dy += 28
        for i, (what, when) in enumerate(events):
            if dy + 30 > totals_top - 12:
                break
            cy = dy + 7
            f.circle([ix0 + 1, cy - 4, ix0 + 9, cy + 4],
                     fill=ACCENT if i == 0 else CARD, outline=ACCENT, w=1.4)
            if i + 1 < len(events) and dy + 30 + 30 <= totals_top - 12:
                f.line((ix0 + 5, cy + 6), (ix0 + 5, cy + 24), BORDER, 1.2)
            f.text((ix0 + 20, dy), what, 11.5, 'b', INK, max_w=ix1 - ix0 - 30)
            f.text((ix0 + 20, dy + 15), when, 10, 'm', INK3)
            dy += 30
    ty = totals_top
    f.hline(ix0, ix1, ty - 8, BORDER, 1)
    for k, v, b in [('Subtotal', 'RM 7,700.00', False), ('SST 6%', 'RM 462.00', False),
                    ('Total', 'RM 8,162.00', True)]:
        f.text((ix0, ty), k, 12.5 if b else 11.5, 'b' if b else 'm', INK if b else INK2)
        f.text((ix1, ty - (2 if b else 0)), v, 16 if b else 12, 'x' if b else 'b', INK,
               anchor='ra')
        ty += 26 if b else 20
    by = y1 - 56
    bw = (ix1 - ix0 - 10) / 2
    f.card([ix0, by, ix0 + bw, by + 40], r=10, fill=ACCENT, border=None)
    f.text((ix0 + bw / 2, by + 20), 'Send to LHDN', 12.5, 'b', CARD, anchor='mm')
    f.card([ix0 + bw + 10, by, ix1, by + 40], r=10, fill=CARD, border=BORDER)
    f.text((ix0 + bw + 10 + bw / 2, by + 20), 'Download PDF', 12.5, 'b', ACCENT,
           anchor='mm')
