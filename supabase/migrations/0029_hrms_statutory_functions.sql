-- =====================================================================
-- iAkauntan :: 0029 hrms statutory functions
-- Applied as project migration 20260810054601.
-- =====================================================================

-- Rounding, as each authority states it.
create or replace function app.round_statutory(p_amount numeric, p_mode text)
returns numeric language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case p_mode
    when 'up_ringgit'   then ceil(p_amount)
    when 'nearest_5sen' then round(p_amount * 20) / 20
    else round(p_amount, 2)
  end;
$$;

create or replace function app.age_at(p_dob date, p_on date)
returns integer language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case when p_dob is null then 30
         else extract(year from age(p_on, p_dob))::integer end;
$$;

-- Which population an employee falls into for each authority.
create or replace function app.epf_category(
  p_residency app.residency_status, p_age integer)
returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case
    when p_residency in ('citizen', 'permanent_resident')
      then case when p_age >= 60 then 'citizen_60plus' else 'citizen_under60' end
      else case when p_age >= 60 then 'noncitizen_60plus' else 'noncitizen_under60' end
  end;
$$;

-- The schedule in force on a given date. Payroll always asks by pay date,
-- so re-running an old period keeps using the rules that applied then.
create or replace function app.statutory_schedule_on(
  p_body app.statutory_body, p_date date)
returns public.statutory_schedules language sql stable
set search_path = public, pg_temp as $$
  select s.* from public.statutory_schedules s
   where s.body = p_body
     and s.effective_from <= p_date
     and (s.effective_to is null or s.effective_to >= p_date)
   order by s.effective_from desc
   limit 1;
$$;

-- One contribution, employee and employer side, from the schedule in
-- force. A flat amount on the rate row wins over the percentage, which
-- is how EPF's flat employer contribution for some non-citizens is
-- expressed without needing a second mechanism.
create or replace function app.calc_statutory(
  p_body app.statutory_body,
  p_category text,
  p_wage numeric,
  p_date date
)
returns table (
  employee_amount numeric,
  employer_amount numeric,
  schedule_id uuid,
  is_verified boolean
)
language plpgsql stable
set search_path = public, app, pg_temp as $$
declare
  v_sched public.statutory_schedules;
  v_rate  public.statutory_rates;
  v_wage  numeric;
  v_ee    numeric := 0;
  v_er    numeric := 0;
begin
  v_sched := app.statutory_schedule_on(p_body, p_date);
  if v_sched.id is null or p_wage <= 0 then
    return query select 0::numeric, 0::numeric, null::uuid, false;
    return;
  end if;

  select * into v_rate
    from public.statutory_rates r
   where r.schedule_id = v_sched.id
     and r.category = p_category
     and p_wage >= r.wage_from
     and (r.wage_to is null or p_wage <= r.wage_to)
   order by r.wage_from desc
   limit 1;

  if v_rate.id is null then
    return query select 0::numeric, 0::numeric, v_sched.id, v_sched.is_verified;
    return;
  end if;

  -- Contributions stop counting wages above the insured ceiling.
  v_wage := least(p_wage, coalesce(v_rate.wage_ceiling, p_wage));

  -- KWSP rounds the wage up to the next RM20 before applying the rate.
  if v_sched.wage_round_up_to is not null and v_sched.wage_round_up_to > 0 then
    v_wage := ceil(v_wage / v_sched.wage_round_up_to) * v_sched.wage_round_up_to;
  end if;

  v_ee := coalesce(v_rate.employee_amount,
                   app.round_statutory(v_wage * v_rate.employee_rate / 100,
                                       v_sched.result_rounding));
  v_er := coalesce(v_rate.employer_amount,
                   app.round_statutory(v_wage * v_rate.employer_rate / 100,
                                       v_sched.result_rounding));

  return query select v_ee, v_er, v_sched.id, v_sched.is_verified;
end;
$$;

-- Progressive tax on an annual chargeable income, from the scale table.
create or replace function app.annual_tax(p_chargeable numeric, p_schedule_id uuid)
returns numeric language plpgsql stable
set search_path = public, pg_temp as $$
declare
  v_b public.tax_brackets;
  v_tax numeric;
begin
  if p_chargeable <= 0 then return 0; end if;

  select * into v_b
    from public.tax_brackets b
   where b.schedule_id = p_schedule_id
     and p_chargeable >= b.chargeable_from
   order by b.chargeable_from desc
   limit 1;

  if v_b.id is null then return 0; end if;

  -- Tax on the bands below, plus the marginal rate on what sits inside
  -- this one. floor() keeps to LHDN's practice of ignoring sen in the
  -- chargeable income before applying the rate.
  v_tax := v_b.cumulative_tax
         + (floor(p_chargeable) - floor(v_b.chargeable_from)) * v_b.rate_percent / 100;

  -- The rebate for small incomes.
  if p_chargeable <= 35000 then
    v_tax := v_tax - 400;
  end if;

  return greatest(round(v_tax, 2), 0);
end;
$$;

comment on function app.annual_tax is
  'Progressive income tax on an annual chargeable income. PCB is this figure spread over the remaining months, which is arithmetically what LHDN''s M/R/B table does.';
