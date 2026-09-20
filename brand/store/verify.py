"""Check every emitted asset against the store's stated limits.

    python3 brand/store/verify.py brand/store/out
    python3 brand/store/verify.py brand/store/out-ios --ios

The limits are the ones each store states per slot, written down here so a
layout change that pushes a file over one fails loudly instead of being
found by the upload form.
"""
import math, os, sys
from PIL import Image

PLAY = {
    '01-feature-graphic': dict(exact={(1024, 500)}, max_mb=15),
    '02-phone': dict(ratio={(9, 16), (16, 9)}, side=(320, 3840), max_mb=8),
    '03-tablet-7in': dict(ratio={(9, 16), (16, 9)}, side=(320, 3840), max_mb=8),
    '04-tablet-10in': dict(ratio={(9, 16), (16, 9)}, side=(1080, 7680), max_mb=8),
    '05-screenshots-min-1080px': dict(ratio={(9, 16), (16, 9)}, side=(1080, 7680),
                                      max_mb=8),
    '06-screenshots-min-720px': dict(ratio={(9, 16), (16, 9)}, side=(720, 7680),
                                     max_mb=15),
    '99-all-screens-phone': dict(ratio={(9, 16), (16, 9)}, side=(320, 3840), max_mb=8),
}

# Apple states the sizes exactly and rejects an alpha channel outright; the
# megabyte ceilings are ours, not Apple's, and are here to catch a file that
# has grown by an order of magnitude rather than to enforce a published cap.
IOS = {
    '01-iphone-6.5in': dict(exact={(1284, 2778), (2778, 1284)}, max_mb=10,
                            count=10, opaque=True),
    '02-ipad-12.9in-portrait': dict(exact={(2048, 2732)}, max_mb=15, count=10,
                                    opaque=True),
    '03-ipad-12.9in-landscape': dict(exact={(2732, 2048)}, max_mb=15, count=10,
                                     opaque=True),
}

LIMITS = {'play': PLAY, 'ios': IOS}


def main(outdir, store='play'):
    bad, n = [], 0
    for folder, rule in LIMITS[store].items():
        path = os.path.join(outdir, folder)
        if not os.path.isdir(path):
            bad.append(f'{folder}: missing')
            continue
        files = sorted(f for f in os.listdir(path) if f.endswith(('.png', '.jpg')))
        if not files:
            bad.append(f'{folder}: empty')
        if 'count' in rule and len(files) != rule['count']:
            bad.append(f'{folder}: {len(files)} files, wanted {rule["count"]}')
        for name in files:
            n += 1
            full = os.path.join(path, name)
            im = Image.open(full)
            w, h = im.size
            mb = os.path.getsize(full) / 1e6
            where = f'{folder}/{name}'
            if im.format not in ('PNG', 'JPEG'):
                bad.append(f'{where}: {im.format} is neither PNG nor JPEG')
            if 'exact' in rule and (w, h) not in rule['exact']:
                bad.append(f'{where}: {w}x{h}, wanted one of '
                           f'{sorted(rule["exact"])}')
            if 'ratio' in rule:
                g = math.gcd(w, h)
                if (w // g, h // g) not in rule['ratio']:
                    bad.append(f'{where}: {w}x{h} is {w//g}:{h//g}, not 16:9 or 9:16')
                lo, hi = rule['side']
                if min(w, h) < lo or max(w, h) > hi:
                    bad.append(f'{where}: sides {w}x{h} outside {lo}-{hi}px')
            if rule.get('opaque') and (im.mode not in ('RGB', 'L')
                                       or 'transparency' in im.info):
                bad.append(f'{where}: {im.mode} carries alpha; App Store Connect '
                           f'rejects that')
            if mb > rule['max_mb']:
                bad.append(f'{where}: {mb:.1f} MB over the {rule["max_mb"]} MB limit')
    for b in bad:
        print('FAIL', b)
    print(f'{n} files checked, {len(bad)} problems')
    return 1 if bad else 0


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    sys.exit(main(args[0], 'ios' if '--ios' in sys.argv[1:] else 'play'))
