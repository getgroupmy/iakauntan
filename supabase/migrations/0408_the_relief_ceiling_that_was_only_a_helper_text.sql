-- ---------------------------------------------------------------------
-- 0408  The relief ceiling that was only a helper text
-- ---------------------------------------------------------------------
--
-- An employee hands HR a TP1 and the company records what is on it.
-- `calc_pcb` then subtracts the lot from projected income before working
-- out the month's PCB:
--
--     select coalesce(sum(etr.amount), 0) into v_manual
--       from public.employee_tax_reliefs etr
--      where etr.employee_id = p_employee_id and etr.tax_year = v_year;
--     v_relief := v_relief + v_manual;
--
-- Every ringgit declared is a ringgit of chargeable income, and PCB is
-- money the employer withholds and remits. Under-withholding is the
-- employer's exposure, not the employee's.
--
-- `tax_reliefs.max_amount` carries the ceiling LHDN sets for each one --
-- RM3,000 on life insurance, RM2,500 on lifestyle, RM8,000 on medical
-- expenses for parents, RM7,000 on education fees. Until this migration
-- that column was read in exactly one place: a helper line under the
-- amount box, reading "LHDN allows up to RM3,000.00". Nothing refused an
-- amount above it, and `employee_tax_reliefs` carried no check at all --
-- not the ceiling, not a floor of zero, and not that `relief_code` names
-- a relief that exists:
--
--     relief_code | text          | not null
--     amount      | numeric(18,2) | not null default 0
--
-- `calc_pcb` sums the rows without looking at the code, so the code is
-- decorative to the arithmetic and the amount is the whole of it. That
-- makes the ceiling the only thing between a typed figure and an
-- arbitrary reduction of the tax withheld.
--
-- ## And the codes that are not the employee's to declare
--
-- The same sum is why an automatic relief must not appear in this table.
-- `calc_pcb` already works the individual allowance, EPF, SOCSO and EIS,
-- the spouse and the children out of the record the company holds --
-- `is_automatic` says which -- and then adds this table on top. A row
-- with `relief_code = 'individual'` claims RM9,000 that has already been
-- given, and neither half can see the other. Only the four the schedule
-- marks `applies_to = 'manual'` are the employee's to declare, which is
-- exactly the set the declaration screen was built to offer.
--
-- ## Which schedule's ceiling
--
-- A declaration is made for a whole tax year, so the schedule taken is
-- the one in force on 31 December of that year: the same one
-- `calc_pcb` reaches for on the year's last pay date, by the same
-- `app.statutory_schedule_on`. A schedule that changes mid-year is
-- therefore judged by the figures that end the year, and this is written
-- down rather than left to be inferred.
--
-- If there is no PCB schedule for that year at all, the trigger stands
-- aside. That is the same choice `0404` made for `app.calc_statutory` --
-- an absent schedule means no arithmetic to be wrong about, and refusing
-- HR data entry because the platform has not published a table yet
-- would be a worse answer than accepting it. `declared_reliefs.sql`
-- asserts the standing aside, so it is a decision and not an oversight.
--
-- ## Nothing had to be migrated
--
-- `employee_tax_reliefs` is empty on the hosted project -- not a row, in
-- any organization. That is not luck. The screen that declares a relief
-- fills its dropdown from `reliefTypes`, which asked PostgREST for
--
--     statutory_schedules?schedule_type=eq.pcb
--
-- and there is no `schedule_type` column; the body of a schedule is
-- `body`, an `app.statutory_body` enum. PostgREST answers 42703 and the
-- whole request fails, the provider's `valueOrNull ?? const []` turns
-- that into an empty list without a word, and `onPressed: types.isEmpty
-- ? null : ...` leaves the Add button greyed out forever. The feature
-- has been unreachable since it was built, which is why there is no data
-- to be embarrassed by and why the ceiling was never tested by use.
--
-- That half is fixed in the client, and `scripts/check_query_columns.py`
-- now refuses any column name the schema does not have, so the next one
-- fails in CI instead of in a browser.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The schedule a tax year is judged by
-- ---------------------------------------------------------------------
create or replace function app.pcb_schedule_for_year(p_tax_year integer)
returns public.statutory_schedules
language sql
stable
set search_path to 'public', 'pg_temp'
as $fn$
  select app.statutory_schedule_on('pcb', make_date(p_tax_year, 12, 31));
$fn$;

comment on function app.pcb_schedule_for_year(integer) is
  'The PCB schedule in force at the end of a tax year — the one '
  'calc_pcb uses for that year''s last pay date. Both the list of '
  'reliefs an employee may declare and the ceilings on them come from '
  'it, so the list offered and the rule enforced cannot disagree.';

-- ---------------------------------------------------------------------
-- The reliefs an employee may declare, and what each is capped at
-- ---------------------------------------------------------------------
--
-- The client had been picking the schedule itself, with a second copy of
-- the rule that left out `effective_to`. One rule, in one place, read by
-- both the screen and the trigger below.
create or replace function public.declarable_reliefs(p_tax_year integer)
returns table (code text, name text, max_amount numeric)
language sql
stable
set search_path to 'public', 'pg_temp'
as $fn$
  select r.code, r.name, r.max_amount
    from public.tax_reliefs r
   where r.schedule_id = (app.pcb_schedule_for_year(p_tax_year)).id
     and r.applies_to = 'manual'
     and not r.is_automatic
   order by r.sort_order, r.code;
