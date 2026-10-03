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

> **Updated 3 October by `0733`.** The table below was right about the
> numbers and WRONG about what they meant, and the row that mattered —
> "4 of 482" — reads as a 478-function backlog. It is not one. The
> corrected figures are in the section after this, and
> `scripts/check_write_idempotency.py` now holds them so they cannot go
> stale again.

| | |
| --- | --- |
| Functions `authenticated` may execute | **1,053** |
| Of those, VOLATILE — i.e. they write | **482**, now 490 |
| Of those, accepting an idempotency key | **4**, now **8** |
| Functions described in `docs/api/` | 787, CI-checked against the schema |
| Paths in the OpenAPI description | 1,149 |
| Tables | 366 |

The first four are `post_manual_journal`, `create_contra`,
`create_deposit` and `record_pdc` — `0307`'s overloads, with `0308`
sweeping keys daily. `0733` added `email_document`, `email_receipt`,
`bulk_email_documents` and `assign_ticket`.

## 478 was the wrong denominator, three times over

A write only needs a key if a CLIENT can retry it, so the population is
not every volatile function — it is the ones `repository.dart` calls.
`scripts/check_write_idempotency.py` measures it on every CI run:

| | |
| --- | --- |
| client-reachable writes | **340** |
| hold an idempotency key | **8** |
| insert nothing at all — `retire_*`, `delete_*`, `mark_*`, `set_*`, where a second call writes the state the first one wrote | **146** |
| refuse a repeat BY NAME — "Adjustment % is already posted", "That contra is already void." | **37** |
| carry a written verdict (a unique index, an `on conflict`, or "it is meant to repeat") | **12** |
| **undecided** | **137** |

So the backlog is 137 and not 478, it is enumerated rather than
estimated, and the gate fails if it grows. That is the number to watch,
and `0733`'s header explains each category.

**Two cautions from doing the first four.** The census was first taken
with a line-based `grep` and found 192 of 577 call sites, because a
quarter of this client's calls put the function name on the line after
`await callRpc(`. And two functions that read exactly like
duplicate-on-retry defects — `save_payment_method`,
`create_layout_from_builtin` — turned out to be refused by a UNIQUE
INDEX that is in neither the table definition nor `pg_constraint`. Both
were in the migration until the assertion that was supposed to
demonstrate the duplicate raised a unique-violation instead. Read the
bodies; then make the duplicate happen.

So:

- **Described surface: met.** `scripts/generate_api_description.py`
  regenerates it and CI fails a description that has drifted. This is
  the strong half and it is genuinely unusual to have.
- **Idempotent writes: 8 of 340 client-reachable, with 195 of the rest
  idempotent already and 137 undecided** — see the corrected table
  above; "4 of 482" was the figure that made this look hopeless. `0307` built the *mechanism*
  — `app.idempotency_begin` / `app.idempotency_end` and an argument
  fingerprint, with a replayed key returning the first answer and a
  reused key with different arguments refused — and applied it to four
  functions. `0733` applied it to the four writes whose retry sends a
  second email or writes a second line of history, and built the census
  that enumerates what is left.

A retry-happy agent calling the undecided 137 is the failure
`gaps-against-rillet` described, and it is a far smaller thing than the
478 this file used to imply. **It is still the first thing to fix, and
it is still not the server.**

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

## The first commit — DONE, 3 October, as `0733`

**Not the server.** Widen `0307`.

Pick the writes an agent would plausibly make, give them the
idempotency overload `post_manual_journal` already has, and assert the
replay. When that list is long enough to be useful, the server is a
thin thing over a surface that is already safe — and if the list turns
out to be short, that is the answer to how much of shape (2) is worth
building.

**It turned out to be short, and the reason is the useful part.** Of 340
client-reachable writes, 195 are already idempotent by construction
rather than by anybody's intention — a `retire_*` that sets a state, a
`post_*(p_id uuid)` that refuses an already-posted document, an
`on conflict do update`. `0733` wrapped the four that were not and that
cost something irreversible when repeated: three that send a customer a
second email, and one that writes the ticket's history twice.

So shape (2) — "read plus a named allowlist of writes, each idempotent"
— is a shorter list than this brief assumed, and the thing standing
between here and it is no longer the mechanism. It is the 137 undecided
writes, which are enumerated by
`scripts/check_write_idempotency.py` and whose count that gate will not
let rise. Each needs somebody to read it and record one of: a key, a
state guard it already has, or why repeating it is the feature.

**What `0733` did NOT do**, deliberately: the `post_*(p_id uuid)` family
still answers a retry with "already posted" rather than with the
original id. `0307` called that "worth having, not worth conflating with
a correctness fix", and it is still a separate change — one an agent
would feel more than a person does, because a person sees the error and
moves on.

## What this brief does not settle

The authorisation model. That is a decision about what iAkauntan is
willing to let an agent do unattended, and it is not mine to make.
