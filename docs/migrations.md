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

## Adding a migration

1. `supabase/migrations/0151_what_it_does.sql`. The number is the next
   one; the name is what it does, in words.
2. A test in `supabase/tests/` for anything with arithmetic or a rule in
   it, added to the list in `.github/workflows/ci.yml`.
3. Push. CI proves it applies from nothing and that the assertions hold.
4. It reaches production when the job above applies it — or by hand
   until the two gates are set, in which case the run summary will keep
   saying it is pending, which is the point.
