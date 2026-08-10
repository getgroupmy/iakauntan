-- =====================================================================
-- iAkauntan :: 0042 hrms insured wage on payslip
-- Applied as project migration 20260810055907.
-- =====================================================================

-- The wage shown against SOCSO and EIS on a payslip should be the
-- insured wage the contribution was actually charged on, not the gross.
-- "SOCSO wage 12,000, contribution 30.00" invites a support call.
create or replace function app.insured_wage(
  p_body app.statutory_body, p_category text, p_wage numeric, p_date date)
returns numeric language plpgsql stable
set search_path = public, app, pg_temp as $$
declare
  v_ceiling numeric;
begin
  select r.wage_ceiling into v_ceiling
    from public.statutory_rates r
    join public.statutory_schedules s on s.id = r.schedule_id
   where s.body = p_body
     and r.category = p_category
     and s.effective_from <= p_date
     and (s.effective_to is null or s.effective_to >= p_date)
     and p_wage >= r.wage_from
     and (r.wage_to is null or p_wage <= r.wage_to)
   order by s.effective_from desc, r.wage_from desc
   limit 1;

  return least(p_wage, coalesce(v_ceiling, p_wage));
end;
$$;

-- Applied to the run that has already been calculated, and from now on
-- by the calculation itself.
update public.payslips p set
  socso_wage = app.insured_wage('socso',
    case when app.age_at(e.date_of_birth,
           (select pp.pay_date from public.payroll_runs r
              join public.pay_periods pp on pp.id = r.period_id
             where r.id = p.run_id)) >= 60
         then 'act800' else 'act4' end,
    p.socso_wage,
    (select pp.pay_date from public.payroll_runs r
       join public.pay_periods pp on pp.id = r.period_id where r.id = p.run_id)),
  eis_wage = app.insured_wage('eis', 'default', p.eis_wage,
    (select pp.pay_date from public.payroll_runs r
       join public.pay_periods pp on pp.id = r.period_id where r.id = p.run_id))
from public.employees e
where e.id = p.employee_id;
