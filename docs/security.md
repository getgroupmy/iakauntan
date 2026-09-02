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
| Data change | `audit_changes` on 52 tables | **No.** A trigger, and the API cannot turn it off. |
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

## The rate everybody is paid by

The count in that row was 41 for a long time and was never wrong. The
question it does not answer is whether anything that *should* be audited
sits outside the 41, and once asked, one thing did — the widest-reaching
row in the product.

`statutory_schedules` and `statutory_rates` hold the EPF, SOCSO, EIS and
PCB schedules that `calculate_payroll_run` reads for every employee of
every tenant. Publishing one changed what every company in the country
pays, and measured before **0442** it wrote nothing to `audit_logs`,
nothing to `security_events`, and there is no `published_by` column —
while `payroll_settings` and `salary_components`, which move one
company's payroll, were both audited. 0442 puts `audit_changes` on both,
which is what takes the count to 43.

Those two tables are platform-wide: their rows have no `org_id`. That
exposed a second thing. `audit_logs_select` read
`app.can_admin(org_id)`, and `can_admin(null)` is not true, so the rows
0442 started writing were readable by nobody at all — an audit trail
that exists and cannot be produced is not one. The policy now also
admits a platform administrator to the rows whose `org_id` is null, and
`audit_redaction.sql` asserts both halves: that a platform administrator
sees the statutory trail, and that they see **not one row** of any
company's own.

### The tenant-scoped half of the same question, and what it cost

0442 answered "what should be audited and is not" for the platform-wide
tables and left the tenant-scoped ones unasked. **0443** is that half.

`leave_types` and `leave_entitlement_bands` decide how many days of
annual and sick leave every employee of a company is entitled to, are
edited from the HR setup screens by anybody who passes
`app.can_manage_hr`, and were audited by nothing — measured, inserting a
band wrote 0 rows and editing it from 8 days to 99 wrote 0 more, while
every neighbouring HR table that decides money was audited. Leave is
money: s.60E(3) of the Employment Act requires payment for untaken
annual leave on termination, and the band says how much. That takes the
count to 45.

The second thing 0443 found is a cost of 0442. `leave_entitlement_bands`
has no `org_id`; it names its tenant through `leave_type_id`.
`access_type_modules` has had exactly that shape since 0236, and on a
cascade — delete the parent, the children follow — the lookup finds no
parent and resolves to null. Measured: one audit row, `org_id` null,
`table_name` `access_type_modules`. Before 0442 that row was readable by
nobody and the mistake was invisible; after 0442 it is a company's
deleted permission set sitting in the trail every platform administrator
reads. **0442 did not create the null. It gave it a reader.**

So the rule is now explicit and enforced in `write_audit_log`: a null
`org_id` means the platform, and only `statutory_schedules` and
`statutory_rates` may write one. Anything else that cannot name its
tenant writes nothing — which loses no event, because those rows only
arise on a cascade and the parent's own deletion is audited against the
right company.

### Where the sweep stopped, and the rule it left behind

**0445** closed it, on the four promotion tables — `pos_promotions` and
the three that hold its scope. A discount applied at the till was
already attributable; the decision to offer it was not.

The trigger was the smaller half. Those three scope tables were
rewritten wholesale on every save, so auditing them as they stood would
have made correcting a promotion's *name* write a delete and an insert
for every item in its scope. A trail that reports a change nobody made
fails the same way as one that misses a change somebody did, and it is
the first failure that stops people reading it. So the write path was
made differential first — only the rows that actually joined or left —
and the trigger added after. That is the rule to carry forward: before
auditing a table, look at how it is written, not only at what it holds.

Which takes the count to 49.

### A trigger that files nothing

**0450** added a practice — `firms`, `firm_members`, and the companies a
firm keeps the books for — and put an `audit_changes` trigger on
`firms`, on the reasonable belief that a table worth having is a table
worth auditing. The trigger fired and wrote nothing.

`app.write_audit_log` derives a tenant from `org_id`, and since 0443
drops any row it cannot place: a row with no tenant is almost always a
child cascading away behind a deleted company, and filing it under the
platform puts one tenant's data where other tenants' staff can reach it.
`firms` has no `org_id` and never will — **a practice is not owned by
any of the companies whose books it keeps** — so every firm row met the
guard and was discarded. Measured, with a control in the same
transaction because a zero from a query nobody has seen return anything
proves nothing:

