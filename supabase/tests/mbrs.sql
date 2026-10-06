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
  -- 4: the exemption on these numbers
  --
  -- Under Practice Directive 3/2018 this company qualified on no ground:
  -- RM250,000 of revenue is over its RM100,000 ceiling. Its year
  -- commences 1 January 2025, so since 0751 it is tested under Practice
  -- Directive 10/2024, where revenue and total assets inside RM1m each
  -- are two of three -- and it qualifies, on that ground only. This is
  -- the change in one line: the old assertion said "audit required" of a
  -- company the Registrar no longer requires to be audited.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a small trading company qualifies on the threshold ground alone',
    (select string_agg(ground, ',') from public.fs_audit_exemption(v_filing) where qualifies),
    'threshold_qualified');

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
  v_2022 uuid; v_2023 uuid; v_2024 uuid; v_2025 uuid; r record;
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

  -- ------------------------------------------------------------------
  -- Zero revenue, which is not the same as dormant
  --
  -- The company above now has a transaction and still no revenue, which
  -- is exactly the second ground: no turnover in three years and total
  -- assets never above RM300,000. Its own ceiling had no test — raising
  -- it to half a million changed nothing anywhere — because the ground
  -- was only ever asserted negatively.
  -- ------------------------------------------------------------------
  select * into r from public.fs_audit_exemption(v_2025)
   where ground = 'zero_revenue';
  perform pg_temp.check_true('no revenue and small assets is the second ground',
    r.qualifies);

  -- Capital paid in, not turnover: revenue is still nil and the ground
  -- ends anyway, which is the whole point of the assets half of it.
  perform pg_temp.jv(v_org, 'JV-D2', date '2023-07-01', v_bank, v_cap, 400000);
  select * into r from public.fs_audit_exemption(v_2025)
   where ground = 'zero_revenue';
  perform pg_temp.check_true('assets over RM300,000 end it even with no revenue',
    not r.qualifies);
  perform pg_temp.check_true('and it says that was the ceiling',
    r.reason like '%RM300,000%');

  -- Threshold-qualified: small in all three years -- under Practice
  -- Directive 3/2018, which governs a financial year commencing before
  -- 1 January 2025. This fixture filed 2023 to 2025 until 0751 made
  -- the 2025 year Practice Directive 10/2024's, so it now files 2022 to
  -- 2024: the same ceilings, asserted in a year they still govern. The
  -- new directive has its own block below.
  v_org := pg_temp.mbrs_org('Probe MBRS Small');
  -- A year at a time: period control refuses a journal dated outside an
  -- open fiscal period, and this fixture spans three.
  perform public.create_fiscal_year(v_org, date '2022-01-01');
  perform public.create_fiscal_year(v_org, date '2023-01-01');
  perform public.create_fiscal_year(v_org, date '2024-01-01');
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
  perform pg_temp.jv(v_org, 'JV-S0', date '2022-01-02', v_bank, v_cap, 20000);
  perform pg_temp.jv(v_org, 'JV-S1', date '2022-06-30', v_bank, v_sales, 80000);
  perform pg_temp.jv(v_org, 'JV-S2', date '2022-07-31', v_exp, v_bank, 72000);
  perform pg_temp.jv(v_org, 'JV-S3', date '2023-06-30', v_bank, v_sales, 90000);
  perform pg_temp.jv(v_org, 'JV-S4', date '2023-07-31', v_exp, v_bank, 81000);
  perform pg_temp.jv(v_org, 'JV-S5', date '2024-06-30', v_bank, v_sales, 95000);
  perform pg_temp.jv(v_org, 'JV-S6', date '2024-07-31', v_exp, v_bank, 85500);

  -- A filing per year, because the headcount is a fact about each year
  -- and the test reads it off that year's own row.
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2022-01-01', date '2022-12-31', 'audit_exempt', 2)
  returning id into v_2022;
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2023-01-01', date '2023-12-31', 'audit_exempt', 4)
  returning id into v_2023;
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2024-01-01', date '2024-12-31', 'audit_exempt', 5)
  returning id into v_2024;

  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true(
    'under RM100k revenue, RM300k assets and five staff for three years',
    r.qualifies);

  -- Revenue over the ceiling in *one* of the three years ends it, and
  -- that year is deliberately the oldest — the one somebody checking
  -- only the current year would miss.
  perform pg_temp.jv(v_org, 'JV-S7', date '2022-09-30', v_bank, v_sales, 30000);
  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('one year over the ceiling ends it',
    not r.qualifies);
  perform pg_temp.check_true('and it says which ceiling',
    r.reason like '%RM100,000%');

  -- A missing headcount beside a revenue already over the ceiling: the
  -- revenue decides it, under a rule that needs all three, and 0751
  -- says so instead of "cannot tell".
  update public.fs_filings set employee_count = null where id = v_2023;
  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('a ceiling already crossed is said before a missing headcount',
    not r.qualifies and r.reason like '%RM100,000%');

  -- ------------------------------------------------------------------
  -- The other two ceilings
  --
  -- Everything above crosses the revenue ceiling and nothing crosses
  -- the other two, so until now the RM300,000 of assets and the five
  -- employees could both be changed to anything at all and this file
  -- still passed. Found by changing each and re-running.
  --
  -- Put the fixture back inside every ceiling first, so what follows
  -- crosses one at a time.
  -- ------------------------------------------------------------------
  perform pg_temp.jv(v_org, 'JV-S8', date '2022-09-30', v_sales, v_bank, 30000);
  -- Inside every ceiling, the missing headcount is the one that would
  -- decide, and that is "cannot tell".
  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('a missing headcount that would decide it is "cannot tell"',
    not r.qualifies and r.reason like 'Cannot tell%');
  update public.fs_filings set employee_count = 4 where id = v_2023;
  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('with the extra revenue reversed it qualifies again',
    r.qualifies);

  -- Six in one year. The ceiling somebody crosses by hiring rather
  -- than by trading, and the oldest year again, because that is the
  -- one a person checking only this year would miss.
  update public.fs_filings set employee_count = 6 where id = v_2022;
  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('six employees in one year ends it',
    not r.qualifies);
  perform pg_temp.check_true('and it says it was the headcount',
    r.reason like '%five employee ceiling%');
  update public.fs_filings set employee_count = 2 where id = v_2022;

  -- Assets over RM300,000, which the revenue ceiling cannot catch
  -- because this is capital paid in and not turnover.
  perform pg_temp.jv(v_org, 'JV-S9', date '2023-03-01', v_bank, v_cap, 400000);
  select * into r from public.fs_audit_exemption(v_2024)
   where ground = 'threshold_qualified';
  perform pg_temp.check_true('assets over the ceiling end it too',
    not r.qualifies);
  perform pg_temp.check_true('and it says which ceiling that was',
    r.reason like '%RM300,000%');

  raise notice 'mbrs: all three exemption grounds tested in both directions';
