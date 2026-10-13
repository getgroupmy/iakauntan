-- =====================================================================
-- iAkauntan :: 0863 a pay band is HR's
--
-- Everything in HR and payroll that says what somebody is paid asks
-- `app.can_manage_hr` or `app.can_run_payroll` -- employees, payslips,
-- year-to-date figures, requisitions, applicants. One table did not:
-- `positions`, read by every member (`is_org_member`), carries each
-- role's salary band in `min_salary` and `max_salary`.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated` (`can_manage_hr` false): "Finance Manager" at
-- 9,000 to 14,000. Production has no positions yet.
--
-- Answered "bands to HR only", as `0856` did for an account's balance.
-- RLS cannot hide a column and `authenticated` is one role, so:
--
--   * `authenticated` reads every column of `positions` but the two;
--     the title, grade and description stay everybody's -- an
--     employee's position is shown by name across the app;
--   * `position_salary_bands(org)`, a definer, gives the bands to a
--     member `can_manage_hr` admits and nothing to anybody else.
--
-- Writes are untouched: `positions_write` already asks `can_manage_hr`,
-- and insert and update privileges are not select.
-- =====================================================================

revoke select on public.positions from authenticated;
grant select (id, org_id, code, title, department_id, grade,
              job_description, is_active, created_at, import_source,
              import_ref, import_batch_id, imported_at)
  on public.positions to authenticated;

create or replace function public.position_salary_bands(p_org_id uuid)
returns table (position_id uuid, min_salary numeric, max_salary numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select p.id, p.min_salary, p.max_salary
    from public.positions p
   where p.org_id = p_org_id
     and app.can_manage_hr(p_org_id)
   order by p.title;
$$;

comment on function public.position_salary_bands(uuid) is
  'Each position''s salary band, for a member app.can_manage_hr admits, '
  'and nothing for anybody else. The columns themselves are withheld '
  'from authenticated. 0863.';

revoke all on function public.position_salary_bands(uuid) from public, anon;
grant execute on function public.position_salary_bands(uuid)
  to authenticated, service_role;
