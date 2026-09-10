# Migrations

The database is the application, so how a migration reaches production
is not a detail. This is how it works, what was wrong with it until
15 August 2026, and what was done about it.

## The rule

Migrations live in `supabase/migrations/`, numbered `0001`–`NNNN`,
applied in order, and **never edited once applied**. A mistake in an
applied migration is corrected by a new migration, not by changing the
old one — the old file is the record of what the database actually did.

CI builds a throwaway stack from every migration in order on each push
and runs `supabase/tests/*.sql` against it, so the files are proved to
apply cleanly from nothing on every commit. That has always been true
and is not what this document is about.

## What was wrong

Getting those same migrations onto the hosted project was done by hand,
one at a time. That is the same arrangement the edge functions were in
before CI deployed them, and it failed the same way: on 15 August the
repository was three migrations ahead of the database while every file
read as though it were live, and it was stated twice in that session
that something was applied when it was not.

The obvious fix — `supabase db push` from CI — could not simply be
switched on. The hosted project's migration history had been written by
a different tool and held **179 rows with timestamp versions**
(`20260809064020`, `20260815092549`) while the repository is numbered
`0001`–`0150`. The two sets had nothing in common, so `db push` would
have treated all 150 local migrations as unapplied.

## What was done

The history was reconciled with the repository, in this order.

**1. The schema was verified against the repository, object by object.**
Not a spot check: every function the migrations create (345), every
table (177), every enum (51), and every column added by an
`alter table … add column` (39) was checked to exist on the hosted
project, and the tables were checked in the other direction too — that
the database holds no table the repository does not create. Nothing was
missing either way. That is what makes the next step safe: marking a
migration as applied when it is not would skip it forever.

**2. The old rows were kept.** They are in
`supabase_migrations.schema_migrations_backup_20260815`, 180 rows with
their `statements` intact. The Supabase CLI reads only
`schema_migrations`, so a sibling table is invisible to it. Nothing in
the application reads either.

**3. `0001`–`0150` were written in their place**, with the names taken
from the filenames — the same thing `supabase migration repair --status
applied` does, for every migration at once. `statements` is empty on
these rows, as it is on repaired rows: they record that a migration ran,
not what it ran, and what it ran is the file in this repository.

The hosted project now records exactly the 150 migrations in
`supabase/migrations/`, with no gaps.

## The CI job

`Apply the migrations` runs on the default branch after the tests pass
and **before** the edge functions and the web bundle deploy — a function
or a screen expecting a column the database does not have yet is the
failure that ordering prevents.

