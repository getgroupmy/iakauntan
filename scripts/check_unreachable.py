#!/usr/bin/env python3
"""Every repository method and every provider is reached by something.

`docs/unreachable.md` describes this sweep and has described it for
months. It was run when somebody remembered, and this is what that
means in practice:

  * `0559` built the personal-mailbox model -- three states, an owner,
    a handover door -- and asserted all of it. Nothing in the app could
    reach any of it: the repository still sent two arguments to
    `request_mailbox`, and `assign_mailbox` had no caller anywhere.
    Found by running the sweep, months later.

  * `0567` built the bank feed. Its screen went in four hours after the
    lesson was written into `docs/unreachable.md`, and the first draft
    of that screen STILL left two of its own methods unreachable.

A procedure that depends on somebody remembering is a procedure that
fails silently, which is the argument this repository makes about
`signup_enabled`, `maintenance_mode` and `einvoice_defaults`. So it is
a gate now.

    python3 scripts/check_unreachable.py

## The two sweeps, and why neither is enough alone

The SQL check in `docs/unreachable.md` finds what the DATABASE can do
and nobody calls. It cannot see the layer where most of this hides: a
repository method or a provider that wraps a function the SQL check
counts as reached, and is itself called by nothing.

`creditLedger` is the specimen. It lives in `ocr_repository.dart` and
*is* called -- by `creditLedgerProvider`, which nothing watches. The
method sweep alone clears it; the provider sweep alone does not say
what it is. Neither on its own would have found it.

## The trap that is not the one it looks like

A provider SEEMS to be a false positive when the screen reads the same
thing through the repository directly. Four of eleven reported in one
pass were written off on those grounds and carried forward as
known-good. Going back found the opposite: a screen calling
`repo.posRecipeLines(id)` is not evidence that `posRecipeLinesProvider`
is reached, it is evidence that nothing needs it. All four were dead
declarations wrapping a call somebody else was already making.

So: do not exempt a name here because a screen "obviously" uses the
data. Read the declaration and decide whether anything reads THAT.
"""
import collections
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / 'app'
LIB = ROOT / 'lib' / 'src'
DATA = LIB / 'data'

# Model files declare constructors and getters, not repository calls.
NOT_A_REPOSITORY = {'models.dart', 'corp_models.dart'}

METHOD = (r'\n  (?:Future<[^>]*>|Future|Stream<[^>]*>|void|String|bool|num|'
          r'double|int|List<[^>]*>|Map<[^>]*>)\??\s+([a-z][A-Za-z0-9_]*)\s*\(')
PROVIDER = r'^final ([a-zA-Z0-9_]+Provider)\b'

# Named, with the reason, the way the dropdown census and the blind-catch
# budget are named. Anything here is a decision somebody made and can be
# argued with; anything not here is a build failure.
#
# Every entry is the same shape: a method whose only callers live in the
# file that declares it. The sweep counts calls across the whole tree
# and subtracts declarations, so a same-file caller DOES count -- these
# remain because their callers are themselves declarations rather than
# calls, or because the name is too common to match safely.
EXEMPT_METHODS = {
    # The two RPC helpers every other method in `repository.dart` is
    # built from. Several hundred callers, all inside that one file.
    'callRpc': 'the wrapper every other repository method calls',
    'callRpcOnce': 'the idempotent variant of the same wrapper',
    # A private-by-convention helper on the same class.
    'keyFor': 'builds a storage key for the methods beside it',
    'succeeded': 'reads an RPC envelope for the methods beside it',
    'notifyPush': 'the push fan-out the notify methods share',
}

# A ratchet, not an exemption. `check_blind_catches.py` uses the same
# shape and says why: "the number should go DOWN rather than up".
#
# Each of these four is declared, invalidated by exactly one screen,
# and watched by nobody — the `bankTransfersProvider` specimen, four
# times over. None is the "screen reads it directly" case either: the
# repository method behind each has no other caller, so the data is not
# reachable by any route. Somebody built each one, wired the
# invalidate, and never drew it.
#
# They are named rather than fixed in the same commit because the guard
# is the point: with them named, no FIFTH one can be added. Take one
# off this list when you draw it.
KNOWN_UNDRAWN = {
    'loyaltyAccountBalanceProvider':
        "a customer's points balance. The loyalty screen refreshes it "
        'after every change and shows it nowhere.',
    'pdcMaturingProvider':
        'post-dated cheques coming due. The cheques screen refreshes '
        'it twice and never lists them.',
    'sstDueProvider':
        'SST returns falling due within 120 days. Statutory, and the '
        'one on this list that matters most: a deadline nobody can see '
        'is a deadline nobody meets.',
    'stockAdjustmentsProvider':
        'what was written off or found. The stock take screen '
        'refreshes it and never shows the history.',
}

