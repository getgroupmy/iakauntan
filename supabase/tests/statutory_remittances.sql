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
-- One clause in the report is deliberately not asserted, and could not
-- be: `sr.org_id = p_org_id` on the join to recorded payments. Since
-- `0502` no row can disagree with its period's company -- the composite
-- key refuses it, and a period id is unique to one company anyway -- so
-- there is no fixture that makes dropping the clause observable. It
-- stays because the join reads as an answer to "whose payment is this",
-- and because a defence that is currently redundant is the cheap half
-- of the pair.
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

  -- And every body with a federal deadline, not only the ones this
  -- company happens to owe. The assertion above reads the report, and
  -- the report answers for what has been recorded -- so the HRD Corp
  -- levy, which nothing in this fixture remits, sat outside it and its
  -- date could have moved unnoticed. Found by changing each due_day in
  -- turn and seeing which the suite failed to catch.
  perform pg_temp.check_eq('every federal deadline is the fifteenth after',
    (select count(*)::integer from public.ref_statutory_remittances body
      where body.due_day is not null
        and app.remittance_due(date '2026-01-31', body.code)
            is distinct from date '2026-02-15'), 0);

  -- The same over a pay date that is not in January. The assertion
  -- above cannot tell the month the wages were paid in from the year
  -- they were paid in: truncate a January date to the year and you get
  -- the same answer, so a function reading the wrong grain would pass
  -- it and put every remittance of 2026 in February. June says which.
  perform pg_temp.check_eq('and it follows the month the wages were paid in',
    (select count(*)::integer from public.ref_statutory_remittances body
      where body.due_day is not null
        and app.remittance_due(date '2026-06-30', body.code)
            is distinct from date '2026-07-15'), 0);

  -- December's salary paid in January is February's remittance, which
  -- is the sentence the function's own comment is written around: it
  -- reads the pay date, not the period the wages were earned in.
  perform pg_temp.check_true(
    'a December salary paid in January is remitted in February',
    app.remittance_due(date '2026-01-05', 'epf') = date '2026-02-15');

  -- The count as well, so a sixth body added later without a deadline
  -- of its own is noticed here rather than by whoever is late paying
  -- it. Five carry a date; zakat does not, and the block below says
  -- why.
  perform pg_temp.check_eq('five bodies carry one',
    (select count(*)::integer from public.ref_statutory_remittances
      where due_day is not null), 5);
end $$;

-- ---------------------------------------------------------------------
-- Zakat has no day, and is not coloured as though it had
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('zakat carries no federal deadline',
    (select due_day from public.ref_statutory_remittances
      where code = 'zakat') is null);

  -- The function opens with `case when r.due_day is null then null`,
  -- which is a shortcut rather than a guard: without it the arithmetic
  -- adds `due_day - 1` to a date and a null day makes the whole
  -- expression null anyway. A mutation sweep reports it as a survivor
  -- for that reason. The assertion stays because it states the rule a
  -- payroll clerk relies on, and it would catch somebody replacing the
  -- addition with something that is not null-safe.
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

