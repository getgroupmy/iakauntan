-- =====================================================================
-- 0754 :: a retired employee has no next leave year
--
-- Answered on 6 October: "exclude retired".
--
-- `app.roll_leave_year` (0058) opens January's leave balances for
-- everybody whose status is not
--
--     ('resigned', 'terminated')
--
-- and `app.employment_status` has a third way to have gone: 'retired'.
-- Every other reader written since counts all three -- 0371's leaver
-- guard and `reinstate_employee`, 0388's permit sweep, 0419, and
-- `close_attendance_day` (0360). So a retired employee was given a
-- fresh year of entitlement and their unused days carried forward,
-- which a leave-liability figure reads as leave the company still owes.
--
-- Production had four employees, all active, when this was written, and
-- the next roll is 1 January 2027, so no balance was opened this way.
--
-- Only the status list changes. Grants survive a CREATE OR REPLACE --
-- 0407 took execute away from every client role, and that stands.
-- =====================================================================

create or replace function app.roll_leave_year(p_org_id uuid, p_year integer)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_type public.leave_types;
  v_emp  record;
  v_prev record;
  v_carry numeric;
  v_n integer := 0;
begin
  for v_type in
    select * from public.leave_types
     where org_id = p_org_id and is_active
  loop
    for v_emp in
      select e.id, e.hire_date from public.employees e
       where e.org_id = p_org_id
         -- The three ways to have gone, as everywhere else (0371).
         and e.employment_status not in ('resigned', 'terminated', 'retired')
    loop
      select * into v_prev from public.leave_balances b
       where b.employee_id = v_emp.id and b.leave_type_id = v_type.id
         and b.leave_year = p_year - 1;

      -- What is left over, capped by the type's own limit. A type with
      -- no limit set carries nothing: silently rolling everything
      -- forward is how leave liability grows unnoticed.
      v_carry := least(
        greatest(coalesce(v_prev.entitled_days, 0)
               + coalesce(v_prev.carried_forward, 0)
               + coalesce(v_prev.adjustment_days, 0)
               - coalesce(v_prev.taken_days, 0), 0),
        coalesce(v_type.max_carry_forward, 0));

      insert into public.leave_balances
        (org_id, employee_id, leave_type_id, leave_year,
         entitled_days, carried_forward)
      values (p_org_id, v_emp.id, v_type.id, p_year,
              app.leave_entitlement(v_type, v_emp.hire_date, p_year), v_carry)
      on conflict (employee_id, leave_type_id, leave_year) do nothing;

      if found then v_n := v_n + 1; end if;
    end loop;
  end loop;
  return v_n;
end; $$;
