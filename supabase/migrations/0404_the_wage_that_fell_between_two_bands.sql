-- =====================================================================
-- iAkauntan :: 0404 the wage that fell between two bands
--
-- `CLAUDE.md`: "Statutory arithmetic is asserted, not eyeballed.
-- Anything touching EPF, SOCSO, EIS, PCB or an SSM deadline needs a
-- test that would fail if the number moved." Zero is a number that
-- moved.
--
-- `app.calc_statutory` looks up the band a wage falls in:
--
--     select * into v_rate from public.statutory_rates r
--      where r.schedule_id = v_sched.id
--        and r.category = p_category
--        and p_wage >= r.wage_from
--        and (r.wage_to is null or p_wage <= r.wage_to)
--
--     if v_rate.id is null then
--       return query select 0::numeric, 0::numeric,
--                           v_sched.id, v_sched.is_verified;
--
-- A wage that matches no band contributes **nothing**, and the payslip
-- reports the schedule's own `is_verified` — so if the table has been
-- checked against the gazette, the payslip says the figures were
-- verified while the contribution is zero because the table had a hole
-- in it. `payslip_pdf.dart` prints its warning off exactly that flag,
-- so the one case that most needs a warning is the case that gets none.
--
-- ---------------------------------------------------------------------
-- Not a bug in today's data, and that is the reason to fix it now
--
-- Measured: every category in the seeded schedules ends in an
-- open-ended band —
--
--     epf   citizen_under60     0.00-5000.00, 5000.01-
--     epf   citizen_60plus      0.00-
--     epf   noncitizen_under60  0.00-
--     epf   noncitizen_60plus   0.00-
--     socso act4 / act800       0.00-        (ceiling 6000.00)
--     eis   default             0.00-        (ceiling 6000.00)
--     pcb   nonresident         0.00-
--     hrdf  mandatory_10plus / optional_5to9  0.00-
--
-- so no wage falls in a hole today. What creates one is the thing this
-- schema was built to have happen: `0026` seeded the rates from
-- published *percentages* and marked every schedule `is_verified =
-- false`, with `README.md` saying they must be transcribed from the
-- authority's gazetted table before anything is filed. The KWSP Third
-- Schedule *is* a table — a finite list of wage bands with a top row —
-- and a person transcribing it is a person typing a `wage_to` on the
-- last band. From that moment every employee above it contributes
-- nothing, on a schedule marked verified, with no warning anywhere.
--
-- SOCSO and EIS are worse: they carry a real ceiling and it is already
-- modelled properly (`wage_ceiling`, applied with `least`), so a
-- transcriber has two plausible ways to express the same rule and only
-- one of them is right. `wage_to = 6000` looks identical to
-- `wage_ceiling = 6000` on the page and means "nobody above RM6,000
-- contributes" instead of "contributions stop counting above RM6,000".
--
-- ---------------------------------------------------------------------
-- Two guards, at the two moments
--
-- **When the table is published.** `platform_publish_statutory_schedule`
-- is the only reachable writer — `authenticated` holds SELECT and
-- nothing else on `statutory_rates`, checked rather than assumed — so
-- the bands are validated there, in the same transaction that inserts
-- them. Every category must start at zero, run without gaps or
-- overlaps, and end open. A schedule that fails is not published.
--
-- **When a wage is calculated.** The publish-time check cannot see rows
-- a future migration inserts directly, and a statutory figure computed
-- from a table with a hole in it should not quietly be zero. So
-- `calc_statutory` raises instead, naming the body, the category and
-- the wage that fell through.
--
-- The two are not redundant. The first stops the hole existing; the
-- second is about what a payslip says when one exists anyway, and rows
-- can reach `statutory_rates` without going through the publisher --
-- `0026` seeded them with a plain insert and any migration can do the
-- same.
--
-- ---------------------------------------------------------------------
-- What is deliberately *not* changed
--
-- The amount stays zero. `statutory_schedules.sql` settled that on its
-- own terms -- "it contributes nothing rather than guessing at the
-- nearest band" -- and that reasoning holds: guessing at a statutory
-- figure is worse than declining to produce one, and the schedule
-- consulted is still recorded either way. Refusing outright was the
-- first draft of this migration and it would have overturned a decision
-- somebody had already taken and written down, to fix a problem that is
-- really about the third value rather than the first.
--
-- ---------------------------------------------------------------------
-- And a warning that was firing on the wrong payslip
--
-- The same function returns `false` for the verified flag whenever the
-- wage is zero:
--
--     if v_sched.id is null or p_wage <= 0 then
--       return query select 0::numeric, 0::numeric, null::uuid, false;
--
-- Those are two different situations sharing one answer. No schedule at
-- all is genuinely unverifiable and `false` is right. A wage of zero on
-- a perfectly good schedule is an employee who was on unpaid leave for
-- the month, and marking their payslip "the statutory figures on this
-- payslip have not been verified" is a false alarm printed on a
-- document that goes to a person. Split, so the zero-wage case reports
-- the schedule it actually used.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The bands of one schedule, per category
-- ---------------------------------------------------------------------
create or replace function app.assert_statutory_bands(p_schedule_id uuid)
returns void
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  r        record;
  v_cat    text := null;
  v_prev_to numeric := null;
  v_body   text;
  v_first  boolean := true;
