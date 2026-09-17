# Turning email on

Everything below the provider account is built and deployed. Three
things need doing by a person, and none of them can be done from this
repository because two of them are secrets and the third is a DNS
record.

## Two kinds of mail, and only one of them is this repository's

This trips people up the first time they see a confirmation email
arrive from `noreply@mail.app.supabase.io` with an "Opt out of these
emails" footer on it, and go looking for the bug in here. There isn't
one. There are two mail paths and they share nothing:

| | **Application mail** | **Auth mail** |
| --- | --- | --- |
| Examples | invoices, share links, overdue chasers, the sales digest, the platform's own bills | confirm your email, password reset, magic link, email change |
| Written by | the database, into `email_outbox` | GoTrue, inside Supabase, the moment `auth.signUp` is called |
| Sent by | `supabase/functions/send-email`, through Resend | Supabase's own SMTP |
| Sender | `MAIL_FROM` — `billing@iakauntan.com` | whatever Supabase Auth is configured with |
| Configured | here, by the steps below | in the dashboard, NOT from this repository |

`sign_in_screen.dart` calls `auth.signUp(...)`, and everything after
that happens inside Supabase. The row never reaches `email_outbox`, the
edge function never sees it, and `MAIL_FROM` has nothing to do with it.
No amount of work in this repository changes that sender.

### Making auth mail come from iakauntan.com

**Authentication → Emails → SMTP Settings → Enable Custom SMTP**, in
the dashboard. Resend is already set up for the application mail, so
point it at the same place:

| Field | Value |
| --- | --- |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | the same `RESEND_API_KEY` |
| Sender email | `no-reply@iakauntan.com` — any address on the domain already verified in Resend |
| Sender name | iAkauntan |

Then **Authentication → Emails → Templates** for the wording, and check
**Authentication → URL Configuration** so the confirmation link lands
on `iakauntan.com` rather than localhost.

### When the sign-in page says the mail server refused it

The confirmation button on the sign-in page (`Send the confirmation
link again`) reports a mail failure in its own words rather than
GoTrue's, because GoTrue answers a refused SMTP login with
`unexpected_failure`, which says nothing about which setting is wrong.
The name of the fault is in the project's auth logs:

```
"auth_event":{"action":"user_confirmation_requested"},
"error":"535 \"Authentication credentials invalid\"",
"error_code":"unexpected_failure","path":"/resend","status":500
```

`535` is the mail server rejecting the login, not Supabase rejecting
the address. With the table above, it is almost always one of two
things: the username is an email address rather than the literal word
`resend`, or the password is something other than the `RESEND_API_KEY`
value. Nothing about the person's address or the app's code changes
this, and pressing the button again will not either — which is why the
banner says so.

### Why this is not only about branding

Supabase's built-in auth SMTP is **for testing** and is rate limited to
a handful of messages an hour across the whole project. It is not a
sender that quietly looks unbranded in production; it is a sender that
quietly stops. The first symptom is somebody signing up and never
receiving the confirmation, with nothing in this repository to show for
it — `email_outbox` will be empty, because the message was never ours.

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
- `public.send_from_mailbox(...)` — queues something a person wrote from
  one of the company's own addresses, optionally threaded onto the
  message it answers. `0560`.
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
hosted function** — the drain returns `scheduler: true`.

**Mail is live.** Resend is configured against the verified domain
`iakauntan.com` — the apex, not a subdomain — and the first message went
out on 13 August 2026:
an invoice queued through `email_document`, drained by the workflow,
accepted by Resend with a provider id, the row moving `queued → sent` in
one attempt with no error. Queue, template, share token, function,
scheduler and provider have now all run once in anger.

Everything below is the setup that produced that, kept because it is
the record of how it was done and what to check when it stops working.

Until the two secrets below exist the function answers 503 and the
workflow warns on every run. Messages queue up meanwhile and go out as
soon as it is configured; nothing is lost.

The workflow also needs `SCHEDULER_SECRET` — one random string, set both
on the function and as a repository secret. It shares that with the
exchange rate feed and with the one that files consolidated e-Invoices,
and [schedulers.md](schedulers.md) covers all three.

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

`MAIL_FROM` is a single value on the function, and it is what **every
document's mail leaves from** — an invoice, a reminder, a receipt. What
varies per organization is the display name and the reply-to, both from
`email_settings` — so a customer of Sinar Teknologi sees
`Sinar Teknologi Sdn Bhd <billing@…>` and their reply reaches Sinar
Teknologi, not this platform.

One kind of message does not leave from `MAIL_FROM`: something a person
wrote from one of the company's reserved addresses. `0328` added
`email_outbox.from_email` for that and `0560` made the worker honour it,
so a reply from `aisyah@iakauntan.com` arrives from `aisyah@iakauntan.com`
and not from the platform's billing address. **That only works if the
reserved addresses live at a domain Resend has verified.** The domain is
the `mail_domain` platform setting, and Resend refuses a From address at
a domain it does not hold — which surfaces as `failed` rows in the
outbox with the provider's own words in `last_error`, not as silence.
So: verify the domain in `mail_domain` too, or set `mail_domain` to the
one already verified.

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
