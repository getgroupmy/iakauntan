#!/usr/bin/env python3
"""A capture is not deleted because somebody closed a sheet.

    python3 scripts/check_capture_is_kept.py

Reported from the scan inbox: a document photographed at 19:33, read by
Gemini, its supplier and number and date all on screen -- and "View the
image" and "Read it again" both dead, because the file had been deleted
out from under them.

Two lines in `scan_flow.dart` did it. Backing out of the "what is this?"
sheet called `deleteAttachmentById` on the capture, on the reasoning
that a file attached to a record that will never exist should not sit in
the bucket. The reasoning is wrong in both halves:

  * somebody who photographs a document and then closes a sheet has not
    said "destroy this". They have said "not now";
  * the READING was already paid for and stays on `ocr_scans`, so what
    the delete leaves behind is a scan row pointing at nothing -- the
    one state nothing can recover from. The figures are there and the
    page they came off is not, so they cannot be checked and cannot be
    read again.

The inbox has a "Became nothing yet" filter for exactly these captures.

## What this gate says

`deleteAttachmentById` must not be called from the capture FLOW.
Removing a file is something a person asks for, from the sheet that
shows it, and `0708` refuses it outright once a posting or a reading was
built from the file.

The rule is about where the call is, not whether it exists: the method
is still the right one to call, from `scan_detail_sheet.dart`, behind a
confirmation.

## Why a gate rather than a test

A widget test for this would have to drive a camera, an upload, a reader
and two bottom sheets to assert that something did NOT happen. This is
one grep, it names the file the report came from, and it fails loudly if
the two lines come back -- which is the whole of what is being kept.
"""
import pathlib
import re
import sys

# Where a capture is turned into a record. Nothing here may throw the
# file away; the person has not asked.
FLOW = 'app/lib/src/features/smartscan/scan_flow.dart'

# Where a person asks for it, which is allowed and is the point.
ASKED = 'app/lib/src/features/smartscan/scan_detail_sheet.dart'

CALL = re.compile(r'\bdeleteAttachmentById\s*\(')


def offenders(root: pathlib.Path) -> list[tuple[str, int, str]]:
    out: list[tuple[str, int, str]] = []
    path = root / FLOW
    if not path.exists():
        return out
    for n, line in enumerate(path.read_text().splitlines(), 1):
        # A mention in a comment is how the decision is written down.
        if line.lstrip().startswith('//'):
            continue
        if CALL.search(line):
            out.append((FLOW, n, line.strip()))
    return out


def main(root: pathlib.Path | None = None) -> int:
    # Takes a root so the self-test can run the REAL function over a
    # tree it built, rather than reimplementing this in the test and
    # asserting against its own copy.
    root = root or pathlib.Path(__file__).resolve().parent.parent
    found = offenders(root)

    if not found:
        asked = root / ASKED
        # The other half: the deliberate one has to still be there, or
        # the rule has become "a file can never be removed", which is
        # not what was asked for either.
        if asked.exists() and not CALL.search(asked.read_text()):
            print('Nothing offers to remove a capture any more.')
            print()
            print(f'`{ASKED}` no longer calls `deleteAttachmentById`. The')
            print('rule is that a file stays until somebody asks for it to')
            print('go -- not that it can never go. Put the deliberate')
            print('remove back, or change this gate and say why.')
            return 1
        print('ok   a capture is kept until somebody asks for it to go')
        return 0

    print('The capture flow deletes the file it just made.')
    print()
    print('Backing out of a sheet is not "destroy this". The reading is')
    print('already paid for and stays on `ocr_scans`, so deleting the')
    print('file leaves a scan pointing at nothing -- figures that cannot')
    print('be checked and cannot be read again. The inbox has a "Became')
    print('nothing yet" filter for these.')
    print()
    for f, n, line in found:
        print(f'    {f}:{n}')
        print(f'        {line}')
    print()
    print('Remove the call. A person asks for a file to go, from')
    print(f'`{ASKED}`, and `0708` refuses once a posting or a reading was')
    print('built from it.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
