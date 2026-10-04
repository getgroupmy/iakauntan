#!/usr/bin/env python3
"""Self-test for check_currency_decimals.py.

The gate compares the `const` map in `format.dart` against the
`ref_currencies` seed, because `Fmt.money` is a pure function called from
four hundred places and cannot await a lookup. A mismatch is a figure
written wrongly on an invoice that goes to somebody.

Both halves are parsed with regexes out of files this repository writes,
and that is the whole risk: **a parse that stops matching returns an
empty map, and an empty map agrees with everything.** The gate already
guards the seed side against exactly that, and the assertions below keep
both guards honest and add a floor on the real files.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SPEC = importlib.util.spec_from_file_location(
    "ccd", HERE / "check_currency_decimals.py")
ccd = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(ccd)

DART = """
const currencyDecimalsBy = <String, int>{
  'JPY': 0,
  'KWD': 3,
};
"""

SEED = """
insert into public.ref_currencies (code, name, symbol, decimals) values
  ('MYR', 'Malaysian Ringgit', 'RM', 2),
  ('JPY', 'Japanese Yen', '¥', 0),
  ('KWD', 'Kuwaiti Dinar', 'KD', 3);
"""


def verdict(theirs, ours):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = ccd.compare(theirs, ours)
    return code, out.getvalue() + err.getvalue()


class ReadingTheTwoFiles(unittest.TestCase):

    def test_the_dart_map_is_read(self):
        self.assertEqual(ccd.dart_map(DART), {"JPY": 0, "KWD": 3})

    def test_the_seed_is_read_including_the_ordinary_two(self):
        self.assertEqual(ccd.seeded(SEED),
                         {"MYR": 2, "JPY": 0, "KWD": 3})

    def test_a_missing_dart_map_is_fatal(self):
        with self.assertRaises(SystemExit):
            ccd.dart_map("const somethingElse = <String, int>{};")

    def test_a_missing_seed_is_fatal(self):
        with self.assertRaises(SystemExit):
            ccd.seeded("insert into public.something_else (a) values (1);")

    def test_a_seed_that_parses_to_nothing_is_fatal(self):
        """The gate's own anti-vacuous-pass guard, and the reason it
        exists: an empty map agrees with everything, so a column order
        that stops matching would make this check pass for ever while
        comparing nothing."""
        with self.assertRaisesRegex(SystemExit, "passing by reading an empty"):
            ccd.seeded(
                "insert into public.ref_currencies (code, decimals) values\n"
                "  ('MYR', 2);")


class TheComparison(unittest.TestCase):

    def test_agreement_passes(self):
        code, said = verdict(ccd.seeded(SEED), ccd.dart_map(DART))
        self.assertEqual(code, 0, said)
        self.assertIn("2 exceptions of 3 seeded", said)

    def test_an_exception_missing_from_dart_fails(self):
        code, said = verdict({"MYR": 2, "JPY": 0}, {})
        self.assertEqual(code, 1)
        self.assertIn("JPY", said)
        self.assertIn("prints as though it had 2", said)

    def test_a_different_number_fails_and_names_both(self):
        code, said = verdict({"KWD": 3}, {"KWD": 2})
        self.assertEqual(code, 1)
        self.assertIn("2 in format.dart and 3 in the seed", said)

    def test_an_ordinary_currency_written_out_in_dart_fails(self):
        """The other direction. Writing the other nineteen out to say "2"
        is nineteen chances to type 3."""
        code, said = verdict({"MYR": 2}, {"MYR": 2})
        self.assertEqual(code, 1)
        self.assertIn("is not an exception in the seed", said)

    def test_a_dart_code_that_is_not_seeded_at_all_says_so(self):
        code, said = verdict({"MYR": 2}, {"XXX": 4})
        self.assertEqual(code, 1)
        self.assertIn("not seeded at all", said)

    def test_two_empty_maps_agree_which_is_why_the_floor_below_exists(self):
        """Stated rather than hidden: the comparison CANNOT tell an
        agreement from a parse that found nothing. That is not a defect in
        `compare`; it is why the parsers abort and why the real files have
        a floor."""
        code, _ = verdict({}, {})
        self.assertEqual(code, 0)


class TheRealFilesAreNotEmpty(unittest.TestCase):
    """A floor on the real repository, because every assertion above is
    about fixtures and would pass on a day both parsers had stopped
    working."""

    def test_the_real_seed_parses_to_a_plausible_number_of_currencies(self):
        self.assertGreater(len(ccd.seeded()), 10)

    def test_the_real_dart_map_has_at_least_one_exception(self):
        self.assertGreater(len(ccd.dart_map()), 0)

    def test_every_real_dart_entry_is_a_real_exception(self):
        """The same statement the gate makes, asserted here so a green
        self-test cannot coexist with a red gate without somebody noticing
        which of the two is wrong."""
        seed = ccd.seeded()
        for code, places in ccd.dart_map().items():
            self.assertIn(code, seed)
            self.assertNotEqual(places, 2, code)
            self.assertEqual(seed[code], places, code)


if __name__ == "__main__":
    unittest.main(verbosity=2)