-- ---------------------------------------------------------------------
-- Two months, and the window between them
-- ---------------------------------------------------------------------
-- What each body is owed, one figure at a time, and which month it
-- belongs to. Everything above this block asserts a single month, so
-- until now the from-date and the to-date had nothing to exclude and
-- the two halves of a contribution had nothing to be confused with.
do $$
declare
  v      record;
  v_p2   uuid;
  v_run  uuid;
  v_msg  text;
  v_them record;
  v_id   uuid;
  v_e    numeric;
  v_r    numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.paid_payroll('Kilang Dua Bulan Sdn Bhd',
                                            2026, 1, date '2026-01-31');
  perform pg_temp.allow_many_companies();

  -- February, paid on the twenty-eighth, for the same one employee.
  v_p2 := public.ensure_pay_period(v.org, 2026, 2);
  update public.pay_periods set pay_date = date '2026-02-28' where id = v_p2;
  v_run := public.create_payroll_run(v.org, v_p2, 'February');
  perform public.calculate_payroll_run(v_run);
  perform public.post_payroll_run(v_run);

  perform pg_temp.check_eq('two months of contributions are owed',
    (select count(distinct pay_date)::integer
       from public.report_statutory_remittances(v.org)), 2);

  -- ------------------------------------------------------------------
  -- What each body gets, and from whom
  -- ------------------------------------------------------------------
  -- RM 5,000 basic. KWSP takes 11 per cent from the employee and 13
  -- from the company; PERKESO takes 0.5 and 1.75. The two halves are
  -- different numbers and they go on different lines of a different
  -- form, so a report that has them the wrong way round is wrong in a
  -- way that adds up.
  select employee_amount, employer_amount into v_e, v_r
    from public.report_statutory_remittances(v.org)
   where code = 'epf' and pay_date = date '2026-01-31';
  perform pg_temp.check_eq('the employee''s eleven per cent to KWSP', v_e, 550.00);
  perform pg_temp.check_eq('and the company''s thirteen', v_r, 650.00);
  perform pg_temp.check_true('which are not the same figure', v_e <> v_r);

  select employee_amount, employer_amount into v_e, v_r
    from public.report_statutory_remittances(v.org)
   where code = 'socso' and pay_date = date '2026-01-31';
  perform pg_temp.check_eq('the employee''s half per cent to PERKESO', v_e, 25.00);
  perform pg_temp.check_eq('and the company''s one and three quarters', v_r, 87.50);

  -- PCB is withheld from the employee and paid over by the company, so
  -- it is the company's line on this list and never the employee's.
  perform pg_temp.check_eq('PCB is remitted by the company',
    (select employee_amount from public.report_statutory_remittances(v.org)
      where code = 'pcb' and pay_date = date '2026-01-31'), 0);
  perform pg_temp.check_true('and it is not nothing',
    (select employer_amount from public.report_statutory_remittances(v.org)
      where code = 'pcb' and pay_date = date '2026-01-31') > 0);

  -- ------------------------------------------------------------------
  -- The window
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('asked from February, January is not on the list',
    (select count(*)::integer
       from public.report_statutory_remittances(v.org, date '2026-02-01')
      where pay_date = date '2026-01-31'), 0);
  perform pg_temp.check_true('and February still is',
    (select count(*) from public.report_statutory_remittances(v.org, date '2026-02-01')
      where pay_date = date '2026-02-28') > 0);
  perform pg_temp.check_eq('asked to January, February is not',
    (select count(*)::integer
       from public.report_statutory_remittances(v.org, null, date '2026-01-31')
      where pay_date = date '2026-02-28'), 0);
  perform pg_temp.check_true('and January still is',
    (select count(*) from public.report_statutory_remittances(v.org, null, date '2026-01-31')
      where pay_date = date '2026-01-31') > 0);

  -- ------------------------------------------------------------------
  -- Paying it
  -- ------------------------------------------------------------------
  -- No date given is today, not nothing. A remittance with no date is
  -- a payment nobody can say was on time.
  v_id := public.record_statutory_remittance(v.org, v.period, 'epf', 1200.00);
  perform pg_temp.check_true('a payment with no date is dated today',
    (select paid_on = app.today() from public.statutory_remittances
      where id = v_id));
  perform pg_temp.check_true('and KWSP is no longer waiting for January',
    (select not is_overdue and paid_on is not null
       from public.report_statutory_remittances(v.org)
      where code = 'epf' and pay_date = date '2026-01-31'));

  -- Recording it again is a correction, not a second payment.
  perform public.record_statutory_remittance(
    v.org, v.period, 'epf', 1234.56, date '2026-02-14', 'KWSP/2026/01');
  perform pg_temp.check_eq('recording it again leaves one payment',
    (select count(*)::integer from public.statutory_remittances
      where org_id = v.org and period_id = v.period and code = 'epf'), 1);
  perform pg_temp.check_eq('for the corrected figure',
    (select amount from public.statutory_remittances
      where org_id = v.org and period_id = v.period and code = 'epf'), 1234.56);

  -- ------------------------------------------------------------------
  -- Somebody else's period
  -- ------------------------------------------------------------------
  -- The message matters as much as the refusal: the next guard down
  -- refuses this too, for saying the payroll is not posted, which sends
  -- somebody looking at the wrong company's payroll.
  select * into v_them from pg_temp.paid_payroll('Kilang Jiran Sdn Bhd',
                                                 2026, 1, date '2026-01-31');
  perform pg_temp.allow_many_companies();
  begin
    perform public.record_statutory_remittance(v.org, v_them.period, 'epf', 100);
    raise exception 'FAIL recorded a payment against another company''s period';
  exception when sqlstate '22023' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a period belonging to another company is refused as such',
      v_msg like '%No such pay period in this company%');
  end;

  -- And `0502`: the pair cannot be written by any route, not merely by
  -- the two functions that know to check.
  begin
    insert into public.statutory_remittances
      (org_id, period_id, code, amount, paid_on)
    values (v.org, v_them.period, 'epf', 100, date '2026-02-14');
    raise exception 'FAIL wrote a payment against another company''s period';
  exception when foreign_key_violation then
    raise notice 'ok   nor can such a row be written directly';
  end;
end $$;

rollback;
