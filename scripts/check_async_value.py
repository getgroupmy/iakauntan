#!/usr/bin/env python3
"""`ref.watch(p).value ?? const []` is not the fallback it looks like.

Riverpod's own documentation, in `AsyncValue`'s doc comment:

    // Reading .value will be throw during error and return null on
    // "loading" states.

`AsyncError.value` calls `throwErrorWithCombinedStackTrace` when the
provider has no previous data. So the `??` never runs. A line that
reads as "the list, or nothing if it has not arrived" is really "the
list, or nothing while it is loading, or throw out of `build` if it
failed" -- and the third case is the only one anybody wrote the `??`
for.

What that looks like from outside depends on where the line is:

  * in `build`, an error widget in debug and a grey screen in release,
    on a screen whose data simply failed to load;
  * in `initState`, nothing catches it at all. That is how pressing
    "Record time" on a matter produced a broken route rather than a
    dialog, when the matters list happened to be in a failed state.

`valueOrNull` is the one that does not throw. It is the same expression
otherwise, and at every site here the `??` or the `?.` beside it says
the author already meant null.

## A ratchet, not a rule

Sixty-five of these are left and they are not all dangerous -- a screen
where the only reachable failure is one the router already guards is
fine as it is. But each one is a place where a failed provider takes a
screen down instead of falling back, and the number should go DOWN. So
this fails a build that adds one, and fails a build that removes one
without lowering the budget.
"""
import re
import sys
from collections import Counter
from pathlib import Path

# Lower this when you fix some. Never raise it.
#
# 70 when first counted -- a hand-written grep said 61, because
# `[^)]*` cannot match a family provider like `itemsProvider('')` and
# quietly skipped nine of them.
#
# 70 to 66: the four in `matter_detail_screen.dart`. The worst of them
# was the `initState` of the Record time dialog, where an exception has
# nowhere at all to go -- it takes the route down rather than showing an
# error on a screen. The other three are `_available`, `_held` and the
# transfer dialog's matter list, all `.value ?? const []` in or under a
# `build`.
#
# 66 to 65: `_tax` in `expenses_screen.dart`, which is read from
# `build` -- so a failed tax-code load did not draw an expense dialog
# with no tax figure on it, it drew an error instead of the dialog.
#
# 65 to 58: all seven in `app_shell.dart`, which are the worst of them
# and were the whole reason to look at this file next. The others take a
# SCREEN down. These take the NAVIGATION down: `_visible` builds the
# rail, so a failed `isPlatformAdminProvider`, `organizationsProvider`
# or `myFirmsProvider` meant no rail to navigate away with and nothing
# on screen but grey -- on every route at once, recoverable only by
# reloading the page. `_RailHeader`, the company switcher and the
# account button are the same shape.
#
# Each one already had a `??` or a null check beside it, so the author
# had already said what to do when the answer is not there. The
# fallbacks are all "show less", which is the safe direction: a door
# missing for a moment beats every door missing until a reload.
# 58 to 50: all eight in `core/providers.dart`, found by the test
# written for the seven above -- `nor a failed role` went on throwing
# after `app_shell.dart` was clean, because `canAdminProvider` reads
# `memberRoleProvider.value` and the shell watches it.
#
# That is the whole of the argument for these being worth fixing. The
# six role gates and the auditor check each carry `?? 'viewer'` or
# `?? ''`, which is least privilege and is the right answer both while
# the role is loading and if it failed. On a failure it never ran. What
# watches them is everything.
# 50 to 39: six in `document_editor.dart` and five in
# `items_screen.dart`.
#
# Three of the six are real and one of those is the worst kind. The
# `_grandTotal` getter read the company's rounding method with
# `.value?.`, from `build`, on the screen whose entire job is the total
# -- so a company that failed to load did not draw an invoice with no
# rounding applied, it drew nothing. The other two decide whether the
# e-Invoice button is offered.
#
# The remaining three each sit behind a `valueOrNull?.isNotEmpty` guard
# on the line ABOVE, so the error state cannot reach them. Changed
# anyway: this ratchet counts lines, and a reader should not have to
# prove to themselves that a `.value` here is the safe one.
#
# All five in `items_screen.dart` are real. `?? const <String>{}` is
# "no modules", which is right while the list loads and right if it
# failed -- the screen offers less. `.value` threw instead, taking the
# Items screen down over a list that only decides which buttons are in
# the app bar.
BUDGET = 39

LIB = Path(__file__).resolve().parent.parent / 'app' / 'lib'

# `ref.read(x).value` / `ref.watch(x).value`, with the provider
# expression allowed to contain brackets so a family provider --
# `ref.watch(timeEntriesProvider(id)).value` -- is counted too.
#
# ON ONE LINE, deliberately. Letting the expression cross a newline
# makes it run past a `.valueOrNull` and match the next `.value`
# further down the file, which reported three sites in
# `document_editor.dart` that are already correct. A call split over
# several lines is missed instead, and a miss is the safe direction for
# a ratchet: it cannot fail a build over a line that is right.
SITE = re.compile(r'ref\.(?:read|watch)\([^;\n]*?\)\s*\.value\b(?!OrNull)')


def sites():
    out = []
    for path in sorted(LIB.rglob('*.dart')):
        src = path.read_text()
        for m in SITE.finditer(src):
            line = src.count('\n', 0, m.start()) + 1
            out.append((str(path.relative_to(LIB)), line))
    return out


def main() -> int:
    found = sites()
    n = len(found)
    if n > BUDGET:
        print(f'FAIL: {n} reads of `.value` on a provider, budget is {BUDGET}.')
        print('`AsyncError.value` THROWS -- the `??` beside it never runs.')
        print('Use `.valueOrNull`, which returns null on error and loading.')
        print()
        for name, count in Counter(f for f, _ in found).most_common(12):
            print(f'  {count:3}  {name}')
        return 1
    if n < BUDGET:
        print(f'{n} reads of `.value` on a provider, budget is {BUDGET}.')
        print(f'Lower BUDGET in {Path(__file__).name} to {n} to hold the ground.')
        return 1
    print(f'{n} reads of `.value` on a provider, at the budget.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