EXEMPT_PROVIDERS: dict[str, str] = dict(KNOWN_UNDRAWN)


def dart_files(base: Path) -> list[Path]:
    return sorted(p for p in base.rglob('*.dart'))


def strip_comments(text: str) -> str:
    """A name in a doc comment is prose, not a caller.

    `check_settings_are_read.py` strips them for the same reason: this
    repository explains itself at length, and a method named in the
    paragraph above its own declaration would count as reached.
    """
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'^\s*///?.*?$', '', text, flags=re.M)


def sweep(declaring: list[Path], pattern: str, exempt: dict,
          call_shape: str) -> list[str]:
    """Names declared in `declaring` that nothing anywhere references.

    Counts references across the WHOLE tree and subtracts the
    declarations themselves, rather than skipping the declaring files.
    Skipping them is what `docs/unreachable.md`'s own version does, and
    it is why that version reports eight names it should not: a helper
    whose callers all live in its own file reads as dead.

    Every file is tokenised once and counted into a Counter. The
    obvious loop — every name against every file — is four hundred
    names times seven hundred files of regex and does not finish.
    """
    declared: dict[str, Path] = {}
    for path in declaring:
        body = strip_comments(path.read_text(encoding='utf-8'))
        for name in re.findall(pattern, body, re.M):
            declared.setdefault(name, path)

    calls = re.compile(call_shape)
    # `ref.invalidate(fooProvider)` is not a read. It is a screen
    # saying "whatever that was, it is stale now" -- and a provider
    # whose ONLY reference anywhere is an invalidate is declared,
    # thrown away on every save, and looked at by nobody.
    #
    # `docs/unreachable.md` names `bankTransfersProvider` as the
    # specimen: it read the transfer register, its only reference was
    # an invalidate in the dialog that creates a transfer, so the RPC
    # behind it counted as reached while a transfer, once made, left
    # the app entirely. The first draft of `bank_feeds_card.dart` did
    # the same thing four hours after that was written down.
    #
    # `ref.refresh` is deliberately NOT here: it returns the value, so
    # somebody is reading it.
    thrown_away = re.compile(r'invalidate\(\s*([a-zA-Z0-9_]+)')
    seen: collections.Counter = collections.Counter()
    declarations: collections.Counter = collections.Counter()
    for path in dart_files(LIB):
        body = strip_comments(path.read_text(encoding='utf-8'))
        seen.update(calls.findall(body))
        for name in thrown_away.findall(body):
            seen[name] -= 1
        # Subtract only in the file that declares the name: the same
        # spelling in another file is a reference, not a declaration.
        declarations.update(
            n for n in re.findall(pattern, body, re.M)
            if declared.get(n) == path
        )

    return sorted(
        n for n in declared
        if seen[n] - declarations[n] <= 0 and n not in exempt
    )


def main() -> int:
    repos = [p for p in dart_files(DATA) if p.name not in NOT_A_REPOSITORY]
    if not repos:
        print('no repository files found — has the layout moved?',
              file=sys.stderr)
        return 1

    # A method is referenced as `name(`; a provider is referenced by
    # bare name, because `ref.watch(fooProvider)` has no bracket after
    # it and `fooProvider(id)` on a family has one.
    dead_methods = sweep(repos, METHOD, EXEMPT_METHODS,
                         r'\b([a-z][A-Za-z0-9_]*)\s*\(')
    dead_providers = sweep(dart_files(LIB), PROVIDER, EXEMPT_PROVIDERS,
                           r'\b([a-zA-Z0-9_]+Provider)\b')

    if dead_methods or dead_providers:
        if dead_methods:
            print('these repository methods are called by nothing: '
                  + ', '.join(dead_methods), file=sys.stderr)
        if dead_providers:
            print('these providers are watched by nothing: '
                  + ', '.join(dead_providers), file=sys.stderr)
        print('', file=sys.stderr)
        print('Each one is a capability the database has and nobody can '
              'reach. Wire it to a screen, or delete it — a wrapper for '
              'a call nobody can make is a promise the product does not '
              'keep. If it is genuinely a helper for the file it lives '
              'in, name it in EXEMPT_METHODS with the reason.',
              file=sys.stderr)
        print('docs/unreachable.md has the argument and the history.',
              file=sys.stderr)
        return 1

    print(f'ok   every repository method and provider is reached '
          f'({len(EXEMPT_METHODS)} helpers exempt, '
          f'{len(KNOWN_UNDRAWN)} providers known undrawn)')
    if KNOWN_UNDRAWN:
        print('     still to draw: ' + ', '.join(sorted(KNOWN_UNDRAWN)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
