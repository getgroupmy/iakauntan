-- The HR reference tables nobody could reach.
--
-- `public_holidays`, `leave_entitlement_bands`, `statutory_schedules`
-- and `statutory_rates` are all read by code that runs every month —
-- leave day counts, the rest-day and public-holiday classification in
-- attendance, and every statutory deduction on every payslip — and none
-- of them had a screen. The first two are empty. The last two are
-- seeded with `is_verified = false`, which `README.md` says must be
-- replaced with the gazetted KWSP and PERKESO tables before filing real
-- returns, and there was no way to do that either.
--
-- The four tables are not the same kind of thing, and this migration
-- treats them differently on purpose:
--
--   `public_holidays` and `leave_entitlement_bands` carry an
--   organization (the latter through its leave type) and are ordinary
--   per-tenant setup. RLS already allows `can_manage_hr` to write them,
--   so the app can use plain inserts; what is added here is only the
--   two things a person should not have to type from memory.
--
--   `statutory_schedules` and `statutory_rates` have no `org_id`. They
--   are one table shared by every tenant in the database, and their RLS
--   is `select true` with no write policy at all — deliberately, because
--   an EPF rate edited by one company would change every other
--   company's payroll. So they stay unwritable by `authenticated`, and
--   the two functions that change them check `app.is_platform_admin()`.

-- ---------------------------------------------------------------------
-- The public holidays nobody needs to look up
--
-- Only the four that are federal, observed in every state, and fall on
-- a fixed date. Malaysia's other holidays are either state-specific
-- (Thaipusam, the Sultans' birthdays) or lunar and gazetted each year
-- (Hari Raya Aidilfitri, Chinese New Year, Deepavali, Wesak, Awal
-- Muharram, Maulidur Rasul), and the Agong's birthday moves. Guessing
-- those from a formula would put wrong dates into attendance and leave
-- with no sign that they were guessed, so this offers the four it can
-- be sure of and leaves the rest to be entered from the gazette.
--
-- New Year's Day is deliberately not here: it is not observed in Johor,
-- Kedah, Kelantan, Perlis or Terengganu.
-- ---------------------------------------------------------------------
create or replace function public.add_fixed_public_holidays(
  p_org_id uuid, p_year integer)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_added integer := 0;
begin
  if not app.can_manage_hr(p_org_id) then
    raise exception 'Only HR may maintain the holiday calendar'
      using errcode = '42501';
  end if;
  if p_year < 2000 or p_year > 2100 then
    raise exception 'Year % is outside the range this calendar covers', p_year
      using errcode = '22023';
  end if;

  with fixed (holiday_date, name) as (
    values (make_date(p_year, 5, 1),   'Labour Day'),
           (make_date(p_year, 8, 31),  'National Day'),
           (make_date(p_year, 9, 16),  'Malaysia Day'),
           (make_date(p_year, 12, 25), 'Christmas Day')
  )
  insert into public.public_holidays (org_id, holiday_date, name)
  select p_org_id, f.holiday_date, f.name
    from fixed f
   where not exists (
     select 1 from public.public_holidays h
      where h.org_id = p_org_id and h.holiday_date = f.holiday_date
        and h.state_code is null);

  get diagnostics v_added = row_count;
  return v_added;
end;
$$;

-- ---------------------------------------------------------------------
-- The Employment Act minimums
--
-- Annual leave is section 60E(1) and sick leave section 60F(1) of the
-- Employment Act 1955. Both scale with completed service and both are
-- floors, not entitlements: a company may grant more and many do, which
-- is why this writes the bands rather than hard-coding them into the
-- calculation.
--
-- Sick leave's 60 days where hospitalisation is necessary is not a band
-- — it is an aggregate cap on a different footing, and putting it in
-- this table would hand 60 days a year to everybody.
--
-- Known wrinkle, left alone deliberately: `app.leave_entitlement`
-- measures service as `year - extract(year from hire_date)`, which is a
-- difference of calendar years rather than completed years, so somebody
-- hired in December crosses a band a few weeks early. Changing that
-- would move leave balances for every organization already using the
-- module, which is not something to do as a side effect of adding a
-- screen.
-- ---------------------------------------------------------------------
create or replace function public.apply_statutory_leave_bands(
  p_leave_type_id uuid, p_preset text)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org uuid;
  v_n   integer;
begin
  select lt.org_id into v_org
    from public.leave_types lt where lt.id = p_leave_type_id;
  if v_org is null then
    raise exception 'Leave type not found' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_org) then
    raise exception 'Only HR may set leave entitlement bands'
      using errcode = '42501';
  end if;
  if p_preset not in ('annual', 'sick') then
    raise exception 'Unknown preset %; expected annual or sick', p_preset
      using errcode = '22023';
  end if;

  -- Replaced wholesale rather than merged. A band table with one row
  -- from the Act and two somebody typed is worse than either.
  delete from public.leave_entitlement_bands
   where leave_type_id = p_leave_type_id;

  insert into public.leave_entitlement_bands
    (leave_type_id, service_years_from, service_years_to, days)
  select p_leave_type_id, b.from_years, b.to_years, b.days
    from (values
      (0, 1,    case p_preset when 'annual' then 8  else 14 end),
      (2, 4,    case p_preset when 'annual' then 12 else 18 end),
      (5, null, case p_preset when 'annual' then 16 else 22 end)
    ) as b (from_years, to_years, days);

  get diagnostics v_n = row_count;

  -- The bands are only consulted when the leave type says it scales.
  update public.leave_types
     set scales_with_service = true
   where id = p_leave_type_id and not scales_with_service;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- Publishing a statutory rate table