end $$;

-- ---------------------------------------------------------------------
-- Practice Directive 10/2024 (0751)
--
-- For a financial year commencing on or after 1 January 2025 the
-- threshold ground is ANY TWO of revenue, total assets and headcount,
-- within limits phased in by the year the financial year commences:
-- RM1m / RM1m / 10, then RM2m / RM2m / 20, then RM3m / RM3m / 30 from
-- 2027. The phase table is asserted at each boundary; the two-of-three
-- rule on a company that files its 2025 year, so every filing in
-- production when 0751 was written is the case under test.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  v_23 uuid; v_24 uuid; v_25 uuid; r record;
begin
  perform pg_temp.check_eq('a year commencing 31 December 2024 is still PD 3/2018',
    (select directive || ' ' || revenue || ' ' || staff || ' ' || any_two
       from app.audit_exemption_thresholds(date '2024-12-31')),
    'Practice Directive 3/2018 100000 5 false');
  perform pg_temp.check_eq('1 January 2025 opens the first phase',
    (select directive || ' ' || revenue || ' ' || assets || ' ' || staff || ' ' || any_two
       from app.audit_exemption_thresholds(date '2025-01-01')),
    'Practice Directive 10/2024 1000000 1000000 10 true');
  perform pg_temp.check_eq('and lasts to the end of 2025',
    (select revenue from app.audit_exemption_thresholds(date '2025-12-31')), 1000000);
  perform pg_temp.check_eq('a year commencing in 2026 is the second',
    (select revenue || ' ' || assets || ' ' || staff
       from app.audit_exemption_thresholds(date '2026-01-01')),
    '2000000 2000000 20');
  perform pg_temp.check_eq('and 2027 onwards the third',
    (select revenue || ' ' || assets || ' ' || staff
       from app.audit_exemption_thresholds(date '2027-01-01')),
    '3000000 3000000 30');
  perform pg_temp.check_eq('where it stays',
    (select revenue from app.audit_exemption_thresholds(date '2031-07-01')), 3000000);

  -- Revenue of about RM900,000 a year, spent down so total assets stay
  -- near RM100,000, and twelve staff -- over the first phase's ten. Two
  -- of three: it qualifies, which under PD 3/2018 it never could.
  v_org := pg_temp.mbrs_org('Probe PD 10 2024');
  perform public.create_fiscal_year(v_org, date '2023-01-01');
  perform public.create_fiscal_year(v_org, date '2024-01-01');
  perform public.create_fiscal_year(v_org, date '2025-01-01');
  v_bank  := pg_temp.acct(v_org, 'bank');
  v_cap   := pg_temp.acct(v_org, 'share_capital');
  v_sales := pg_temp.acct(v_org, 'sales');
  v_exp   := pg_temp.acct(v_org, 'operating_expense');
  perform pg_temp.jv(v_org, 'JV-P0', date '2023-01-02', v_bank, v_cap, 50000);
  perform pg_temp.jv(v_org, 'JV-P1', date '2023-06-30', v_bank, v_sales, 900000);
  perform pg_temp.jv(v_org, 'JV-P2', date '2023-07-31', v_exp, v_bank, 880000);
  perform pg_temp.jv(v_org, 'JV-P3', date '2024-06-30', v_bank, v_sales, 900000);
  perform pg_temp.jv(v_org, 'JV-P4', date '2024-07-31', v_exp, v_bank, 880000);
  perform pg_temp.jv(v_org, 'JV-P5', date '2025-06-30', v_bank, v_sales, 900000);
  perform pg_temp.jv(v_org, 'JV-P6', date '2025-07-31', v_exp, v_bank, 880000);
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2023-01-01', date '2023-12-31', 'audited', 12) returning id into v_23;
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2024-01-01', date '2024-12-31', 'audited', 12) returning id into v_24;
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'audit_exempt', 12) returning id into v_25;

  select * into r from public.fs_audit_exemption(v_25) where ground = 'threshold_qualified';
  perform pg_temp.check_true('revenue and assets within, headcount over: two of three qualifies',
    r.qualifies);
  perform pg_temp.check_true('and it names the directive and the two it met',
    r.reason like '%Practice Directive 10/2024%' and r.reason like '%revenue under RM1,000,000%'
    and r.reason like '%total assets under RM1,000,000%' and r.reason not like '%headcount%');

  -- The same company's 2024 year is PD 3/2018's, and fails it three ways.
  select * into r from public.fs_audit_exemption(v_24) where ground = 'threshold_qualified';
  perform pg_temp.check_true('its 2024 year is tested under the old directive, and fails',
    not r.qualifies and r.reason like '%RM100,000%');

  -- Revenue over RM1m in the OLDEST year: now one of three.
  perform pg_temp.jv(v_org, 'JV-P7', date '2023-09-30', v_bank, v_sales, 150000);
  perform pg_temp.jv(v_org, 'JV-P8', date '2023-10-31', v_exp, v_bank, 150000);
  select * into r from public.fs_audit_exemption(v_25) where ground = 'threshold_qualified';
  perform pg_temp.check_true('one of three is not enough',
    not r.qualifies);
  perform pg_temp.check_true('and it says what was over, and by how much',
    r.reason like '%revenue reached RM1,050,000 against RM1,000,000%'
    and r.reason like '%headcount reached 12 against 10%');

  -- Ten staff is within: assets and headcount make two.
  update public.fs_filings set employee_count = 10 where id in (v_23, v_24, v_25);
  select * into r from public.fs_audit_exemption(v_25) where ground = 'threshold_qualified';
  perform pg_temp.check_true('ten staff is within the first phase, and makes two again',
    r.qualifies and r.reason like '%headcount under 11%');

  -- With revenue over and assets within, the missing headcount decides.
  update public.fs_filings set employee_count = null where id = v_24;
  select * into r from public.fs_audit_exemption(v_25) where ground = 'threshold_qualified';
  perform pg_temp.check_true('a missing headcount that would decide it is "cannot tell"',
    not r.qualifies and r.reason like 'Cannot tell%');

  -- With revenue and assets both within, it does not matter.
  perform pg_temp.jv(v_org, 'JV-P9', date '2023-11-30', v_sales, v_bank, 150000);
  perform pg_temp.jv(v_org, 'JV-PA', date '2023-12-01', v_bank, v_exp, 150000);
  select * into r from public.fs_audit_exemption(v_25) where ground = 'threshold_qualified';
  perform pg_temp.check_true('and one that would not decide it does not stop it',
    r.qualifies);
