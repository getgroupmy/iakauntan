-- =====================================================================
-- iAkauntan :: the reliefs PCB is computed after, and the figures it
-- falls back on when the table does not carry them
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/pcb_reliefs_and_defaults.sql
--
-- A sweep of `app.calc_pcb` killed 36 of 52 one-line mutants. The
-- projection, the reliefs themselves, the children, the zakat, the
-- year-to-date and the bonus are all pinned.
--
-- WHAT WAS NOT PINNED IS EVERY FALLBACK. Six figures in this function
-- are written `coalesce(<what the table says>, <what the Act says>)`:
--
--     the EPF relief ceiling            4,000
--     the SOCSO and EIS relief ceiling    350
--     the spouse relief                 4,000
--     a disabled employee's own relief  6,000
--     a disabled spouse's relief        5,000
--     a non-resident's flat rate            0
--
-- Every fixture used the seeded LHDN table, which carries all of them —
-- so on every test the coalesce read its first argument and the second
-- was never reached. Each of those numbers could have been anything.
--
-- They are reached the moment a schedule is published without a row:
-- LHDN gazettes a table, a platform administrator publishes the bands
-- and not the reliefs, and from that day every resident's deduction is
-- computed after whatever these literals say. The right answer is the
-- Act's figure; the wrong one is silent and monthly.
--
-- This file publishes exactly that table — bands, one automatic
-- relief, and nothing else — and asks what an employee with a
-- non-working disabled spouse, a disability of their own and EPF and
-- SOCSO well past both ceilings is deducted. One number, 763.75,
-- carries all five ceilings: move any of them and it moves.
--
-- It also asks the three questions nothing else asked: whether a
-- relief marked NOT automatic is claimed anyway, whether last year's
-- declared relief is claimed this year, and whether the answer names
-- the table it was computed from.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid := pg_temp.test_org('Potongan Bulanan Sdn Bhd');
  v_sched uuid;
  v_emp   uuid;
  v_exp   uuid;
  v_pcb   numeric;
  v_id    uuid;
  v_ver   boolean;
