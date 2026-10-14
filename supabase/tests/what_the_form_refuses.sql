-- =====================================================================
-- iAkauntan :: what the form refuses, the database refuses (0885)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/what_the_form_refuses.sql
--
-- The departure form refuses a resignation dated after the last working
-- day, and the matter screen a negative hourly rate. Neither was the
-- database's rule: `record_departure` took the one, and filled it in
-- itself whenever a departure was recorded late, and `time_entries`
-- took the other. Asked as the owner, with the role `authenticated`,
-- as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_fr (org uuid, u uuid, late uuid, onday uuid,
  ahead uuid, sacked uuid, edited uuid, project uuid, te uuid);
grant select, update on t_fr to authenticated;

create or replace function pg_temp.fr_employee(p_org uuid, p_no text)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (p_org, p_no, 'Pekerja ' || p_no, date '2020-01-01', 4000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v;
  return v;
end $$;

-- What the record says about somebody leaving.
create or replace function pg_temp.fr_left(p_employee uuid)
returns text language sql as $$
  select coalesce(employment_status::text, '-') || ' resigned '
         || coalesce(resignation_date::text, '-') || ' last day '
         || coalesce(last_working_date::text, '-')
    from public.employees where id = p_employee;
$$;

do $$
declare r t_fr; v_c uuid;
begin
  r.u := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.u);
  r.org    := pg_temp.test_org('Borang Dan Pangkalan Sdn Bhd');
  r.late   := pg_temp.fr_employee(r.org, 'E1');
  r.onday  := pg_temp.fr_employee(r.org, 'E2');
  r.ahead  := pg_temp.fr_employee(r.org, 'E3');
  r.sacked := pg_temp.fr_employee(r.org, 'E4');
  r.edited := pg_temp.fr_employee(r.org, 'E5');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Klien', 'customer') returning id into v_c;
  insert into public.projects (org_id, code, name, contact_id)
  values (r.org, 'P-1', 'Projek', v_c) returning id into r.project;
  insert into t_fr select r.*;
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- A resignation is handed in on or before the last day
-- ---------------------------------------------------------------------
do $$
declare d t_fr;
begin
  select * into d from t_fr;
  perform pg_temp.check_refused('notice given after the last day is refused',
    format($q$select public.record_departure(%L, %L, 'resigned', 'Pindah', %L)$q$,
           d.late, pg_temp.today() - 30, pg_temp.today() - 10),
    'They cannot have given notice after they had already left%', '23514');
  perform pg_temp.check_eq('and nothing about them changed',
    pg_temp.fr_left(d.late), 'probation resigned - last day -');

  -- Recorded a month late with no date given: the latest they can have
  -- resigned is the day they left, not the day somebody typed it in.
  perform public.record_departure(d.late, pg_temp.today() - 30, 'resigned', 'Pindah');
  perform pg_temp.check_eq('a late entry with no date resigns them on their last day',
    pg_temp.fr_left(d.late),
    'resigned resigned ' || (pg_temp.today() - 30) || ' last day ' || (pg_temp.today() - 30));

  perform public.record_departure(d.onday, pg_temp.today() - 30, 'resigned', 'Pindah',
    pg_temp.today() - 30);
  perform pg_temp.check_eq('notice on the last day itself is accepted',
    pg_temp.fr_left(d.onday),
    'resigned resigned ' || (pg_temp.today() - 30) || ' last day ' || (pg_temp.today() - 30));

  perform public.record_departure(d.ahead, pg_temp.today() + 30, 'resigned', 'Pindah');
  perform pg_temp.check_eq('a departure still to come resigns them today, as before',
    pg_temp.fr_left(d.ahead),
    'notice resigned ' || pg_temp.today() || ' last day ' || (pg_temp.today() + 30));

  -- Only a resignation has a date to give. A termination's stray one is
  -- not read, so it is not refused either.
  perform public.record_departure(d.sacked, pg_temp.today() - 30, 'terminated', 'Salah laku',
    pg_temp.today());
  perform pg_temp.check_eq('a termination with a stray later date is recorded without it',
    pg_temp.fr_left(d.sacked),
    'terminated resigned - last day ' || (pg_temp.today() - 30));

  -- And an edit of the row itself, which HR may make, meets the same rule.
  perform public.record_departure(d.edited, pg_temp.today() - 30, 'resigned', 'Pindah',
    pg_temp.today() - 60);
  perform pg_temp.check_refused('an edit of the record cannot move notice past the last day',
    format('update public.employees set resignation_date = %L where id = %L',
           pg_temp.today() - 29, d.edited),
    '%employees_resignation_before_leaving_ck%', '23514');
  perform pg_temp.check_eq('so the record is as the departure left it',
    pg_temp.fr_left(d.edited),
    'resigned resigned ' || (pg_temp.today() - 60) || ' last day ' || (pg_temp.today() - 30));
end $$;

-- ---------------------------------------------------------------------
-- An hour is charged at nothing or more
-- ---------------------------------------------------------------------
do $$
declare d t_fr; v uuid;
begin
  select * into d from t_fr;
  perform pg_temp.check_refused('a negative hourly rate is refused',
    format($q$insert into public.time_entries
                (org_id, project_id, user_id, entry_date, description, minutes,
                 hourly_rate, is_billable)
              values (%L, %L, %L, %L, 'Muhibah', 600, -300, true)$q$,
           d.org, d.project, d.u, pg_temp.today()),
    '%time_entries_hourly_rate_ck%', '23514');

  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, is_billable)
  values (d.org, d.project, d.u, pg_temp.today(), 'Bina', 120, 300, true)
  returning id into v;
  update t_fr set te = v;
  perform pg_temp.check_eq('two hours at RM300 come to RM600, as before',
    (select amount from public.time_entries where id = v), 600.00);

  perform pg_temp.check_refused('nor is an entry''s rate taken below zero afterwards',
    format('update public.time_entries set hourly_rate = -1 where id = %L', v),
    '%time_entries_hourly_rate_ck%', '23514');

  -- Nothing is the rate that means "use the billing rate"; with none
  -- set, the hour is logged at nothing.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, is_billable)
  values (d.org, d.project, d.u, pg_temp.today(), 'Mesyuarat', 60, 0, true)
  returning id into v;
  perform pg_temp.check_eq('a rate of nothing is still logged',
    (select hourly_rate || '/' || amount from public.time_entries where id = v),
    '0.00/0.00');
end $$;

reset role;

rollback;