end $$;

-- ---------------------------------------------------------------------
-- Practice Directive 10/2024, the edges (0751)
--
-- A sweep of 0751 left three mutants alive: the phase read from the
-- year's END rather than its commencement, revenue exactly on the limit
-- counted as over it, and "cannot tell" said of a headcount that could
-- not have changed the answer. One company each.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_bank uuid; v_cap uuid; v_sales uuid; v_exp uuid;
  v_f uuid; r record;
begin
  -- July 2024 to June 2025: COMMENCED in 2024, so PD 3/2018 governs,
  -- and RM250,000 of revenue is over its RM100,000 -- though the year
  -- ends in 2025, under the new directive it would have qualified.
  v_org := pg_temp.mbrs_org('Probe PD Edge July');
  perform public.create_fiscal_year(v_org, date '2024-07-01');
  v_bank := pg_temp.acct(v_org, 'bank'); v_cap := pg_temp.acct(v_org, 'share_capital');
  v_sales := pg_temp.acct(v_org, 'sales'); v_exp := pg_temp.acct(v_org, 'operating_expense');
  perform pg_temp.jv(v_org, 'JV-E1', date '2024-09-01', v_bank, v_sales, 250000);
  perform pg_temp.jv(v_org, 'JV-E2', date '2024-10-01', v_exp, v_bank, 240000);
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2024-07-01', date '2025-06-30', 'audited', 3) returning id into v_f;
  select * into r from public.fs_audit_exemption(v_f) where ground = 'threshold_qualified';
  perform pg_temp.check_true('a year that commenced in 2024 is the old directive''s, wherever it ends',
    not r.qualifies and r.reason like '%RM100,000%');

  -- Revenue of exactly RM1,000,000: "not exceeding" is within. Fifty
  -- staff, so revenue is one of the two it needs.
  v_org := pg_temp.mbrs_org('Probe PD Edge Million');
  perform public.create_fiscal_year(v_org, date '2025-01-01');
  v_bank := pg_temp.acct(v_org, 'bank'); v_cap := pg_temp.acct(v_org, 'share_capital');
  v_sales := pg_temp.acct(v_org, 'sales'); v_exp := pg_temp.acct(v_org, 'operating_expense');
  perform pg_temp.jv(v_org, 'JV-M1', date '2025-03-01', v_bank, v_sales, 1000000);
  perform pg_temp.jv(v_org, 'JV-M2', date '2025-04-01', v_exp, v_bank, 990000);
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'audit_exempt', 50) returning id into v_f;
  select * into r from public.fs_audit_exemption(v_f) where ground = 'threshold_qualified';
  perform pg_temp.check_true('revenue of exactly RM1,000,000 is within the limit',
    r.qualifies and r.reason like '%revenue under RM1,000,000%');

  -- Revenue and assets both over, headcount missing: nothing the
  -- headcount could be would make two, so the answer is no, not
  -- "cannot tell".
  v_org := pg_temp.mbrs_org('Probe PD Edge Large');
  perform public.create_fiscal_year(v_org, date '2025-01-01');
  v_bank := pg_temp.acct(v_org, 'bank'); v_cap := pg_temp.acct(v_org, 'share_capital');
  v_sales := pg_temp.acct(v_org, 'sales');
  perform pg_temp.jv(v_org, 'JV-L1', date '2025-01-02', v_bank, v_cap, 2000000);
  perform pg_temp.jv(v_org, 'JV-L2', date '2025-03-01', v_bank, v_sales, 1500000);
  insert into public.fs_filings (org_id, fy_start, fy_end, audit_status)
  values (v_org, date '2025-01-01', date '2025-12-31', 'audited') returning id into v_f;
  select * into r from public.fs_audit_exemption(v_f) where ground = 'threshold_qualified';
  perform pg_temp.check_true('a headcount that could not decide it is not "cannot tell"',
    not r.qualifies and r.reason not like 'Cannot tell%'
    and r.reason like '%Within 0 of the three limits%');
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

