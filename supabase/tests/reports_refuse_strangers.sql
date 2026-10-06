-- =====================================================================
-- iAkauntan :: no report reads another company's books
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reports_refuse_strangers.sql
--
-- `no_tenant_sees_another.sql` asks every TABLE whether a member of one
-- company can read another's rows, through RLS. RLS does not reach a
-- SECURITY DEFINER function: it runs as its owner and sees every row in
-- the database. Each `public.report_*` function that takes a company is
-- definer, and each keeps its own tenant boundary -- an
-- `app.is_org_member(p_org_id)` in its WHERE, or an `app.can_*` guard --
-- and that line is the WHOLE of it.
--
-- On 6 October 2026 a mutation sweep dropped that line from
-- `report_withholding`, `report_trial_balance`, `report_profit_loss` and
-- `report_balance_sheet` in turn, and nothing in the suite noticed on
-- any of them. Those four are now asserted where they live. This file
-- asks the question of ALL of them at once, so the next report written
-- is asked too.
--
-- ## How, and why it cannot go vacuous
--
-- The demo is rebuilt inside this file's transaction, so the reports
-- have a company with a year of trading to read: Sinar Teknologi. Each
-- definer report taking `p_org_id` is called twice -- as Sinar's owner,
-- then as a signed-in stranger who is a member of nothing -- with its
-- required arguments filled by type (a from-date at the start of the
-- year, a to-date of today, a null for an id) and the rest defaulted.
--
-- "The stranger got nothing" is also what a broken call returns, and a
-- report with no data. So only the reports that returned rows FOR THE
-- OWNER count, their number is floored, and they are named in the
-- output. A stranger may get zero rows or an error -- either way they
-- read nothing -- and never a row.
--
-- Measured on 6 October 2026: 29 reports had rows for an owner in some
-- demo company and were asked. 25 at first, until required ids were
-- filled with a REAL matter, item or asset of the company under test
-- instead of null; that brought in the per-matter, per-item and
-- per-asset ledgers. The 15 left have no data of their kind in any demo
-- company (no withholding certificate, bank reconciliation, group,
-- vacancy, leave, lot or layout) and are named in the output.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_msg     text;
  v_sinar   uuid;
  v_owner   uuid;
  v_stranger uuid;
  f         record;
  v_args    text;
  v_call    text;
  v_n_owner bigint;
  v_n_str   bigint;
  v_leaks   text[] := '{}';
  v_counted text[] := '{}';
  i         integer;
  v_type    text;
  v_name    text;
  v_state   text;
  v_err     text;
  v_uncalled text[] := '{}';
  v_odd     text[] := '{}';
  o         record;
  v_tested  boolean;