begin
  -- ------------------------------------------------------------------
  -- A gazette published as bands and nothing else
  -- ------------------------------------------------------------------
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, is_verified)
  values ('pcb', 'Bands, and no reliefs beside them', 'table',
          date '2035-01-01', 'nearest_5sen', true)
  returning id into v_sched;

  -- One band, flat, so the arithmetic below is readable: ten per cent
  -- of whatever is chargeable, and no rebate at this income.
  insert into public.tax_brackets
    (schedule_id, chargeable_from, chargeable_to, rate_percent,
     cumulative_tax, sort_order)
  values (v_sched, 0, null, 10, 0, 1);

  -- The individual relief, and NOTHING else. No epf row, no socso_eis
  -- row, no spouse, no disabled_self, no disabled_spouse.
  insert into public.tax_reliefs
    (schedule_id, code, name, is_automatic, default_amount, sort_order)
  values (v_sched, 'individual', 'Individu', true, 9000, 1);

  -- And one an employee may declare but the payroll may not assume,
  -- so that the year of a declared relief can be asked about below.
  insert into public.tax_reliefs
    (schedule_id, code, name, is_automatic, default_amount, max_amount,
     applies_to, sort_order)
  values (v_sched, 'lifestyle', 'Gaya hidup', false, 0, 2500, 'manual', 2);

  -- ------------------------------------------------------------------
  -- Somebody every one of those five figures applies to
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status,
     residency_status, date_of_birth, marital_status, spouse_is_working,
     is_disabled, spouse_is_disabled, pcb_eligible)
  values (v_org, 'E-1', 'Encik Ismail', date '2020-01-01', 'active',
          'citizen', date '1985-03-01', 'married', false,
          true, true, true)
  returning id into v_emp;

  -- Ten thousand a month from January, so the year projects to 120,000;
  -- EPF of 1,100 a month projects to 13,200, well past the 4,000
  -- ceiling; SOCSO and EIS of 50 a month project to 600, well past 350.
  -- Both ceilings therefore BIND, which is what makes them observable:
  -- a ceiling that is never reached is a number that never matters.
  --
  --   projected            120,000
  --   individual             9,000  (the one automatic row)
  --   EPF, capped            4,000  ← the Act's ceiling, not the table's
  --   SOCSO and EIS, capped    350  ←
  --   spouse                 4,000  ←
  --   disabled, self         6,000  ←
  --   disabled, spouse       5,000  ←
  --                        --------
  --   chargeable            91,650
  --   tax at 10%             9,165
  --   over twelve months       763.75
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 1100, 50, 0, date '2035-01-15');
  perform pg_temp.check_eq(
    'the five statutory ceilings are the Act''s when the table is silent',
    v_pcb, 763.75);

  -- A RELIEF NOBODY CLAIMED IS NOT ONE THE PAYROLL MAY ASSUME.
  -- `is_automatic` is the whole of that rule, and with every relief on
  -- the seeded table marked automatic it decided nothing. Marked
  -- otherwise, the nine thousand comes off the reliefs and the
  -- deduction rises by a twelfth of a tenth of it.
  update public.tax_reliefs set is_automatic = false
   where schedule_id = v_sched and code = 'individual';
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 1100, 50, 0, date '2035-01-15');
  perform pg_temp.check_eq('a relief that is not automatic is not claimed',
    v_pcb, 838.75);
  update public.tax_reliefs set is_automatic = true
   where schedule_id = v_sched and code = 'individual';

  -- And the answer names the table it was computed from, which is what
  -- a payslip records and an auditor reads.
  select schedule_id, is_verified into v_id, v_ver
    from app.calc_pcb(v_emp, 10000, 1100, 50, 0, date '2035-01-15');
  perform pg_temp.check_eq('the deduction names the table behind it',
    v_id, v_sched);
  perform pg_temp.check_true('and says the table was checked', v_ver);

  -- ------------------------------------------------------------------
  -- Last year's declared relief is last year's
  -- ------------------------------------------------------------------
  insert into public.employee_tax_reliefs
    (org_id, employee_id, tax_year, relief_code, amount)
  values (v_org, v_emp, 2034, 'lifestyle', 2500);
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 1100, 50, 0, date '2035-01-15');
  perform pg_temp.check_eq('a relief declared for another year is not claimed',
    v_pcb, 763.75);

  -- This year's is, which is the other half of the same rule and says
  -- the assertion above is about the YEAR and not about the reliefs
  -- being ignored altogether.
  insert into public.employee_tax_reliefs
    (org_id, employee_id, tax_year, relief_code, amount)
  values (v_org, v_emp, 2035, 'lifestyle', 2500);
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 1100, 50, 0, date '2035-01-15');
  perform pg_temp.check_eq('and this year''s is',
    v_pcb, 742.90);

  -- ------------------------------------------------------------------
  -- A table with no rate for a non-resident
  -- ------------------------------------------------------------------
  -- The flat rate is `coalesce(<the table's rate>, 0)`. Nought is the
  -- only safe fallback: deducting at a guessed rate from somebody's pay
  -- is money taken that was never owed, and the alternative — deducting
  -- nothing until the table says otherwise — is recoverable at the
  -- assessment. The published table above has no `nonresident` row.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status,
     residency_status, date_of_birth, pcb_eligible)
  values (v_org, 'E-2', 'Mr Alvarez', date '2033-01-01', 'active',
          'expatriate', date '1980-01-01', true)
  returning id into v_exp;

  select pcb into v_pcb from app.calc_pcb(
    v_exp, 12000, 0, 0, 0, date '2035-01-15');
  perform pg_temp.check_eq('a table with no non-resident rate deducts nothing',
    v_pcb, 0);

  -- And with a rate on it, at thirty per cent to the nearest five sen —
  -- not to the ringgit, which would take an extra ninety-seven sen a
  -- month off somebody who cannot easily ask why.
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employee_rate, employer_rate)
  values (v_sched, 'nonresident', 0, 30, 0);
  select pcb into v_pcb from app.calc_pcb(
    v_exp, 1000.11, 0, 0, 0, date '2035-01-15');
  perform pg_temp.check_eq('the flat rate lands on the nearest five sen',
    v_pcb, 300.05);

  -- The bonus is part of the month for a flat rate: there is no
  -- projection to distort, so it is simply pay.
  select pcb into v_pcb from app.calc_pcb(
    v_exp, 1000.11, 0, 0, 0, date '2035-01-15', 999.89, 0);
  perform pg_temp.check_eq('and the bonus is taxed with the rest of the month',
    v_pcb, 600.00);

  -- ------------------------------------------------------------------
  -- A bonus that is not a bonus
  -- ------------------------------------------------------------------
  -- Both additional arguments are clamped at nought. A negative one
  -- would take the month's pay DOWN before the flat rate is applied —
  -- which is a deduction computed on a number the employee was never
  -- paid — and a negative EPF on it would inflate the relief.
  select pcb into v_pcb from app.calc_pcb(
    v_exp, 1000.11, 0, 0, 0, date '2035-01-15', -500, 0);
  perform pg_temp.check_eq('a negative bonus is not taken off the month',
    v_pcb, 300.05);
  -- The EPF on a bonus only matters where there IS a bonus, and only
  -- where the year's EPF has not already reached the ceiling: below it
  -- a negative would drag the relief down by its own size. So this one
  -- is asked with a real bonus and an employee whose EPF for the year
  -- comes to 2,400 against a 4,000 ceiling.
  --
  --   a thousand of bonus, taxed at ten per cent          100.00
  --   the month's own deduction                           756.25
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 200, 50, 0, date '2035-01-15', 1000, 0);
  perform pg_temp.check_eq('a bonus is taxed by the difference it makes',
    v_pcb, 856.25);
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 200, 50, 0, date '2035-01-15', 1000, -5000);
  perform pg_temp.check_eq('and a negative EPF on it buys no relief',
    v_pcb, 856.25);

  -- ------------------------------------------------------------------
  -- No table at all
  -- ------------------------------------------------------------------
  -- The one case where `false` is the honest answer: nothing was
  -- consulted, so nothing has been verified, and the payslip should say
  -- so rather than carry a silent nil.
  select pcb, schedule_id, is_verified into v_pcb, v_id, v_ver
    from app.calc_pcb(v_emp, 10000, 1100, 50, 0, date '1970-01-15');
  perform pg_temp.check_eq('a date before any table deducts nothing', v_pcb, 0);
  perform pg_temp.check_true('names no table', v_id is null);
  perform pg_temp.check_true('and does not claim to have been verified',
    not v_ver);

  -- ------------------------------------------------------------------
  -- The two clamps three surviving mutants lean on
  -- ------------------------------------------------------------------
  -- `greatest(v_projected - v_relief, 0)` and
  -- `greatest(v_tax - v_zakat_year, 0)` can both be removed without any
  -- deduction moving, because what they guard against is already
  -- refused downstream: `app.annual_tax` answers nought for anything
  -- chargeable at or below nought, and the month's figure leaves this
  -- function through a `greatest(..., 0)` of its own. They stay for
  -- what they say to a reader; what is asserted is the rule beneath
  -- them, so that removing THAT is a failing build.
  perform pg_temp.check_eq('nothing chargeable is nothing taxed',
    app.annual_tax(0, v_sched), 0);
  perform pg_temp.check_eq('and less than nothing is not a refund',
    app.annual_tax(-50000, v_sched), 0);
  -- Zakat larger than the year's tax leaves nothing owed rather than
  -- something owing back through the payslip.
  select pcb into v_pcb from app.calc_pcb(
    v_emp, 10000, 1100, 50, 100000, date '2035-01-15');
  perform pg_temp.check_eq('zakat past the tax leaves nothing to deduct',
    v_pcb, 0);
end $$;

rollback;
