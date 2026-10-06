-- =====================================================================
-- 0753 :: an undated payslip is outside a bounded grant
--
-- Answered on 6 October: "outside bounded grants".
--
-- `app.covering_grant` (0047) decides whether an auditor's approved
-- request covers a payslip, and tested the request's period with
--
--     (r.period_from is null or p_pay_date is null
--      or p_pay_date >= r.period_from)
--
-- and the same for `period_to`. So a grant an administrator limited to
-- January ALSO covered every payslip whose `pay_date` is null -- the
-- bound was dropped exactly where nothing said which month the payslip
-- belonged to. Fail-open, on the most private table in the database.
--
-- `payslips.pay_date` is nullable. Payroll sets it, and production had
-- 36 payslips, none undated, and no access requests at all when this
-- was written, so nothing was ever read this way.
--
-- Now a period bound is a bound: a payslip with no pay date is outside
-- every grant that names a period, because `null >= x` is not true. A
-- grant with no period still covers it, as it covers everything else
-- its run and employee allow. Nothing else changes.
-- =====================================================================

create or replace function app.covering_grant(
  p_org_id uuid,
  p_run_id uuid,
  p_employee_id uuid,
  p_pay_date date
)
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select r.id from public.payslip_access_requests r
   where r.org_id = p_org_id
     and r.requested_by = auth.uid()
     and r.status = 'approved'
     and (r.expires_at is null or r.expires_at > now())
     and (r.run_id is null or r.run_id = p_run_id)
     and (r.employee_id is null or r.employee_id = p_employee_id)
     -- A payslip with no pay date is in no period, so outside any grant
     -- that names one.
     and (r.period_from is null or p_pay_date >= r.period_from)
     and (r.period_to is null or p_pay_date <= r.period_to)
   order by r.expires_at desc nulls last
   limit 1;
$$;