begin
  v_msg := app.demo_rebuild();
  select id into v_sinar from public.organizations
   where is_demo and name = 'Sinar Teknologi Sdn Bhd';
  select m.user_id into v_owner from public.org_members m
   where m.org_id = v_sinar and m.role = 'owner' and m.status = 'active'
   limit 1;
  perform pg_temp.check_true('-- the demo has Sinar and an owner for it',
    v_sinar is not null and v_owner is not null);
  v_stranger := pg_temp.another_user('nobody@reports-refuse-strangers.test');

  for f in
    select p.oid, p.proname, p.pronargs, p.pronargdefaults,
           p.proargnames,
           -- 1-based, like proargnames. `proargtypes::oid[]` keeps the
           -- oidvector's 0-based bounds, and the first version of this
           -- file read every argument's type off its neighbour.
           string_to_array(p.proargtypes::text, ' ')::oid[] as types
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and p.proretset
       and p.proname like 'report\_%'
       and p.proargnames[1] = 'p_org_id'
       and p.proargtypes[0] = 'uuid'::regtype
     order by p.proname
  loop
    -- Each demo company in turn, until one whose owner gets rows: a
    -- property report needs the property company, a payroll one a
    -- company that runs payroll. The first such company is the one the
    -- stranger is pointed at.
    v_tested := false;
    v_err := null;
    for o in
      select org.id, (select m.user_id from public.org_members m
                       where m.org_id = org.id and m.role = 'owner'
                         and m.status = 'active' limit 1) as owner
        from public.organizations org
       where org.is_demo
       order by (org.id = v_sinar) desc, org.name
    loop
      continue when o.owner is null;
      v_args := format('%L::uuid', o.id);
      for i in 2 .. (f.pronargs - f.pronargdefaults) loop
        v_type := format_type(f.types[i], null);
        v_name := f.proargnames[i];
        v_args := v_args || ', ' || case
          when v_type = 'date' and v_name ~ 'from'
            then format('%L::date', make_date(extract(year from app.today())::integer, 1, 1))
          when v_type = 'date' then format('%L::date', app.today())
          when v_type = 'integer' then format('%s', extract(year from app.today())::integer)
          when v_type = 'boolean' then 'false'
          -- A required id is a REAL one from the company under test, so a
          -- per-matter, per-item or per-asset report has something to
          -- show its owner -- and the stranger is handed another
          -- company's real id, which is the leak worth looking for.
          when v_type = 'uuid' and v_name = 'p_matter_id' then format(
            '(select id from public.matters where org_id = %L limit 1)', o.id)
          when v_type = 'uuid' and v_name = 'p_item_id' then format(
            '(select item_id from public.stock_movements where org_id = %L '
            'group by item_id order by count(*) desc limit 1)', o.id)
          when v_type = 'uuid' and v_name = 'p_asset_id' then format(
            '(select id from public.fixed_assets where org_id = %L limit 1)', o.id)
          when v_type in ('text', 'uuid') then format('null::%s', v_type)
          else format('(select enum_first(null::%s))', v_type)
        end;
      end loop;
      v_call := format('select count(*) from public.%I(%s)', f.proname, v_args);

      -- As the owner. A failure is kept, and named below if no company
      -- could run the call, so a mistyped call cannot pass itself off
      -- as "no rows".
      perform pg_temp.sign_in_as(o.owner);
      begin
        execute v_call into v_n_owner;
      exception when others then
        get stacked diagnostics v_err = message_text;
        v_n_owner := 0;
      end;
      continue when v_n_owner = 0;

      v_tested := true;
      v_counted := v_counted || f.proname::text;

      -- As a stranger: none of it. Refused is fine, and reads nothing --
      -- but refused as a REFUSAL; anything other than 42501 on a call
      -- that worked for the owner is a different problem, and reported.
      perform pg_temp.sign_in_as(v_stranger);
      begin
        execute v_call into v_n_str;
      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_err = message_text;
        v_n_str := 0;
        if v_state <> '42501' then
          v_odd := v_odd || format('%s: %s %s', f.proname, v_state, v_err);
        end if;
      end;
      if v_n_str > 0 then
        v_leaks := v_leaks || format('%s (%s rows)', f.proname, v_n_str);
      end if;
      exit;
    end loop;
    if not v_tested then
      v_uncalled := v_uncalled || format('%s: %s', f.proname,
                                         coalesce(v_err, 'no rows in any demo company'));
    end if;
  end loop;
  perform pg_temp.sign_out();

  raise notice 'reports with rows for the owner, and so tested: %',
    array_to_string(v_counted, ', ');
  raise notice 'reports the owner''s call could not run, so untested: %',
    coalesce(nullif(array_to_string(v_uncalled, '; '), ''), 'none');
  perform pg_temp.check_eq(
    'a stranger is refused as a refusal, not by some other error'
    || coalesce(': ' || nullif(array_to_string(v_odd, '; '), ''), ''),
    coalesce(array_length(v_odd, 1), 0), 0);
  perform pg_temp.check_eq(
    'no report gives a stranger another company''s rows'
    || coalesce(': ' || nullif(array_to_string(v_leaks, '; '), ''), ''),
    coalesce(array_length(v_leaks, 1), 0), 0);
  -- The floor. Measured on 6 October 2026 and set at what was measured;
  -- a fall means a report stopped returning rows for its owner here,
  -- and the check above silently stopped testing it.
  perform pg_temp.check_true(
    format('and that was asked of enough reports to mean something (%s)',
           coalesce(array_length(v_counted, 1), 0)),
    coalesce(array_length(v_counted, 1), 0) >= 29);
end $$;

rollback;
