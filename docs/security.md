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

## A log must not block the deletion it records

Three separate bugs in this work were the same bug, so the rule is worth
stating once:

1. `security_events.user_id` as a foreign key — `record_session_end`
   fires *during* the cascade that deletes an account, so the reference
   pointed at a row being deleted by the same statement. Dropped.
2. `record_session_end` inner-joining `auth.users` — by the time it fires
   the user row is gone, so the join matched nothing and the event went
   unrecorded. Changed to a scalar subquery.
3. `write_audit_log` writing a row for a company that is already gone —
   0236 put the trigger on thirteen tables that cascade from
   `organizations`, and `audit_logs.org_id` then refused the row. That
   broke demo teardown, and would have broken closing any account with a
   contact or an invoice in it.

The third is fixed in 0237 by declining to write when the organization
no longer exists, on DELETE only — on insert and update the source row's
own foreign key already guarantees it exists, so the check stays off the
path every invoice takes.

Nothing is lost by declining. `audit_logs.org_id` cascades, so every
audit row for that company is being deleted by the same statement:
measured on a real company, 27 rows before the delete and 0 after. A row
written mid-cascade would have been inserted and immediately removed.
Measured on production before the change: across 1,988 audit rows there
was not one `delete` of an `organizations` row — the record was never
being kept, only either doomed or fatal.

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

0236 made the tampering visible: update and delete on both tables are
audited. Insert is not, because an insert *is* the ledger and auditing
it would keep the books twice.

**0238 closed it.** The four policies are gone and the `update`/`delete`
grants are revoked, so a posted journal cannot be changed or removed by
any hand the API offers. The supported way to undo one is
`reverse_gl_entry`: the original stands and a reversing entry says so,
which is what double-entry expects.

### TRUNCATE ignores every policy you have written

0238 was not enough, and the gap is worth remembering. Row level
security filters rows; `TRUNCATE` does not look at rows, so no policy in
the schema applies to it. With 0238 already on production, as
`authenticated`:

```
truncate public.gl_lines cascade;   -- 10 rows -> 0 rows
```

Supabase grants `TRUNCATE` to `authenticated` on every table in `public`
by default — 238 of them here. PostgREST emits no verb that produces a
TRUNCATE, so this was not reachable over the API; that is a property of
the client in front of the database, not of the database. Anything
holding a connection string gets the privilege, not the API's opinion of
it.

0239 revokes `TRUNCATE`, `REFERENCES` and `TRIGGER` on the two ledger
tables, leaving a client role with `INSERT, SELECT` and nothing else.

### The same three grants, on every other table

0239 left the same three grants on the rest of the schema and said the
decision belonged in its own change. **0240 is that change.** Counted on
production before writing it:

| role | TRUNCATE | REFERENCES | TRIGGER |
|---|---|---|---|
| `authenticated` | 238 | 238 | 238 |
| `anon` | 228 | 228 | 228 |

out of 247 tables and 2 views. 0240 revokes all three from both roles on
every relation in `public`, including `audit_logs` and
`security_events` — the two tables an attacker would most want to empty,
and the two `TRUNCATE` would have emptied without leaving a row behind.

`SELECT`, `INSERT`, `UPDATE` and `DELETE` are untouched, and so are
`service_role` and `postgres`. Verified on production inside a
rolled-back transaction, as `authenticated` with a real member's JWT:
truncating `audit_logs` and `security_events` refused with 42501, while
reading `accounts`, `contacts`, `gl_entries`, `audit_logs` and
`org_modules`, updating a contact, and posting a balanced journal all
still worked.

**The half of it that is easy to miss.** A one-time revoke only covers
the tables that exist. Supabase's default ACL grants `anon` and
`authenticated` `arwdDxtm` on every *new* table in `public` — the `D`,
`x` and `t` being exactly these three. Without changing the default, one
`create table` in migration 0241 silently re-opens the hole for that
table. 0240 narrows the default privileges for `postgres`, the role
migrations run as.

**Known limit:** a second default ACL over `public` is owned by
`supabase_admin` and still carries all three. 0240 cannot change it —
`postgres` is not a member of that role, and the attempt fails with
42501. It is inert only because every one of the 249 relations in
`public` is owned by `postgres`. `table_grants.sql` asserts that premise
rather than trusting it: if a relation ever appears under another owner,
the test fails.

### A client role does not vacuum your tables

`MAINTAIN` is the fourth privilege in that default grant — the `m` in
`arwdDxtm` — and **0241 revokes it**, on every relation and in the
default for new ones. `authenticated` held it on 240 of the 249
relations in `public`.

It carries `ANALYZE`, `VACUUM`, `REINDEX`, `CLUSTER`, `LOCK TABLE` and
`REFRESH MATERIALIZED VIEW`. `VACUUM FULL` and `CLUSTER` take an ACCESS
EXCLUSIVE lock and rewrite the table, so this is a way to stall the
ledger rather than to corrupt it — an availability hole, which is why it
was held back from 0240 rather than folded into it.

