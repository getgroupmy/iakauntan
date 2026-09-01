-- =====================================================================
-- iAkauntan :: audited financial statements and MBRS
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mbrs.sql
--
-- Four things here can be wrong in ways nobody notices until SSM
-- rejects the filing or a director signs something untrue.
--
--   1. **The statements do not balance.** There is no year-end close in
--      this ledger, so `report_balance_sheet` is out by cumulative
--      profit. A Statement of Financial Position whose assets do not
--      equal equity plus liabilities is a rejected submission, and the
--      module's whole job is to not produce one.
--   2. **The freeze does not hold.** A set of accounts lodged in May
--      must still read the same in November, after somebody posts a
--      correction into the closed year. If the figures move, what was
--      filed and what the system says were filed are different numbers.
--   3. **The deadline is out by a day.** Six months is not 180 days.
--      From 31 August it is 28 February, and a filing lodged on the
--      strength of a day-count is late.
--   4. **The exemption is claimed on one good year.** Practice
--      Directive 3/2018 tests the current financial year *and the
--      immediate past two*. Getting that wrong means filing unaudited
--      accounts that needed an audit.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company, its chart of accounts and the entitlement.
create or replace function pg_temp.mbrs_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end $$;

-- A posted journal, two lines, so the fixtures read as accounting
-- rather than as inserts.
create or replace function pg_temp.jv(
  p_org uuid, p_no text, p_date date,
  p_dr uuid, p_cr uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (p_org, p_no, p_date, 'manual', 'posted', p_no)
  returning id into v_entry;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (p_org, v_entry, 1, p_dr, p_amount, 0),
         (p_org, v_entry, 2, p_cr, 0, p_amount);
end $$;

create or replace function pg_temp.acct(p_org uuid, p_subtype text)
returns uuid language sql as $$
  select id from public.accounts
   where org_id = p_org and account_subtype = p_subtype::app.account_subtype
     and not is_group
   order by code limit 1;
$$;

-- ---------------------------------------------------------------------
-- A trading company
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_filing uuid; v_bank uuid; v_cap uuid;
  v_sales uuid; v_exp uuid; v_rows integer; r record;
  v_frozen numeric; v_live numeric;
begin
  v_org  := pg_temp.mbrs_org('Probe MBRS Trading');
  perform public.create_fiscal_year(v_org, date '2025-01-01');
  v_bank  := pg_temp.acct(v_org, 'bank');
  v_cap   := pg_temp.acct(v_org, 'share_capital');
  v_sales := pg_temp.acct(v_org, 'sales');
  v_exp   := pg_temp.acct(v_org, 'operating_expense');

  perform pg_temp.jv(v_org, 'JV-1', date '2025-01-02', v_bank, v_cap, 100000);
  perform pg_temp.jv(v_org, 'JV-2', date '2025-06-30', v_bank, v_sales, 250000);
  perform pg_temp.jv(v_org, 'JV-3', date '2025-06-30', v_exp, v_bank, 180000);

  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'mpers', 'audited', 3)
  returning id into v_filing;

  -- ------------------------------------------------------------------
  -- 1: it balances, and *why* it balances
  --
  -- Nothing has swept the year's RM70,000 profit anywhere. If retained
  -- earnings were read straight off the balance sheet it would be nil
  -- and the statement would be out by exactly that.
  -- ------------------------------------------------------------------
  select current_amount into v_frozen from public.fs_prepare(v_filing)
   where element_code = 'RetainedEarnings';
  perform pg_temp.check_eq('undistributed profit reaches retained earnings',
    v_frozen, 70000);

  select * into r from public.fs_balance_check(v_filing);
  perform pg_temp.check_eq('assets', r.assets, 170000);
  perform pg_temp.check_eq('equity', r.equity, 170000);
  perform pg_temp.check_eq('and the difference is nil', r.difference, 0);
  perform pg_temp.check_true('so it balances', r.balances);

  -- Every account landed somewhere. An element that silently mapped to
  -- null would balance too — by leaving the same money out of both
  -- sides — so this is the control that catches it.
  perform pg_temp.check_eq('revenue is on the face of it',
    (select current_amount from public.fs_prepare(v_filing)
      where element_code = 'Revenue'), 250000);
  perform pg_temp.check_eq('and so are the costs',
    (select current_amount from public.fs_prepare(v_filing)
      where element_code = 'AdministrativeExpenses'), 180000);

  -- ------------------------------------------------------------------
  -- Audited means audited
  -- ------------------------------------------------------------------
  begin
    perform public.fs_freeze(v_filing);
    raise exception 'froze audited accounts with no auditor named';
  exception when sqlstate '22023' then
    raise notice 'ok   audited accounts need an auditor and an opinion';
  end;

  update public.fs_filings
     set auditor_name = 'Tan & Partners', auditor_firm_no = 'AF 1234',
         opinion = 'unmodified', audit_report_date = date '2026-04-15',
         -- `0391` refuses a circulation with no approval behind it:
         -- under s.258 what goes to the members is the *approved*
         -- accounts, so the board meeting has to be on the record
         -- first. The fixture now runs in the order the Act does.
         directors_approval_date = date '2026-04-15',
         circulated_on = date '2026-04-20'
   where id = v_filing;

  v_rows := public.fs_freeze(v_filing);
  perform pg_temp.check_true('freezing writes the figures', v_rows >= 5);

  -- ------------------------------------------------------------------
  -- 2: the freeze holds
  --
  -- The correction below is exactly what happens in practice: a journal
  -- dated inside the closed year, posted after the accounts were
  -- approved. The ledger moves. The filing must not.
  -- ------------------------------------------------------------------
  perform pg_temp.jv(v_org, 'JV-4', date '2025-12-31', v_exp, v_bank, 5000);

  select current_amount into v_frozen from public.fs_figures
   where filing_id = v_filing and element_code = 'AdministrativeExpenses';
  select amount into v_live
    from app.fs_figures_at(v_org, date '2025-01-01', date '2025-12-31')
   where element_code = 'AdministrativeExpenses';

  perform pg_temp.check_eq('what was filed stays filed', v_frozen, 180000);
  -- The positive control on the freeze. If the ledger had *not* moved,
  -- the assertion above would pass for the wrong reason and prove
  -- nothing at all.
  perform pg_temp.check_eq('while the ledger has moved on', v_live, 185000);

  -- And the frozen figures cannot be edited round the back.
  begin
    update public.fs_figures set current_amount = 1
     where filing_id = v_filing and element_code = 'Revenue';
    raise exception 'edited the figures of a frozen filing';
  exception when insufficient_privilege then
    raise notice 'ok   frozen figures refuse a direct edit';
  end;

  -- ------------------------------------------------------------------
  -- 3: the clock
  --
  -- Year end 31 December 2025. Six months is 30 June 2026. The company
  -- circulated on 20 April, so section 259 runs thirty days from *that*
  -- — 20 May — not from the deadline it did not use.
  -- ------------------------------------------------------------------
  select * into r from public.fs_deadlines(v_filing);
  perform pg_temp.check_true('six months to circulate',
    r.circulate_by = date '2026-06-30');
  perform pg_temp.check_true('thirty days from circulation, not from the deadline',
    r.lodge_by = date '2026-05-20');
  perform pg_temp.check_true('and the outside limit is six months plus thirty',
    r.outside_limit = date '2026-07-30');

  -- ------------------------------------------------------------------
  -- 4: no exemption on these numbers
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a trading company qualifies on no ground',
    (select count(*) from public.fs_audit_exemption(v_filing) where qualifies), 0);

  -- ------------------------------------------------------------------
  -- Lodged is lodged
  -- ------------------------------------------------------------------
  perform public.fs_lodge(v_filing, 'MBRS-2026-000123', date '2026-05-02');

  begin
    update public.fs_filings set opinion = 'qualified' where id = v_filing;
    raise exception 'restated a set of accounts already lodged with SSM';
  exception when insufficient_privilege then
    raise notice 'ok   lodged accounts refuse a restatement';
  end;

  -- A typo in the reference is a typo, not a restatement.
  update public.fs_filings set mbrs_reference = 'MBRS-2026-000124'
   where id = v_filing;
  raise notice 'ok   but the reference can still be corrected';

  begin
    perform public.fs_unfreeze(v_filing);
    raise exception 'reopened accounts that had been lodged';
  exception when insufficient_privilege then
    raise notice 'ok   and they cannot be reopened';
  end;

  raise notice 'mbrs: statements balance, the freeze holds, the clock is right';
