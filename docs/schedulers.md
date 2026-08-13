# The two scheduled jobs, and the one secret they share

Two things in this system happen on a timer rather than because somebody
pressed a button:

| Workflow | What it does | When |
| --- | --- | --- |
| `.github/workflows/exchange-rates.yml` | calls `fetch-rates`, which brings Bank Negara's published rates into `exchange_rates` | weekdays, 09:30 UTC (17:30 MYT) |
| `.github/workflows/send-email.yml` | calls `send-email`, which drains `email_outbox` through Resend | every 30 min on weekdays 09:00–19:30 MYT, plus 17:15 UTC daily |

Both act for **every organization at once** — rates price everybody's
ledger, the outbox holds everybody's mail — so both need a credential no
signed-in user has.

## Setting it up

Two pastes of the same random string.

**1. Invent one.** Anything unguessable:

```bash
openssl rand -base64 32
```

**2. Give it to the functions.** Supabase dashboard → **Edge Functions →
Secrets** → add `SCHEDULER_SECRET`. This is the same screen where
`RESEND_API_KEY` and `MAIL_FROM` go, so do all three in one visit — see
[email-setup.md](email-setup.md).

**3. Give it to GitHub.** **Settings → Secrets and variables → Actions**
→ new repository secret named `SCHEDULER_SECRET`, same value.

That is the whole setup. The next scheduled run picks it up, or run
either workflow by hand from the Actions tab to check now.

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
- **Any refused rate** — fails red and lists the currency by name. A
  shape change at the publisher means a currency silently stops being
  priced, which is the failure the whole feed exists to prevent.

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
