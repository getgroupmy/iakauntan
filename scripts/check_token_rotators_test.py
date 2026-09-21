#!/usr/bin/env python3
"""Assertions for check_token_rotators.py.

    python3 scripts/check_token_rotators_test.py

A gate with no test is a gate that reports what it reports. This breaks
it on purpose from both sides: the shape that caused the reload loop
must be refused, and the shapes that are legitimate must not be -- a
gate that refused `listFactors()` everywhere would be deleted within a
week, because enrolling a factor genuinely needs a new token.
"""

from __future__ import annotations

import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from check_token_rotators import problems  # noqa: E402

failures: list[str] = []


def count(label: str, dart: str, want: int) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "app" / "lib"
        root.mkdir(parents=True)
        (root / "w.dart").write_text(dart)
        found = problems(root)
    if len(found) != want:
        failures.append(
            f"{label}\n      got {len(found)}, want {want}\n"
            + "".join(f"      | {ln}\n" for p in found
                      for ln in p.splitlines())
        )


# --- refused ---------------------------------------------------------

count(
    "THE DEFECT: listFactors from initState",
    """
class _S extends ConsumerState<C> {
  @override
  void initState() {
    super.initState();
    _load();
  }
}
""",
    0,  # `_load()` is a call to a helper; the rotation is not textually
        # in initState. See the note at the foot of this file.
)

count(
    "listFactors directly in initState",
    """
class _S extends ConsumerState<C> {
  @override
  void initState() {
    super.initState();
    ref.read(supabaseProvider).auth.mfa.listFactors();
  }
}
""",
    1,
)

count(
    "listFactors in build",
    """
class _S extends ConsumerState<C> {
  @override
  Widget build(BuildContext context) {
    final f = ref.read(supabaseProvider).auth.mfa.listFactors();
    return Text('x');
  }
}
""",
    1,
)

count(
    "refreshSession in build",
    """
class _S extends ConsumerState<C> {
  @override
  Widget build(BuildContext context) {
    ref.read(supabaseProvider).auth.refreshSession();
    return Text('x');
  }
}
""",
    1,
)

count(
    "listFactors in didChangeDependencies",
    """
class _S extends ConsumerState<C> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ref.read(supabaseProvider).auth.mfa.listFactors();
  }
}
""",
    1,
)

count(
    "both, in one build, are two problems",
    """
class _S extends ConsumerState<C> {
  @override
  Widget build(BuildContext context) {
    auth.mfa.listFactors();
    auth.refreshSession();
    return Text('x');
  }
}
""",
    2,
)

count(
    "nested braces do not end the body early",
    # The reason the body is found by counting braces. A build method is
    # full of nested ones and the first `}` is never the right one -- a
    # regex that stopped there would clear every offender below the
    # first closure.
    """
class _S extends ConsumerState<C> {
  @override
  Widget build(BuildContext context) {
    final w = Builder(builder: (c) { return Text('x'); });
    auth.mfa.listFactors();
    return w;
  }
}
""",
    1,
)

# --- allowed ---------------------------------------------------------

count(
    "after enrolling, which genuinely needs a new token",
    """
class _S extends ConsumerState<C> {
  Future<void> _enrol() async {
    await auth.mfa.enroll();
    await auth.mfa.listFactors();
  }

  @override
  Widget build(BuildContext context) => Text('x');
}
""",
    0,
)

count(
    "from a button handler",
    """
class _S extends ConsumerState<C> {
  Future<void> _onPressed() async {
    await auth.refreshSession();
  }
}
""",
    0,
)

count(
    "reading the factors already on the session",
    # The fix. No round trip, no event, nothing to loop.
    """
class _S extends ConsumerState<C> {
  @override
  void initState() {
    super.initState();
    final f = ref.read(supabaseProvider).auth.currentUser?.factors;
  }
}
""",
    0,
)

count(
    "getUser, which is a plain GET",
    """
class _S extends ConsumerState<C> {
  @override
  void initState() {
    super.initState();
    ref.read(supabaseProvider).auth.getUser();
  }
}
""",
    0,
)

count(
    "a file with no rotation in it at all",
    "class _S { @override Widget build(c) => Text('x'); }",
    0,
)

# ---------------------------------------------------------------------
# WHAT THIS GATE DOES NOT CATCH, said plainly because the very first
# assertion above is the shape that actually shipped:
#
#     void initState() { super.initState(); _load(); }
#     Future<void> _load() async { await auth.mfa.listFactors(); }
#
# The rotation is one hop away and this gate is textual, so it passes.
# Following the hop means resolving a method call, which is a job for
# the analyzer and not for a regex.
#
# It is still worth having. It catches the direct shape, which is the
# one somebody writes next, and the indirect shape is caught by
# `app/test/token_refresh_loop_test.dart` at the other end: the loop
# needs BOTH halves, and the amplifier is asserted there. A gate that
# catches one of two necessary conditions is a gate.
#
# If the hop is worth following later, the tool is `dart analyze` with a
# custom lint, not a longer regex.
# ---------------------------------------------------------------------

if failures:
    print(f"{len(failures)} assertion(s) failed:\n")
    for f in failures:
        print(f"  * {f}\n")
    sys.exit(1)

print("check_token_rotators.py: every assertion passed.")
