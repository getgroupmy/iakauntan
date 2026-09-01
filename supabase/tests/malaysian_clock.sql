-- =====================================================================
-- Malaysian time, everywhere the clock is read
--
-- `0305` pinned one function to `Asia/Kuala_Lumpur` and `0419` pinned
-- the other eighteen. What is asserted here is not eighteen dates. It
-- is the two things that, together, make the defect impossible:
--
--   1. `app.today()` gives Malaysia's day, and gives the same one
--      whoever asks; and
--   2. no STABLE function in `public` or `app` asks anybody else.
--
-- ## Why the property and not the value
--
-- `supabase/tests/secretarial.sql` gives the long version, and it is
-- the reason this file exists at all. A test that compares UTC against
-- Kuala Lumpur can only fail during the eight hours they differ: green
-- every morning, red every afternoon. The first person to see it red
-- would call the suite flaky and the second would delete it.
--
-- So the clock assertions below run under two session time zones
-- twenty-six hours apart. `Pacific/Kiritimati` is UTC+14 and
-- `Etc/GMT+12` is UTC-12, so they are never on the same date, at any
-- instant, on any day of the year. Anything reading the session clock
-- answers differently in the two; anything pinned answers the same.
-- No window, no flake.
--
-- ## How the defect was found, and what it cost
--
-- `supabase/tests/vacancies.sql` dates a requisition forty-five days
-- before the Malaysian today and asserts the report says forty-five. At
-- 02:02 in Kuala Lumpur it said forty-four, because it was still the
-- previous day in London and the report was reading London's clock.
--
-- The permit fixture below is the same bug where it costs the most.
-- `report_expiring_documents` exists to tell an HR manager that a
-- foreign worker's permit has run out -- it says `offence` rather than
-- `permit`, in those words, because employing somebody on an expired
-- one is an offence. For the eight hours of the Malaysian morning, a
-- permit that expired last night was reported as expiring today and
-- still in order.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The helper itself
-- ---------------------------------------------------------------------
do $$
declare
  v_east date; v_west date;
  v_vol  "char";
begin
  begin
    set local time zone 'Pacific/Kiritimati';
    v_east := app.today();
    set local time zone 'Etc/GMT+12';
    v_west := app.today();
  end;
  reset time zone;

  perform pg_temp.check_true(
    'today does not depend on who is asking',
    v_east = v_west);

  -- The control for the assertion above. If both calls somehow returned
  -- null it would pass on nulls being equal -- which they are not in
  -- SQL, but the shape is worth closing anyway.
  perform pg_temp.check_true('and it returned a date at all',
    v_east is not null);

  -- Weaker than the property above, and kept for what the property
  -- cannot reach: pinning to the *wrong* zone passes a
  -- caller-independence test perfectly. This catches that whenever
  -- Malaysia and the session differ, which is most of the day but not
  -- all of it. `0305` made the same call, in the same words.
  perform pg_temp.check_eq('and it is Malaysia''s day',
    app.today()::text,
    (now() at time zone 'Asia/Kuala_Lumpur')::date::text);

  -- STABLE, not IMMUTABLE. An IMMUTABLE app.today() would be folded at
  -- plan time and a prepared statement or a cached plan would go on
  -- returning the day it was planned on -- a subtler version of the
  -- same defect, and one that would only show up after midnight.
  select p.provolatile into v_vol
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'today';
  perform pg_temp.check_eq('and it is stable rather than immutable',
    v_vol::text, 's');
end $$;

