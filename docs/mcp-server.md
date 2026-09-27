# iAkauntan MCP Server — handoff brief

For a session picking this up cold. It is a brief and not a plan: it
says what is true today, what the decision is, and what the first
commit should be. Nothing here is built.

**Read `docs/gaps-against-rillet.md` and `docs/handoff.md` §5 first.**
This file exists because both of them say "not yet" for reasons that
have partly expired, and somebody has to work out which half.

## The one-sentence version

The two preconditions this repository set for itself — idempotent
writes and a described surface — are **one met and one barely
started**, and the question neither document considered is the one that
decides the whole shape: *what may an agent do on a person's behalf*.

## What the repository already argued

`docs/gaps-against-rillet.md` kept an MCP server off its roadmap:

> An MCP server is deliberately not on this list. It is the fashionable
> item and the least useful until (1) and (2) exist, because an agent
> calling undescribed, non-idempotent write functions is the worst
> version of this.

That was right, and it named its own exit conditions. `docs/handoff.md`
then recorded both as met. **One of them is not**, and the brief turns
on that.

## What is actually true, counted rather than remembered

| | |
| --- | --- |
| Functions `authenticated` may execute | **1,053** |
| Of those, VOLATILE — i.e. they write | **482** |
| Of those, accepting an idempotency key | **4** |
| Functions described in `docs/api/` | 787, CI-checked against the schema |
| Paths in the OpenAPI description | 1,149 |
| Tables | 366 |

The four are `post_manual_journal`, `create_contra`, `create_deposit`
and `record_pdc` — `0307`'s overloads, with `0308` sweeping keys daily.

So:

- **Described surface: met.** `scripts/generate_api_description.py`
  regenerates it and CI fails a description that has drifted. This is
  the strong half and it is genuinely unusual to have.
- **Idempotent writes: 4 of 482.** `0307` built the *mechanism*
  — `app.idempotency_begin` / `app.idempotency_end` and an argument
  fingerprint, with a replayed key returning the first answer and a
  reused key with different arguments refused. What it did not do is
  apply it broadly, and nothing since has.

A retry-happy agent calling the other 478 is the exact failure
`gaps-against-rillet` described. **This is the first thing to fix and
it is not the server.**

## The question that decides the design

RLS and the `app.can_*` guards answer *what may this USER see and do*.
They are per-organization and per-role, they are enforced in the
database, and they are good.

MCP needs a narrower question: **what may this AGENT do on this user's
behalf, in this session, without being asked again.** That is not a
role. A bookkeeper may post a journal; it does not follow that an agent
holding that bookkeeper's token may post one unattended.

Nothing in the schema answers it today. There is **no personal access
token, no API key, no grant or scope table** — `device_tokens` is push
notifications and nothing else. Every write path in this product is a
signed-in human with a Supabase JWT.

Three shapes, and the choice is a product decision rather than an
engineering one:

1. **Read-only, no new authorisation.** The agent gets the user's JWT
   and may call only `STABLE`/`IMMUTABLE` functions and `select`. 571
   of 1,053 qualify without a single new grant. Ships in days, cannot
   corrupt a ledger, and answers most of what people actually want —
   *"what did we spend on Grab last quarter"*.
2. **Read plus a named allowlist of writes**, each idempotent, each
   with a human confirmation carried in the call. A dozen functions,
   not 482.
3. **Full delegated authority** with a scope table, per-scope grants,
   an audit trail keyed to the agent rather than the user, and
   revocation. This is the real thing and it is a quarter, not a week.

**(1) is the recommendation.** It is the only one whose blast radius is
zero, and it makes (2) a question about a list rather than about a
design.

## What must not be exposed, whatever is chosen

- Anything the console owns. **53 `platform_*` functions are
  execute-grantable to `authenticated`** — which is not a hole: every
  one of them calls `app.is_platform_admin()` inside, checked, so a
  tenant's token is refused at the guard rather than at the grant. It
  matters here anyway, because a tool LIST is a different thing from a
  permission: an agent should not be offered 53 tools it will be
  refused at. This is the clearest argument for the census.
- Any `SECURITY DEFINER` function whose guard is a role check the
  caller can satisfy but the *agent* should not — the same distinction
  as above, and the reason a scope table exists in shape (3).
- Key material. `org_ocr_credentials` and `ocr_provider_keys` have RLS
  with no policies and no grants; the only reader is an edge function.
  That stays true.
- Anything in `docs/security.md`'s "deliberately not recorded" list.

## Where it would live

An edge function, beside the others, for the reason they are all
there: it is the only place with a service-role key and it is already
the pattern (`supabase/functions/_shared/cors.ts`,
`context.ts`). `scripts/check_edge_authorization.py` already refuses a
function that writes as the service role without knowing its caller,
and that gate is exactly the one this work must not weaken.

## How it would be gated

Nothing here is new machinery; it is the machinery that exists,
pointed at this:

- The tool list is a CENSUS, in the shape of `DENO_CENSUS` and
  `dropdown_census_test.dart` — a frozen list, so a tool appearing is
  a decision somebody made rather than a function that drifted into
  reach.
- `scripts/check_ambiguous_overloads.py` matters more here than
  anywhere: an agent calls by name, and `2c6a456f` is the commit that
  explains what two overloads do to a named call.
- The idempotency work needs its own assertions — a replayed key
  returning the first answer is exactly the kind of thing that passes
  a test written optimistically.

## The first commit

**Not the server.** Widen `0307`.

Pick the writes an agent would plausibly make, give them the
idempotency overload `post_manual_journal` already has, and assert the
replay. When that list is long enough to be useful, the server is a
thin thing over a surface that is already safe — and if the list turns
out to be short, that is the answer to how much of shape (2) is worth
building.

## What this brief does not settle

The authorisation model. That is a decision about what iAkauntan is
willing to let an agent do unattended, and it is not mine to make.
