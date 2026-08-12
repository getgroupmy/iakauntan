# Turning email on

Everything below the provider account is built and deployed. Three
things need doing by a person, and none of them can be done from this
repository because two of them are secrets and the third is a DNS
record.

## What is already in place

- `email_settings` — per organization: on/off, from name, reply-to, and
  which days after a due date to chase.
- `email_templates` — editable wording, falling back to built-in text so
  a new organization can send before configuring anything.
- `email_outbox` — one row per message, queued. Failures stay visible
  and retryable.
- `public.email_document(...)` — queues a document with a fresh share
  link in it.
- `app.queue_overdue_reminders(...)` — runs from the nightly job, once
  per invoice per configured day offset.
- `supabase/functions/send-email` — the only thing that can send, and
  the only thing that holds the key.

The database cannot send. It writes rows; the edge function drains them.

## What is already done

`send-email` is **deployed** (version 1, active) and
`.github/workflows/send-email.yml` **drains the outbox on a schedule** —
every half hour through the Malaysian working day, plus a pass at 17:15
UTC, fifteen minutes after `app.run_daily_jobs` queues the overdue
reminders.

Until the two secrets below exist the function answers 503 and the
workflow warns on every run. Messages queue up meanwhile and go out as
soon as it is configured; nothing is lost.

The workflow also needs the repository secret
`SUPABASE_SERVICE_ROLE_KEY` (**Settings → Secrets and variables →
Actions**) — the same one the exchange rate feed uses.

### Who may drain the outbox

The scheduler presents the service role key and drains every
organization. Anybody else — the **Send now** button on the outbox
screen — drains only their own, because the rows are chosen under their
token and `email_outbox` carries `app.is_org_member(org_id)`.

That distinction was missing until the scheduler was built. The function
took any JWT the project had signed, and the publishable key ships
inside the web bundle, so anyone at all could have pushed every
organization's mail out early. They could never compose a message, only
release ones already queued, but it was not their call to make.

### On the half hour

GitHub bills every job run at a minimum of one minute, so a five-minute
cron would consume a private repository's whole monthly allowance and
then some. Half-hourly is about 510 runs a month.

The cost is latency: pressing **Email** on an invoice can mean a wait of
up to half an hour. The Send now button covers the impatient case. If
that is not good enough, the answer is not a tighter cron — it is
`pg_cron` firing `pg_net` every minute from inside the database, which
costs nothing per run and needs the service role key pasted into Vault.

## 1. A Resend account and a verified domain

Sign up at resend.com, add the sending domain, and publish the DNS
records it gives you — SPF and DKIM at least, and DMARC if the domain
does not already have one.

**This part is not optional and not quick.** Mail from an unverified
domain goes to spam or is rejected outright, and the failure looks like
the software being broken rather than the domain being unverified.
Chasing a customer for payment with a message that lands in junk is
worse than not chasing them, because everybody involved believes it was
sent.

## 2. The secrets

```
supabase secrets set RESEND_API_KEY=re_xxxxxxxx --project-ref ewwcgtnniwqndrzukksm
supabase secrets set MAIL_FROM=billing@yourdomain.com --project-ref ewwcgtnniwqndrzukksm
```

`MAIL_FROM` must be at the domain verified in step 1.

Neither value belongs in this repository, in a migration, in a table, or
in the Flutter bundle. The edge function reads them from its own
environment and nothing else in the system can see them.

Until they are set, `send-email` returns 503 and says so in as many
words, rather than leaving messages queued with nobody able to explain
why.

## 3. Deploy the function

```
supabase functions deploy send-email --project-ref ewwcgtnniwqndrzukksm
```

## 4. Drain the queue on a schedule

Queueing happens in the database; sending has to be driven. Either:

- **pg_cron plus pg_net** — schedule a call to the function's URL every
  few minutes with the service role key in the header. The key would
  then be stored in the database, which is a real trade-off and the
  reason this is not already done in a migration.
- **An external scheduler** — GitHub Actions on a cron, or the Supabase
  dashboard's scheduled functions, holding the key outside the database.

The second is preferable. Until one of them is set up, the Outbox screen
has a **Send queued** button that drains it by hand, which is enough to
work with and not enough to rely on.

## 5. Switch it on per company

Settings → Email. Off by default, deliberately: an accounting system
that starts emailing customers the day it is installed is a support
incident.

Set the reminder days there too. `0, 7, 30` chases on the due date, a
week later and a month later. Empty means never chase.

## What to check first when nothing arrives

1. Outbox → Failed. `last_error` carries what Resend said.
2. Still queued and nothing failing? Nothing is draining the queue —
   step 4.
3. Sent but not received? The domain is not verified — step 1.