**How not to test for it.** Running `analyze public.gl_lines` as
`authenticated` succeeds — and it succeeds just as happily *after* the
privilege has been revoked, which is how the mistake was caught. ANALYZE
does not raise when the caller lacks the privilege; it emits a warning
and skips the table. An earlier note here cited that success as evidence
the grant was live, and it was not evidence of anything. The privilege
bit is: `has_table_privilege('authenticated', rel, 'MAINTAIN')` was true
on 240 relations before 0241 and is false on all 249 after. `VACUUM
FULL` and `CLUSTER` were not demonstrated end to end — neither runs
inside a transaction block, so probing them on production would have
meant rewriting a live table to prove a point about a grant.

### The two environments are not the same major version

Worth knowing before reading a green CI run as proof of anything about
grants. **Production runs PostgreSQL 17.6; the stack CI builds with
`supabase start` is pinned to `major_version = 15`** in
`supabase/config.toml`.

`MAINTAIN` did not exist before 17. On the CI stack `revoke maintain` is
a syntax error and `has_table_privilege(..., 'MAINTAIN')` raises
`unrecognized privilege type` rather than returning false. So 0241 puts
the whole of its work behind a `server_version_num >= 170000` guard and
issues it as dynamic SQL, and `table_grants.sql` guards its assertion the
same way.

The consequence is that **CI cannot prove 0241.** It runs where the
privilege is absent, so the assertion passes vacuously; the real check
happens when `supabase db push` applies the file against 17.6. The same
caveat applies to anything else version-dependent: a green run means the
schema is consistent on 15, not that it is on 17.

### The part that would have broken every posting

Dropping the four policies on its own breaks *all* posting, and not
visibly. `assert_balanced` on `gl_lines` is DEFERRABLE INITIALLY
DEFERRED, so it fires at COMMIT — and a deferred trigger runs under the
session's role, not under the SECURITY DEFINER function that queued it.
`app.assert_gl_balanced` maintains the entry's totals with an `update
public.gl_entries`, and it was SECURITY INVOKER. At commit, as
`authenticated`, with the policy gone, that fails:

```
ERROR: permission denied for table gl_entries
```

An ordinary rolled-back test never reaches commit, so the trigger never
fires and the totals sit at zero — which looks identical to the bug.
`SET CONSTRAINTS ALL IMMEDIATE` forces it, and the three cases separate:

| | totals after posting |
|---|---|
| as it was | 100.00 / 100.00 |
| policies dropped, trigger SECURITY INVOKER | **permission denied** |
| policies dropped, trigger SECURITY DEFINER | 100.00 / 100.00 |

So the trigger is now SECURITY DEFINER, which is the right shape
regardless: an entry's totals are the database's own bookkeeping about
rows it has already accepted, derived from the lines. They were never
the writer's to authorise.

`supabase/tests/ledger_append_only.sql` asserts both halves — every
refusal paired with the posting and the reversal that must still work,
because a ledger nobody can edit is worthless if nobody can post to it
either.

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

## Voiding a sent line is a grant of its own (0244)

Taking food off a bill the kitchen already has is the oldest way to
steal from a till: ring it up, take the customer's cash, void the line,
keep the difference. Both books balance afterwards, which is why 0225
writes a void record with a name on it.

What 0225 did not decide is who may void. It asked
`can_write_module(org, 'pos')` — the same question as "may this person
work the till" — so every cashier could, and a shop that wanted
otherwise had nowhere to say so.

0244 makes it a permission in its own right, `pos_void`, enforced by
`app.can_void_pos` = write on `pos` **and** write on `pos_void`.
Working the till is the floor: a void grant does not let somebody into
a module they were not given.

### Where it changes behaviour, and where it does not

`app.module_access` returns `write` for a member with **no access type
assigned**, and always for owners and administrators. That is most
members of most companies, so on those companies 0244 is inert — every
cashier still voids exactly as before.

It bites on companies that have already defined access types. Those
members must now be granted `pos_void` explicitly, because an access
type grants what it lists and nothing else — the rule 0127 set, and the
reason an action can be added to the model later at all. That is a real
change for those companies, and it is the point: defaulting an
anti-theft control to on-for-everybody is not a control.

### A permission is not a module

`platform_modules` is the billing catalog — what a company bought, at
what price, shown in the platform console. Nobody sells voiding. The
new `access_permissions` table is a separate list of actions *inside* a
module that a company can hand out itself, keyed to the module they
live in so a company without pos is never offered one. Nothing writes
it from the app: it is a catalog of what the product can enforce, so it
changes with a migration, not with a company's mind.

The *storage* is reused — `access_type_modules` is keyed on free text
and never cared whether a code was a module — but the *reading* could
not be, and the reason is worth writing down because it is invisible in
0127. 0232 taught `app.module_access` to ask whether the company holds
the module before anything else, and to answer `none` when it does
not. A permission is not on the price list, so routing one through
that function denies it to everybody, owners included. The first cut
of 0244 did exactly that and CI caught it: the existing dining-room
assertions could no longer void a line as the shop's own owner.

`app.has_permission` asks the two questions of the two things they are
about instead. The entitlement question goes to the module the
permission lives in, via `can_write_module` — which doubles as the
floor, since a permission inside a module somebody may not write is
not a way in. The grant question goes to the permission itself,
against the same access-type rows and by the same rule.

`my_module_access` unions the permissions in through that same
function, which is how the till learns whether to offer the button
from the call the shell already makes. Hiding is still a courtesy; the
refusal in `void_pos_sale_line` is the control.