--
-- Platform admin only, and one function rather than a row editor: a
-- rate table is a document, not a set of independent rows. Editing
-- bands one at a time means a payroll run can read a half-updated EPF
-- table and produce numbers that were never anybody's rates.
--
-- Publishing also closes the schedule it supersedes. `statutory_schedule_on`
-- resolves overlaps by taking the latest start, so leaving the old one
-- open would still calculate correctly — and the table would say two
-- rate sets are in force at once, which is exactly the sort of thing
-- somebody checks at the wrong moment.
--
-- `p_body` and `p_method` are text and cast inside: the enums live in
-- the `app` schema, which PostgREST does not publish, so a client
-- cannot name them.
-- ---------------------------------------------------------------------
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
  v_id   uuid;
  v_rate jsonb;
  v_n    integer := 0;
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

-- Marking a schedule as checked against the gazette. Separate from
-- publishing because it is a different act by a different person: one
-- types the numbers, another confirms they match the source.
create or replace function public.platform_set_schedule_verified(
  p_schedule_id uuid,
  p_verified boolean,
  p_source text default null,
  p_notes text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Statutory rates are shared by every organization and '
                    'may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  update public.statutory_schedules
     set is_verified = coalesce(p_verified, false),
         source = coalesce(nullif(btrim(p_source), ''), source),
         notes  = coalesce(nullif(btrim(p_notes), ''), notes)
   where id = p_schedule_id;

  if not found then
    raise exception 'Schedule not found' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.add_fixed_public_holidays(uuid, integer)
  from public, anon;
grant execute on function public.add_fixed_public_holidays(uuid, integer)
  to authenticated;

revoke all on function public.apply_statutory_leave_bands(uuid, text)
  from public, anon;
grant execute on function public.apply_statutory_leave_bands(uuid, text)
  to authenticated;

revoke all on function public.platform_publish_statutory_schedule(
  text, text, text, date, jsonb, text, text, numeric, text, boolean)
  from public, anon;
grant execute on function public.platform_publish_statutory_schedule(
  text, text, text, date, jsonb, text, text, numeric, text, boolean)
  to authenticated;

revoke all on function public.platform_set_schedule_verified(uuid, boolean, text, text)
  from public, anon;
grant execute on function public.platform_set_schedule_verified(uuid, boolean, text, text)
  to authenticated;
