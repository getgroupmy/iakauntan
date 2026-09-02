-- =====================================================================
-- iAkauntan :: the fifteenth of the month after
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statutory_remittances.sql
--
-- A posted payroll takes the money out of the company and leaves five
-- liabilities behind: KWSP, PERKESO twice, LHDN and HRD Corp. Before
-- 0457 the ledger held all five correctly and nothing ever mentioned
-- them again.
--
-- The date is the one thing here worth asserting one case at a time.
-- The fifteenth of the month following the month the wages were
-- **paid** -- a December salary paid in January is remitted in
-- February -- and a company that reads the period instead is a month
-- early all year and a month late once.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company with one employee and one posted payroll run.
create or replace function pg_temp.paid_payroll(
  p_name text, p_year integer, p_month integer, p_pay_date date default null)
returns table (org uuid, period uuid) language plpgsql as $$
declare v_org uuid; v_period uuid; v_run uuid;
begin
  v_org := pg_temp.test_org(p_name, array['hr', 'payroll']);
  perform public.create_fiscal_year(v_org, make_date(p_year, 1, 1));
  -- Posting reaches the ledger and the ledger will not take a date no
  -- fiscal period covers. A December payroll paid in January posts
  -- into the next year, which is the case this file exists to assert.
  if p_pay_date is not null
     and extract(year from p_pay_date)::integer <> p_year then
    perform public.create_fiscal_year(
      v_org, make_date(extract(year from p_pay_date)::integer, 1, 1));
  end if;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E1', 'Hafiz', make_date(p_year - 4, 1, 1), 5000,
          date '1990-01-01', 'citizen');

  v_period := public.ensure_pay_period(v_org, p_year, p_month);
  if p_pay_date is not null then
    update public.pay_periods set pay_date = p_pay_date where id = v_period;
  end if;

  v_run := public.create_payroll_run(v_org, v_period, 'Run');
  perform public.calculate_payroll_run(v_run);
  perform public.post_payroll_run(v_run);

  org := v_org; period := v_period;
  return next;
end;
$$;

-- ---------------------------------------------------------------------
-- What a posted payroll leaves owing
-- ---------------------------------------------------------------------
do $$
declare
  v   record;
  v_n integer;
  r   record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into v from pg_temp.paid_payroll('Kilang Caruman Sdn Bhd', 2026, 1);

  select count(*)::integer into v_n
    from public.report_statutory_remittances(v.org);
  perform pg_temp.check_true('a posted payroll owes somebody something',
    v_n > 0);

  -- EPF, both halves, and both of them non-zero for a citizen on
  -- RM5,000. A report that showed the employee half only would be the
  -- amount the company deducted, not the amount it has to send.
  select * into r from public.report_statutory_remittances(v.org)
   where code = 'epf';
  perform pg_temp.check_true('EPF is owed', r.total_amount > 0);
  perform pg_temp.check_true('by the employee', r.employee_amount > 0);
  perform pg_temp.check_true('and by the employer', r.employer_amount > 0);
  perform pg_temp.check_eq('and the total is the two together',
    r.total_amount, r.employee_amount + r.employer_amount);
  perform pg_temp.check_eq('to the body that collects it',
    r.authority, 'Kumpulan Wang Simpanan Pekerja');

  -- PCB is the employee's tax. The company remits it; it does not
  -- contribute to it, so an employee half would be double-counting.
  select * into r from public.report_statutory_remittances(v.org)
   where code = 'pcb';
  if r.code is not null then
    perform pg_temp.check_eq('the employer contributes nothing to PCB',
      r.employee_amount, 0);
  end if;

  -- A body that took nothing is not a line on a list of things to pay.
  perform pg_temp.check_true(
    'a body owed nothing is not on the list',
    not exists (select 1 from public.report_statutory_remittances(v.org) x
                 where x.total_amount = 0));
end $$;

-- ---------------------------------------------------------------------
-- The date, one case at a time
-- ---------------------------------------------------------------------
do $$
declare
  v record;
  r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- January wages, paid in January: due 15 February.
  select * into v from pg_temp.paid_payroll(
    'Kilang Januari Sdn Bhd', 2026, 1, date '2026-01-31');
  select * into r from public.report_statutory_remittances(v.org)
   where code = 'epf';
  perform pg_temp.check_eq('wages paid in January are remitted in February',
    r.due_date::text, '2026-02-15');

  -- December wages, paid on 5 January: due 15 February, not 15 January.
  -- This is the assertion that separates the pay date from the period.
  select * into v from pg_temp.paid_payroll(
    'Kilang Disember Sdn Bhd', 2025, 12, date '2026-01-05');
  select * into r from public.report_statutory_remittances(v.org)
   where code = 'epf';
  perform pg_temp.check_eq(
    'and December wages paid in January are too, not in January',
    r.due_date::text, '2026-02-15');

  -- Every statutory body on the same day, which is what makes the
  -- fifteenth worth remembering at all.
  perform pg_temp.check_eq('all of them fall on the same day',
    (select count(distinct x.due_date)::integer
       from public.report_statutory_remittances(v.org) x
      where x.due_date is not null), 1);
