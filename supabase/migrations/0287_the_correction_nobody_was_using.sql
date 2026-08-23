-- ---------------------------------------------------------------------
-- A corrected rate table, republished the same day, was ignored
--
-- `platform_publish_statutory_schedule` closes what it supersedes with
-- `effective_to = p_effective_from - 1`, and deliberately only for
-- schedules that started *earlier* — 0091's comment explains why: a
-- correction to the table currently in force must not be given an
-- effective_to before its own effective_from.
--
-- That much is right. What follows from it is not. 0091 also says
--
--     `statutory_schedule_on` resolves overlaps by taking the latest
--     start, so leaving the old one open would still calculate
--     correctly
--
-- and that only holds while the starts differ. Publish a correction at
-- the *same* effective_from and there are two open schedules with
-- identical starts; `order by s.effective_from desc limit 1` has no
-- tie-break, so the row that comes back is whichever the heap yields.
-- On the harness that is reliably the older one — the typo. Payroll
-- then goes on computing the figures the correction was published to
-- replace, and every screen reads the corrected table, so nothing looks
-- wrong anywhere.
--
-- A tie-break in the selector would hide it rather than fix it. There
-- are three selectors, not one: `app.statutory_schedule_on`,
-- `app.insured_wage`, and the HRDF rate lookup written out longhand
-- inside `calculate_payroll_run`. Any of them left alone stays wrong,
-- and a fourth written next year would be wrong again.
--
-- So the ambiguity is removed instead of resolved. Two schedules for
-- one body may not start on the same day — a unique index says so, for
-- every writer and not only this function — and republishing at a start
-- that is already taken replaces the schedule sitting there rather than
-- joining it.
--
-- Replacing means deleting: a table published and corrected before
-- anything used it was never in force for a day, and closing it at
-- `effective_from - 1` would record a window that ran backwards. Its
-- bands, brackets and reliefs cascade away with it.
--
-- Unless a payslip used it. Then the correction genuinely starts later
-- than the table it corrects, somebody has already been paid on the old
-- figures, and only the platform admin can say from when — so this
-- refuses, with 55006 (`object_in_use`) rather than the 23514 the rest
-- of the function raises, so a caller can tell the two apart.
-- ---------------------------------------------------------------------

create unique index if not exists statutory_schedules_one_start_per_body
  on public.statutory_schedules (body, effective_from);

create or replace function public.platform_publish_statutory_schedule(
  p_body text,
  p_name text,
  p_method text,
  p_effective_from date,
  p_rates jsonb,
  p_source text default null,
  p_notes text default null,
  p_wage_round_up_to numeric default null,
  p_result_rounding text default 'nearest_cent',
  p_is_verified boolean default false)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id    uuid;
  v_prior uuid;
  v_rate  jsonb;
  v_n     integer := 0;
begin
  if not app.is_platform_admin() then
    raise exception 'Statutory rates are shared by every organization and '
                    'may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if jsonb_typeof(p_rates) <> 'array' or jsonb_array_length(p_rates) = 0 then
    raise exception 'A schedule with no rates would calculate nothing'
      using errcode = '23514';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A schedule needs a name' using errcode = '23514';
  end if;
  if p_result_rounding not in ('nearest_cent', 'nearest_5sen', 'up_ringgit') then
    raise exception 'Unknown rounding mode %', p_result_rounding
      using errcode = '22023';
  end if;

  -- Close whatever this supersedes, but only schedules that started
  -- earlier: republishing a correction to the current table must not
  -- give it an effective_to before its own effective_from.
  update public.statutory_schedules
     set effective_to = p_effective_from - 1
   where body = p_body::app.statutory_body
     and effective_from < p_effective_from
     and (effective_to is null or effective_to >= p_effective_from);

  -- A schedule already starting on this day is the one being corrected.
  select id into v_prior
    from public.statutory_schedules
   where body = p_body::app.statutory_body
     and effective_from = p_effective_from;

  if v_prior is not null then
    if exists (select 1 from public.payslips ps
                where ps.epf_schedule_id   = v_prior
                   or ps.socso_schedule_id = v_prior
                   or ps.eis_schedule_id   = v_prior
                   or ps.pcb_schedule_id   = v_prior) then
      raise exception
        'Payslips were already calculated on the % table starting %. '
        'Publish the correction from the date it takes effect.',
        p_body, p_effective_from using errcode = '55006';
    end if;
    delete from public.statutory_schedules where id = v_prior;
  end if;

  insert into public.statutory_schedules
    (body, name, method, effective_from, wage_round_up_to,
     result_rounding, source, is_verified, notes)
  values (p_body::app.statutory_body, btrim(p_name),
          p_method::app.statutory_method, p_effective_from,
          p_wage_round_up_to, p_result_rounding,
          nullif(btrim(p_source), ''), coalesce(p_is_verified, false),
          nullif(btrim(p_notes), ''))
  returning id into v_id;

  for v_rate in select * from jsonb_array_elements(p_rates) loop
    v_n := v_n + 1;
    insert into public.statutory_rates
      (schedule_id, category, wage_from, wage_to,
       employee_rate, employer_rate, employee_amount, employer_amount,
       wage_ceiling, sort_order)
    values (
      v_id,
      coalesce(nullif(v_rate ->> 'category', ''), 'default'),
      coalesce((v_rate ->> 'wage_from')::numeric, 0),
      (v_rate ->> 'wage_to')::numeric,
      coalesce((v_rate ->> 'employee_rate')::numeric, 0),
      coalesce((v_rate ->> 'employer_rate')::numeric, 0),
      (v_rate ->> 'employee_amount')::numeric,
      (v_rate ->> 'employer_amount')::numeric,
      (v_rate ->> 'wage_ceiling')::numeric,
      coalesce((v_rate ->> 'sort_order')::integer, v_n));
  end loop;

  return v_id;
end;
$$;

revoke all on function public.platform_publish_statutory_schedule(
  text, text, text, date, jsonb, text, text, numeric, text, boolean)
  from public, anon, authenticated;
grant execute on function public.platform_publish_statutory_schedule(
  text, text, text, date, jsonb, text, text, numeric, text, boolean)
  to authenticated;
