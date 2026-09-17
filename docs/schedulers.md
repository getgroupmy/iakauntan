# The scheduled jobs, and the one secret they share

Three things in this system happen on a timer rather than because
somebody pressed a button:

| Workflow | What it does | When |
| --- | --- | --- |
| `.github/workflows/exchange-rates.yml` | calls `fetch-rates`, which brings Bank Negara's published rates into `exchange_rates` | weekdays, 09:30 UTC (17:30 MYT) |
| `.github/workflows/send-email.yml` | calls `send-email`, which drains `email_outbox` through Resend | every 30 min on weekdays 09:00–19:30 MYT, plus 17:15 UTC daily |
| `.github/workflows/file-consolidations.yml` | calls `myinvois` with `action: file-consolidations`, which files the month's consolidated B2C e-Invoices | daily, 02:00 UTC (10:00 MYT) |

All three act for **every organization at once** — rates price
everybody's ledger, the outbox holds everybody's mail, and a
consolidation deadline falls on every shop in the same week — so all
three need a credential no signed-in user has.

The third one is the only one with a **statutory** deadline behind it.
Under the LHDN guideline a seller aggregates the month's sales to buyers
who did not ask for an invoice into one submission, due within seven
days of month end; `app.run_daily_jobs` rolls them up on the first and
this files them. It runs every day rather than only in the first week,
because `einvoice_consolidations_due` returns overdue consolidations
however late they are, and a company that could not file on the eighth
should file on the ninth rather than next month.

## Setting it up

Two pastes of the same random string.

**1. Invent one.** Anything unguessable:

```bash
openssl rand -base64 32
```

**2. Give it to the functions.** Add `SCHEDULER_SECRET` here:

> https://supabase.com/dashboard/project/ewwcgtnniwqndrzukksm/functions/secrets

The direct link, because this is the step that goes wrong. It has to be
the **Edge Functions → Secrets** list — that is what becomes `Deno.env`
inside a function. Project Settings → API is for keys, and Vault is a
different store the functions do not read; a secret in either of those
looks set and is invisible to the code. It is the same screen where
`RESEND_API_KEY` and `MAIL_FROM` go, so do all three in one visit — see
[email-setup.md](email-setup.md).

**3. Give it to GitHub.** **Settings → Secrets and variables → Actions**
→ new repository secret named `SCHEDULER_SECRET`, same value.

That is the whole setup. The next scheduled run picks it up, or run any
of the three by hand from the Actions tab to check now.

The 403 from `fetch-rates` distinguishes the two ways this goes wrong,
so a failed run says which half to fix: *"No SCHEDULER_SECRET is set on
this function"* means step 2 did not land where the function reads;
*"does not match"* means the two copies differ. Copy from one field into
the other rather than generating twice — that second message is what
generating twice produces.

## Why not the service role key

Because it was never the right size for the job.

The original design had the workflows present the service role key, and
the functions compare it against their own copy. It works. It also means
GitHub Actions holds full read and write across every organization's
ledger, payroll and LHDN credentials, with RLS bypassed — to run a
timer. Anyone with write access to this repository, and anything that
runs inside a workflow, is one mistake away from that key.

The functions do not need the caller to supply it. **They already have
it** — the platform injects `SUPABASE_SERVICE_ROLE_KEY` into every edge
function. The caller only has to prove it is the timer.

So the secret above proves exactly that and nothing else. Someone who
steals it can make the project fetch public exchange rates, and send mail
that was already queued and already authorised by somebody who was
entitled to queue it. Someone who steals the service role key owns the
books. That difference is the whole reason this exists.

**The service role key is still accepted**, since it legitimately
identifies the project's owner and nothing should break the day this
ships. If `SCHEDULER_SECRET` is set in the repository it is used; failing
that, `SUPABASE_SERVICE_ROLE_KEY` is used if set; failing both, the
workflow warns on its run summary and exits green.

## What each layer actually checks

`verify_jwt = true` on both functions is **not** the security boundary,
and it is worth being clear about that rather than trusting it by
association. It accepts any JWT this project signed — including the
publishable key, which ships inside the web bundle and is public. It
proves the caller reached the internet.

The real check is `isSchedulerCall` in
[`supabase/functions/_shared/scheduler.ts`](../supabase/functions/_shared/scheduler.ts),
which the CI `edge` job asserts on every push. The assertions that matter
there are the negative ones, especially the unconfigured cases: a
function deployed with no secret set must refuse everybody, rather than
match an absent header (`""`) against an unset variable (`""`) and make
the entire internet the scheduler.

Because `verify_jwt` still has to be satisfied, the workflows send the
project's anon key as the bearer token and the real secret in an
`X-Scheduler-Secret` header. That anon key is written into the workflow
files, which is fine — it is public by design. If the legacy anon key is
ever disabled, set the repository *variable* `SUPABASE_ANON_KEY` to the
publishable key and the workflows will use it instead.

## How each one fails

