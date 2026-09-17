-- ---------------------------------------------------------------------
-- 0499  A privilege no policy permits
-- ---------------------------------------------------------------------
-- `supabase/tests/payslip_access.sql` says of the read log: "0047 gave
-- the table a select policy and nothing else, so there is no route by
-- which the record of a read can be tidied up afterwards", and asserts
-- it by trying the delete as `authenticated` and expecting
-- `insufficient_privilege`.
--
-- On the hosted project that delete does not raise. `authenticated`
-- holds INSERT and DELETE on `payslip_access_log` -- Supabase's default
-- privileges again, the same ones 0498 has just taken away from `anon`
-- -- so the statement is allowed to run and row level security is what
-- stops it, silently, by matching no rows. The record of who read whose
-- payslip is safe either way. What is not true is the sentence the test
-- tells you, and the local stub is what let it stay untrue: it did not
-- reproduce Supabase's defaults, so the privilege was absent locally
-- and present in production.
--
-- ### The rule
--
-- A table privilege that no policy permits is a privilege that cannot
-- do anything -- and one policy typed wrong away from being able to do
-- everything. So: for each table, and for insert, update and delete
-- separately, if no permissive policy covers that command, the
-- privilege goes. Two hundred and forty of them, across eighty-six
-- tables.
--
-- Nothing that works today stops working. Where no permissive policy
-- covers a command, the write already affects no rows; all that changes
-- is that the caller is told so, instead of being handed a silent
-- success. That is a better answer to a request that was never going to
-- do anything.
--
-- SELECT is deliberately left alone. PostgREST needs it to return the
-- row from an `insert ... returning`, so a table with an insert policy
-- and no select policy is a shape where taking the read privilege away
-- would break a write that works.
--
-- ### Mutants
--
-- Run against `supabase/tests/statutory.sql` and
-- `supabase/tests/payslip_access.sql`:
--   * a restrictive policy counted as permission -- "a module gate is
--     not a permission", asserted against a table that has nothing but
--     a gate, because every real table has a permissive policy too and
--     the predicate would look right on all of them;
--   * the sweep not run, and a command an `all` policy permits swept
--     anyway -- both refused by this migration's own self-check before
--     they can install. "nor deleted" in payslip_access and "an invoice
--     can still be raised from the API" in statutory are what would
--     catch them, and what stops a later migration undoing this one.
--     The second of those names `corp_officers` as well as the two
--     obvious tables: its writes come from a single `for all` policy,
--     so a sweep that read only the per-command policies would take it
--     and leave `sales_documents` and `contacts` standing.
-- ---------------------------------------------------------------------

-- What the policies actually permit, per table and per command. Written
-- as a function because 0499 sweeps with it and
-- `supabase/tests/statutory.sql` asserts with it, and two copies of
-- this predicate would be two chances to disagree about what a
-- restrictive policy means.
create or replace function app.policy_permits(
  p_table text, p_cmd text)
returns boolean
language sql stable
set search_path = public, app, pg_temp as $$
  select exists (
    select 1 from pg_policies p
     where p.schemaname = 'public'
       and p.tablename = p_table
       -- Permissive only. A restrictive policy -- the module gates 0127
       -- and 0133 wrote -- narrows what a permissive one allows and
       -- grants nothing on its own, so counting it as permission would
       -- keep exactly the privileges that have no way to be used.
       and p.permissive = 'PERMISSIVE'
       and p.cmd in ('ALL', upper(p_cmd)));
$$;

comment on function app.policy_permits(text, text) is
  'Whether any permissive policy on a table covers a command. The rule '
  '0499 sweeps by and the assertion in statutory.sql measures against.';

do $do$
declare
  v_table text;
  v_cmd   text;
  v_gone  integer := 0;
begin
  for v_table in
    select c.relname::text
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and c.relkind in ('r', 'p')
     order by 1
  loop
    foreach v_cmd in array array['insert', 'update', 'delete']
    loop
      if has_table_privilege('authenticated',
                             format('public.%I', v_table), v_cmd)
         and not app.policy_permits(v_table, v_cmd) then
        execute format('revoke %s on public.%I from authenticated',
                       v_cmd, v_table);
        v_gone := v_gone + 1;
      end if;
    end loop;
  end loop;
  raise notice '0499: took away % privileges no policy permitted', v_gone;
end $do$;

-- And the default, so the next table does not arrive with three write
-- privileges and no policy to use them. 0498 did this for `anon`; the
-- difference here is that `authenticated` genuinely needs writing on
-- most tables, so the grant stays and the migration that creates a
-- table keeps saying which commands it wants -- as every one of them
-- already does.
alter default privileges for role postgres in schema public
  revoke insert, update, delete on tables from authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare v_left text;
begin
  select string_agg(c.relname || '.' || cmd, ', ' order by c.relname)
    into v_left
    from pg_class c
    cross join unnest(array['insert', 'update', 'delete']) cmd
   where c.relnamespace = 'public'::regnamespace
     and c.relkind in ('r', 'p')
     and has_table_privilege('authenticated', c.oid, cmd)
     and not app.policy_permits(c.relname::text, cmd);
  if v_left is not null then
    raise exception '0499: still permitted with no policy: %', v_left;
  end if;

  -- The other half: a sweep that took a privilege a policy does permit
  -- would break every write in the product, and the first place anybody
  -- would notice is an invoice that cannot be saved.
  if not has_table_privilege('authenticated', 'public.sales_documents',
                             'insert')
     or not has_table_privilege('authenticated', 'public.contacts',
                                'update')
     -- And one whose writes come from a `for all` policy rather than a
     -- policy per command, which is the half a sweep that forgot to
     -- read 'ALL' would take while leaving the two above standing.
     or not has_table_privilege('authenticated', 'public.corp_officers',
                                'insert') then
    raise exception '0499: the sweep took a privilege the policies permit';
  end if;

  -- A module gate is restrictive and permits nothing on its own.
  if app.policy_permits('expense_lines', 'select')
     and not exists (select 1 from pg_policies
                      where tablename = 'expense_lines'
                        and permissive = 'PERMISSIVE') then
    raise exception '0499: a restrictive policy is being read as permission';
  end if;
end $do$;
