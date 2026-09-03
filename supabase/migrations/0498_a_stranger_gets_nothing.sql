-- ---------------------------------------------------------------------
-- 0498  A stranger gets nothing
-- ---------------------------------------------------------------------
-- 0496 was refused by its own self-check when CI applied it to the
-- hosted project: `anon` could read `expense_lines`. Nothing in that
-- migration granted it. Supabase's own default privileges did --
-- `alter default privileges in schema public grant all on tables to
-- anon` is in force on every hosted project, so every table carries an
-- `anon` grant from the moment it is created. `0165` added an event
-- trigger that strips `PUBLIC` and `anon` from every new *function*;
-- nothing does the same for tables, so a migration has to write
-- `revoke all on public.<table> from anon` by hand and roughly fifty
-- of them do. Two hundred and sixty-seven do not.
--
-- ### What this is, and what it is not
--
-- It is not an open door, and saying otherwise would be wrong. Row
-- level security is enabled on all three hundred and eighteen tables in
-- `public`, `anon` has no insert, update or delete anywhere, and of the
-- policies that reach `PUBLIC` -- and so reach `anon` -- exactly five
-- have no guard at all:
--
--   corp_filing_types, landing_logos, landing_stats,
--   landing_testimonials, ref_statutory_remittances
--
-- Every other policy is `can_read_ledger`, `is_org_member`,
-- `can_read_module` or similar, all of which are false for somebody who
-- is not signed in. A stranger reading any other table today gets zero
-- rows, not somebody's ledger.
--
-- What it is: the second line of a defence this project keeps writing
-- by hand and keeps forgetting. A policy that is wrong once -- a
-- `using (true)` typed in a hurry on a table with an `anon` grant
-- behind it -- is the whole difference, and the grant is what makes
-- that mistake reachable rather than inert.
--
-- ### What changes
--
-- The default privilege itself, so a table created after this one
-- carries no `anon` grant and no migration has to remember; then the
-- three hundred-odd tables that already exist. The four tables that are
-- deliberately public keep their grant -- the three the landing page
-- reads and the statutory remittance calendar, all four of which have
-- the unguarded policy to match. `corp_filing_types` keeps its policy
-- and loses its grant: nothing anonymous reads the SSM filing types,
-- and the policy is there so a member of any company can.
--
-- ### Mutants
--
-- Run against `supabase/tests/statutory.sql`:
--   * the landing tables swept with the rest -- "except the four the
--     front page and the calendar need";
--   * the sweep not run at all, and the default privilege left alone --
--     both refused by this migration's own self-check, which reads the
--     grants back and the `pg_default_acl` entry and will not install a
--     sweep that did not sweep. Neither reaches the suite. "nothing in
--     public is readable by a stranger" and "and a table made after
--     this one is shut too" are what would catch them, and are what
--     keeps a later migration from undoing this one.
--
-- That the self-check does most of the killing here is the right way
-- round for a migration of this kind: it runs against the database
-- being changed, at the moment of changing it, and a sweep is only ever
-- true of the database it swept.
-- ---------------------------------------------------------------------

-- The four that are meant to be readable by somebody who is not signed
-- in. Each has an unguarded `using (true)` policy to match, which is
-- what makes the grant meaningful rather than decorative.
create or replace function app.anon_readable_tables()
returns text[]
language sql immutable
set search_path = public, app, pg_temp as $$
  select array['landing_logos', 'landing_stats', 'landing_testimonials',
               'ref_statutory_remittances']::text[];
$$;

comment on function app.anon_readable_tables() is
  'The tables a stranger may read: the front page''s three and the '
  'statutory remittance calendar. Everything else in public is shut to '
  'anon by 0498, and this list is what the assertion in '
  'supabase/tests/statutory.sql measures against.';

-- The default, first. A table created after this line carries no anon
-- grant at all, so the next migration to add one cannot forget -- which
-- is the half of this that stops the problem coming back.
alter default privileges for role postgres in schema public
  revoke all on tables from anon;

do $do$
declare
  v_table text;
  v_keep  text[] := app.anon_readable_tables();
begin
  for v_table in
    select c.relname::text
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and c.relkind in ('r', 'p', 'v', 'm')
       and not (c.relname = any(v_keep))
     order by 1
  loop
    execute format('revoke all on public.%I from anon', v_table);
  end loop;

  -- And the four, said out loud rather than left to whatever they
  -- happened to have. A grant nobody can find in a migration is a
  -- grant nobody will think to check.
  foreach v_table in array v_keep
  loop
    if exists (select 1 from pg_class c
                where c.relnamespace = 'public'::regnamespace
                  and c.relname = v_table) then
      execute format('grant select on public.%I to anon', v_table);
    end if;
  end loop;
end $do$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_open  text;
  v_shut  text;
  v_keep  text[] := app.anon_readable_tables();
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_open
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind in ('r', 'p', 'v', 'm')
     and not (c.relname = any(v_keep))
     and has_table_privilege('anon', c.oid, 'select');
  if v_open is not null then
    raise exception '0498: a stranger can still read %', v_open;
  end if;

  -- And the four are still there. A sweep that took them with it would
  -- empty the front page and take the remittance calendar off the
  -- public site, which is a different kind of broken and a quiet one.
  select string_agg(t, ', ' order by t) into v_shut
    from unnest(v_keep) t
   where exists (select 1 from pg_class c
                  where c.relnamespace = 'public'::regnamespace
                    and c.relname = t)
     and not has_table_privilege('anon', 'public.' || quote_ident(t),
                                 'select');
  if v_shut is not null then
    raise exception '0498: the sweep took % with it', v_shut;
  end if;

  -- The default privilege, which is what stops this coming back.
  --
  -- Scoped to `postgres`, and that is the whole subtlety. A hosted
  -- project carries two default-ACL entries for tables in `public`:
  -- one for `postgres` and one for `supabase_admin`. A default ACL
  -- only governs tables created *by that role*, and every table in
  -- this schema is created by a migration, which runs as `postgres`.
  -- The `supabase_admin` entry belongs to Supabase's own machinery,
  -- is not ours to alter, and governs nothing in here.
  --
  -- Checking every entry instead of that one is what refused this
  -- migration the first time CI ran it: the sweep was right and the
  -- self-check was asking about somebody else's default.
  if exists (
    select 1 from pg_default_acl d
     where d.defaclnamespace = 'public'::regnamespace
       and d.defaclobjtype = 'r'
       and d.defaclrole = 'postgres'::regrole
       and array_to_string(d.defaclacl, ',') like '%anon=%') then
    raise exception '0498: the next table will be exposed again';
  end if;
end $do$;
