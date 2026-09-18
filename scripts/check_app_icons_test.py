#!/usr/bin/env python3
"""The icon gate's own assertions.

    python3 scripts/check_app_icons_test.py

Beside the other gates' tests, for the reason they all give: a gate
that is wrong is worse than no gate, because it is believed.

This one earned it immediately. Its first version compared the NUMBER
OF DARK FILES against the number of entries and failed a set that was
complete -- several entries share one image on purpose, an iPhone and
an iPad both drawing `Icon-App-29x29@1x.png`, so fourteen files cover
eighteen entries. A gate that cries wolf on correct work is how the
next real finding gets waved through.
"""
import contextlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
import zlib
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'check_app_icons', Path(__file__).with_name('check_app_icons.py'))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def png(width: int, height: int, alpha: int = 255) -> bytes:
    """A real PNG, so the gate's own decoder is what reads it."""
    raw = bytearray()
    for _ in range(height):
        raw.append(0)                       # filter: none
        raw += bytes([1, 220, 0, alpha]) * width

    def chunk(kind: bytes, body: bytes) -> bytes:
        return (len(body).to_bytes(4, 'big') + kind + body +
                zlib.crc32(kind + body).to_bytes(4, 'big'))

    ihdr = (width.to_bytes(4, 'big') + height.to_bytes(4, 'big') +
            bytes([8, 6, 0, 0, 0]))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) +
            chunk(b'IDAT', zlib.compress(bytes(raw))) + chunk(b'IEND', b''))


