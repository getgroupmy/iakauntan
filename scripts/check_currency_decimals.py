#!/usr/bin/env python3
"""The app's copy of the currency decimals matches the seeded one.

`Fmt.money` is a pure function called from four hundred places with no
async context, so it cannot await a lookup in `ref_currencies`. It
carries a `const` map of the ISO 4217 exceptions instead -- and a second
copy of anything is a second copy that goes stale.

So this compares the two on every build: the Dart map in
`app/lib/src/core/format.dart` against the `ref_currencies` seed in
`supabase/migrations/0011_seed_reference.sql`.

Only the EXCEPTIONS are in the Dart map, because writing out the other
nineteen seeded currencies to say "2" is nineteen chances to type 3. So
the comparison is: every seeded currency whose decimals are not 2 is in
the map with that number, and nothing else is in the map at all.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DART = ROOT / "app/lib/src/core/format.dart"
SEED = ROOT / "supabase/migrations/0011_seed_reference.sql"


def dart_map(text: str | None = None) -> dict[str, int]:
    """The const map in `format.dart`. Takes the text so
    `check_currency_decimals_test.py` can feed it a fixture rather than
    reimplementing the parse, which is the half most likely to drift."""
    text = DART.read_text() if text is None else text
    block = re.search(
        r"currencyDecimalsBy\s*=\s*<String,\s*int>\{(.*?)\};", text, re.S)
    if not block:
        sys.exit("FAIL: no `currencyDecimalsBy` map in format.dart")
    return {
        code: int(places)
        for code, places in re.findall(
            r"'([A-Z]{3})'\s*:\s*(\d+)", block.group(1))
    }


def seeded(text: str | None = None) -> dict[str, int]:
    """The `ref_currencies` seed in `0011`. Takes the text for the same
    reason as `dart_map`."""
    text = SEED.read_text() if text is None else text
    block = re.search(
        r"insert into public\.ref_currencies\s*\([^)]*\)\s*values(.*?);",
        text, re.S)
    if not block:
        sys.exit("FAIL: no `ref_currencies` seed in 0011")
    # ('JPY', 'Japanese Yen', '¥', 0)
    rows = re.findall(
        r"\(\s*'([A-Z]{3})'\s*,\s*'[^']*'\s*,\s*'[^']*'\s*,\s*(\d+)\s*\)",
        block.group(1))
    if not rows:
        sys.exit("FAIL: the `ref_currencies` seed parsed to nothing -- the "
                 "column order probably changed, and this check has been "
                 "passing by reading an empty list")
    return {code: int(places) for code, places in rows}


def main() -> int:
    return compare(seeded(), dart_map())


def compare(theirs: dict[str, int], ours: dict[str, int]) -> int:
    """The verdict, over two parsed maps. Separated so the test can state
    a disagreement directly instead of building two files to imply one."""
    expected = {c: d for c, d in theirs.items() if d != 2}

    problems: list[str] = []
    for code, places in sorted(expected.items()):
        if code not in ours:
            problems.append(
                f"  {code} has {places} decimals in the seed and is missing "
                f"from format.dart, so it prints as though it had 2")
        elif ours[code] != places:
            problems.append(
                f"  {code} is {ours[code]} in format.dart and {places} in "
                f"the seed")
    for code in sorted(ours):
        if code not in expected:
            problems.append(
                f"  {code} is in format.dart and is not an exception in the "
                f"seed ({theirs.get(code, 'not seeded at all')})")

    if problems:
        print("FAIL: the currency decimals in format.dart do not match the "
              "seed.")
        print("\n".join(problems))
        print("\nFmt.money prints at the map's precision, so a mismatch is a "
              "figure written wrongly on an invoice that goes to somebody.")
        return 1

    print(f"currency decimals agree ({len(expected)} exceptions of "
          f"{len(theirs)} seeded)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