| table | rows written |
|---|---|
| `organizations` (control) | 1 |
| `company_transfers` | 1 |
| `firms` | **0** |
| `firm_members` | **0** |

A trigger that files nothing is worse than no trigger, because it reads
as coverage: the count above said 51 on the strength of the trigger
existing.

`firm_members` had no trigger at all, and it is the one that matters
more. Adding somebody to a practice with forty clients grants them forty
companies' ledgers in a single insert.

**0452** widens the null-tenant allowance from the two statutory tables
to four, the firm tables being above every company rather than below
them, files a staff change under the *practice* the way 0445 files a
scope row under its promotion, and adds the trigger `firm_members` never
had. It also adds the reader — `firm_audit_trail`, guarded by
`app.can_manage_firm`, because widening a policy is not the same as
adding a reader and a member of staff should not read the record of
their own appointment being questioned.

Which takes the count to 52, and leaves a second rule beside 0445's:
a trigger is not coverage until a row has been seen in the table it
writes to.

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

Both halves of that are now asserted, and one of them was not.
`security_audit.sql` has always proved the *function* keeps six years
and eleven months and drops eight — but it calls it with a literal `7`,
and `scheduled_work.sql` only proved the function was reachable from
some scheduled job. Neither read the number in the command the scheduler
actually runs, so `purge_audit_history(1)` in that string would have
passed every assertion in this repository while destroying a company's
statutory records six years early, with no sign but an audit trail that
began last year. `scheduled_work.sql` now parses the number out of
`cron.job.command` and asserts it is seven, that the purge has a job of
its own, and that the daily run does not purge anything itself.

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

## Voiding is a grant of its own (0244, 0246–0248)

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
refusal in the database is the control.

### The whole bill, not just a line (0246)

0225 and 0244 between them covered one line at a time. A party walking
out on six lines was six voids, six reasons and six records for one
event, and there was no way to write a bill off at all — which 0206 had
been assuming there was since long before it existed, since it refuses
to close a shift over a parked sale and tells the cashier to "finish or
void" it.

`void_pos_sale` writes the bill off whole. It keeps the lines and the
total: a line void deletes the line because the bill carries on and has
to re-total, whereas a written-off bill stops there and what was on it
is the evidence. `status` becomes `voided`, which every aggregate in
the schema already excludes — expected cash, the floor plan, the open
orders list, the consolidated e-Invoice and the channel report all
filter `parked` or `completed` — so nothing had to be taught to ignore
it. Live kitchen dockets are cancelled; a docket already served stays
served, because that food went out.

### Which needs the grant every time (0247)

0246 asked for `pos_void` only when the kitchen had cooked from the
bill, reasoning that a bill nobody cooked from is keystrokes the
cashier could remove one at a time anyway.

That was wrong about what the control is for, and it is worth keeping
the correction visible. A shop that takes voids away from a cashier is
not counting plates — it has decided that making a bill *disappear* is
a supervisor's act. A bill that vanishes before anything reached the
kitchen is precisely the shape of an order rung up, paid in cash and
quietly removed. The line rule does not carry over: taking one unsent
line off leaves the bill, and the cashier still has to account for it.

So 0247 moved the guard ahead of any question about what was cooked.
There is no path through `void_pos_sale` that does not need the grant.
Removing a single unsent line is untouched and still needs nothing.

The cost is real and intended: 0206 refuses to close a shift over a
parked sale, so a cashier without `pos_void` who opens a bill by
mistake cannot clear it and cannot close their own drawer. A shop
avoids that by granting `pos_void` to whoever closes the till.

### And a written-off bill has to show somewhere (0248)

The two changes above left a hole exactly where the control was
tightened. `pos_void_summary` reads `pos_sale_line_voids`, and a bill
void only writes rows there for lines the kitchen cooked — so the case
0247 exists to catch produced no void lines, no value, and appeared in
no report at all. The only trace was a `voided` row nothing read.

`pos_voided_bills` reads it: which bill, what it came to, why, the
note, and who. Listed rather than grouped, which is deliberately the
opposite of the line report — that one groups because one void is an
accident and thirty "never came out" is a conversation, while these are
few, each is a whole order, and the question is which one and whose.
It reports the cooked count beside the line count, because food lost
and an order that never existed are different facts.