class ReadingAPng(unittest.TestCase):
    def test_the_size_comes_off_the_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'a.png'
            p.write_bytes(png(60, 40))
            self.assertEqual(gate.png_header(p)[:2], (60, 40))

    def test_an_opaque_image_has_no_transparency(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'a.png'
            p.write_bytes(png(8, 8, alpha=255))
            self.assertFalse(gate.has_transparency(p))

    def test_and_a_transparent_one_does(self):
        # The App Store rejection this exists to prevent. Decoded here
        # rather than with an imaging library, so the check cannot
        # quietly stop running on a machine that has none.
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'a.png'
            p.write_bytes(png(8, 8, alpha=254))
            self.assertTrue(gate.has_transparency(p))

    def test_something_that_is_not_a_png_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'a.png'
            p.write_bytes(b'not a png at all')
            with self.assertRaises(ValueError):
                gate.png_header(p)


class TheRealTree(unittest.TestCase):
    def test_the_icons_in_this_repository_pass(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main()
        self.assertEqual(code, 0, out.getvalue())


class WhatItRefuses(unittest.TestCase):
    """Each check, broken on purpose against a copy of the real set."""

    def run_on(self, wreck):
        with tempfile.TemporaryDirectory() as tmp:
            ios = Path(tmp) / 'AppIcon.appiconset'
            shutil.copytree(gate.IOS, ios)
            wreck(ios)
            saved = gate.IOS
            gate.IOS = ios
            try:
                problems: list = []
                gate.check_ios(problems)
                return problems
            finally:
                gate.IOS = saved

    def test_a_complete_set_is_accepted(self):
        # The control. Without it every assertion below could be
        # passing because the harness refuses everything.
        self.assertEqual(self.run_on(lambda _: None), [])

    def test_a_named_file_that_is_not_there(self):
        problems = self.run_on(
            lambda d: (d / 'Icon-App-60x60@3x.png').unlink())
        self.assertTrue(any('is not there' in p for p in problems), problems)

    def test_an_image_of_the_wrong_size(self):
        problems = self.run_on(
            lambda d: (d / 'Icon-App-60x60@3x.png').write_bytes(png(12, 12)))
        self.assertTrue(any('12x12' in p for p in problems), problems)

    def test_a_file_no_entry_names(self):
        problems = self.run_on(
            lambda d: (d / 'Icon-App-leftover.png').write_bytes(png(4, 4)))
        self.assertTrue(
            any('no entry names it' in p for p in problems), problems)

    def test_a_dark_variant_that_is_a_copy_of_the_light_one(self):
        # What copy-and-rename produces, and it changes nothing on a
        # phone -- the failure with no symptom until somebody switches
        # their phone to dark and sees the same icon.
        def wreck(d):
            shutil.copyfile(d / 'Icon-App-60x60@3x.png',
                            d / 'Icon-App-60x60@3x-dark.png')
        self.assertTrue(
            any('byte-for-byte' in p for p in self.run_on(wreck)),
            self.run_on(wreck))

    def test_dark_mode_left_half_done(self):
        def wreck(d):
            spec = json.loads((d / 'Contents.json').read_text())
            spec['images'] = [i for i in spec['images']
                              if not (i.get('appearances')
                                      and i['size'] == '60x60')]
            (d / 'Contents.json').write_text(json.dumps(spec))
            for f in d.glob('Icon-App-60x60*-dark.png'):
                f.unlink()
        problems = self.run_on(wreck)
        self.assertTrue(any('half-done' in p for p in problems), problems)
        self.assertTrue(any('60x60' in p for p in problems), problems)

    def test_but_sharing_one_image_between_two_entries_is_not_a_gap(self):
        # The bug this gate shipped with for about a minute. An iPhone
        # and an iPad both draw `Icon-App-29x29@1x.png`, so a check
        # counting FILES sees fourteen where there are eighteen
        # entries, and fails a set with nothing wrong with it.
        spec = json.loads((gate.IOS / 'Contents.json').read_text())
        shared = [i for i in spec['images']
                  if i.get('filename') == 'Icon-App-29x29@1x.png']
        self.assertGreater(
            len(shared), 1,
            'this assertion is about a file two entries share; if the set '
            'stops sharing one, it is asserting nothing')
        self.assertEqual(self.run_on(lambda _: None), [])


class TheAndroidSide(unittest.TestCase):
    def run_on(self, wreck):
        with tempfile.TemporaryDirectory() as tmp:
            res = Path(tmp) / 'res'
            shutil.copytree(gate.RES, res)
            manifest = Path(tmp) / 'AndroidManifest.xml'
            shutil.copyfile(gate.MANIFEST, manifest)
            wreck(res, manifest)
            saved_res, saved_manifest = gate.RES, gate.MANIFEST
            gate.RES, gate.MANIFEST = res, manifest
            try:
                problems: list = []
                gate.check_android(problems)
                return problems
            finally:
                gate.RES, gate.MANIFEST = saved_res, saved_manifest

    def test_the_real_tree_passes(self):
        self.assertEqual(self.run_on(lambda r, m: None), [])

    def test_a_density_missing_its_foreground(self):
        problems = self.run_on(
            lambda r, m: (r / 'mipmap-xxhdpi/ic_launcher_foreground.png')
            .unlink())
        self.assertTrue(any('xxhdpi' in p for p in problems), problems)

    def test_the_monochrome_layer_dropped(self):
        # The only launcher-icon theming Android documents. Losing it
        # is losing themed icons on 13 and later, silently.
        def wreck(r, m):
            p = r / 'mipmap-anydpi-v26/ic_launcher.xml'
            p.write_text(p.read_text().replace('<monochrome', '<!-- x'))
        problems = self.run_on(wreck)
        self.assertTrue(any('monochrome' in p for p in problems), problems)

    def test_the_night_colour_dropped(self):
        problems = self.run_on(
            lambda r, m: (r / 'values-night/ic_launcher_background.xml')
            .unlink())
        self.assertTrue(
            any('values-night' in p for p in problems), problems)

    def test_a_layer_pointing_at_nothing(self):
        def wreck(r, m):
            p = r / 'mipmap-anydpi-v26/ic_launcher.xml'
            p.write_text(p.read_text()
                         .replace('@mipmap/ic_launcher_foreground',
                                  '@mipmap/ic_launcher_nonexistent'))
        problems = self.run_on(wreck)
        self.assertTrue(
            any('nonexistent' in p for p in problems), problems)

    def test_the_manifest_forgetting_the_round_icon(self):
        def wreck(r, m):
            m.write_text(m.read_text().replace(
                'android:roundIcon="@mipmap/ic_launcher_round"', ''))
        problems = self.run_on(wreck)
        self.assertTrue(any('roundIcon' in p for p in problems), problems)


if __name__ == '__main__':
    unittest.main(verbosity=0, buffer=True)
