-- =====================================================================
-- iAkauntan :: the depreciation schedule
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/depreciation_schedule.sql
--
-- The fixed asset note is the one disclosure in a set of Malaysian
-- accounts that is almost never checked against the ledger, because it
-- is usually kept on a spreadsheet beside them. A note that adds up
-- internally and disagrees with the trial balance looks perfect.
--
-- So the two assertions this file exists for are movement identities:
--
--   cost carried forward  = brought forward + additions - disposals
--   accumulated carried   = brought forward + charge    - disposals
--
-- and in both cases the carried-forward figure is derived independently
-- of the three that are supposed to reconcile to it — from what each
-- surviving asset cost and has actually been charged, not by adding the
-- movements up.
--
-- The second identity is the one with teeth. It holds only if every
-- movement in accumulated depreciation was recorded as a depreciation
-- entry, and until 0156 a disposal relieved the balance sheet of a
-- catch-up it never charged. This file would have failed on that, which
-- is the point of writing it this way round.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.check_text(
  p_label text, p_actual text, p_expected text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %',
      p_label, coalesce(p_expected, '(null)'), coalesce(p_actual, '(null)');
  end if;
  raise notice 'ok   % = %', p_label, coalesce(p_actual, '(null)');
end;
$$;

-- ---------------------------------------------------------------------
-- A year with one of everything in it
--
--   FA-1  Van, 12,000 over 60 months — 200 a month. Bought 1 January,
--         depreciated to 31 March, sold on 30 June for 10,000.
--   FA-2  Lathe, 24,000 over 48 months — 500 a month. Bought 1 February
--         and still held.
--
-- The van is the interesting one: it is bought and gone inside the
-- period, and its last three months of charge exist only because the
-- disposal put them there.
-- ---------------------------------------------------------------------
create or replace function pg_temp.sched_org()
returns uuid language plpgsql as $$
declare
  v_org uuid := pg_temp.test_org('Schedule Sdn Bhd');
  v_van uuid; v_lathe uuid; v_x uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (v_org, 'FA-1', 'Van', 'Motor Vehicles', date '2026-01-01',
          12000, 0, 'straight_line', 60)
  returning id into v_van;

  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (v_org, 'FA-2', 'Lathe', 'Plant', date '2026-02-01',
          24000, 0, 'straight_line', 48)
  returning id into v_lathe;

  v_x := public.run_depreciation(v_org, date '2026-03-31');
  v_x := public.dispose_fixed_asset(v_van, date '2026-06-30', 10000, null);
  v_x := public.run_depreciation(v_org, date '2026-12-31');

  perform set_config('app.test_van', v_van::text, true);
  perform set_config('app.test_lathe', v_lathe::text, true);
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- The identities
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sched_org();
  v_rows integer;
  v_bad  integer;
begin
  select count(*) into v_rows
    from public.report_asset_movements(v_org, date '2026-01-01',
                                       date '2026-12-31');
  perform pg_temp.check_eq('a row for each category held', v_rows, 2);

  select count(*) into v_bad
    from public.report_asset_movements(v_org, date '2026-01-01',
                                       date '2026-12-31') m
   where m.cost_closing <> m.cost_opening + m.additions - m.disposals_cost;
  perform pg_temp.check_eq('cost carried forward reconciles', v_bad, 0);

  select count(*) into v_bad
    from public.report_asset_movements(v_org, date '2026-01-01',
                                       date '2026-12-31') m
   where m.accum_closing <> m.accum_opening + m.charge - m.disposals_accum;
  perform pg_temp.check_eq('and so does accumulated depreciation', v_bad, 0);

  -- Neither of those means anything if the report returned nothing, and
  -- both of them are "count the rows that disagree".
  perform pg_temp.check_eq('on figures that are not all nil',
    (select sum(m.cost_closing + m.charge)
       from public.report_asset_movements(v_org, date '2026-01-01',
                                          date '2026-12-31') m),
    30700);
end $$;

-- ---------------------------------------------------------------------
-- The note against the ledger
--
-- The disclosure has to be the same numbers the trial balance carries,
-- or one of the two is a work of fiction.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sched_org();
begin
  -- 1510 was only ever credited, by the disposal: assets are not
  -- capitalised through this module, so the cost side is checked
  -- against what left rather than against a balance.
  perform pg_temp.check_eq('the disposal took the cost off the ledger',
    (select coalesce(sum(l.credit) - sum(l.debit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and ac.code = '1510'), 12000);
  perform pg_temp.check_eq('which is what the note reports as disposals',
    (select sum(m.disposals_cost)
       from public.report_asset_movements(v_org, date '2026-01-01',
                                          date '2026-12-31') m), 12000);

  -- Accumulated depreciation in the ledger is a credit balance; the note
  -- reports it as a positive figure, so the sign is flipped once here
  -- and nowhere else.
  perform pg_temp.check_eq('accumulated depreciation agrees with 1590',
    (select coalesce(sum(l.credit) - sum(l.debit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and ac.code = '1590'),
    (select sum(m.accum_closing)
       from public.report_asset_movements(v_org, date '2026-01-01',
                                          date '2026-12-31') m));

  -- Eleven months of lathe and six of van.
  perform pg_temp.check_eq('the charge for the year agrees with 6400',
    (select coalesce(sum(l.debit) - sum(l.credit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and ac.code = '6400'), 6700);
  perform pg_temp.check_eq('and with the note',
    (select sum(m.charge)
       from public.report_asset_movements(v_org, date '2026-01-01',
                                          date '2026-12-31') m), 6700);
end $$;

-- ---------------------------------------------------------------------
-- What each category says
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sched_org();
begin
  -- In and out inside the same year: nothing brought forward, nothing
  -- carried forward, and the whole of it through the movements.
  perform pg_temp.check_eq('the van arrived',
    (select m.additions from public.report_asset_movements(
       v_org, date '2026-01-01', date '2026-12-31') m
      where m.category = 'Motor Vehicles'), 12000);
  perform pg_temp.check_eq('and left',
    (select m.disposals_cost from public.report_asset_movements(
       v_org, date '2026-01-01', date '2026-12-31') m
      where m.category = 'Motor Vehicles'), 12000);
  perform pg_temp.check_eq('leaving nothing under motor vehicles',
    (select m.cost_closing from public.report_asset_movements(
       v_org, date '2026-01-01', date '2026-12-31') m
      where m.category = 'Motor Vehicles'), 0);
  perform pg_temp.check_eq('and no assets to count',
    (select m.assets from public.report_asset_movements(
       v_org, date '2026-01-01', date '2026-12-31') m
      where m.category = 'Motor Vehicles'), 0);
  -- Six months at 200, of which the last three were charged by the
  -- disposal. Before 0156 this read 600.
  perform pg_temp.check_eq('six months of van were charged',
    (select m.charge from public.report_asset_movements(
       v_org, date '2026-01-01', date '2026-12-31') m
      where m.category = 'Motor Vehicles'), 1200);

  perform pg_temp.check_eq('the lathe is carried at cost less charge',
    (select m.net_book_value from public.report_asset_movements(
       v_org, date '2026-01-01', date '2026-12-31') m
      where m.category = 'Plant'), 18500);
end $$;

-- ---------------------------------------------------------------------
-- A period that opens on something
--
-- The second half of the year, where the lathe is brought forward part
-- depreciated and the van is gone before it starts. A schedule that
-- reported the van here would be reporting a disposal twice across two
-- periods.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sched_org();
begin
  perform pg_temp.check_eq('one category left in the second half',
    (select count(*) from public.report_asset_movements(
       v_org, date '2026-07-01', date '2026-12-31')), 1);
  perform pg_temp.check_text('and it is not motor vehicles',
    (select m.category from public.report_asset_movements(
       v_org, date '2026-07-01', date '2026-12-31') m), 'Plant');

  perform pg_temp.check_eq('the lathe is brought forward at cost',
    (select m.cost_opening from public.report_asset_movements(
       v_org, date '2026-07-01', date '2026-12-31') m), 24000);
  -- Charged to 31 March only, because the December run had not happened
  -- when the period opened.
  perform pg_temp.check_eq('with two months already charged',
    (select m.accum_opening from public.report_asset_movements(
       v_org, date '2026-07-01', date '2026-12-31') m), 1000);
  perform pg_temp.check_eq('and nine more in the half year',
    (select m.charge from public.report_asset_movements(
       v_org, date '2026-07-01', date '2026-12-31') m), 4500);
  perform pg_temp.check_eq('closing where the full year closed',
    (select m.accum_closing from public.report_asset_movements(
       v_org, date '2026-07-01', date '2026-12-31') m), 5500);

  -- No start date at all means since the beginning, which must give the
  -- same closing position as the year did.
  perform pg_temp.check_eq('and an open-ended schedule agrees',
    (select sum(m.net_book_value) from public.report_asset_movements(
       v_org, null, date '2026-12-31') m), 18500);
end $$;

-- ---------------------------------------------------------------------
-- One asset's history
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sched_org();
  v_van uuid := current_setting('app.test_van')::uuid;
  v_lathe uuid := current_setting('app.test_lathe')::uuid;
begin
  perform pg_temp.check_eq('the van was charged twice',
    (select count(*) from public.report_depreciation_history(v_org, v_van)), 2);
  perform pg_temp.check_text('a run, then the disposal',
    (select string_agg(h.source, ' then ' order by h.run_date)
       from public.report_depreciation_history(v_org, v_van) h),
    'Depreciation run then Disposal');

  perform pg_temp.check_eq('the first charge is three months',
    (select h.charge from public.report_depreciation_history(v_org, v_van) h
      where h.run_date = date '2026-03-31'), 600);
  perform pg_temp.check_eq('the second is the three to disposal',
    (select h.charge from public.report_depreciation_history(v_org, v_van) h
      where h.run_date = date '2026-06-30'), 600);
  perform pg_temp.check_eq('each opens where the last one closed',
    (select h.opening_accumulated
       from public.report_depreciation_history(v_org, v_van) h
      where h.run_date = date '2026-06-30'), 600);
  -- 12,000 less 1,200, which is what the disposal measured the loss
  -- against: sold for 10,000, so a loss of 800.
  perform pg_temp.check_eq('and the last net book value is what it sold at',
    (select h.net_book_value
       from public.report_depreciation_history(v_org, v_van) h
      where h.run_date = date '2026-06-30'), 10800);

  perform pg_temp.check_eq('the lathe has its two runs',
    (select count(*) from public.report_depreciation_history(v_org, v_lathe)), 2);
  perform pg_temp.check_eq('and none of them is a disposal',
    (select count(*) from public.report_depreciation_history(v_org, v_lathe) h
      where h.source = 'Disposal'), 0);

  perform pg_temp.check_eq('an asset never charged has no history',
    (select count(*) from public.report_depreciation_history(
       v_org, gen_random_uuid())), 0);
end $$;

-- ---------------------------------------------------------------------
-- Who may read it
--
-- The fixed asset note is a balance sheet disclosure, so this is the
-- ledger bar rather than the membership bar the stock card uses. The
-- pair below is what makes that assertion mean something: the same
-- report, refused to one member and given to another.
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid := pg_temp.sched_org();
  v_van     uuid := current_setting('app.test_van')::uuid;
  v_owner   uuid := (select user_id from public.org_members
                      where org_id = v_org and role = 'owner' limit 1);
  v_buyer   uuid := pg_temp.another_user('purchaser@schedule.test');
  v_auditor uuid := pg_temp.another_user('auditor@schedule.test');
  v_msg     text;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_buyer, 'purchaser'), (v_org, v_auditor, 'auditor');

  perform pg_temp.sign_in_as(v_buyer);
  begin
    perform * from public.report_asset_movements(v_org);
    v_msg := null;
  exception when others then
    v_msg := sqlerrm;
  end;
  -- A caught exception unwinds to the savepoint and takes the sign-in
  -- with it, so it has to be done again before anything else is asked.
  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_text('a purchaser is refused the note',
    v_msg, 'Insufficient privileges to read the ledger');

  -- Both categories, because the default period runs from before the
  -- van was bought to today and the van is on it as a disposal.
  perform pg_temp.check_eq('an auditor is not',
    (select count(*) from public.report_asset_movements(v_org)), 2);
  perform pg_temp.check_eq('and gets the history too',
    (select count(*) from public.report_depreciation_history(v_org, v_van)), 2);

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and so does the owner',
    (select count(*) from public.report_asset_movements(v_org)), 2);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the note is closed to anon',
    not has_function_privilege('anon',
      'public.report_asset_movements(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('and open to authenticated',
    has_function_privilege('authenticated',
      'public.report_asset_movements(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('the history likewise',
    has_function_privilege('authenticated',
      'public.report_depreciation_history(uuid, uuid)', 'execute'));
  perform pg_temp.check_true('and what has been charged stays internal',
    not has_function_privilege('authenticated',
      'app.accumulated_charged_at(uuid, date)', 'execute'));
end $$;

do $$
declare
  v_org uuid;
  v_n   integer;
begin
  v_org := pg_temp.sched_org();
  set local role authenticated;
  perform pg_temp.check_text('running as authenticated', current_user,
    'authenticated');
  select count(*) into v_n
    from public.report_asset_movements(v_org, date '2026-01-01',
                                       date '2026-12-31');
  perform pg_temp.check_eq('and the note comes back', v_n, 2);
end $$;

-- `set local` lasts to the end of the transaction, not the end of the
-- block, and the rollback below wants the superuser back.
reset role;

rollback;