-- ---------------------------------------------------------------------
-- The permit that ran out last night
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Kilang Masa Sdn Bhd');
  v_emp   uuid;
  v_east  jsonb;
  v_west  jsonb;
  v_row   record;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status)
  values (v_org, 'E1', 'Encik Ravi', date '2020-01-01', 3000,
          date '1990-01-01', 'foreign_worker', 'active')
  returning id into v_emp;

  -- Yesterday in Kuala Lumpur. Between midnight and eight in the
  -- morning there, UTC still calls this today.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_emp, 'permit', 'Work Permit',
          (now() at time zone 'Asia/Kuala_Lumpur')::date - 1);

  begin
    set local time zone 'Pacific/Kiritimati';
    select jsonb_agg(jsonb_build_object(
             'days', d.days_until, 'expired', d.is_expired,
             'consequence', d.consequence) order by d.document_id)
      into v_east from public.report_expiring_documents(v_org, 60) d;

    set local time zone 'Etc/GMT+12';
    select jsonb_agg(jsonb_build_object(
             'days', d.days_until, 'expired', d.is_expired,
             'consequence', d.consequence) order by d.document_id)
      into v_west from public.report_expiring_documents(v_org, 60) d;
  end;
  reset time zone;

  -- The control. Without it the two could be equal as nulls and this
  -- block would assert that the report returns nothing.
  perform pg_temp.check_true(
    'the fixture put a permit in front of the report',
    v_east is not null and jsonb_array_length(v_east) = 1);

  perform pg_temp.check_true(
    'an expired permit is expired whoever is asking',
    v_east = v_west);

  -- And the answer is the Malaysian one, not either extreme's.
  select * into v_row from public.report_expiring_documents(v_org, 60);
  perform pg_temp.check_eq('the permit ran out yesterday',
    v_row.days_until, -1);
  perform pg_temp.check_true('so it is expired', v_row.is_expired);
  perform pg_temp.check_eq(
    'and employing him on it is an offence, in those words',
    v_row.consequence, 'offence');
end $$;

-- ---------------------------------------------------------------------
-- The rule: nothing that only reads still reads the session's clock
--
-- This is what makes the nineteenth one loud. A new report that reaches
-- for `current_date` -- the obvious thing to reach for, and what every
-- one of the eighteen did -- turns this red before it reaches anybody's
-- screen.
--
-- The scan is confined to STABLE and IMMUTABLE functions on purpose.
-- The VOLATILE ones read the clock to stamp a date on a row they are
-- writing, and `0419` says at length why that is a separate migration:
-- the date a posting carries runs into fiscal period control and into
-- document numbers already issued. When that migration lands, this
-- predicate is the one to widen.
-- ---------------------------------------------------------------------
do $$
declare
  v_re    text := '(\mcurrent_date\M)|(\mlocaltimestamp\M)'
                  '|(\mcurrent_timestamp\M\s*::\s*date)'
                  '|(\mnow\M\s*\(\s*\)\s*::\s*date)';
  v_left  text[];
  v_seen  integer;
begin
  -- The pattern is asserted before it is trusted. A regex that matched
  -- nothing would pass the rule below by not doing anything, which is
  -- the failure mode a mechanical assertion has.
  perform pg_temp.check_true(
    'the pattern finds every way of asking the session what day it is',
    'select current_date + 1'          ~* v_re and
    'select localtimestamp'            ~* v_re and
    'select current_timestamp::date'   ~* v_re and
    'select now()::date'               ~* v_re and
    'select now() :: date'             ~* v_re);

  perform pg_temp.check_true(
    'and does not fire on the two correct ways of asking',
    'select app.today()' !~* v_re and
    'select (now() at time zone ''Asia/Kuala_Lumpur'')::date' !~* v_re);

  perform pg_temp.check_true(
    'nor on a column that merely starts the same way',
    'select current_date_of_birth from x' !~* v_re);

  -- The other half of the same worry: that the scan found no functions
  -- to look at. There are hundreds.
  select count(*) into v_seen
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app') and p.provolatile in ('s', 'i');
  perform pg_temp.check_true(
    'and there are functions to scan', v_seen > 100);

  select array_agg(n.nspname || '.' || p.proname order by 1)
    into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.provolatile in ('s', 'i')
     -- `0306` left the word in a comment in `module_dashboard`,
     -- explaining why it no longer reads it. That is not a defect.
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* v_re;

  perform pg_temp.check_eq(
    'no function that only reads asks the caller what day it is',
    coalesce(array_to_string(v_left, ', '), ''), '');
end $$;

rollback;