**That sentence was true of the intent and not of the condition, until
it was measured.** The job's `if` read `github.event_name !=
'pull_request'` — every branch, not the default one. The functions and
worker jobs both carry the second half of the test and this one did not,
so a push of any branch would have applied that branch's migrations to
the one live project. It never did, because the only branch pushed here
*is* the default branch: the guard was missing rather than the accident
having happened. The condition now matches the sentence.

The asymmetry with the Vercel deploy is deliberate and worth stating. A
preview deploy off the default branch is fine — it gets its own URL — so
`deploy` still runs there, and it now tolerates `migrate` being skipped
rather than being skipped along with it. What a preview cannot have is
that branch's schema: there is one database, and the preview reads the
production one. A branch whose screens need a new column will show that
as a missing column in the preview, which is the honest outcome and not
a reason to loosen the gate.

It has two gates, and they are separate on purpose.

| To get | Set |
|---|---|
| A report of what is applied and what is pending, changing nothing | secret `SUPABASE_DB_PASSWORD` |
| Pending migrations actually applied | also repository variable `MIGRATIONS_AUTOPUSH` = `true` |

`SUPABASE_DB_PASSWORD` is the database password from **Supabase →
Settings → Database**. `SUPABASE_ACCESS_TOKEN` is already set for the
edge-function deploy and is reused.

The reason for two gates rather than one: nobody's first run of an
automated schema push should be one that writes to a live ledger's
schema unseen. With only the password set, the job runs
`supabase migration list --linked` and prints it to the run summary.
Read a few of those, satisfy yourself the two sides agree, then set the
variable.

Until the password is set the job says so on the summary and warns —
loudly, because a green run that applied nothing looks exactly like a
green run that applied everything. That is the same reasoning the
Vercel and edge-function jobs already use.

## Why the push says `--include-all`

Two versions on the hosted project are timestamps rather than numbers:
`20260909090115` and `20260909090607`, written in the dashboard and
adopted as files afterwards. They are the highest versions the project
has, and they always will be — this repository numbers its migrations
`0001`, `0002`, … , and every number it will ever write sorts below a
2026 timestamp.

`supabase db push` refuses to apply a migration that would be inserted
before the remote's last version, which after those two means every
migration from here on. `0552` is the one that found it. So the push
carries `--include-all`.

What that flag gives up is the guard against a migration written
against an older schema arriving late. The guard that replaces it is
stronger and was already there: `supabase/tests/run_locally.sh` and the
`database` job apply every migration in filename order to an empty
database on every run, so a file that does not work in its own position
never reaches the hosted project.

If a future migration must run *after* one of those two — none does
today, both being trigger drops on read-receipt tables — give it a
timestamp version above `20260909090607` rather than a number.

## The drift check

Applying the pending ones is not the same as the hosted project matching
the files. A migration applied by hand records itself as applied, and
`db push` skips it from then on — so whatever the console ran is what
production has, permanently, while the file is what everyone reads.
0159–0173 were applied that way.

So the `database` job dumps both schemas and compares them with
`scripts/schema_drift.py`. It runs there rather than in a job of its own
because that is the only place a stack built from the migrations already
exists.

**It only compares when the hosted project is level.** The `database`
job runs *before* `Apply the migrations`, so on any commit adding a
migration the hosted schema is legitimately one behind, and every object
that migration creates would read as drift — going red on exactly the
commits that matter most. A schema behind by a known migration is a
queue, not drift.

### Cosmetic against behavioural

The comparison has two tiers, and the reason is measured rather than
assumed. When it was first written, all 47 functions defined by
0159–0173 were compared against the hosted project: **35 differed
textually and none differed in behaviour.** Pasting a migration into a
console drops its explanatory comments, and SQL's adjacent-literal
continuation means the same string can be written two ways.

So every statement is matched on its *code* — comments removed, string
continuation resolved, whitespace discarded. A difference there is drift
and fails the build. A difference in text alone is counted and reported,
because a check that fails on a missing comment is a check somebody
switches off within a fortnight. A rising cosmetic count is still worth
looking at: it means more is being applied by hand.

`GRANT` and `REVOKE` are excluded, which costs something and is the one
exclusion worth defending: hosted Supabase projects carry default
privileges that a migrations-only stack does not, so grants differ on
essentially every object. The property that matters — every policy
having the privilege it needs to run — is asserted directly by
`supabase/tests/table_grants.sql`, which is what caught `0168`.

### The comparison lags a migration push by one run

The level gate has a consequence worth knowing before you go looking for
a run that never comes. A push that adds a migration cannot compare:
the gate sees it pending and skips, then `Apply the migrations` applies
it at the end of the same run. The comparison happens on the *next* run.

If you want it the same day, re-run the workflow by hand
(`workflow_dispatch`) once the applying run is green. Nothing is pending
by then, so the gate opens. A push touching only `graphify-out/**` will
not do it — that path is ignored and starts no run at all.

### What the first reconciliation found

Seven findings, closed by `0174`–`0180`. Worth reading as a set, because
the moral is not the one the first few suggest.

| | Finding | Which side was stale |
|---|---|---|
| `0174` | `v_stock_valuation` had no `security_invoker` | repository |
| `0175` | `post_expense` never adjusted the cached bank balance; `resync_bank_balance` existed in no file | repository |
| `0176` | `create_organization` carried an `update` made dead by the seed fifty lines above it | repository |
| `0177` | `import_opening_balances` left two subqueries unaliased against its own `returns table` columns | repository |
| `0178` | `transfer_document` wrapped a subquery in `coalesce(x, null)` | repository |
| `0179` | a function comment present only on the project; a column comment truncated mid-sentence on the project | **one each way** |
| `0180` | `einvoice_documents.cancel_deadline` had no comment on the project | project |

Five in a row resolving in production's favour looked like a rule, and
it is not one. It was a pattern with a single cause — changes applied to
the hosted project by hand and never written into a file — and that
cause leaves whichever side was not touched stale. `0179` is where it
runs the other way: `0145`'s comment on
`organizations.default_sales_tax_code_id` is five lines in the file and
two on the project, the hosted text being an exact prefix of the file's.
`git log` shows `0145` was never edited, so the two diverged the day it
was applied.

**`0180` is the one that justifies the check.** `0174`–`0179` all closed
findings that had already been spotted by reading. `0180` is the first
the check found on its own — a `comment on column` in `0007` that never
reached the project, on a column whose name carries none of the rule it
states. On the run that found it: 166 statements differed cosmetically
and four differed in code, the four being three distinct comment
findings. Nothing else in the entire schema differed.

Note what that says about the tiers. A comment *inside* a function body
is cosmetic and ignored — it lives or dies with the body it sits in. A
`COMMENT ON` is a schema object in its own right, and its absence is a
real difference. All three non-function findings were of the second
kind, which is not a coincidence: comments are the first thing lost when
a migration is pasted into a console instead of pushed. They sit at the
bottom of the file, they change nothing when omitted, and until this
check existed nothing ever noticed.

`0174` is the one to remember. A view without `security_invoker` runs as
its owner, so every RLS policy underneath it is skipped — a second
project stood up from these files would have served every tenant's stock
to every other. Nothing was wrong with production. Nothing was wrong
with the policies. The gap existed only in the deployment nobody had
built yet, which is precisely the class of fault no amount of using the
application will surface. `supabase/tests/view_security.sql` now asserts
it for every view in `public`, including ones added later.

## Adding a migration

1. `supabase/migrations/0151_what_it_does.sql`. The number is the next
   one; the name is what it does, in words.
2. A test in `supabase/tests/` for anything with arithmetic or a rule in
   it, added to the list in `.github/workflows/ci.yml`.
3. Push. CI proves it applies from nothing and that the assertions hold.
4. It reaches production when the job above applies it — or by hand
   until the two gates are set, in which case the run summary will keep
   saying it is pending, which is the point.
