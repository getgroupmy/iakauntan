# The security audit

Two logs, kept apart on purpose.

| | `audit_logs` | `security_events` |
|---|---|---|
| Answers | what the **data** did | what the **people** did |
| Written by | `audit_changes` triggers | triggers on `auth.sessions`, and the functions that export, read and refuse |
| Read with | `audit_trail(org, …)` | `security_log(org, …)` |
| Who may | owner, admin | owner, admin |
| Kept for | 7 years | 7 years |

Neither can be derived from the other. A sign-in changes no row; a
supplier's bank details changing is not an event anybody attended.

## What is recorded, and how much to believe it

Being straight about this is the point of the table. A log that implies
it saw more than it did is worse than one that says where it stops.

| Event | Source | Can it be skipped? |
|---|---|---|
| Sign-in | trigger on `auth.sessions` insert | **No.** GoTrue writes the row; the trigger is on the table. |
| Session ended | trigger on `auth.sessions` delete | **No.** Covers signing out, expiry and revocation alike, which is why it is not called "signed out". An account *being deleted* is the exception — see below. |
| Data change | `audit_changes` on 41 tables | **No.** A trigger, and the API cannot turn it off. |
| Export | `record_export`, called by `exportTextFile`/`exportBytesFile` | Only by not using the app. Every download path goes through those two. |
| Sensitive read | `app.note_read`, inside `security_log` and `audit_trail` | **No.** Reading either log records the read. |
| Refusal | `report_denied`, called by `Repo.callRpc` on a 42501 | **Yes** — see below. |
| Failed sign-in | `report_failed_sign_in`, called by the sign-in screen | **Yes** — see below. |

### An account being deleted

Removing a user cascades to their sessions *and* to their `org_members`
row, so when `record_session_end` fires there is no membership left to
say which company the session belonged to. No row is written, and that
is the right outcome rather than a gap: `org_members` has carried an
audit trigger since 0055, so the deletion is recorded against the right
company with who did it. A second, orgless row for the session would add
nothing anybody could act on.

`security_events.user_id` is deliberately **not** a foreign key, unlike
`audit_logs.user_id`. A log has to outlive what it records and must
never be able to block the deletion it is recording.

### Why two of them are reported rather than recorded

**A refusal cannot record itself.** The obvious design is a function
that writes the row and then raises the refusal. It does not work: the
raise unwinds the transaction the row was written in. Measured, not
argued — a clerk was correctly refused, the exception carried the right
message, and `count(*) where kind = 'denied'` returned **0**. Postgres
has no autonomous transactions; the only way out is a second connection,
which means a database password stored in the database, which this
project does not do. So `Repo.callRpc` catches the 42501 and reports it
in the next request.

**A failed sign-in has no server-side record at all.** GoTrue writes no
row for a rejected password, and this project's
`auth.audit_log_entries` is empty — checked. The only party that knows
is the browser that was refused.

Both are worth having and neither is evidence. They catch a colleague
reaching for a screen they should not have, a locked-out user, and an
account somebody else is using *through the app*. They do not catch a
script talking to the API directly and declining to report itself.
Nothing in this database can, and the screen says so.

`report_failed_sign_in` is callable by `anon`, so it is built to be
safe rather than trusted: nothing is recorded for an address that is not
a user, no password or attempt is stored, the same `void` comes back
either way so it cannot be used to enumerate addresses, and at most one
row a minute per account is written so it cannot bury a real event.
`report_denied` is rate-limited the same way and refuses an org the
caller is not a member of.

## Entitlement, visibility and this log

`security_events` is not a module and never will be. Keeping a record of
who reached the books is part of keeping books, not an add-on — so the
Security destination carries `adminOnly` rather than a module code, and
`security_log` refuses anybody who is not an owner or an admin. The bar
is not membership: the log says where each colleague works from.

## Secrets never reach the trail

`einvoice_credentials` holds a client secret and a private key, and
`audit_logs` is readable by every admin. `app.audit_redact` replaces a
value whose column name matches
`secret|password|private_key|passphrase|api_key|token|credential` with
`***`, on insert, update and delete alike.

That last clause is the bug 0236 shipped with for one revision:
redaction lived inside `audit_diff`, which only runs on UPDATE, so
*changing* a secret hid it and *creating* one stored it in full. The
test now puts a known string in through all three routes and searches
the whole trail for it.

## The ledger is not append-only

`gl_entries` and `gl_lines` carry `for update` and `for delete` policies
whose entire condition is `app.can_post(org_id)`. Anybody who may post
may also edit or delete a journal that has already been posted, through
the API. No screen offers it — the Flutter client only ever selects from
those two tables — but the policy decides, not the screen.

0236 does not close this, because closing it changes what the product
allows. What it does is make it visible: update and delete on both
tables are audited. Insert is not, because an insert *is* the ledger and
auditing it would keep the books twice.

**The fix, when somebody decides to take it:** drop the four policies
and let reversal be the way to undo a posting, which is what
double-entry expects and what `reverse_journal` already does. Nothing in
the client would notice.

## Seven years

Section 245(5) of the Companies Act 2016 requires accounting records to
be kept for seven years, and a record of who changed them is part of
them. `app.purge_audit_history(7)` runs weekly under `pg_cron` as its
own job rather than a line in `run_daily_jobs`, so a purge that fails
cannot take the recurring invoices with it.

Before 0235 neither log had any retention at all: `audit_logs` had been
growing without bound since 0055.

## What is deliberately not recorded

Clicks. The ask was "every login, click and activity", and click
telemetry was ruled out: it is a second product with its own storage
bill, it cannot be trusted for security because the client reports it,
and the thing an auditor actually needs — who reached the data, who
changed it, who took a copy — is all server-side and is all here.

Document lines. An invoice's total is on the invoice; a trail of every
line edit while somebody types one is the failure 0055 named, where the
audit trail nobody reads is the same as no audit trail. `pos_sales` is
scoped by column for the same reason: a till writes to that row several
times per sale, and what is worth keeping is what happened to a bill
*after* it was a bill.
