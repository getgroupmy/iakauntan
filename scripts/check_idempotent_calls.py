#!/usr/bin/env python3
"""Refuse a protected write that quietly reaches the unprotected overload.

    python3 scripts/check_idempotent_calls.py "$DATABASE_URL"

`0307` protects four money-writing functions against a double tap or a
retry after a timeout, and it does it with *overloads*: the original,
and a wrapper taking `p_idempotency_key` as a trailing argument with no
default. Its header explains why the key must not be given a default —
PostgREST chooses between the two by matching parameter names, so a body
without the key matches only the original and a body with it matches
only the wrapper.

The consequence for a caller is the dangerous half, and nothing said it
out loud until it was measured: **the wrapper has no defaults on any of
its parameters**. A call that omits one merely-optional argument does
not fail and does not warn. It resolves to the original, does the work,
returns an id, and is not protected. The screen looks right, the ledger
looks right, and the guarantee is gone.

That is unobservable from either side alone. The Dart analyzer sees a
map of string literals. The SQL tests know the wrapper works but not who
calls it. The widget tests do not talk to a database. So this is the
only place the two halves meet, which is the same argument
`check_embeds.py` makes about embeds — and the same way the fault got
into production, which is that `0307` shipped complete and the client
was never changed to send a key at all.

Three things are checked:

1. Every `callRpcOnce` names a function that really has a key overload.
   Sending a key to a function with no wrapper is a request PostgREST
   cannot resolve at all.
2. Every `callRpcOnce` names *every* parameter of that wrapper. This is
   the silent one.
3. No function with a key overload is also reached through plain
   `callRpc`. One path, or the protection is whatever route the caller
   happened to take.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CLIENT = REPO / "app" / "lib" / "src" / "data" / "repository.dart"

# Every public function taking an idempotency key, with the parameters a
# caller has to name to select it. Asked of the database rather than
# parsed out of the migrations: what matters is the signature that is
# actually installed, which is what PostgREST resolves against.
WRAPPERS_SQL = """
select p.proname || ' ' || array_to_string(p.proargnames, ',')
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
   and 'p_idempotency_key' = any (p.proargnames)
 order by p.proname;
"""


def wrappers(db: str) -> dict[str, set[str]]:
    out = subprocess.run(
        ["psql", db, "-At", "-c", WRAPPERS_SQL],
        capture_output=True, text=True, check=True,
    ).stdout
    found: dict[str, set[str]] = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        name, args = line.split(" ", 1)
        found[name] = set(args.split(","))
    return found


def call_sites(text: str, opener: str) -> list[tuple[str, set[str], int]]:
    """Every `opener('fn', params: {...})`, with the keys it names.

    Brace-matched rather than regexed to the closing `}`: `p_lines` and
    `p_documents` are nested structures, and a lazy match would stop at
    the first inner brace and report keys that are not there.
    """
    sites = []
    for m in re.finditer(
        re.escape(opener) + r"\(\s*'([a-z0-9_]+)'\s*,\s*params:\s*\{", text
    ):
        fn = m.group(1)
        i = m.end() - 1
        depth = 0
        keys: set[str] = set()
        while i < len(text):
            ch = text[i]
            if ch in "{[(":
                depth += 1
            elif ch in "}])":
                depth -= 1
                if depth == 0:
                    break
            elif depth == 1 and ch == "'":
                k = re.match(r"'(p_[a-z0-9_]+)'\s*:", text[i:])
                if k:
                    keys.add(k.group(1))
            i += 1
        sites.append((fn, keys, text.count("\n", 0, m.start()) + 1))
    return sites


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2].strip(), file=sys.stderr)
        return 2

    protected = wrappers(sys.argv[1])
    if not protected:
        print("No idempotency wrappers in this database at all — 0307 did "
              "not apply.", file=sys.stderr)
        return 1

    text = CLIENT.read_text()
    problems: list[str] = []

    once = call_sites(text, "callRpcOnce")
    for fn, keys, line in once:
        if fn not in protected:
            problems.append(
                f"{CLIENT.name}:{line}: callRpcOnce('{fn}') but '{fn}' has "
                f"no idempotency-key overload. PostgREST cannot resolve a "
                f"body carrying p_idempotency_key against it."
            )
            continue
        # callRpcOnce adds the key itself, so the call site is not
        # expected to name it.
        wanted = protected[fn] - {"p_idempotency_key"}
        missing = sorted(wanted - keys)
        if missing:
            problems.append(
                f"{CLIENT.name}:{line}: callRpcOnce('{fn}') does not name "
                f"{', '.join(missing)}. The wrapper has no defaults, so "
                f"this resolves to the unprotected overload — silently, "
                f"and with a plausible answer."
            )

    protected_called_once = {fn for fn, _, _ in once}
    for fn, _, line in call_sites(text, "callRpc"):
        if fn in protected and fn in protected_called_once:
            problems.append(
                f"{CLIENT.name}:{line}: '{fn}' is reached through plain "
                f"callRpc as well as callRpcOnce. One path, or the "
                f"protection is whichever route the caller happened to "
                f"take."
            )

    unreached = sorted(set(protected) - protected_called_once)
    if unreached:
        problems.append(
            "These have an idempotency-key overload that no caller uses, "
            "so the protection 0307 built is not in force for them: "
            + ", ".join(unreached)
        )

    if problems:
        print("Idempotent calls that do not protect anything:\n",
              file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1

    print(f"ok: {len(once)} protected call(s) name every parameter of "
          f"their wrapper")
    return 0


if __name__ == "__main__":
    sys.exit(main())
