"""Compose one screenshot: chrome, then the body, at a given device size."""
import bodies
from frame import Frame
from ui import BG, CARD, INK, INK2, INK3, BORDER, ACCENT

PROFILES = {
    'phone':      dict(px=(1080, 1920), dp_w=360, mode='phone'),
    'tablet7':    dict(px=(1920, 1080), dp_w=820, mode='tablet'),
    'tablet10':   dict(px=(2560, 1440), dp_w=980, mode='tablet'),
    # Rendered at their own size rather than resampled from another: a
    # 3,840px shot upscaled from 2,560 is a blurred one, and text at 720p
    # wants a lower dp width, not a shrunk 7-inch layout.
    'tablet4k':   dict(px=(3840, 2160), dp_w=980, mode='tablet'),
    'tablet720':  dict(px=(1280, 720), dp_w=700, mode='tablet'),
    # App Store sizes, at their real point sizes: an iPhone 6.5-inch is
    # 428 x 926pt at 3x, an iPad Pro 12.9-inch 1024 x 1366pt at 2x. The
    # platform only changes the two bars iOS draws itself.
    'ios_phone':  dict(px=(1284, 2778), dp_w=428, mode='phone', platform='ios'),
    'ios_ipad':   dict(px=(2048, 2732), dp_w=1024, mode='tablet', platform='ios'),
    'ios_ipad_l': dict(px=(2732, 2048), dp_w=1366, mode='tablet', platform='ios'),
}

# What iOS keeps for itself at the bottom of the screen.
HOME_INDICATOR = 34
IPAD_INDICATOR = 20


def render(spec, profile='phone'):
    p = PROFILES[profile]
    f = Frame(p['px'][0], p['px'][1], p['dp_w'], p['mode'],
              p.get('platform', 'android'))
    return _phone(f, spec) if p['mode'] == 'phone' else _tablet(f, spec)


def _phone(f, spec):
    ios = f.platform == 'ios'
    safe = HOME_INDICATOR if ios else 0
    y = f.ios_status_bar() if ios else f.status_bar()
    y = f.app_bar(y, spec['title'], spec.get('actions', ('search', 'bell')),
                  sub=spec.get('sub'))
    if spec.get('tabs'):
        y = f.tabs(y, spec['tabs'], spec.get('active_tab', 0))
    f.rect([0, y, f.dw, f.dh], fill=BG)
    y += 10
    if spec.get('search'):
        y = f.search(y, spec['search']) + 10
    # 'chips' on a conversation screen are the suggestions above the
    # composer, which the body draws — not filters over a list.
    if spec.get('chips') and spec['kind'] not in ('ask', 'chat'):
        y = f.filter_chips(y, spec['chips']) + 10
    bar = f.dh - 62 - safe
    bodies.RENDER[spec['kind']](f, spec, (0, y, f.dw, bar - 8))
    f.bottom_bar(spec.get('nav', 5), safe=safe)
    if spec.get('fab'):
        f.fab(spec['fab'], bottom=78 + safe)
    return f.img


def _tablet(f, spec):
    ios = f.platform == 'ios'
    safe = IPAD_INDICATOR if ios else 0
    bot = f.dh - 8 - safe
    sb = 24
    f.rect([0, 0, f.dw, sb], fill=CARD)
    f.text((16, sb / 2), '9:41', 11, 'b', INK, anchor='lm')
    if ios:
        f._radios(f.dw - 16, sb / 2, INK, CARD)
    else:
        f.text((f.dw - 16, sb / 2), 'Wed 18 Sep', 11, 'm', INK3, anchor='rm')
    rw = f.rail(spec.get('rail', 6), w=200, org=spec['org'], top=sb, bottom=safe)
    y = f.app_bar(sb, spec['title'], spec.get('actions', ('search', 'bell')),
                  sub=spec['module'], x0=rw, h=58)
    if spec.get('tabs'):
        y = f.tabs(y, spec['tabs'], spec.get('active_tab', 0), x0=rw)
    f.rect([rw, y, f.dw, f.dh], fill=BG)
    y += 10
    kind = spec['kind']
    wide = kind in ('doclist', 'list')
    if wide:
        main_w = (f.dw - rw) * 0.56
        if spec.get('search'):
            f.search(y, spec['search'], x0=rw, x1=rw + main_w)
            if spec.get('chips'):
                f.filter_chips(y, spec['chips'][:3], x0=rw + main_w + 12)
            y += 48
        elif spec.get('chips'):
            y = f.filter_chips(y, spec['chips'], x0=rw + 12) + 10
        bodies.RENDER[kind](f, spec, (rw, y, rw + main_w, bot))
        bodies.detail_pane(f, spec, (rw + main_w + 12, y, f.dw - 14, bot))
    else:
        if spec.get('search'):
            y = f.search(y, spec['search'], x0=rw) + 10
        if spec.get('chips') and kind not in ('ask', 'chat'):
            y = f.filter_chips(y, spec['chips'], x0=rw + 12) + 10
        bodies.RENDER[kind](f, spec, (rw, y, f.dw, bot))
    # No FAB where the detail pane already carries the actions: two primary
    # buttons a thumb apart is the phone layout stretched, not a tablet one.
    if spec.get('fab') and not wide:
        f.fab(spec['fab'], bottom=20 + safe)
    if ios:
        f.home_indicator(safe, bg=BG)
    return f.img
