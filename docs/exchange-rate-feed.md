# Fetching the day's exchange rates

`exchange_rates` has been in the schema since migration 0002 and every
row in it has been typed by a person. That is not merely tedious.
`revalue_foreign_balances` refuses a currency it cannot price — it raises
`P0002` rather than assuming par, deliberately, because assuming 1 would
write nearly the whole balance off as an exchange loss. So the safety
check and the empty table together mean month end quietly does not
happen.

Migration `0104` and `supabase/functions/fetch-rates` close that.

## What it does

- **`public.ingest_exchange_rates(p_rows, p_source, p_quote)`** takes
  published quotes and writes **system rows** — `org_id is null`,
  `source = 'bnm'`. It is closed to every signed-in user and open only to
  the service role.
- **`app.exchange_rate_for`** now falls back to those rows when an
  organization has none of its own.
- **`public.exchange_rate_board(org, on_date)`** says what rate is in
  force for each currency and where it came from, including the
  currencies with nothing on file.
- **`supabase/functions/fetch-rates`** fetches Bank Negara Malaysia's
  Open API and hands the figures over unchanged.

## Which rate wins

A fetched rate never touches an organization's own row — the feed writes
only `org_id is null` — and the organization's row wins wherever both
exist for the same date. A rate somebody typed is a deliberate act, it
may already have priced a posted document, and a nightly job must not be
able to move it.

What the feed does is fill the gaps. With a typed rate on the 1st and a
published rate on the 15th, a document dated the 20th uses the published
one: the typed rate says what the rate was on 1 March, not that 1 March
should govern forever. The precedence is **by date first, then by whose
row it is**.

An organization whose base currency is not the ringgit gets nothing from
a feed quoting in ringgit and keeps entering rates by hand. That is
correct rather than a limitation — the fallback only matches rows whose
`to_currency` is that organization's base.

## The hundred-yen problem

Bank Negara quotes some currencies **per 100 units** — the yen, the won,
the rupiah — and others per unit. RM 2.85 per *hundred* yen is not RM
2.85 per yen, and storing it undivided posts a JPY 1,000,000 invoice at
RM 2,850,000 instead of RM 28,500: a figure that balances, foots, and
passes every other check in this system.

So the division by `unit` is done **in SQL**, inside
`ingest_exchange_rates`, where `supabase/tests/exchange_rate_feed.sql`
runs it on every commit. The edge function performs no arithmetic at all
— anything computed there would be computed nowhere CI can see. If a feed
stops sending `unit`, the row is refused and reported rather than assumed
to be 1.

## Deploying it

**Already deployed** — version 2, active. Redeploy after a change with:

```bash
supabase functions deploy fetch-rates --project-ref ewwcgtnniwqndrzukksm
```

There is **no API key**. BNM's Open API is public; the only credential
involved is the project's own service role key, which the platform
injects into the function.

**It must be called with the service role key**, not the publishable
one. `verify_jwt` alone accepts any JWT this project signed, and the
publishable key ships inside the web bundle — so without the check in
the function anybody could make the project hammer Bank Negara. The app
cannot call this and should not want to: rates belong to every
organization at once, so fetching them is not an action any one user
takes.

```bash
curl -X POST https://ewwcgtnniwqndrzukksm.supabase.co/functions/v1/fetch-rates \
  -H "Authorization: Bearer <service role key>" \
  -H "Content-Type: application/json" -d '{}'
```

**This has not been run yet.** The sandbox the function was written in
cannot reach `api.bnm.gov.my` or `*.supabase.co` — both are refused by
its egress policy — so the mapping from BNM's response onto
`ingest_exchange_rates` is written from the documented shape and has
never met the live API. The first real call is the test. Read the reply
rather than glancing at the status code, and check one thing in
particular: **JPY should come back around 0.028, not around 2.8.** The
first is right, the second means `unit` was ignored.

It answers with a count and the full per-currency verdict:

```json
{"session":"1700","published":21,"stored":18,"skipped":3,"errors":0,
 "rates":[{"currency":"JPY","applied_rate":0.0285,"status":"stored",
           "message":"quoted per 100 units"}, ...]}
```

`skipped` is normal — it counts currencies BNM lists that
`ref_currencies` does not hold, and the ringgit quoting against itself.
`errors` should be zero; anything there names the currency and says why.

A 403 saying the scheduler calls this means the publishable key was
used instead of the service role key.

### Scheduling

**Built** — `.github/workflows/exchange-rates.yml`, weekdays at 09:30
UTC, which is 17:30 in Malaysia: half an hour after the `1700` session
closes the day.

It needs one thing set by hand, once:

> **Settings → Secrets and variables → Actions → New repository secret**
> `SUPABASE_SERVICE_ROLE_KEY`, from Supabase → Project Settings → API.

Until that exists the job runs, warns on the run summary, and exits
green having done nothing — deliberately, because a scheduler that is
quietly not running looks exactly like a scheduler with nothing to
report, and the symptom would surface a month later as a revaluation
that will not post.

Two things to know about GitHub's scheduler. It runs workflows from the
**default branch** only, and it **disables scheduled workflows after 60
days without repository activity**, with an email first. Neither matters
while this is being worked on; both matter if it is left alone.

You can also run it by hand — **Actions → Exchange rates → Run
workflow** — with an optional date and session, which is the easiest way
to backfill.

**Why not `pg_cron`.** It is installed, `pg_net` is available and Vault
would hold the key, so it would work. Two reasons against: `pg_net` is
asynchronous, so the reply lands in `net._http_response` later and the
job becomes two jobs with state between them; and the version that
avoids the key entirely — Postgres calling Bank Negara directly — would
need the field mapping written a second time in SQL beside the one in
the edge function. Two implementations of the same thing is how they
drift.

The trade being made is that the service role key sits in this
repository's Actions secrets. That is not the repository and not the app
bundle, which is the rule it has to satisfy. It *is* readable by anybody
with write access here.

`send-email` needs the same treatment and can reuse the same secret —
that workflow does not exist yet, and until `RESEND_API_KEY` is set the
function answers 503 anyway.

Running it more often is harmless. The same quote arriving again
rewrites the same row rather than adding one, which is what the partial
unique index in 0104 is for: in a plain `UNIQUE` constraint two NULLs are
distinct, so without it every run would insert a duplicate.

### Backfilling

```bash
-d '{"date":"2026-08-11"}'      # a particular day
-d '{"session":"0900"}'         # a different session
```

Weekends and public holidays have no publication and answer 404, which is
the honest answer rather than a rate invented for a day that had none.

## Where it can go wrong

| Symptom | Cause |
|---|---|
| A currency still says "no rate" | BNM does not list it. Enter it by hand; the board marks it as yours. |
| `errors` above zero, "unit is missing" | The API's shape changed. Do not default it — read the response and fix the mapping. |
| Every rate is a hundred times too big | The division was moved out of SQL. It belongs in `ingest_exchange_rates`. |
| A typed rate stopped being used | Expected on dates after a later published rate. Enter one for the date in question. |
