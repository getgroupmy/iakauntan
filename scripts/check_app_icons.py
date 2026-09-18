#!/usr/bin/env python3
"""The app icons on both phones, and the dark half of each.

    python3 scripts/check_app_icons.py

An icon set is the one part of a mobile app nothing else looks at. The
analyser does not read it, no test renders it, and a build succeeds
with a wrong-sized image, a filename nobody renamed on both sides, or a
"dark" variant that is a byte-for-byte copy of the light one. The first
anybody hears is a home screen.

So the claims are checked here:

IOS
  * every `Contents.json` entry names a file that exists;
  * every image is exactly `size x scale` pixels, because an asset
    catalogue takes a wrong one without complaint and the system then
    scales it;
  * nothing is left in the folder that no entry names -- an orphan is
    usually the other half of a rename;
  * every entry the SYSTEM draws has a dark twin, so dark mode is not
    half-done;
  * no dark twin is identical to its light counterpart, which is what a
    copy-and-rename produces and which changes nothing on a phone;
  * the App Store's 1024 has no transparency. App Store Connect
    rejects an alpha channel on submission, and that is a rejection
    that arrives hours after a build somebody thought had shipped.

ANDROID
  * every density carries all three files an adaptive icon needs;
  * the adaptive XML's drawables resolve;
  * `values` AND `values-night` both define the background colour --
    see the note below about what that does and does not buy;
  * the manifest names both `icon` and `roundIcon`.

## What Android dark icons actually are

Android has no light/dark launcher icon. The icon is drawn by the
LAUNCHER, in the launcher's own process, and what it resolves is the
adaptive icon's background colour against that process's configuration
-- so `values-night` is honoured by many launchers and guaranteed by
none of them.

The mechanism Android does document is the MONOCHROME layer: on 13 and
later a themed icon is tinted to match the wallpaper. That is why the
adaptive XML carries one, and why the check below insists on it.
"""
import json
import re
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / 'app/ios/Runner/Assets.xcassets/AppIcon.appiconset'
RES = ROOT / 'app/android/app/src/main/res'
MANIFEST = ROOT / 'app/android/app/src/main/AndroidManifest.xml'

DENSITIES = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']
ADAPTIVE = ['ic_launcher.xml', 'ic_launcher_round.xml']


def png_header(path: Path):
    """(width, height, bit depth, colour type) from IHDR."""
    d = path.read_bytes()
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'{path.name} is not a PNG')
    w = int.from_bytes(d[16:20], 'big')
    h = int.from_bytes(d[20:24], 'big')
    return w, h, d[24], d[25]


def has_transparency(path: Path) -> bool:
    """Whether any pixel is less than fully opaque.

    Decoded here rather than with Pillow so the check cannot quietly
    stop running on a machine that has no imaging library -- which is
    the failure mode of every "skip if unavailable" check ever written.
    """
    d = path.read_bytes()
    w, h, depth, colour = png_header(path)
    if colour not in (4, 6):        # no alpha channel at all
        return False
    if depth != 8:
        raise ValueError(f'{path.name}: {depth}-bit PNG, cannot read alpha')
    idat, i = bytearray(), 8
    interlace = None
    while i < len(d):
        length = int.from_bytes(d[i:i + 4], 'big')
        kind = d[i + 4:i + 8]
        if kind == b'IHDR':
            interlace = d[i + 8 + 12]
        elif kind == b'IDAT':
            idat += d[i + 8:i + 8 + length]
        elif kind == b'IEND':
            break
        i += 12 + length
    if interlace:
        raise ValueError(f'{path.name}: interlaced, cannot read alpha')

    raw = zlib.decompress(bytes(idat))
    bpp = 4 if colour == 6 else 2
    stride = w * bpp
    prev = bytearray(stride)
    pos = 0
    for _ in range(h):
        f = raw[pos]
        row = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                row[x] = (row[x] + a) & 0xFF
            elif f == 2:
                row[x] = (row[x] + b) & 0xFF
            elif f == 3:
                row[x] = (row[x] + ((a + b) >> 1)) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc
                                    else b if pb <= pc else c)) & 0xFF
        if any(row[x] != 255 for x in range(bpp - 1, stride, bpp)):
            return True
        prev = row
    return False


