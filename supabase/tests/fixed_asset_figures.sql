-- =====================================================================
-- iAkauntan :: an asset is depreciated by depreciating it (0822)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixed_asset_figures.sql
--
-- `run_depreciation` charges from the day after an asset's
-- `depreciated_to`, and `dispose_fixed_asset` posts a disposal before it
-- marks one. Before `0822` a client could write both columns and the
-- rest of what those functions keep: a van's depreciation reset by
-- hand was charged again -- RM1,200 in the ledger against RM600 in the
-- register -- and a van marked disposed left the register with no
-- journal. Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_fa (org uuid, van uuid, entry uuid, bank uuid);
grant select, update on t_fa to authenticated;

-- What the ledger has charged: the debits to depreciation expense.
create or replace function pg_temp.fa_charged(p_org uuid)
returns numeric language sql as $$
  select coalesce(sum(l.debit), 0)
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where e.org_id = p_org and a.code = '6400';
$$;
grant execute on function pg_temp.fa_charged(uuid) to authenticated;

do $$
declare
  v_org uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Susut Nilai Sdn Bhd', array['fixed_assets']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.open_years(v_org, date '2026-01-01');
  -- The bank the van's proceeds go into. Made here, as the session:
  -- since `0823` a client sets one up only through
  -- `upsert_bank_account`.
  insert into t_fa (org, bank)
  values (v_org, pg_temp.test_bank_account(v_org, 'Maybank current', 'current', 'MYR', 0, 0, '1234'));
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_fa;
  r record;
begin
  select * into d from t_fa;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- Registered by the editor, as new, and depreciated by running it.
  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (d.org, 'FA-1', 'Van', 'Motor Vehicles', date '2026-01-01',
          12000, 0, 'straight_line', 60)
  returning id into d.van;
  update t_fa set van = d.van;
  perform public.run_depreciation(d.org, date '2026-03-31');
  perform pg_temp.check_eq('three months of a sixty-month RM12,000 van: RM600, register and ledger',
    (select accumulated_depreciation || '/' || depreciated_to || '/' || pg_temp.fa_charged(d.org)
       from public.fixed_assets where id = d.van), '600.00/2026-03-31/600.00');
  select e.id into d.entry from public.gl_entries e
   where e.org_id = d.org order by e.created_at desc limit 1;
  update t_fa set entry = d.entry;

  -- What was measured: the van reset by hand, then March run again.
  perform pg_temp.check_refused('the depreciation is not reset by hand',
    format('update public.fixed_assets set accumulated_depreciation = 0, depreciated_to = null where id = %L', d.van),
    'What FA-1 has been depreciated by follows from the depreciation that was charged%', '42501');
  -- Each column on its own, so no one of them is the only one asked.
  for r in select * from (values
      ('accumulated_depreciation = 0', 'the figure alone', 'What FA-1 has been depreciated by%'),
      ('depreciated_to = null', 'nor the date alone', 'What FA-1 has been depreciated by%'),
      ('status = ''disposed''', 'nor is the van marked disposed', 'FA-1 is active and becomes otherwise%'),
      ('disposal_date = date ''2026-03-31''', 'nor given a disposal date', 'FA-1 is active and becomes otherwise%'),
      ('disposal_proceeds = 9000', 'nor proceeds', 'FA-1 is active and becomes otherwise%'),
      (format('disposal_entry_id = %L', d.entry), 'nor a disposal entry', 'FA-1 is active and becomes otherwise%'))
      as t(set_clause, label, msg)
  loop
    perform pg_temp.check_refused(r.label,
      format('update public.fixed_assets set %s where id = %L', r.set_clause, d.van),
      r.msg, '42501');
  end loop;

  -- Nor registered already part-way through its life.
  for r in select * from (values
      ('accumulated_depreciation', '500', 'an asset is not registered already depreciated'),
      ('depreciated_to', 'date ''2026-03-31''', 'nor depreciated to a date'),
      ('status', '''disposed''', 'nor disposed of'),
      ('disposal_date', 'date ''2026-03-31''', 'nor with a disposal date'),
      ('disposal_proceeds', '1', 'nor proceeds'),
      ('disposal_entry_id', format('%L::uuid', d.entry), 'nor a disposal entry'))
      as t(col, val, label)
  loop
    perform pg_temp.check_refused(r.label,
      format($q$insert into public.fixed_assets
                  (org_id, asset_no, name, category, acquisition_date, cost,
                   residual_value, method, useful_life_months, %s)
                values (%L, 'FA-X', 'Lori', 'Motor Vehicles', date '2026-01-01',
                        6000, 0, 'straight_line', 60, %s)$q$, r.col, d.org, r.val),
      'An asset is registered as new%', '42501');
  end loop;

  -- So March run again charges nothing more.
  perform public.run_depreciation(d.org, date '2026-03-31');
  perform pg_temp.check_eq('so March run again charges nothing more',
    pg_temp.fa_charged(d.org), 600::numeric);

  -- The editor's fields are the editor's.
  update public.fixed_assets
     set name = 'Van (Hilux)', location = 'Shah Alam', notes = 'Spare key in the safe'
   where id = d.van;
  perform pg_temp.check_eq('the editor still names and places it',
    (select name || '/' || location from public.fixed_assets where id = d.van),
    'Van (Hilux)/Shah Alam');

  -- The road: run to June, then dispose of it.
  perform public.run_depreciation(d.org, date '2026-06-30');
  perform pg_temp.check_eq('to June: RM1,200, register and ledger',
    (select accumulated_depreciation || '/' || pg_temp.fa_charged(d.org)
       from public.fixed_assets where id = d.van), '1200.00/1200.00');
  perform public.dispose_fixed_asset(d.van, date '2026-06-30', 10000, d.bank);
  perform pg_temp.check_true('and disposed of by disposing of it, with its journal',
    (select status = 'disposed' and disposal_proceeds = 10000
            and disposal_entry_id is not null
       from public.fixed_assets where id = d.van));
end $$;

reset role;

-- The database itself, as the owner, is not a client: the guard asks
-- who wrote the statement, and the functions are not the only ones it
-- lets through.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives
-- as an equivalent one: every writer of `fixed_assets` is a definer,
-- which runs as the owner whatever the depth, and none of the six
-- columns is one a foreign key sets. It is kept for the first trigger
-- that writes an asset on a client's behalf, which `0813` needed for
-- `items` on the day it was written.
do $$
declare d t_fa;
begin
  select * into d from t_fa;
  update public.fixed_assets
     set accumulated_depreciation = 999, status = 'active'
   where id = d.van;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select accumulated_depreciation || '/' || status
       from public.fixed_assets where id = d.van), '999.00/active');
end $$;

rollback;
