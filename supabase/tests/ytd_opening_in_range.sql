-- =====================================================================
-- iAkauntan :: the year an employee brings with them (0834)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ytd_opening_in_range.sql
--
-- What a joiner earned and paid elsewhere earlier in the year is read
-- by `app.calc_pcb` as it stands. Before `0834` a PCB typed as -600 put
-- RM200 a month on somebody's deductions, a gross typed as -30,000 took
-- their PCB to nothing, and a year typed as 26 was never read at all.
-- Asked as the owner with the role `authenticated`, as the HR screen
-- asks, and the PCB as the payroll run works it out.
--
-- Every bound is asked at its edge: the smallest step past it refused,
-- the edge itself taken.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_yo (org uuid, e uuid);
grant select on t_yo to authenticated;

-- July's PCB for somebody on RM5,000, as the run works it out.
create or replace function pg_temp.july_pcb()
returns numeric language plpgsql as $$
declare d t_yo; v numeric;
begin
  select * into d from t_yo;
  select pcb into v from app.calc_pcb(d.e, 5000, 550, 35, 0, date '2026-07-31');
  return v;
end $$;

do $$
declare r t_yo;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Pembuka Tahun Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'hr', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.employees (org_id, employee_no, full_name, hire_date,
    basic_salary, date_of_birth, marital_status, residency_status)
  values (r.org, 'J1', 'Joined in July', date '2026-07-01', 5000,
          date '1990-01-01', 'single', 'citizen')
  returning id into r.e;
  insert into t_yo select r.*;
  perform pg_temp.check_eq('with nothing brought in, July''s PCB',
    pg_temp.july_pcb(), 0.00);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_yo;
  r record;
begin
  select * into d from t_yo;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- The previous employer's EA form, as the screen saves it.
  insert into public.employee_ytd_opening (org_id, employee_id, tax_year,
    gross_pay, epf_employee, pcb_paid, zakat_paid, benefits_in_kind)
  values (d.org, d.e, 2026, 30000, 3300, 600, 0, 0);

  -- What was measured, and each figure on its own: the smallest step
  -- below nothing refused.
  for r in select * from (values
      ('gross_pay'), ('epf_employee'), ('pcb_paid'), ('zakat_paid'),
      ('benefits_in_kind')) as t(col)
  loop
    perform pg_temp.check_refused(format('its %s is not below nothing', r.col),
      format('update public.employee_ytd_opening set %s = -0.01 where employee_id = %L',
             r.col, d.e),
      format('new row for relation "employee_ytd_opening" violates check constraint "employee_ytd_opening_%s_not_negative_ck"%%', r.col),
      '23514');
  end loop;
  perform pg_temp.check_refused('nor is one made below nothing',
    format($q$insert into public.employee_ytd_opening (org_id, employee_id, tax_year, pcb_paid)
              values (%L, %L, 2025, -600)$q$, d.org, d.e),
    'new row for relation "employee_ytd_opening" violates check constraint "employee_ytd_opening_pcb_paid_not_negative_ck"%',
    '23514');

  -- Nothing at all is a figure.
  update public.employee_ytd_opening
     set gross_pay = 0, epf_employee = 0, pcb_paid = 0, zakat_paid = 0,
         benefits_in_kind = 0
   where employee_id = d.e;
  perform pg_temp.check_true('nothing is taken, for every figure',
    (select gross_pay = 0 and epf_employee = 0 and pcb_paid = 0
            and zakat_paid = 0 and benefits_in_kind = 0
       from public.employee_ytd_opening where employee_id = d.e));

  -- The year: two digits, and either side of the range, refused.
  for r in select * from (values (26), (1999), (2101)) as t(y) loop
    perform pg_temp.check_refused(format('a tax year of %s is refused', r.y),
      format('update public.employee_ytd_opening set tax_year = %s where employee_id = %L',
             r.y, d.e),
      'new row for relation "employee_ytd_opening" violates check constraint "employee_ytd_opening_tax_year_ck"%',
      '23514');
  end loop;
  update public.employee_ytd_opening set tax_year = 2000 where employee_id = d.e;
  update public.employee_ytd_opening set tax_year = 2100 where employee_id = d.e;
  perform pg_temp.check_eq('2000 and 2100 are taken',
    (select tax_year from public.employee_ytd_opening where employee_id = d.e), 2100);

  -- Back to the EA form's figures.
  update public.employee_ytd_opening
     set tax_year = 2026, gross_pay = 30000, epf_employee = 3300, pcb_paid = 600
   where employee_id = d.e;
end $$;

reset role;

-- The run reads the figures as they were saved.
do $$
declare d t_yo;
begin
  select * into d from t_yo;
  perform pg_temp.check_eq('July''s PCB on the EA form''s figures',
    pg_temp.july_pcb(), 117.90);
  -- A constraint, so the owner is held to it too.
  perform pg_temp.check_refused('the owner is not let through',
    format('update public.employee_ytd_opening set pcb_paid = -600 where employee_id = %L', d.e),
    'new row for relation "employee_ytd_opening" violates check constraint "employee_ytd_opening_pcb_paid_not_negative_ck"%',
    '23514');
end $$;

rollback;
