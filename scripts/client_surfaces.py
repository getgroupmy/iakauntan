#!/usr/bin/env python3
"""Where the Flutter client can reach the database — ONE definition.

Three gates needed this answer and each had its own copy of it, pinned
to a single file:

    CLIENT = ROOT / "app" / "lib" / "src" / "data" / "repository.dart"

That file holds most of it — 576 of the 597 named RPC calls — so all
three gates looked thorough and reported clean sweeps over an incomplete
denominator. What they could not see:

  * **16 writing functions** reached only from `ai_repository.dart`,
    `corp_repository.dart`, `custom_fields_repository.dart` and
    `ocr_repository.dart`, seven of them corporate secretarial. The
    write-idempotency census said "340 client-reachable writes, 0
    undecided" and the real population was 355.
  * **14 more tables written directly**, including every `corp_*`
    statutory register, `attachments`, and — from a SCREEN rather than a
    repository at all — `inbound_emails`, `organizations`, `firm_members`
    and `profiles`.

The last four are why this globs the whole of `app/lib` and not
`app/lib/src/data`. A directory is a convention, and `settings_screen.dart`
updating `organizations` directly does not break any convention loudly
enough for a glob to notice.

So: derived, never pinned, and shared. `scripts/client_surfaces_test.py`
asserts the scope is wider than one file and wider than one directory,
because the failure this module exists to prevent looks exactly like
success.
"""

from __future__ import annotations

import pathlib
import re

#: Everything the Flutter app is built from. `app/lib` is the whole of
#: it: `main.dart`, `src/core`, `src/data`, `src/features`.
CLIENT_ROOT = ("app", "lib")

#: A named RPC, through either wrapper. `callRpcOnce` is the keyed form.
RPC = re.compile(r"callRpc(?:Once)?\(\s*'([a-z0-9_]+)'")

#: PostgREST straight onto a table, with whatever filters and newlines
#: sit between the table and the verb. 75 of the direct writes in
#: `repository.dart` alone break the chain across lines.
DIRECT = re.compile(
    r"\.from\('([a-z0-9_]+)'\)"
    r"((?:\s|\.[a-zA-Z_]+\([^()]*\))*?)"
    r"\.(insert|update|upsert|delete)\b"
)


def dart_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Every Dart file in the app, newest-irrelevant, sorted for stability."""
    return sorted((root / pathlib.Path(*CLIENT_ROOT)).rglob("*.dart"))


#: What separates two files in `client_text`. A NEWLINE IS NOT ENOUGH, and
#: `client_surfaces_test.py` proves it: `DIRECT`'s middle group matches
#: `\s`, so a file ending at `client.from('t')` splices onto a next file
#: starting at `.insert({...})` and the gate reports a write that is in
#: neither. The semicolon cannot be matched by that group or by `RPC`, so
#: it ends any expression spanning the join. Found by a test written to
#: assert the newline was sufficient -- it was not.
BOUNDARY = "\n;\n"


def client_text(root: pathlib.Path) -> str:
    """All of it as one string, for a gate that only wants to grep.

    Joined with `BOUNDARY` rather than a newline, so no pattern here can
    match across two files' contents.
    """
    return BOUNDARY.join(f.read_text() for f in dart_files(root))


def by_file(root: pathlib.Path) -> dict[pathlib.Path, str]:
    """Each surface's own text, for a gate that must report a location."""
    return {f: f.read_text() for f in dart_files(root)}


def surfaces_that_touch_the_database(root: pathlib.Path) -> list[pathlib.Path]:
    """The subset that actually calls an RPC or writes a table.

    Reported rather than used for filtering: the gates read everything,
    because a file that starts touching the database should not have to
    be added to a list first.
    """
    return [f for f, t in by_file(root).items()
            if RPC.search(t) or DIRECT.search(t)]