end $$;

-- ---------------------------------------------------------------------
-- Zakat has no day, and is not coloured as though it had
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('zakat carries no federal deadline',
    (select due_day from public.ref_statutory_remittances
      where code = 'zakat') is null);

  perform pg_temp.check_true('so no date is invented for it',
    app.remittance_due(date '2026-01-31', 'zakat') is null);

  -- And a body with no day can never be overdue, however long it sits.
  perform pg_temp.check_true('nor can it ever be reported late',
    app.remittance_due(date '2000-01-31', 'zakat') is null);
end $$;

-- ---------------------------------------------------------------------
-- Recording that one went
-- ---------------------------------------------------------------------
do $$
declare
  v      record;
  r      record;
  v_took boolean;
  v_amt  numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Paid over a year ago, so the deadline is long past.
  select * into v from pg_temp.paid_payroll(
    'Kilang Lewat Sdn Bhd', 2026, 1, (app.today() - interval '13 months')::date);

  select * into r from public.report_statutory_remittances(v.org)
   where code = 'epf';
  perform pg_temp.check_true('an unpaid contribution is overdue', r.is_overdue);
  perform pg_temp.check_true('and is chased',
    exists (select 1 from public.report_statutory_due(v.org, 3650) d
             where d.code = 'epf' and d.is_overdue));

  v_amt := r.total_amount;
  perform public.record_statutory_remittance(
    v.org, v.period, 'epf', v_amt, app.today(), 'KWSP/2026/001');

  select * into r from public.report_statutory_remittances(v.org)
   where code = 'epf';
  perform pg_temp.check_true('once sent it is not overdue', not r.is_overdue);
  perform pg_temp.check_eq('and the reference is kept',
    r.reference, 'KWSP/2026/001');
  perform pg_temp.check_true('and it stops being chased',
    not exists (select 1 from public.report_statutory_due(v.org, 3650) d
                 where d.code = 'epf'));

  -- The due date is stamped on the record, so a rule that changes next
  -- year does not rewrite what was true when the payment was made.
  perform pg_temp.check_true('the deadline it was measured against is kept',
    (select due_date from public.statutory_remittances
      where org_id = v.org and code = 'epf') is not null);

  -- SOCSO is still owed: recording one body's payment says nothing
  -- about another's.
  perform pg_temp.check_true('paying one body does not pay another',
    exists (select 1 from public.report_statutory_due(v.org, 3650) d
             where d.code = 'socso'));

  -- Nobody is owed anything called that.
  begin
    perform public.record_statutory_remittance(v.org, v.period, 'gst', 1);
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('a payment to nobody is refused', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- A draft payroll owes nobody anything yet
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_took   boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Draf Sdn Bhd', array['hr', 'payroll']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E1', 'Siti', date '2022-01-01', 5000,
          date '1990-01-01', 'citizen');
  v_period := public.ensure_pay_period(v_org, 2026, 1);
  v_run := public.create_payroll_run(v_org, v_period, 'Draft');
  perform public.calculate_payroll_run(v_run);

  -- Calculated, not posted. The figures exist and can still change, and
  -- nothing has been deducted from anybody.
  perform pg_temp.check_eq('a calculated run owes nobody yet',
    (select count(*)::integer
       from public.report_statutory_remittances(v_org)), 0);

  begin
    perform public.record_statutory_remittance(v_org, v_period, 'epf', 100);
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and cannot be recorded as remitted', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- Who may see any of it
-- ---------------------------------------------------------------------
do $$
declare
  v      record;
  v_seen uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into v from pg_temp.paid_payroll('Kilang Sulit Sdn Bhd', 2026, 1);

  -- What the company owes KWSP is derived from what it pays people,
  -- and a salesperson is not entitled to work backwards to that.
  v_seen := pg_temp.another_user('sales-0457@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v.org, v_seen, 'sales', 'active', now());
  perform pg_temp.sign_in_as(v_seen);

  perform pg_temp.check_eq('a salesperson sees no contributions',
    (select count(*)::integer
       from public.report_statutory_remittances(v.org)), 0);

  begin
    perform public.record_statutory_remittance(v.org, v.period, 'epf', 1);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('nor may they record one', not v_took);
end $$;

rollback;
