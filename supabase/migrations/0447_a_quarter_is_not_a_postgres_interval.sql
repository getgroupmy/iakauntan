-- ---------------------------------------------------------------------
-- 0447  A quarter is not a Postgres interval
-- ---------------------------------------------------------------------
-- Two faults in nine lines, found by asking 0446's question of the date
-- arithmetic: which figures depend on where in a cycle you stand, and
-- do the assertions ever stand anywhere else?
--
-- `app.advance_schedule` built an interval by pasting a number to a
-- word:
--
--     (p_interval || ' ' || case p_frequency
--        when 'daily' then 'days' ... when 'quarterly' then 'quarters'
--        ... end)::interval
--
-- ### One: `quarterly` has never worked
--
-- Postgres has no `quarters` unit. `'1 quarters'::interval` raises
-- 22007, and it does so on a code path the app offers: the recurring
-- journal editor has a **Quarter** option in its dropdown, and
-- `recurring_documents_screen.dart` renders `quarterly` in its summary
-- line.
--
-- Measured end to end, through the real scheduler:
--
--     quarterly journal ran, 0 raised
--     last_error: invalid input syntax for type interval: "1 quarters"
--     next_run_date is still: 2026-01-31
--
-- And that is the worst part. `run_recurring_journals` catches the
-- failure, writes `last_error` and deliberately leaves `next_run_date`
-- alone so the run is retried — which is right for a transient fault
-- and wrong for one that will never stop happening. A quarterly
-- schedule fails every night, posts nothing, and says so only in a
-- column. Nobody's rent, accrual or retainer is raised, and nothing
-- shouts.
--
-- ### Two: monthly drifts off the end of the month
--
-- `date '2026-01-31' + interval '1 month'` is 2026-02-28, which is
-- correct. The next step adds a month to *that*, and 2026-02-28 + 1
-- month is 2026-03-28. Measured:
--
--     2026-01-31 -> 2026-02-28 -> 2026-03-28 -> 2026-04-28 -> ...
--
-- A tenancy invoiced on the last day of every month quietly becomes
-- the 28th of every month, for good, the first time it crosses
-- February. The 30th does the same through a leap February:
-- 2024-01-30 -> 02-29 -> 03-29 -> 04-29.
--
-- The cause is that the function advances from the previous occurrence
-- and so has no idea what day the schedule was meant to fall on. Once
-- a short month has clamped it, the intent is gone.
--
-- ### The fix
--
-- `make_interval` instead of a pasted string, so a unit that does not
-- exist is a compile-time impossibility rather than a runtime string;
-- a quarter is three months, which is what it has always been.
--
-- And an anchor. The function now takes the date the schedule started
-- and puts the result back on that day of the month, clamped to the
-- month's length — so 31 January goes to 28 February and then back to
-- 31 March, while the 15th stays the 15th and a fortnightly schedule
-- is untouched. Both callers have a `start_date` to hand.
--
-- The old three-argument function is dropped rather than left beside
-- the new one: a defaulted fourth argument would make every existing
-- call ambiguous.
--
-- ### Mutants
--
--   * `quarterly` mapped to one month -- killed by this migration's own
--     apply-time check, so it exercised no assertion. Narrowed to "only
--     a single quarter is three months", which the check still passes,
--     it was killed by "and two quarters are six", reading 2026-03-15;
--   * the anchor dropped once a short month had already moved the date
--     -- killed by the apply-time check again, which tests exactly that
--     step. So:
--   * February hard-coded at 28 days, which both checked cases avoid
--     because they land in March and April -- killed by "and
--     twenty-nine of it in a leap year";
--   * the anchor applied to weekly schedules as well -- killed by "a
--     fortnightly schedule is left alone", which snapped a 14-day step
--     onto the 28th.
--
-- Two of the four were caught by the guard rather than by an
-- assertion, which is the guard working and is not a test kill. Both
-- were rerun in a form the guard passes, and both then died on the
-- suite.
-- ---------------------------------------------------------------------

drop function if exists app.advance_schedule(date, text, integer);

create or replace function app.advance_schedule(
  p_from date,
  p_frequency text,
  p_interval integer,
  p_anchor date default null)
returns date
language plpgsql immutable
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_n      integer := greatest(coalesce(p_interval, 1), 1);
  v_next   date;
  v_day    integer;
  v_last   integer;