end $$;

-- ---------------------------------------------------------------------
-- Six months is not 180 days
--
-- Its own block because the point is the calendar, not the company. A
-- 31 August year end falls due on 28 February — 181 days — and a
-- deadline computed by adding 180 would say the 27th and be wrong by a
-- day in the direction that matters.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_filing uuid; r record;
begin
  v_org := pg_temp.mbrs_org('Probe MBRS Calendar');
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status)
  values (v_org, date '2024-09-01', date '2025-08-31', 'audited')
  returning id into v_filing;

  select * into r from public.fs_deadlines(v_filing);
  perform pg_temp.check_true('31 August falls due on 28 February',
    r.circulate_by = date '2026-02-28');
  perform pg_temp.check_eq('which a 180-day rule would have got wrong',
    r.circulate_by - date '2025-08-31', 181);
end $$;

-- ---------------------------------------------------------------------
-- Practice Directive 3/2018
--
-- The three grounds, each tested positively. A file that only ever
-- asserts "does not qualify" would pass with the function hard-wired to
-- false.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  v_2023 uuid; v_2024 uuid; v_2025 uuid; r record;
begin
  -- Dormant: incorporated, never traded, not a single journal.
  v_org := pg_temp.mbrs_org('Probe MBRS Dormant');
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'audit_exempt', 0)
  returning id into v_2025;

  select * into r from public.fs_audit_exemption(v_2025) where ground = 'dormant';
  perform pg_temp.check_true('a company that never traded is dormant',
    r.qualifies);

  -- One journal in the third year back is enough to end it. Dormancy is
  -- about any accounting transaction, not about revenue: a company that
  -- paid its own filing fee had a transaction.
  perform public.create_fiscal_year(v_org, date '2023-01-01');
  v_bank := pg_temp.acct(v_org, 'bank');
  v_cap  := pg_temp.acct(v_org, 'share_capital');
  perform pg_temp.jv(v_org, 'JV-D1', date '2023-06-01', v_bank, v_cap, 100);

  select * into r from public.fs_audit_exemption(v_2025) where ground = 'dormant';
  perform pg_temp.check_true('one transaction in three years ends dormancy',
    not r.qualifies);

  -- Threshold-qualified: small in all three years.
  v_org := pg_temp.mbrs_org('Probe MBRS Small');
  -- A year at a time: period control refuses a journal dated outside an
  -- open fiscal period, and this fixture spans three.
  perform public.create_fiscal_year(v_org, date '2023-01-01');
  perform public.create_fiscal_year(v_org, date '2024-01-01');
  perform public.create_fiscal_year(v_org, date '2025-01-01');
  v_bank  := pg_temp.acct(v_org, 'bank');
  v_cap   := pg_temp.acct(v_org, 'share_capital');
  v_sales := pg_temp.acct(v_org, 'sales');
  v_exp   := pg_temp.acct(v_org, 'operating_expense');

  -- A small company that spends most of what it earns, which is what
  -- makes it a small company. The first draft of this fixture booked the
  -- revenue and no costs, so the bank balance compounded to RM315,000 by
  -- the third year and the company failed the RM300,000 *assets*
  -- ceiling while passing the revenue one — the exemption test was
  -- right and the fixture was wrong.
  perform pg_temp.jv(v_org, 'JV-S0', date '2023-01-02', v_bank, v_cap, 20000);
  perform pg_temp.jv(v_org, 'JV-S1', date '2023-06-30', v_bank, v_sales, 80000);
  perform pg_temp.jv(v_org, 'JV-S2', date '2023-07-31', v_exp, v_bank, 72000);
  perform pg_temp.jv(v_org, 'JV-S3', date '2024-06-30', v_bank, v_sales, 90000);
  perform pg_temp.jv(v_org, 'JV-S4', date '2024-07-31', v_exp, v_bank, 81000);
  perform pg_temp.jv(v_org, 'JV-S5', date '2025-06-30', v_bank, v_sales, 95000);
  perform pg_temp.jv(v_org, 'JV-S6', date '2025-07-31', v_exp, v_bank, 85500);

  -- A filing per year, because the headcount is a fact about each year
  -- and the test reads it off that year's own row.
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2023-01-01', date '2023-12-31', 'audit_exempt', 2)
  returning id into v_2023;
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2024-01-01', date '2024-12-31', 'audit_exempt', 4)
  returning id into v_2024;
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'audit_exempt', 5)
  returning id into v_2025;

  select * into r from public.fs_audit_exemption(v_2025)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true(
    'under RM100k revenue, RM300k assets and five staff for three years',
    r.qualifies);

  -- Revenue over the ceiling in *one* of the three years ends it, and
  -- that year is deliberately the oldest — the one somebody checking
  -- only the current year would miss.
  perform pg_temp.jv(v_org, 'JV-S7', date '2023-09-30', v_bank, v_sales, 30000);
  select * into r from public.fs_audit_exemption(v_2025)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('one year over the ceiling ends it',
    not r.qualifies);
  perform pg_temp.check_true('and it says which ceiling',
    r.reason like '%RM100,000%');

  -- A missing headcount is answered honestly rather than as a refusal.
  update public.fs_filings set employee_count = null where id = v_2024;
  select * into r from public.fs_audit_exemption(v_2025)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('a missing headcount is "cannot tell"',
    not r.qualifies and r.reason like 'Cannot tell%');

  raise notice 'mbrs: all three exemption grounds tested in both directions';
