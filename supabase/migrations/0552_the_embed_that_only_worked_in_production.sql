-- ---------------------------------------------------------------------
-- 0552  The embed that only worked in production
-- ---------------------------------------------------------------------
-- The drift check went red, and it was right twice.
--
-- ### One: two foreign keys the migrations never wrote
--
-- `repository.dart` reads the payslip access requests like this:
--
--     '*, requester:profiles!payslip_access_requests_requested_by_fkey'
--     '     (id, full_name, email), '
--     'decider:profiles!payslip_access_requests_decided_by_fkey(...)'
--
-- PostgREST resolves an embed by constraint name, and it will only
-- embed `profiles` through a constraint that POINTS at `profiles`. In
-- these migrations both of those constraints point at `auth.users`
-- (0045), so on a database built from this repository that screen
-- cannot load at all.
--
-- On the hosted project it loads, because somebody made it load: there
-- the two auth constraints carry an `_auth_fkey` suffix and two more
-- named exactly what the client asks for point at `public.profiles`.
-- That was done to the deployed database and never written down, which
-- is the definition of drift -- and it is the direction of drift that
-- hides: production works, every developer's copy is broken, and the
-- thing that tells you is a screen nobody opens locally.
--
-- So this reconciles TOWARDS the hosted shape, because the hosted shape
-- is the one the application needs. Renaming the auth constraints
-- rather than dropping them keeps the referential guarantee that a
-- requester is a real login; the profile constraint is what the embed
-- travels along. `profiles.id` references `auth.users` itself, so the
-- two say the same thing twice and the second one is for PostgREST.
--
-- ### Two: two tables left off the live feed
--
-- 0547 attaches three statement triggers to every table carrying an
-- `org_id`, and `live_change_feed.sql` asserts that none is missing. On
-- the hosted project `payslip_access_log` and `security_events` have
-- none, while `audit_logs` beside them has all three -- so whatever
-- 0547 saw on that database, those two were not in it. Both are
-- ordinary tables with row security and an org_id today.
--
-- The attach block is re-run here for anything still missing. It is
-- idempotent by construction: a database that already has them (every
-- local one) is untouched.
--
-- ### Why the local suite never caught either
--
-- The first is invisible to `run_locally.sh` unless something asks
-- PostgREST to resolve that embed, and the schema/client check reads
-- column names rather than constraint targets. The second cannot be
-- seen locally at all -- the triggers are there, because 0547 ran
-- against a database that had both tables.
--
-- Both were only ever visible from the deployed project, which is what
-- the drift job is for and why it is worth the five minutes it costs.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- One: the constraints the client embeds along
-- ---------------------------------------------------------------------
-- Written as four guarded steps rather than four bare statements: this
-- has to be a no-op on the hosted project, where all four already
-- exist, and has to do the whole job on every other copy, where none
-- of them do.
do $do$
begin
  -- The auth constraints step aside, keeping what they guarantee.
  if exists (select 1 from pg_constraint
              where conname = 'payslip_access_requests_requested_by_fkey'
                and conrelid = 'public.payslip_access_requests'::regclass
                and confrelid = 'auth.users'::regclass)
  then
    alter table public.payslip_access_requests
      rename constraint payslip_access_requests_requested_by_fkey
                     to payslip_access_requests_requested_by_auth_fkey;
  end if;

  if exists (select 1 from pg_constraint
              where conname = 'payslip_access_requests_decided_by_fkey'
                and conrelid = 'public.payslip_access_requests'::regclass
                and confrelid = 'auth.users'::regclass)
  then
    alter table public.payslip_access_requests
      rename constraint payslip_access_requests_decided_by_fkey
                     to payslip_access_requests_decided_by_auth_fkey;
  end if;

  -- And the names the client embeds along point at `profiles`.
  if not exists (select 1 from pg_constraint
                  where conname = 'payslip_access_requests_requested_by_fkey'
                    and conrelid = 'public.payslip_access_requests'::regclass)
  then
    alter table public.payslip_access_requests
      add constraint payslip_access_requests_requested_by_fkey
      foreign key (requested_by) references public.profiles (id)
      on delete cascade;
  end if;

  if not exists (select 1 from pg_constraint
                  where conname = 'payslip_access_requests_decided_by_fkey'
                    and conrelid = 'public.payslip_access_requests'::regclass)
  then
    alter table public.payslip_access_requests
      add constraint payslip_access_requests_decided_by_fkey
      foreign key (decided_by) references public.profiles (id);
  end if;
end $do$;

-- ---------------------------------------------------------------------
-- Two: the tables left off the live feed
-- ---------------------------------------------------------------------
-- 0547's attach block, run again for anything still missing. Named
-- `live_change_insert` and so on, so a table that already has them
-- matches the `not exists` and is skipped rather than rebuilt.
do $do$
declare
  v_table text;
begin
  for v_table in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and c.relname <> 'live_changes'
       and exists (
         select 1 from information_schema.columns col
          where col.table_schema = 'public'
            and col.table_name = c.relname
            and col.column_name = 'org_id')
       and not exists (
         select 1 from pg_trigger t
          where t.tgrelid = c.oid
            and not t.tgisinternal
            and t.tgname = 'live_change_insert')
     order by c.relname
  loop
    raise notice '0552: putting % back on the live feed', v_table;

    execute format(
      'drop trigger if exists live_change_insert on public.%I', v_table);
    execute format(
      'create trigger live_change_insert after insert on public.%I '
      'referencing new table as new_rows '
      'for each statement execute function app.note_live_change()',
      v_table);

    execute format(
      'drop trigger if exists live_change_update on public.%I', v_table);
    execute format(
      'create trigger live_change_update after update on public.%I '
      'referencing new table as new_rows old table as old_rows '
      'for each statement execute function app.note_live_change()',
      v_table);

    execute format(
      'drop trigger if exists live_change_delete on public.%I', v_table);
    execute format(
      'create trigger live_change_delete after delete on public.%I '
      'referencing old table as old_rows '
      'for each statement execute function app.note_live_change()',
      v_table);
  end loop;
end $do$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_missing text;
begin
  -- The embed the client actually writes has to resolve now.
  foreach v_missing in array array[
    'payslip_access_requests_requested_by_fkey',
    'payslip_access_requests_decided_by_fkey']
  loop
    if not exists (
      select 1 from pg_constraint
       where conname = v_missing
         and conrelid = 'public.payslip_access_requests'::regclass
         and confrelid = 'public.profiles'::regclass)
    then
      raise exception
        '0552: % does not point at profiles, so the embed that names it '
        'cannot resolve', v_missing;
    end if;
  end loop;

  select string_agg(c.relname, ', ' order by c.relname) into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname <> 'live_changes'
     and exists (select 1 from information_schema.columns col
                  where col.table_schema = 'public'
                    and col.table_name = c.relname
                    and col.column_name = 'org_id')
     and not exists (select 1 from pg_trigger t
                      where t.tgrelid = c.oid and not t.tgisinternal
                        and t.tgname = 'live_change_insert');
  if v_missing is not null then
    raise exception '0552: still off the live feed: %', v_missing;
  end if;
end $do$;