begin
  if p_from is null then return null; end if;

  v_next := case p_frequency
    when 'daily'     then p_from + make_interval(days   => v_n)
    when 'weekly'    then p_from + make_interval(weeks  => v_n)
    when 'monthly'   then p_from + make_interval(months => v_n)
    -- A quarter is three months. Postgres has no such unit, which is
    -- the whole of the first fault this migration fixes.
    when 'quarterly' then p_from + make_interval(months => v_n * 3)
    when 'yearly'    then p_from + make_interval(years  => v_n)
    else                  p_from + make_interval(months => v_n)
  end;

  -- Days and weeks have no day-of-month to preserve: a fortnightly
  -- schedule is every fourteen days and nothing else.
  if p_anchor is null or p_frequency in ('daily', 'weekly') then
    return v_next;
  end if;

  v_day  := extract(day from p_anchor)::integer;
  v_last := extract(day from
    (date_trunc('month', v_next::timestamp) + interval '1 month - 1 day')
  )::integer;

  -- The schedule's own day of the month, as far as this month goes.
  -- The 31st is the 28th in February and the 31st again in March,
  -- rather than being permanently rounded down by the first short
  -- month it meets.
  return (date_trunc('month', v_next::timestamp)
          + make_interval(days => least(v_day, v_last) - 1))::date;
end;
$fn$;

comment on function app.advance_schedule(date, text, integer, date) is
  'The next occurrence after p_from. Pass the schedule''s start date as '
  'p_anchor so a monthly schedule keeps its day of the month instead of '
  'drifting down to the 28th the first time it crosses February -- see '
  '0447.';

-- ---------------------------------------------------------------------
-- The callers, which both have a start date to anchor on
-- ---------------------------------------------------------------------
create or replace function app.run_recurring_journals(
  p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  r public.recurring_journals;
  v_n integer := 0;
begin
  for r in
    select * from public.recurring_journals
     where is_active
       and next_run_date is not null
       and next_run_date <= p_on
       and (end_date is null or next_run_date <= end_date)
  loop
    begin
      if r.auto_post then
        perform app.create_gl_entry_internal(
          p_org_id       => r.org_id,
          p_entry_date   => r.next_run_date,
          p_source       => 'recurring'::app.journal_source,
          p_lines        => r.template -> 'lines',
          p_description  => coalesce(r.description, r.name),
          p_source_table => 'recurring_journals',
          p_source_id    => r.id,
          p_reference    => r.name);
      end if;

      update public.recurring_journals
         set last_run_date = r.next_run_date,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count, r.start_date),
             last_error = null,
             last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      -- next_run_date is left alone, so it is retried once whatever is
      -- wrong has been put right.
      update public.recurring_journals
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
    end;
  end loop;
  return v_n;
end;
$fn$;

CREATE OR REPLACE FUNCTION app.advance_recurring_document(p_id uuid, p_on date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r public.recurring_documents;
  v_doc uuid;
  v_n integer := 0;
begin
  loop
    select * into r from public.recurring_documents where id = p_id;
    exit when not found;
    exit when not r.is_active;
    exit when r.next_run_date > p_on;
    exit when r.end_date is not null and r.next_run_date > r.end_date;
    exit when r.max_occurrences is not null and r.occurrences >= r.max_occurrences;
    exit when v_n >= 60;

    begin
      v_doc := app.raise_recurring_document(r.id, r.next_run_date);

      update public.recurring_documents
         set last_run_date = r.next_run_date,
             last_document_id = v_doc,
             occurrences = r.occurrences + 1,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count,
               r.start_date),
             -- A schedule that has produced everything it was asked for
             -- stops rather than sitting due forever.
             is_active = case
               when r.max_occurrences is not null
                    and r.occurrences + 1 >= r.max_occurrences then false
               else true end,
             last_error = null, last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      update public.recurring_documents
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
      raise warning 'recurring document % (%) skipped: %', r.name, r.id, sqlerrm;
      -- `next_run_date` is untouched, so leaving now is what makes this
      -- terminate rather than retrying the same failure forever.
      exit;
    end;
  end loop;

  return v_n;
end; $function$;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_doc text := pg_get_functiondef(
    to_regprocedure('app.advance_recurring_document(uuid, date)'));
  v_jnl text := pg_get_functiondef(
    to_regprocedure('app.run_recurring_journals(date)'));
begin
  if to_regprocedure('app.advance_schedule(date, text, integer)') is not null
  then
    raise exception '0447: the old three-argument advance_schedule remains';
  end if;

  if app.advance_schedule(date '2026-01-31', 'quarterly', 1, date '2026-01-31')
     <> date '2026-04-30' then
    raise exception '0447: a quarter is not three months';
  end if;

  if app.advance_schedule(date '2026-02-28', 'monthly', 1, date '2026-01-31')
     <> date '2026-03-31' then
    raise exception '0447: a monthly schedule still drifts';
  end if;

  -- Both callers have to pass the anchor, or the function is fixed and
  -- nothing uses the fix.
  if position('r.start_date' in v_doc) = 0 then
    raise exception '0447: the document scheduler passes no anchor';
  end if;
  if position('r.start_date' in v_jnl) = 0 then
    raise exception '0447: the journal scheduler passes no anchor';
  end if;
end
$do$;
