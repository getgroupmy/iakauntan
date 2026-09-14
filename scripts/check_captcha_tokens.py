#!/usr/bin/env python3
"""A way in that forgets the security check.

GoTrue's captcha protection is a PROJECT setting. Once it is on, every
call to sign in, sign up, reset a password or resend a confirmation is
refused unless it carries a `captchaToken`. The refusal is a 400 whose
message was written for whoever wrote GoTrue.

This was got wrong three times in one day, on three different doors:

  * the passkey button sent no token and showed "captcha protection:
    request disallowed (no captcha_token found)" to somebody who had
    pressed a button with a fingerprint on it;
  * the demo buttons sent no token, and the 400 was reported as "the
    demo accounts are not available on this deployment" -- a wrong
    cause, confidently stated, about accounts that were there;
  * the re-authentication dialog sent no token, so confirming your own
    password inside the app failed with no way to tell why.

Each was found by somebody trying to sign in. None of them is visible
until the dashboard switch is on, and by then every door is shut at
once -- which is the worst possible moment to discover a fourth.

    python3 scripts/check_captcha_tokens.py

## Why a script rather than care

Adding a door is a normal thing to do, and the token is easy to leave
out precisely because nothing near the call site mentions it. The
project setting is invisible from the code, so there is no version of
"read carefully" that catches this. A list does.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUTH = ROOT / 'app' / 'lib' / 'src' / 'features' / 'auth'

# Every GoTrue call that takes a captchaToken. If a new one appears in
# the SDK, add it here -- an unlisted method is not checked.
GUARDED = (
    'signInWithPassword',
    'signUp',
    'resetPasswordForEmail',
    'resend',
    'signInWithOtp',
    'startAuthentication',
)

CALL = re.compile(r'\.(' + '|'.join(GUARDED) + r')\s*\(')


def argument_text(src: str, start: int) -> str:
    """The text between the call's brackets, nesting respected."""
    depth = 0
    for i in range(start, len(src)):
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return src[start:i]
    return src[start:]


def main() -> int:
    missing = []
    checked = 0

    for path in sorted(AUTH.glob('*.dart')):
        src = path.read_text()
        for m in CALL.finditer(src):
            # A call inside a doc comment is prose, not a door.
            line_start = src.rfind('\n', 0, m.start()) + 1
            if src[line_start:m.start()].lstrip().startswith('///'):
                continue
            checked += 1
            args = argument_text(src, m.end() - 1)
            if 'captchaToken' in args:
                continue
            line = src.count('\n', 0, m.start()) + 1
            missing.append((path.relative_to(ROOT), line, m.group(1)))

    if missing:
        print(f'FAIL: {len(missing)} call(s) into GoTrue that send no '
              f'captcha token.')
        print()
        print('With captcha protection on for the project, GoTrue refuses')
        print('each of these with a 400 written for somebody reading its')
        print('source, and the door simply does not open.')
        print()
        for path, line, name in missing:
            print(f'  {path}:{line}  {name}(...)')
        print()
        print('Pass `captchaToken: _captchaToken`, and refuse locally with')
        print('`captchaNotDone` when `_captchaPending` -- a request that is')
        print('going to be refused is better not sent.')
        return 1

    print(f'ok   {checked} call(s) into GoTrue, every one of them carrying '
          f'a captcha token')
    return 0


if __name__ == '__main__':
    sys.exit(main())
