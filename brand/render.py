import sys
sys.path.insert(0, '/tmp/claude-0/-home-user-iakauntan/dd93afc2-58fb-5573-bf05-85f24e64ab07/scratchpad/brand')
import importlib, mark; importlib.reload(mark)
from PIL import Image, ImageDraw

def rgb(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))

def ink_bounds():
    """The mark's own extents. The artwork is not centred on its grid —
    it sits left and high — so an icon that simply scales the grid puts
    the mark off-centre, which Android's circular crop makes obvious."""
    xs, ys = [], []
    for poly in (mark.stem_and_bowl(), mark.chevron()):
        xs += [p[0] for p in poly]; ys += [p[1] for p in poly]
    x0, y0, x1, y1 = mark.DOT
    xs += [x0, x1]; ys += [y0, y1]
    return min(xs), min(ys), max(xs), max(ys)

def draw(size, pad=0.0, bg=None, ss=4):
    big = size * ss
    img = Image.new('RGBA', (big, big), bg or (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    bx0, by0, bx1, by1 = ink_bounds()
    k = big * (1 - 2 * pad) / max(bx1 - bx0, by1 - by0)
    ox = (big - (bx1 - bx0) * k) / 2 - bx0 * k
    oy = (big - (by1 - by0) * k) / 2 - by0 * k
    T = lambda p: (ox + p[0] * k, oy + p[1] * k)
    for poly in (mark.stem_and_bowl(), mark.chevron()):
        d.polygon([T(p) for p in poly], fill=rgb(mark.GREEN))
    x0, y0, x1, y1 = mark.DOT
    d.rounded_rectangle([T((x0, y0)), T((x1, y1))], radius=6 * k, fill=rgb(mark.GREEN))
    return img.resize((size, size), Image.LANCZOS)

if __name__ == '__main__':
    out = '/tmp/claude-0/-home-user-iakauntan/dd93afc2-58fb-5573-bf05-85f24e64ab07/scratchpad/brand'
    draw(1000, bg=(255, 255, 255, 255)).save(out + '/preview-1000.png')
    print('ok')
