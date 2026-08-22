-- =====================================================================
-- iAkauntan :: 0279 the twenty-ninth is not the end of the month
--
-- ensure_pay_period decides a period's pay date, and its own comment
-- says what the rule is meant to be:
--
--   -- Day 0 means the last day of the month, and a pay day past the
--   -- end of a short month falls back to its last day.
--
-- The code does not do that. It clamps the day to 28 and then throws
-- the clamp away again:
--
--   v_pay := case when v_pay_day = 0 then v_end
--                 else least(make_date(y, m, least(v_pay_day, 28)), v_end)
--            end;
--   if v_pay_day between 29 and 31 then v_pay := v_end; end if;
--
-- so 29, 30 and 31 all become the last day of every month, not only of
-- the months too short to hold them. A company paying on the 29th is
-- paid on the 31st in January, March, May, July, August, October and
-- December.
--
-- The check constraint on payroll_settings.pay_day allows 0 to 31 and
-- `authenticated` holds INSERT and UPDATE on the table behind
-- app.can_run_payroll, so an owner, admin, HR manager or accountant can
-- set 29 through the API and the database will accept it. The setup
-- screen's dropdown offers only 0 and 1 to 28, so nothing reaches this
-- through the shipped UI today — which is why it has sat here since
-- 0037 rather than being noticed.
--
-- It is worth fixing rather than constraining away, because the pay
-- date is not decoration. app.age_at reads it for the sixty year
-- boundary that stops EPF employee contributions and EIS altogether,
-- app.calc_statutory reads it to choose the effective rate schedule,
-- and app.calc_pcb reads it to decide which month of the year is being
-- annualised. Two days is enough to move all three for somebody with a
-- birthday in the gap.
--
-- The replacement is the rule the comment describes, in one expression:
-- counting from the first of the month lands on the requested day, and
-- least() caps it at the month's end when the month is too short.
-- Tightening the constraint to 0..28 instead was the alternative, and
-- was rejected: it would reject rows that already exist.
-- =====================================================================

create or replace function public.ensure_pay_period(
  p_org_id uuid, p_year integer, p_month integer)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_uuid uuid;
  v_start date := make_date(p_year, p_month, 1);
  v_end date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_pay_day integer;
  v_pay date;
begin
  if not app.can_run_payroll(p_org_id) then
    raise exception 'Not permitted to manage payroll' using errcode = '42501';
  end if;

  select coalesce(pay_day, 25) into v_pay_day
    from public.payroll_settings where org_id = p_org_id;
  v_pay_day := coalesce(v_pay_day, 25);

  -- Day 0 means the last day of the month. Any other day is counted
  -- from the first, and capped at the month's end -- so the 29th is the
  -- 29th in January and the 28th in a February that has no 29th.
  v_pay := case when v_pay_day = 0 then v_end
                else least(v_start + (v_pay_day - 1), v_end) end;

  -- The period is keyed on (org_id, code) and is deliberately not
  -- rewritten when it already exists: a run may already have been
  -- calculated against this pay date, and moving it underneath would
  -- change every statutory figure the run computed. Changing the pay
  -- day affects the periods raised after it, not the ones already
  -- raised. The do-update is a no-op that exists so RETURNING fires.
  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (p_org_id, to_char(v_start, 'YYYY-MM'), v_start, v_end, v_pay)
  on conflict (org_id, code) do update set code = excluded.code
  returning id into v_uuid;

  return v_uuid;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function public.ensure_pay_period(uuid, integer, integer)
  to authenticated;
