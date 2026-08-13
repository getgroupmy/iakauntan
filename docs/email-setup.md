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

`send-email` is **deployed** — by CI, on every push to the default
branch, so it never drifts from this repository — and
`.github/workflows/send-email.yml` **drains the outbox on a schedule**:
every half hour through the Malaysian working day, plus a pass at 17:15
UTC, fifteen minutes after `app.run_daily_jobs` queues the overdue
reminders.

The scheduler's credential is set and **confirmed working against the
hosted function** — the drain returns `scheduler: true`. Resend is the
only thing left.

Until the two secrets below exist the function answers 503 and the
workflow warns on every run. Messages queue up meanwhile and go out as
soon as it is configured; nothing is lost.

The workflow also needs `SCHEDULER_SECRET` — one random string, set both
on the function and as a repository secret. It shares that with the
exchange rate feed, and [schedulers.md](schedulers.md) covers both.

The 503 reports `scheduler: true|false` alongside the complaint about
mail, and the workflow fails on `false`. That matters more than it
sounds: without it, a scheduler whose secret was wrong would be told
"mail is not configured" on every run, exactly like a scheduler whose
secret was right, and the credential would stay unproven until the day
Resend was finally set up and somebody expected mail to start moving.
Two faults found one at a time, the second only after the thing looked
finished.

### Who may drain the outbox

The scheduler drains every organization. Anybody else — the **Send now**
button on the outbox screen — drains only their own, because the rows
are chosen under their
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

**This part is not optional and not quick.** Mail from an unverified
domain goes to spam or is rejected outright, and the failure looks like
the software being broken rather than the domain being unverified.
Chasing a customer for payment with a message that lands in junk is
worse than not chasing them, because everybody involved believes it was
sent.

### Which domain, and why it is one decision not two

`MAIL_FROM` is a single value on the function, so **every organization's
mail leaves from the same address**. What varies per organization is the
display name and the reply-to, both from `email_settings` — so a customer
of Sinar Teknologi sees `Sinar Teknologi Sdn Bhd <billing@…>` and their
reply reaches Sinar Teknologi, not this platform.

That makes the sending domain shared infrastructure. One tenant's bounce
rate is every tenant's reputation, which decides the choice:

- **Does the domain already carry human mail** (Google Workspace,
  Microsoft 365, anything with MX records)? Then send from a
  **subdomain** — `send.iakauntan.com` or `mail.iakauntan.com`. It keeps
  bulk transactional reputation away from the mailboxes people actually
  read, and it means not touching the apex SPF record, which is where
  this goes wrong (below).
- **Is it a bare domain with no mail on it?** The apex is fine and the
  From address reads better on an invoice.

Either way the From address must be at whatever domain Resend verified.
Verify `send.iakauntan.com` and you send from `billing@send.iakauntan.com`.

### The records

Resend → **Domains** → Add Domain, then publish the records it shows you
at whatever hosts that domain's DNS. Copy them from Resend rather than
from anywhere else, this file included — the values are theirs and they
change.

Two things about publishing them:

**SPF: a domain may have exactly one SPF record.** If the domain already
has a `v=spf1 …` TXT record, *merge* Resend's `include:` into it. Adding
a second TXT record starting `v=spf1` does not add a sender — it makes
the domain's SPF a permanent error and **every** sender fails, including
the mail that worked yesterday. This is the single most common way this
step goes wrong, and it breaks more than it was meant to fix.

**DKIM does not have that problem.** It sits at its own selector, so it
never collides with an existing one.

**DMARC, if the domain has none:** publish `p=none` first and read the
reports for a week or two before tightening. Starting at `p=reject` on a
domain whose other senders were never checked will bin legitimate mail
from sources nobody remembered.

Verification is usually minutes, occasionally hours, and is bounded by
the TTL of whatever the records replaced. Resend shows the domain as
verified when it is; nothing here needs doing until it does.

### Proving the plumbing before the DNS is ready

Resend provides a shared test sender that delivers only to the address
the account was registered with — check the dashboard for the current
address, as `onboarding@resend.dev` has been the one historically. Set
`MAIL_FROM` to it and the whole path can be proven today: queue a
document to yourself, run the workflow, watch the row go to `sent`.

Worth doing. It separates "the pipeline works" from "the domain is
verified", so if mail does not arrive later, only one of the two is in
question.

## 2. The secrets

Both go here, the same screen as `SCHEDULER_SECRET`:

> https://supabase.com/dashboard/project/ewwcgtnniwqndrzukksm/functions/secrets

| Name | Value |
| --- | --- |
| `RESEND_API_KEY` | the `re_…` key from Resend → API Keys |
| `MAIL_FROM` | a bare address at the verified domain, e.g. `billing@iakauntan.com` |

Give the API key **sending permission only**, and scope it to the one
domain if Resend offers that. It is shown once; if it is lost, make
another and delete the old one rather than hunting for it.

`MAIL_FROM` is the address alone, not `Name <addr>` — the function
composes the display name from each organization's settings.

Neither value belongs in this repository, in a migration, in a table, or
in the Flutter bundle. The edge function reads them from its own
environment and nothing else in the system can see them.

Until both are set, `send-email` returns 503 and names which one is
missing, rather than leaving messages queued with nobody able to explain
why.

## 3. Deploy the function

Nothing to do. `send-email` is deployed by CI on every push to the
default branch, along with the other two edge functions — see
[edge-functions.md](edge-functions.md).

## 4. Drain the queue on a schedule

Done — `.github/workflows/send-email.yml`, on the cadence above, holding
`SCHEDULER_SECRET` rather than the service role key. See
[schedulers.md](schedulers.md).

The Outbox screen's **Send queued** button still works and drains only
the signed-in user's own organization, which is the right answer for
somebody who does not want to wait half an hour.

## 5. Switch it on per company

Settings → Email. Off by default, deliberately: an accounting system
that starts emailing customers the day it is installed is a support
incident.

Set the reminder days there too. `0, 7, 30` chases on the due date, a
week later and a month later. Empty means never chase.

## What to check first when nothing arrives

0. **Nothing in the outbox at all — not queued, not failed?** Then
   nothing ever queued, and the send never happened. `email_document`
   refuses before it writes a row:

   ```
   Email is switched off for this organization
   ```

   That is step 5, and it is a prerequisite for the others rather than a
   finishing touch: an organization with no `email_settings` row has
   `is_enabled` null, which `coalesce(s.is_enabled, false)` reads as off.
   A brand new deployment has no such row for anybody, so the first thing
   anyone tries to send fails this way.

1. **Outbox → Failed.** `last_error` carries what Resend said, verbatim.
   A 4xx there is a bad address or an unverified From; it is marked
   failed immediately rather than retried five times to the same end.
2. **Still queued, nothing failing?** Read the last scheduler run. A 503
   means the two secrets above are not both set — it names which.
3. **Sent but not received?** The domain is not verified, or SPF broke
   when Resend's include was added as a second record rather than merged
   into the existing one — step 1. Check the recipient's spam folder
   before assuming the software.
4. **Some recipients only?** That is reputation or a specific provider,
   not this system. The row says `sent` because Resend accepted it;
   what happened after is in Resend's own dashboard.
