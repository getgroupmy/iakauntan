import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import mark
from render import draw, rgb
from PIL import Image, ImageDraw

OUT = os.path.dirname(__file__)

def svg(pad=0.0):
    inner = 1 - 2 * pad
    def T(p): return (mark.S * pad + p[0] * inner, mark.S * pad + p[1] * inner)
    def path(poly):
        d = 'M ' + ' L '.join('%.2f %.2f' % T(p) for p in poly) + ' Z'
        return '  <path d="%s"/>' % d
    x0, y0, x1, y1 = [c * inner + mark.S * pad for c in mark.DOT]
    return '\n'.join([
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" '
        'fill="%s" fill-rule="nonzero">' % (mark.S, mark.S, mark.GREEN),
        '  <title>iAkauntan</title>',
        path(mark.stem_and_bowl()),
        path(mark.chevron()),
        '  <rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f"/>'
        % (x0, y0, x1 - x0, y1 - y0, 6 * inner),
        '</svg>', ''])

if __name__ == '__main__':
    open(OUT + '/iakauntan-mark.svg', 'w').write(svg())
    open(OUT + '/iakauntan-mark-padded.svg', 'w').write(svg(pad=0.18))

    white = (255, 255, 255, 255)
    draw(512, bg=white).save(OUT + '/Icon-512.png')
    draw(192, bg=white).save(OUT + '/Icon-192.png')
    draw(32,  bg=white).save(OUT + '/favicon.png')
    # Maskable: Android crops to a circle, so the mark is inset into the
    # safe zone and the plate is filled edge to edge.
    draw(512, pad=0.18, bg=white).save(OUT + '/Icon-maskable-512.png')
    draw(192, pad=0.18, bg=white).save(OUT + '/Icon-maskable-192.png')

    # A sheet at the sizes these are actually judged at.
    sheet = Image.new('RGB', (1180, 300), 'white')
    d = ImageDraw.Draw(sheet)
    x = 20
    for s in (256, 192, 96, 64, 48, 32, 16):
        im = draw(s, bg=white)
        sheet.paste(im, (x, 20 + (256 - s) // 2))
        d.text((x, 285), '%dpx' % s, fill=(90, 90, 90))
        x += s + 24
    # the maskable one with the circle Android crops to
    m = draw(256, pad=0.18, bg=white).convert('RGB')
    md = ImageDraw.Draw(m)
    md.ellipse([2, 2, 253, 253], outline=(200, 30, 30), width=2)
    sheet.paste(m, (x + 10, 20))
    d.text((x + 10, 285), 'maskable, safe circle', fill=(90, 90, 90))
    sheet.save(OUT + '/contact-sheet.png')
    print('built')