$fn$;

comment on function public.declarable_reliefs(integer) is
  'The reliefs an employee may put on a TP1 for a tax year, with LHDN''s '
  'ceiling on each. Everything the company can work out for itself is '
  'excluded: calc_pcb applies those from the record it already holds, '
  'and a declared copy would be counted twice.';

-- ---------------------------------------------------------------------
-- The ceiling, enforced
-- ---------------------------------------------------------------------
create or replace function app.check_declared_relief()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_sched public.statutory_schedules;
  v_relief public.tax_reliefs;
begin
  if new.amount < 0 then
    raise exception
      'A declared relief cannot be a negative amount. % was given for %.',
      new.amount, new.relief_code
      using errcode = '23514';
  end if;

  v_sched := app.pcb_schedule_for_year(new.tax_year);
  if v_sched.id is null then
    -- No published PCB table for that year. `calc_pcb` returns zero in
    -- the same situation rather than raising, and refusing the
    -- declaration would take a working HR screen down with it.
    return new;
  end if;

  select * into v_relief
    from public.tax_reliefs r
   where r.schedule_id = v_sched.id and r.code = new.relief_code;

  if v_relief.id is null then
    raise exception
      '% is not a relief in the % PCB schedule. The reliefs that may be '
      'declared are the ones public.declarable_reliefs(%) lists.',
      new.relief_code, new.tax_year, new.tax_year
      using errcode = '23514';
  end if;

  if v_relief.is_automatic or v_relief.applies_to <> 'manual' then
    raise exception
      '% is worked out from the employee''s own record and applied '
      'automatically. Declaring it here would claim it a second time.',
      new.relief_code
      using errcode = '23514';
  end if;

  if v_relief.max_amount is not null and new.amount > v_relief.max_amount then
    raise exception
      'LHDN allows up to RM% on % for %. RM% was declared.',
      to_char(v_relief.max_amount, 'FM999G999G990D00'),
      new.relief_code, new.tax_year,
      to_char(new.amount, 'FM999G999G990D00')
      using errcode = '23514';
  end if;

  return new;
end
$fn$;

drop trigger if exists check_declared_relief on public.employee_tax_reliefs;
create trigger check_declared_relief
  before insert or update on public.employee_tax_reliefs
  for each row execute function app.check_declared_relief();

comment on function app.check_declared_relief() is
  'Refuses a declared relief that is negative, names a relief the year''s '
  'PCB schedule does not have, names one calc_pcb already applies '
  'automatically, or exceeds LHDN''s ceiling for it. Before 0408 the '
  'ceiling existed only as helper text under the amount box.';

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare
  v_bad int;
  v_manual int;
begin
  -- Nothing on the project violates the new rule, which is worth
  -- checking rather than asserting from the outside: a migration that
  -- installs a constraint the existing rows fail is a migration that
  -- cannot be applied twice.
  select count(*) into v_bad
    from public.employee_tax_reliefs e
    left join public.tax_reliefs r
      on r.schedule_id = (app.pcb_schedule_for_year(e.tax_year)).id
     and r.code = e.relief_code
   where (app.pcb_schedule_for_year(e.tax_year)).id is not null
     and (r.id is null
          or r.is_automatic
          or r.applies_to <> 'manual'
          or (r.max_amount is not null and e.amount > r.max_amount)
          or e.amount < 0);

  if v_bad > 0 then
    raise exception
      'FAIL 0408: % declared reliefs already break the rule this '
      'migration installs. They have to be settled with the employees '
      'they belong to before the trigger can go on.', v_bad;
  end if;

  -- And the trigger is actually attached. `create trigger` would have
  -- raised, but a later migration that drops the table and rebuilds it
  -- would not, and this is where that shows up.
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.employee_tax_reliefs'::regclass
       and t.tgname = 'check_declared_relief'
       and not t.tgisinternal)
  then
    raise exception 'FAIL 0408: the trigger did not attach';
  end if;

  -- The positive control. A rule that refuses everything satisfies every
  -- refusal assertion, so the thing to prove is that the four reliefs a
  -- TP1 actually carries are still offered. Four is what `0011` seeds
  -- for the 2023 schedule; the assertion is that there is a set at all
  -- rather than that it is exactly four, because the day LHDN adds a
  -- fifth this must not be what fails.
  select count(*) into v_manual
    from public.declarable_reliefs(extract(year from current_date)::integer);

  if v_manual = 0 and exists (select 1 from public.statutory_schedules
                               where body = 'pcb') then
    raise exception
      'FAIL 0408: a PCB schedule exists and not one relief may be '
      'declared against it -- the screen would offer an empty list, '
      'which is the defect this migration is here to close';
  end if;

  raise notice
    '0408: the ceiling is enforced; % reliefs may be declared this year',
    v_manual;
end
$do$;