Neither is allowed to fail quietly, because a scheduler that has stopped
running looks exactly like a scheduler with nothing to report — and the
symptom surfaces weeks later as a revaluation that will not post, or an
invoice the customer says never arrived.

- **No credential set at all** — warns, names the missing secret on the
  run summary, exits green. A pending setup step, not a fault.
- **`401`** — the platform rejected the bearer token. Named explicitly,
  because the fix (the anon key, above) is nothing to do with the
  scheduler secret.
- **`403` from `fetch-rates`** — the secret does not match the one on the
  function. Fails red.
- **A wrong secret at `send-email`** — this one does *not* 403, and that
  is why it gets its own assertion. An unrecognised caller is not
  refused; it reads the outbox under its own token, matches no
  organization through `app.is_org_member(org_id)`, and drains nothing.
  So it would return `considered: 0` — indistinguishable from an empty
  queue, for as long as it took somebody to notice no mail was going out.
  The function therefore reports `scheduler: true|false`, and the
  workflow goes red on `false`.
- **`503` from `send-email`** — Resend is not configured yet. Warns every
  run, because messages are piling up behind it.
- **`404` from `fetch-rates`** — Bank Negara published nothing. Public
  holidays have no rates; this is the honest answer, not a failure.
- **`403` from `file-consolidations`** — the secret does not match.
  Fails red, and unlike `send-email` it cannot be mistaken for a quiet
  month: the `file-consolidations` action is answered before the
  function resolves a caller at all, so an unrecognised one is refused
  by name rather than reading nothing and reporting `considered: 0`.
- **A company skipped by `file-consolidations`** — warns, names the
  company and what it is missing, and stays green. A skip is somebody's
  unfinished setup — no MyInvois credentials, or version 1.1 with no
  signing certificate — and going red every day for one misconfigured
  company is how a real failure stops being noticed. A *rejected*
  filing warns separately, because the two need different people.
- **Any refused rate** — fails red and lists the currency by name. A
  shape change at the publisher means a currency silently stops being
  priced, which is the failure the whole feed exists to prevent.

## What the cron says and what GitHub does

Measured, because the tables above are what was asked for and not what
arrives. `send-email` asks for every thirty minutes between 09:00 and
19:30 MYT on weekdays plus one daily pass, which is about twenty-three
runs a day. Its five most recent scheduled runs, on 16 September 2026:

    20:06, 15:22, 10:56, 05:40 UTC, and 20:14 the day before

Five runs in twenty-four hours, at times matching **none** of its cron
expressions, and a six-and-a-half-hour gap after the last of them. The
workflow is not broken, the cron is not wrong, and nothing failed: on a
private repository GitHub treats a `schedule` trigger as best-effort,
delays it under load and drops runs entirely. Its own documentation says
so; what is not obvious until you count is how much it drops.

**So read every cadence in this document as an upper bound.** The
consequences differ per job and are worth stating separately:

- **`file-consolidations`** asks for daily and is fine with this. The
  deadline it serves is seven days after month end, and a job that runs
  once every few hours somewhere in that week discharges it. This is
  also why it looks at every overdue consolidation and not only the ones
  due today.
- **`exchange-rates`** asks for once a weekday. A missed day leaves
  yesterday's rate in force, which `docs/exchange-rate-feed.md` already
  treats as the ordinary case.
- **`send-email` is the one this hurts.** The section below says
  somebody who presses **Email** "may wait half an hour". On the
  evidence above they may wait five. The outbox screen's **Send now**
  button is therefore not a convenience for the impatient; it is how
  mail actually goes out promptly, and it is worth saying so to whoever
  is trained on the screen.

Nothing here was known when the cadences were chosen, and the argument
in the next section changes with it: the billing floor is a reason to
prefer thirty minutes over five, and GitHub delivering neither is a
reason to prefer `pg_cron`.

## Why GitHub Actions and not `pg_cron`

`pg_cron` with `pg_net` would work — both extensions are available and
Vault is installed — and it costs nothing per run, where GitHub bills a
minimum of one minute per job. That billing floor is why `send-email`
runs every 30 minutes rather than every 5, and why somebody who presses
**Email** on an invoice may wait half an hour if they do not use the
outbox screen's **Send now** button.

It was not chosen because `pg_net` is asynchronous: the request returns
an id and the reply lands in `net._http_response` later, so one job
becomes two and a piece of state between them. And it would put a
credential inside the database, which is the thing this whole arrangement
is trying to avoid.

If the latency ever matters more than that, `pg_cron` firing `pg_net`
every minute is the answer — and it can now hold `SCHEDULER_SECRET`
rather than the service role key, which makes it a considerably better
trade than it was.

On the measurements above it matters already, for `send-email` at least.
`pg_cron` runs inside the database on the database's own clock, so it
fires when it says it will; the asynchrony of `pg_net` is a real cost
and the one to weigh, not the billing floor. The other two jobs are
daily and best-effort suits them, so this is one workflow's decision
rather than a rewrite of the arrangement.