def check_ios(problems: list):
    spec = json.loads((IOS / 'Contents.json').read_text())
    named, dark = set(), {}
    for entry in spec['images']:
        fn = entry.get('filename')
        if not fn:
            problems.append('an entry in Contents.json names no file')
            continue
        named.add(fn)
        path = IOS / fn
        if not path.exists():
            problems.append(f'ios: {fn} is named by Contents.json and is not there')
            continue
        want = round(float(entry['size'].split('x')[0]) * int(entry['scale'][0]))
        w, h, _, _ = png_header(path)
        if (w, h) != (want, want):
            problems.append(
                f'ios: {fn} is {w}x{h} and its entry says {want}x{want}')
        if entry['idiom'] == 'ios-marketing' and has_transparency(path):
            problems.append(
                f'ios: {fn} has transparent pixels. App Store Connect '
                f'refuses an alpha channel on the marketing icon')
        if entry.get('appearances'):
            dark[(entry['idiom'], entry['size'], entry['scale'])] = fn

    for fn in sorted(p.name for p in IOS.glob('*.png')):
        if fn not in named:
            problems.append(
                f'ios: {fn} is in the folder and no entry names it')

    # Matched on (idiom, size, scale) and NOT on how many files there
    # are. Several entries share one image on purpose -- an iPhone and
    # an iPad both draw `Icon-App-29x29@1x.png` -- so counting files
    # says fourteen where there are eighteen entries, and the first
    # version of this check failed a set that was complete.
    drawn = {(e['idiom'], e['size'], e['scale'])
             for e in spec['images']
             if e['idiom'] != 'ios-marketing' and not e.get('appearances')}
    missing = drawn - set(dark)
    if missing:
        problems.append(
            'ios: no dark variant for ' +
            ', '.join(f'{i} {s} @{c}' for i, s, c in sorted(missing)) +
            '. Dark mode is half-done')

    for fn in set(dark.values()):
        light = fn.replace('-dark.png', '.png')
        if (IOS / light).exists() and \
                (IOS / light).read_bytes() == (IOS / fn).read_bytes():
            problems.append(
                f'ios: {fn} is byte-for-byte {light}. A dark variant that is '
                f'a copy of the light one changes nothing on a phone')


def check_android(problems: list):
    for d in DENSITIES:
        for name in ['ic_launcher.png', 'ic_launcher_round.png',
                     'ic_launcher_foreground.png']:
            if not (RES / f'mipmap-{d}' / name).exists():
                problems.append(f'android: mipmap-{d}/{name} is missing')

    for name in ADAPTIVE:
        path = RES / 'mipmap-anydpi-v26' / name
        if not path.exists():
            problems.append(f'android: {name} is missing, so there is no '
                            f'adaptive icon at all')
            continue
        body = path.read_text()
        for layer in ['background', 'foreground', 'monochrome']:
            if f'<{layer}' not in body:
                problems.append(
                    f'android: {name} has no <{layer}>. Themed icons need '
                    f'the monochrome layer; the other two are the icon')
        for ref in re.findall(r'@mipmap/(\w+)', body):
            if not all((RES / f'mipmap-{d}' / f'{ref}.png').exists()
                       for d in DENSITIES):
                problems.append(
                    f'android: {name} draws @mipmap/{ref} and it is not at '
                    f'every density')

    for values in ['values', 'values-night']:
        path = RES / values / 'ic_launcher_background.xml'
        if not path.exists() or 'ic_launcher_background' not in path.read_text():
            problems.append(
                f'android: {values}/ic_launcher_background.xml does not '
                f'define the colour the adaptive icon draws')

    manifest = MANIFEST.read_text()
    for attr, value in [('android:icon', '@mipmap/ic_launcher'),
                        ('android:roundIcon', '@mipmap/ic_launcher_round')]:
        if f'{attr}="{value}"' not in manifest:
            problems.append(f'android: the manifest does not set {attr}')


def main() -> int:
    problems: list[str] = []
    check_ios(problems)
    check_android(problems)
    if problems:
        for p in problems:
            print(f'::error::{p}')
        return 1
    print('app icons: every size, every reference, and a dark variant for '
          'each of the icons iOS draws')
    return 0


if __name__ == '__main__':
    sys.exit(main())