end $$;

-- ---------------------------------------------------------------------
-- 5. The default mapping, subtype by subtype
--
-- `app.fs_default_element` decides which line of the statements every
-- account lands on when the company has written no override, and until
-- now nothing asserted a single one of its arms. It is also mirrored in
-- the app, in `fs_mapping.dart`, so the mapping screen can show what an
-- account will do before anybody overrides it -- and a mirror that
-- drifts shows the wrong thing confidently.
--
-- Every subtype is checked, so changing one here fails this file and
-- sends somebody to the copy.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_got text;
begin
  for r in
    select * from (values
      -- Accumulated depreciation deliberately lands on the same element
      -- as the cost it relieves: the face of the statement shows
      -- carrying amount and the split is a note.
      ('fixed_asset',              'PropertyPlantAndEquipment'),
      ('accumulated_depreciation', 'PropertyPlantAndEquipment'),
      ('other_asset',              'OtherNonCurrentAssets'),
      ('inventory',                'Inventories'),
      ('accounts_receivable',      'TradeAndOtherReceivables'),
      ('bank',                     'CashAndCashEquivalents'),
      ('cash',                     'CashAndCashEquivalents'),
      ('current_asset',            'OtherCurrentAssets'),
      ('accounts_payable',         'TradeAndOtherPayables'),
      ('tax_payable',              'CurrentTaxLiabilities'),
      ('current_liability',        'OtherCurrentLiabilities'),
      ('long_term_liability',      'LoansAndBorrowings'),
      ('other_liability',          'OtherNonCurrentLiabilities'),
      ('share_capital',            'ShareCapital'),
      ('reserves',                 'Reserves'),
      ('retained_earnings',        'RetainedEarnings'),
      -- Drawings are debit-natural equity, so they come back negative
      -- and correctly reduce retained earnings.
      ('drawings',                 'RetainedEarnings'),
      ('sales',                    'Revenue'),
      ('cost_of_sales',            'CostOfSales'),
      ('other_income',             'OtherIncome'),
      ('operating_expense',        'AdministrativeExpenses'),
      ('payroll_expense',          'StaffCosts'),
      ('depreciation_expense',     'DepreciationAndAmortisation'),
      ('finance_cost',             'FinanceCosts'),
      ('other_expense',            'OtherOperatingExpenses'),
      ('tax_expense',              'TaxExpense')
    ) as t(subtype, element)
  loop
    -- The type is deliberately wrong for most of these: the function
    -- reads the subtype first, and an account whose type was mistyped
    -- still has to land where its subtype says.
    v_got := app.fs_default_element('asset'::app.account_type,
                                    r.subtype::app.account_subtype);
    perform pg_temp.check_eq('default element for ' || r.subtype,
      v_got, r.element);
  end loop;

  -- An account created without a subtype still lands somewhere
  -- defensible rather than vanishing off the face of the statement.
  perform pg_temp.check_eq('no subtype, asset',
    app.fs_default_element('asset'::app.account_type, null::app.account_subtype), 'OtherCurrentAssets');
  perform pg_temp.check_eq('no subtype, liability',
    app.fs_default_element('liability'::app.account_type, null::app.account_subtype),
    'OtherCurrentLiabilities');
  perform pg_temp.check_eq('no subtype, equity',
    app.fs_default_element('equity'::app.account_type, null::app.account_subtype), 'Reserves');
  perform pg_temp.check_eq('no subtype, revenue',
    app.fs_default_element('revenue'::app.account_type, null::app.account_subtype), 'OtherIncome');
  perform pg_temp.check_eq('no subtype, expense',
    app.fs_default_element('expense'::app.account_type, null::app.account_subtype),
    'OtherOperatingExpenses');

  -- Every element the mapping names has to exist in the taxonomy, or
  -- the override's foreign key would refuse what the default happily
  -- produces.
  if exists (
    select 1 from unnest(enum_range(null::app.account_subtype)) s
     where app.fs_default_element('asset'::app.account_type, s) is not null
       and not exists (
         select 1 from public.mbrs_elements e
          where e.code = app.fs_default_element('asset'::app.account_type, s))
  ) then
    raise exception
      'FAIL: a subtype defaults to an element that is not in mbrs_elements';
  end if;

  raise notice 'mbrs: every subtype maps to an element that exists';
end $$;

rollback;
