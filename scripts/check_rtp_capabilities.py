#!/usr/bin/env python3
"""The call engine must not serialise RTP capabilities with the package's own
`toMap`, which throws away every header extension.

    python3 scripts/check_rtp_capabilities.py

`RtpCapabilities.toMap()` in `mediasfu_mediasoup_client 0.1.4` is, in
full:

    Map<String, dynamic> toMap() {
      return <String, dynamic>{
        'codecs': codecs.map((c) => c.toMap()).toList()
      };
    }

It serialises the codecs and silently drops `headerExtensions` and
`fecMechanisms`. `RtpHeaderExtension` has no `toMap` at all, so the
package cannot serialise one even when asked.

A mediasoup client sends that set once, at `join`, and the server uses it
to decide what each CONSUMER may carry. Sending no header extensions had
the server build every consumer against an empty list and strip every
extension from every stream the device received — including
`urn:3gpp:video-orientation`, without which a receiver draws a phone's
raw landscape sensor frames. That is the whole of why every incoming
camera was ninety degrees out.

## Why a gate rather than a test

Because the fix is ONE call site and nothing can test it from here.
`CallEngine` is an interface precisely because the real one needs a
microphone, a camera, a network and an SFU, none of which exist in a
widget test — so `app/test/call_rtp_test.dart` can prove
`rtpCapabilitiesToMap` is correct and can prove the package's `toMap`
loses the extensions, and still cannot prove the engine calls the right
one.

Reverting that line would restore a user-visible bug, silently, with a
green suite. So the call site is asserted here instead.

The failure it guards against is also the kind somebody reintroduces
innocently: `device.rtpCapabilities.toMap()` is what every mediasoup
example in every language writes, and it is wrong only in this package.
"""
from __future__ import annotations

import pathlib
import re
import sys

ENGINE = 'app/lib/src/features/chat/call_engine.dart'
HELPER = 'app/lib/src/features/chat/call_rtp.dart'

# `device.rtpCapabilities.toMap()`, and any other receiver spelled the
# same way. Whitespace and newlines between the parts are allowed,
# because a formatter is entitled to wrap it.
LOSSY = re.compile(r'rtpCapabilities\s*\.\s*toMap\s*\(\s*\)')

# The helper, called on something. Not anchored to `device.` — what
# matters is that the whole set goes, not which variable held it.
WHOLE = re.compile(r'rtpCapabilitiesToMap\s*\(')


def strip_comments(source: str) -> str:
    """Dart line and block comments, so prose may name the thing it warns of.

    This file's own point is that `rtpCapabilities.toMap()` must not be
    CALLED; the engine is expected to mention it in a comment explaining
    why it does not, and a check that could not tell those apart would
    fail on the explanation.
    """
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    return re.sub(r'//[^\n]*', '', source)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    problems: list[str] = []

    helper = root / HELPER
    if not helper.exists():
        problems.append(
            f'{HELPER} is missing. It holds `rtpCapabilitiesToMap`, which is '
            f'the only complete serialiser for a capability set.'
        )

    engine = root / ENGINE
    if not engine.exists():
        problems.append(f'{ENGINE} is missing.')
    else:
        code = strip_comments(engine.read_text())

        for match in LOSSY.finditer(code):
            line = code[: match.start()].count('\n') + 1
            problems.append(
                f'{ENGINE}:{line} calls `{match.group(0)}`. That serialises '
                f'the codecs and DROPS every header extension, so the server '
                f'strips `urn:3gpp:video-orientation` from every stream this '
                f'device receives and remote cameras arrive ninety degrees '
                f'out. Call `rtpCapabilitiesToMap(...)` from call_rtp.dart.'
            )

        if not WHOLE.search(code):
            problems.append(
                f'{ENGINE} never calls `rtpCapabilitiesToMap`. The capability '
                f'set is sent exactly once, at `join`, so if nothing calls it '
                f'the header extensions are not being sent at all.'
            )

    if problems:
        for problem in problems:
            print(f'::error::{problem}')
        return 1

    print('the call engine sends its RTP capabilities whole')
    return 0


if __name__ == '__main__':
    sys.exit(main())