begin
  select s.body::text into v_body
    from public.statutory_schedules s where s.id = p_schedule_id;

  for r in
    select category, wage_from, wage_to
      from public.statutory_rates
     where schedule_id = p_schedule_id
     order by category, wage_from
  loop
    if v_cat is distinct from r.category then
      -- The previous category has to have ended open. Checked here
      -- rather than after the loop so the message can still name it.
      if not v_first and v_prev_to is not null then
        raise exception
          'The % table stops at % for %. A wage above that would match '
          'no band and contribute nothing, on a schedule that says it '
          'was verified. If the intention is that contributions stop '
          'counting above a figure, that is `wage_ceiling` on the last '
          'band, not `wage_to` — leave `wage_to` empty so the band runs '
          'to the top.',
          v_body, v_prev_to, v_cat
          using errcode = '23514';
      end if;
      v_cat := r.category;
      v_prev_to := null;
      if r.wage_from > 0 then
        raise exception
          'The % table for % starts at % and nothing covers a wage below '
          'it. The first band must start at zero.',
          v_body, r.category, r.wage_from using errcode = '23514';
      end if;
    else
      if v_prev_to is null then
        raise exception
          'The % table for % has a band after one that already runs to '
          'the top. Only the last band may leave `wage_to` empty.',
          v_body, r.category using errcode = '23514';
      end if;
      if r.wage_from > v_prev_to + 0.01 then
        raise exception
          'The % table for % jumps from % to %. A wage in between would '
          'match no band and contribute nothing.',
          v_body, r.category, v_prev_to, r.wage_from
          using errcode = '23514';
      end if;
      if r.wage_from <= v_prev_to then
        raise exception
          'The % table for % has two bands covering %. Which one applies '
          'would depend on the order rows came back in.',
          v_body, r.category, r.wage_from using errcode = '23514';
      end if;
    end if;
    v_prev_to := r.wage_to;
    v_first := false;
  end loop;

  if v_first then
    raise exception 'The % schedule has no bands at all', v_body
      using errcode = '23514';
  end if;
  if v_prev_to is not null then
    raise exception
      'The % table stops at % for %. A wage above that would match no '
      'band and contribute nothing, on a schedule that says it was '
      'verified. If the intention is that contributions stop counting '
      'above a figure, that is `wage_ceiling` on the last band, not '
      '`wage_to` — leave `wage_to` empty so the band runs to the top.',
      v_body, v_prev_to, v_cat using errcode = '23514';
  end if;
end $$;

comment on function app.assert_statutory_bands(uuid) is
  'Every category in a statutory schedule must start at zero, run '
  'without gaps or overlaps, and end open. `0404`: a wage matching no '
  'band contributed nothing and the payslip still said the figures were '
  'verified.';

revoke all on function app.assert_statutory_bands(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The table that exists already has to pass
-- ---------------------------------------------------------------------
-- Before the guard is wired in, not after: a rule the current data
-- fails is a rule that was wrong about the data.
do $do$
declare r record;
begin
  for r in select id, body from public.statutory_schedules loop
    perform app.assert_statutory_bands(r.id);
  end loop;
  raise notice '0404: every seeded schedule covers every wage';
end
$do$;


-- ---------------------------------------------------------------------
-- Published tables are checked before they exist
-- ---------------------------------------------------------------------
-- `0091`'s function, unchanged except for the one call at the end. It
-- is the only writer an admin can reach: `authenticated` holds SELECT
-- and nothing else on `statutory_rates`, checked against the catalogue
-- rather than assumed.
CREATE OR REPLACE FUNCTION public.platform_publish_statutory_schedule(p_body text, p_name text, p_method text, p_effective_from date, p_rates jsonb, p_source text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_wage_round_up_to numeric DEFAULT NULL::numeric, p_result_rounding text DEFAULT 'nearest_cent'::text, p_is_verified boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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

  -- `0404`. In the same transaction that inserted them, so a schedule
  -- with a hole in it is never published rather than published and
  -- then found.
  perform app.assert_statutory_bands(v_id);

  return v_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- And a wage that falls through is an error, not a zero
-- ---------------------------------------------------------------------
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

  -- No table for this date. Nothing to compute and nothing to trust,
  -- which is the one case where `false` is the honest answer.
  if v_sched.id is null then
    return query select 0::numeric, 0::numeric, null::uuid, false;
    return;
  end if;

  -- A month of unpaid leave. There is nothing to contribute on, but the
  -- schedule is whatever it is -- reporting `false` here printed "the
  -- statutory figures on this payslip have not been verified" on a
  -- payslip whose schedules were fine.
  if p_wage <= 0 then
    return query select 0::numeric, 0::numeric, v_sched.id, v_sched.is_verified;
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

  -- The hole, and the one thing that changes about it.
  --
  -- The amount stays zero. `statutory_schedules.sql` decided that
  -- deliberately -- "it contributes nothing rather than guessing at the
  -- nearest band" -- and guessing at a statutory figure is worse than
  -- not producing one. The schedule it consulted is still named, for
  -- the reason that file gives: a payslip should record what was looked
  -- in even when the answer was nothing.
  --
  -- What was wrong was the third value. It handed back the schedule's
  -- own `is_verified`, so a table checked against the gazette but
  -- missing a band reported a zero contribution as a verified figure --
  -- and `payslip_pdf.dart` prints its warning off that flag, so the one
  -- payslip that most needed a warning was the one that got none.
  -- Nothing about a wage no table covers has been verified.
  if v_rate.id is null then
    return query select 0::numeric, 0::numeric, v_sched.id, false;
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

comment on function app.calc_statutory(app.statutory_body, text, numeric, date) is
  'A wage that matches no band still contributes nothing, but no longer '
  'reports the schedule''s is_verified with it. `0404`: a verified table '
  'with a missing band produced a zero contribution on a payslip that '
  'said the figures had been checked.';
