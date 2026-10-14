-- =====================================================================
-- iAkauntan :: EPF for non-citizens from October 2025 (0906)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/epf_non_citizens_from_october_2025.sql
--
-- From October 2025 wages a non-Malaysian citizen employee pays 2% and
-- the employer 2%, at every age, directly on the wage, each share
-- rounded up to the ringgit (Third Schedule Part F). A member from
-- before 1 August 1998 keeps 11% and RM5. Before `0906` every
-- non-citizen was charged 11% and RM5 on a wage rounded up to RM20.
--
-- Against the SEEDED tables, because what is pinned is the figure a
-- payslip gets. The wages are chosen so that the RM20 step and the
-- direct calculation part company: RM1,741 is RM35 direct and RM36 on
-- RM1,760.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ep(p_cat text, p_wage numeric, p_on date)
returns text language sql as $$
  select c.employee_amount::text || ' / ' || c.employer_amount::text
    from app.calc_statutory('epf', p_cat, p_wage, p_on) c;
$$;

do $$
begin
  -- -------------------------------------------------------------------
  -- From October 2025: 2% and 2%, on the wage itself
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('KWSP''s own example: RM1,751 is RM36 a side',
    pg_temp.ep('noncitizen_under60', 1751, date '2025-10-31'), '36 / 36');
  perform pg_temp.check_eq('on the wage itself, not the next RM20: RM1,741 is RM35',
    pg_temp.ep('noncitizen_under60', 1741, date '2025-10-31'), '35 / 35');
  perform pg_temp.check_eq('a foreign worker on RM2,000 gives RM40, not RM220',
    pg_temp.ep('noncitizen_under60', 2000, date '2026-06-30'), '40 / 40');
  perform pg_temp.check_eq('and nothing changes at sixty',
    pg_temp.ep('noncitizen_60plus', 2000, date '2026-06-30'), '40 / 40');

  -- -------------------------------------------------------------------
  -- Before it: the old table, as it was
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('a September 2025 pay date reads the old table',
    pg_temp.ep('noncitizen_under60', 3000, date '2025-09-30'), '330 / 5.00');
  perform pg_temp.check_true('which ends the day before the new one starts',
    (app.statutory_schedule_on('epf', date '2025-09-30')).effective_to = date '2025-09-30'
    and (app.statutory_schedule_on('epf', date '2025-10-01')).effective_from = date '2025-10-01');

  -- -------------------------------------------------------------------
  -- The member from before August 1998: 11% and RM5, either side
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('a pre-1998 member keeps 11% and RM5',
    pg_temp.ep('noncitizen_pre1998_under60', 3000, date '2026-06-30'), '330 / 5.00');
  perform pg_temp.check_eq('and at sixty the employer''s RM5 alone',
    pg_temp.ep('noncitizen_pre1998_60plus', 3000, date '2026-06-30'), '0 / 5.00');
  perform pg_temp.check_eq('as they were before October 2025',
    pg_temp.ep('noncitizen_pre1998_under60', 3000, date '2025-09-30'), '330 / 5.00');

  -- -------------------------------------------------------------------
  -- A citizen: untouched, RM20 step and all
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('a citizen on RM5,001 still rounds up to RM5,020',
    pg_temp.ep('citizen_under60', 5001, date '2026-06-30'), '553 / 603');

  -- -------------------------------------------------------------------
  -- Who is filed where
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('a foreign worker is a non-citizen',
    app.epf_category('foreign_worker', 35, false), 'noncitizen_under60');
  perform pg_temp.check_eq('a member from before 1998 is filed apart',
    app.epf_category('expatriate', 35, true), 'noncitizen_pre1998_under60');
  perform pg_temp.check_eq('at sixty too',
    app.epf_category('foreign_worker', 60, true), 'noncitizen_pre1998_60plus');
  perform pg_temp.check_eq('the flag means nothing to a citizen',
    app.epf_category('citizen', 35, true), 'citizen_under60');
  perform pg_temp.check_eq('nor to a permanent resident',
    app.epf_category('permanent_resident', 61, true), 'citizen_60plus');
end $$;

-- ---------------------------------------------------------------------
-- On a payslip
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_period uuid; v_run uuid;
  v_new uuid; v_old uuid; v_pre uuid;
  r record;
begin
  v_org := pg_temp.test_org('Pekerja Asing Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-06', date '2026-06-01', date '2026-06-30', date '2026-06-30')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status)
  values (v_org, 'F1', 'Tran Thi Mai', date '2023-01-01', 1741,
          date '1995-04-01', 'single', 'foreign_worker', 'active')
  returning id into v_new;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status)
  values (v_org, 'F2', 'Kumar Raj', date '2010-01-01', 3000,
          date '1962-02-01', 'single', 'expatriate', 'active')
  returning id into v_old;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status,
     epf_pre_august_1998)
  values (v_org, 'F3', 'Hassan Ali', date '1996-01-01', 3000,
          date '1975-05-01', 'married', 'foreign_worker', 'active', true)
  returning id into v_pre;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-06') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips where run_id = v_run and employee_id = v_new;
  perform pg_temp.check_eq('the payslip of a foreign worker on RM1,741',
    r.epf_employee || ' / ' || r.epf_employer, '35.00 / 35.00');
  select * into r from public.payslips where run_id = v_run and employee_id = v_old;
  perform pg_temp.check_eq('an expatriate of sixty-four on RM3,000',
    r.epf_employee || ' / ' || r.epf_employer, '60.00 / 60.00');
  select * into r from public.payslips where run_id = v_run and employee_id = v_pre;
  perform pg_temp.check_eq('and a member from 1996 on the old terms',
    r.epf_employee || ' / ' || r.epf_employer, '330.00 / 5.00');
end $$;

-- ---------------------------------------------------------------------
-- A table published from the console keeps a band's own wage step
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user(); v_id uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin) on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  v_id := public.platform_publish_statutory_schedule(
    'epf', 'EPF, republished', 'percentage', date '2030-01-01',
    jsonb_build_array(
      jsonb_build_object('category', 'citizen_under60', 'employee_rate', 11, 'employer_rate', 12),
      jsonb_build_object('category', 'noncitizen_under60', 'employee_rate', 2, 'employer_rate', 2,
                         'wage_round_up_to', 0)),
    null, null, 20, 'up_ringgit', false);
  perform pg_temp.check_eq('a band published with its own step keeps it',
    pg_temp.ep('noncitizen_under60', 1741, date '2030-01-31'), '35 / 35');
  perform pg_temp.check_eq('and one published without keeps the table''s',
    pg_temp.ep('citizen_under60', 5001, date '2030-01-31'), '553 / 603');
end $$;

rollback;
