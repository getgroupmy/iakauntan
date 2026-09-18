"""The 1,024 x 500 feature graphic.

Google overlays its own play button and, in some placements, the app name
over this image, so the left two thirds carry the message and the right
third carries the product. Nothing important goes within 48px of an edge.
"""
import math
from PIL import Image, ImageDraw, ImageFilter
import ui
from ui import font, CARD, ACCENT, ACCENT_DK
from frame import Frame

W, H = 1024, 500
DEEP = (5, 59, 50)
MID = (11, 122, 107)
LIGHT = (18, 156, 133)


def _gradient():
    img = Image.new('RGB', (W, H), DEEP)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        for band in (0,):
            pass
        d.line([(0, y), (W, y)], fill=ui.blend(MID, DEEP, t * 0.85))
    # a diagonal wash so the flat teal has somewhere to go
    glow = Image.new('L', (W, H), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-240, -320, 620, 360], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(150))
    img = Image.composite(Image.new('RGB', (W, H), LIGHT), img, glow)
    return img


def _watermark(img):
    """The mark, very large and barely there, behind the product shot."""
    layer = Frame(W, H, W)
    layer.img = Image.new('RGB', (W, H), (0, 0, 0))
    layer.d = ImageDraw.Draw(layer.img)
    layer.mark([560, -60, 1160, 540], (255, 255, 255))
    mask = layer.img.convert('L').point(lambda v: int(v * 0.10))
    return Image.composite(Image.new('RGB', (W, H), (255, 255, 255)), img, mask)


def _phone(route='/dashboard'):
    import catalogue, specs, shot
    cat = {r: (m, a, l) for m, a, l, r in catalogue.screens()}
    m, a, l = cat[route]
    return shot.render(specs.build(m, a, l, route), 'phone')


def _device(shot_img, h):
    """A phone body around a screenshot: bezel, rounded screen, shadow."""
    w = round(h * 9 / 16)
    screen = shot_img.resize((w, h), Image.LANCZOS)
    bez = 9
    W2, H2 = w + bez * 2, h + bez * 2
    body = Image.new('RGBA', (W2, H2), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    d.rounded_rectangle([0, 0, W2 - 1, H2 - 1], radius=34, fill=(14, 22, 20, 255))
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=26, fill=255)
    body.paste(screen, (bez, bez), mask)
    return body


def build(out_path):
    img = _gradient()
    img = _watermark(img)
    d = ImageDraw.Draw(img)

    # --- product shot -----------------------------------------------------
    back = _device(_phone('/einvoice'), 360).rotate(8, Image.BICUBIC, expand=True)
    front = _device(_phone('/dashboard'), 430).rotate(-5, Image.BICUBIC, expand=True)
    for layer, pos in ((back, (600, 108)), (front, (742, 62))):
        sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
        sh.paste(Image.new('RGBA', layer.size, (0, 30, 24, 150)), (pos[0] + 6, pos[1] + 14),
                 layer.split()[3])
        sh = sh.filter(ImageFilter.GaussianBlur(18))
        img.paste(Image.alpha_composite(img.convert('RGBA'), sh).convert('RGB'), (0, 0))
        img.paste(layer, pos, layer)
    d = ImageDraw.Draw(img)

    # --- wordmark ---------------------------------------------------------
    f = Frame(W, H, W)
    f.img, f.d = img, d
    f.mark([64, 58, 118, 112], (255, 255, 255))
    d.text((132, 85), 'iAkauntan', font=font(46, 'x'), fill=CARD, anchor='lm')

    # --- message ----------------------------------------------------------
    y = 162
    for line in ('Accounting, payroll and', 'e-Invoice for Malaysia'):
        d.text((64, y), line, font=font(40, 'x'), fill=CARD)
        y += 50
    d.text((64, y + 14), 'LHDN MyInvois · EPF, SOCSO, EIS and PCB · SSM',
           font=font(18, 'm'), fill=(186, 222, 213))

    # --- proof chips ------------------------------------------------------
    x, cy = 64, 366
    for label in ('e-Invoice ready', 'Payroll and statutory', 'Point of sale'):
        w = d.textlength(label, font=font(17, 'b')) + 36
        d.rounded_rectangle([x, cy, x + w, cy + 40], radius=20,
                            fill=(255, 255, 255, 255) if label == 'e-Invoice ready'
                            else None,
                            outline=None if label == 'e-Invoice ready' else (120, 178, 166),
                            width=2)
        d.text((x + w / 2, cy + 20), label, font=font(17, 'b'),
               fill=ACCENT if label == 'e-Invoice ready' else (206, 232, 225),
               anchor='mm')
        x += w + 12

    img.save(out_path, 'PNG', optimize=True)
    return out_path


if __name__ == '__main__':
    import sys
    print(build(sys.argv[1] if len(sys.argv) > 1 else 'featured-graphic.png'))
