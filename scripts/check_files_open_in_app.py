#!/usr/bin/env python3
"""A private document is never handed to another application.

    python3 scripts/check_files_open_in_app.py

## The exposure this exists for

Four screens used to open an attachment the same way: mint a SIGNED URL
and call

    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)

That puts a working link to a private document into a different
application -- its address bar, its history, its tab list, and whatever
a password manager or an extension can read. For as long as the
signature lasts, forwardable to anybody. On bank statements.

Asked for as: "images or pdf files should not open using external
browser or app, all should be in app only ... to avoid exposure of link
and addresses".

## What is checked

No file under `app/lib/` may call a signed-URL minter -- the helpers
that produce a link to a private object -- anywhere. Reading a document
goes through `showFileInApp`, which downloads the BYTES through the
authenticated client and draws them in the app, so no URL is created
and there is nothing to leak rather than a leak that expires.

`file_viewer.dart` and the repository that defines the minters are the
only exemptions, and the repository one is the definition itself.

## What is NOT checked, said out loud

`launchUrl` in general is fine and stays: a company's own website, a
`tel:` link, the LHDN portal. This is about PRIVATE STORAGE, not about
leaving the app.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / 'app/lib'

# The primitive, not the wrappers.
#
# The first version of this sweep matched the two HELPERS that existed
# at the time -- `attachmentUrl` and `chatFileUrl`. That was too narrow
# twice over: there were two more minters it had never heard of
# (`inboundAttachmentUrl` on the mail bucket, `feedbackFileUrl` on the
# feedback one), and a rename would have left it matching nothing while
# still printing `ok`. `createSignedUrl` is what actually produces the
# link, it comes from the Supabase client rather than from this
# repository, and nothing here can rename it.
MINTER = 'createSignedUrl'

# Nothing. Every private file in this app is now read as BYTES through
# `showFileInApp`, so there is no legitimate caller left -- and an
# allowlist with nothing in it is the strongest statement this sweep can
# make. A future one goes here WITH ITS REASON, not silently.
ALLOWED: set[str] = set()

CALL = re.compile(r'\b' + MINTER + r'\s*\(')


def main() -> int:
    if not LIB.exists():
        print(f'FAIL no lib at {LIB}', file=sys.stderr)
        return 1

    # A sweep that could not see its own subject would pass every file
    # for ever. `download` is what replaced the minter, so its presence
    # is the proof this tree is the one being guarded.
    reads_bytes = sum(
        1 for f in LIB.rglob('*.dart') if '.download(' in f.read_text())
    if reads_bytes < 3:
        print(f'FAIL only {reads_bytes} files read storage as bytes; this '
              'sweep is looking at the wrong tree', file=sys.stderr)
        return 1

    bad = []
    for f in sorted(LIB.rglob('*.dart')):
        rel = f.relative_to(ROOT).as_posix()
        if rel in ALLOWED:
            continue
        text = f.read_text()
        for m in CALL.finditer(text):
            line = text[:m.start()].count('\n') + 1
            bad.append((rel, line))

    if bad:
        print('FAIL these mint a link to a private document:', file=sys.stderr)
        for rel, line in bad:
            print(f'  {rel}:{line}  {MINTER}(...)', file=sys.stderr)
        print(file=sys.stderr)
        print('  Read it with `showFileInApp`, which takes the BYTES.',
              file=sys.stderr)
        print('  A signed URL handed out is a working link to private',
              file=sys.stderr)
        print('  paperwork, sitting in another application.', file=sys.stderr)
        return 1

    print('ok   nothing mints a link to a private document')
    return 0


if __name__ == '__main__':
    sys.exit(main())