## What was found after 0248 (0399–0407)

The document above stops at `0248`, and a reader reaching the end of it
would take away two things that are no longer true. Both were narrated
correctly when written; the schema moved.

### The ledger holds `SELECT` and nothing else now (0399)

`0239` "leaves a client role with `INSERT, SELECT` and nothing else",
and that sentence stood for a hundred and sixty migrations. The insert
grant was kept as `0239`'s "positive control" — the reasoning being that
revoking everything would satisfy a no-excess-privilege check by leaving
nothing at all.

The belief underneath it was false. `app.create_gl_entry_internal`,
`public.create_gl_entry` and `public.post_manual_journal` are all
SECURITY DEFINER and owned by the role that owns `gl_entries`, so
posting runs as the owner and never consults the grant. Measured rather
than argued: with `insert` revoked and both policies dropped,
`post_manual_journal` called as `authenticated` still posts both lines.

What the grant did buy was a second door. Measured as an `accountant`
with a period closed, under `set local role authenticated` — the role
change matters, and the first measurement of this was made without it
and proved nothing:

- an entry dated inside a **closed period**, inserted straight into
  `gl_entries` — accepted;
- a single line of 1,000,000 debit and no credit, straight into
  `gl_lines` — accepted;
- so the header said debit 100 credit 100 while its own lines summed to
  1,000,000;
- and `post_manual_journal`, given the same closed period, refused it.

The guard was never wrong. It was avoidable. `0399` revokes `insert`,
`update` and `delete` from both client roles on both tables and drops
the two insert policies: the ledger is written by SECURITY DEFINER
functions and read by whoever may read it, and there is no third thing.

### `anon` could write 251 tables (0401)

`0240`'s table counts three privileges — TRUNCATE, REFERENCES, TRIGGER —
and says "`SELECT`, `INSERT`, `UPDATE` and `DELETE` are untouched". True,
and the omission mattered: on the hosted project `anon` held INSERT,
UPDATE or DELETE on **251 relations** in `public`, because `0238`
revoked update and delete from `authenticated` and never named `anon`,
and a freshly started local stack does not have them. Every CI run was
green and every local suite passed while the real project carried them.

Excess privilege rather than an open door — RLS was enabled on 250 of
the 251 and not one policy admits `anon` to write anything, checked
against the project rather than assumed. But it put the whole of
`anon`'s inability to write this database on every policy being right,
forever, across 250 tables. `0401` takes all three from `anon` on every
relation and narrows the default privileges so the next `create table`
does not hand them back.

### And the rest, briefly

- **`0402`, `0403`** — a posted sales or purchase document was fully
  editable: a line repriced from RM100 to RM1 with the header recomputed
  to match, the document deleted with its journal left standing, and
  `gl_entry_id` cleared so the same invoice posted a second time. Eleven
  posting routines guard against a double posting by reading that one
  column, so `0403` makes it immutable on all twenty tables that carry
  it.
- **`0400`** — the same for a posted payslip, which is what the EPF,
  SOCSO and LHDN submissions and the bank file are built from.
- **`0405`** — four storage policies cast a path segment to `uuid`
  instead of using `app.uuid_or_null`. A policy predicate that raises
  does not deny a row, it fails the statement, so one badly named object
  made a whole bucket unreadable for every user of it.
- **`0407`** — `0095` asserted that no SECURITY DEFINER function outside
  a three-name allowlist is executable by **`anon`**. Nobody had asked it
  of **`authenticated`**. Four functions in `app` wrote and were
  executable by any signed-in user with no guard: rolling another
  company's leave year, posting every tenant's recurring journals,
  seeding a chart of accounts, and writing the module entitlements that
  decide what a company has paid for. Excess privilege again — PostgREST
  does not publish `app` — but the grant was explicit, not a default.

### Two sweeps that found nothing, and are now tests

- **Can a member of one company read another's rows?** Asked by reading
  rows as `authenticated` with the JWT of somebody in one company and
  not the other, across every table the other company actually has rows
  in. No leak. `no_tenant_sees_another.sql`.
- **Does every edge function holding the service role establish the
  caller first?** Seven do, by four different routes. All correct.
  `scripts/check_edge_authorization.py` keeps it that way.

`docs/unreachable.md` carries the full reasoning for each, including the
measurements that turned out to be wrong the first time.
