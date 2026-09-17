#!/usr/bin/env python3
"""Refuse an edge function that writes as the service role without asking who called.

    python3 scripts/check_edge_authorization.py

An edge function holding `SUPABASE_SERVICE_ROLE_KEY` is outside RLS
entirely. Every policy in this schema, every `app.can_*` guard and the
whole of `no_tenant_sees_another.sql` are downstream of a client the
function builds for itself, and a function that builds only the
service-role one and then trusts `body.org_id` writes wherever the body
says.

Nothing in the repository could see that. `deno check` type-checks the
file, the SQL assertions never reach it, and the Deno tests exercise the
pure helpers rather than the handler. This is the only place the two
halves meet, which is the argument `check_embeds.py` and
`check_idempotent_calls.py` each make about their own seam.

## What is checked

Every function directory under `supabase/functions` that reads
`SUPABASE_SERVICE_ROLE_KEY` must do one of two things:

1. **Establish the caller.** Build a second client from the anon key
   carrying the request's own `Authorization` header, or go through
   `_shared/context.ts`, which does the same and validates membership.
   What that client can then see is what RLS lets the caller see, so a
   forged `org_id` returns nothing rather than somebody else's rows.

2. **Be named below as having no user caller at all.** An inbound
   webhook and a scheduled job are authenticated by a signature or a
   shared secret, not by a session, and demanding an `Authorization`
   header of them would be asking the wrong question.

Measured when this was written: all ten functions pass, by four
different routes -- `_shared/context.ts` (`myinvois`), an inline
caller-scoped client calling a guarded SECURITY DEFINER function
(`ocr` -> `ocr_begin` -> `app.can_write`), a caller-scoped read whose
RLS decides the work set (`send-email`, `billplz-checkout`,
`send-push`), and the three with no user caller.

The list below is the whole of the judgement in this file. Adding a name
to it is saying "this one has no session to check", and that is a
decision somebody should have to write down.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FUNCS = ROOT / "supabase" / "functions"

# No user caller. Each is authenticated by something other than a
# session, and the reason is stated so the next person adding a name has
# to state one too.
NO_CALLER = {
    "billplz-callback":
        "inbound webhook from Billplz; the X-Signature header is verified "
        "against the gateway's signing key before anything is read",
    "pay-invoice-callback":
        "inbound webhook from a tenant's own acquirer; the signature is "
        "verified against that tenant's key, found from the reference in "
        "the unverified body, before anything is read",
    "pay-invoice":
        "the payer is a customer holding a share link and has no account "
        "to hold a session; the token is the credential and is checked in "
        "SQL by app.shared_payment_intent, not here",
    "receive-email":
        "inbound webhook from the mail router; authenticated by a shared "
        "secret in the request",
    "fetch-rates":
        "scheduled job; runs on a timer with no request behind it",
    "punch":
        "a clock bolted to a door frame has no login; the terminal's "
        "own secret is checked in SQL by public.terminal_secret_matches "
        "against a bcrypt hash before any punch is read, and the org_id "
        "is taken from the terminal row rather than from the body",
}

SERVICE_KEY = "SUPABASE_SERVICE_ROLE_KEY"


def establishes_caller(source: str) -> bool:
    """A client built from the caller's own Authorization header."""
    if "_shared/context" in source:
        return True
    # `createClient(url, anonKey, { global: { headers: { Authorization: ... } } })`
    # is the inline form. Both halves are required: the anon key alone
    # is not a caller, and an Authorization header passed to a
    # service-role client would be ignored.
    has_anon = re.search(r"SUPABASE_ANON_KEY", source) is not None
    has_auth = re.search(
        r"Authorization[\"']?\s*:\s*(?:req|request)\.headers\.get|"
        r"Authorization[\"']?\s*:\s*`?\$?\{?\s*auth",
        source) is not None
    return has_anon and has_auth


def main() -> int:
    if not FUNCS.is_dir():
        print(f"no {FUNCS}", file=sys.stderr)
        return 2

    problems: list[str] = []
    checked = 0
    exempt_used: set[str] = set()

    for d in sorted(p for p in FUNCS.iterdir() if p.is_dir()):
        if d.name == "_shared":
            continue
        entry = d / "index.ts"
        if not entry.is_file():
            continue
        source = entry.read_text()
        if SERVICE_KEY not in source:
            continue
        checked += 1
        if d.name in NO_CALLER:
            exempt_used.add(d.name)
            continue
        if not establishes_caller(source):
            problems.append(
                f"  supabase/functions/{d.name}/index.ts reads "
                f"{SERVICE_KEY} and never builds a client from the "
                f"caller's own Authorization header. It is outside RLS, "
                f"so whatever org_id the body names is the org_id it "
                f"writes. Either read through a caller-scoped client "
                f"(see ocr or billplz-checkout), or add it to NO_CALLER in "
                f"this script with the reason it has no session.")

    # A name in the list that no longer matches a function is a stale
    # exemption, and a stale exemption is how one gets granted to
    # something else later.
    stale = sorted(set(NO_CALLER) - exempt_used)
    for name in stale:
        problems.append(
            f"  NO_CALLER names {name!r}, which is not a function that "
            f"reads {SERVICE_KEY}. Remove it: an exemption nothing uses "
            f"is one waiting to be inherited.")

    if problems:
        print("Edge functions that hold the service role without "
              "establishing the caller:\n")
        print("\n\n".join(problems))
        return 1

    print(f"ok   {checked} edge functions hold the service role; "
          f"{checked - len(exempt_used)} establish the caller first and "
          f"{len(exempt_used)} have no session to establish")
    return 0


if __name__ == "__main__":
    sys.exit(main())