-- ---------------------------------------------------------------------
-- fs_lodge, rule by rule
--
-- A sweep of 0739's definition left six of nine mutants alive across
-- the four files that lodge accounts. Every one of them lodges ONCE, as
-- the owner of a company with the module, on frozen, circulated
-- accounts, with a reference that has no spaces round it -- and only
-- `mbrs.sql` asks what was stored, and only the opinion afterwards. So
-- each refusal and both stored values were rules no call could tell from
-- their absence.
--
-- The filing is written frozen directly: freezing is `fs_freeze`'s
-- business and has its own file, and a full set of accounts to get
-- there would be fixture standing in for the rule under test.
-- ---------------------------------------------------------------------
-- One filing per company per year, so each call names its year.
create or replace function pg_temp.frozen_filing(
  p_org uuid, p_year integer, p_status text default 'frozen',
  p_circulated date default date '2026-04-20')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.fs_filings
    (org_id, fy_start, fy_end, audit_status, status,
     directors_approval_date, circulated_on)
  values (p_org, make_date(p_year, 1, 1), make_date(p_year, 12, 31), 'audited',
          p_status::app.fs_filing_status,
          date '2026-04-15', p_circulated)
  returning id into v_id;
  return v_id;
end $$;

do $$
declare
  v_org    uuid := pg_temp.mbrs_org('Lodging Rules Sdn Bhd');
  v_owner  uuid := auth.uid();
  v_reader uuid := pg_temp.another_user('lodge-viewer@example.test');
  v_filing uuid;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_reader, 'viewer');

  v_filing := pg_temp.frozen_filing(v_org, 2025);
  perform pg_temp.sign_in_as(v_reader);
  perform pg_temp.check_refused('somebody who may only read cannot lodge',
    format('select public.fs_lodge(%L, %L, %L)', v_filing, 'MBRS-1', date '2026-05-02'),
    '%may not lodge%', '42501');
  perform pg_temp.sign_in_as(v_owner);

  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'mbrs';
  perform pg_temp.check_refused('nor can a company without the module',
    format('select public.fs_lodge(%L, %L, %L)', v_filing, 'MBRS-1', date '2026-05-02'),
    '%may not lodge%', '42501');
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'mbrs';

  perform pg_temp.check_refused('accounts still open are not lodged',
    format('select public.fs_lodge(%L, %L, %L)',
           pg_temp.frozen_filing(v_org, 2024, 'draft'), 'MBRS-1', date '2026-05-02'),
    '%Freeze the accounts%', '22023');
  perform pg_temp.check_refused('nor ones never sent to the members',
    format('select public.fs_lodge(%L, %L, %L)',
           pg_temp.frozen_filing(v_org, 2023, 'frozen', null), 'MBRS-1', date '2026-05-02'),
    '%went to the members first%', '22023');
  perform pg_temp.check_refused('a reference of spaces is no reference',
    format('select public.fs_lodge(%L, %L, %L)', v_filing, '   ', date '2026-05-02'),
    '%MBRS reference%', '22023');

  perform public.fs_lodge(v_filing, '  MBRS-2026-000777  ', date '2026-05-02');
  perform pg_temp.check_eq('lodged on the day it was lodged, not the day it was typed',
    (select lodged_on::text from public.fs_filings where id = v_filing), '2026-05-02');
  perform pg_temp.check_eq('the reference as mPortal gave it, without the spaces',
    (select mbrs_reference from public.fs_filings where id = v_filing),
    'MBRS-2026-000777');
  perform pg_temp.sign_out();
end $$;

rollback;
