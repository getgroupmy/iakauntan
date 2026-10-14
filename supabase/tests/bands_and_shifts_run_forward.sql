-- =====================================================================
-- iAkauntan :: a band and a shift run forward (0890)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bands_and_shifts_run_forward.sql
--
-- The leave-band dialog refuses a band that ends before it starts and
-- negative days, and the shift-assignment dialog an assignment that ends
-- before it starts; the tables took all three. Asked as the owner, with
-- the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bs (org uuid, lt uuid, emp uuid, ws uuid);
grant select on t_bs to authenticated;

do $$
declare r t_bs;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Jalur Hadapan Sdn Bhd');
  insert into public.leave_types (org_id, code, name, default_days, scales_with_service)
  values (r.org, 'AL', 'Annual', 8, true) returning id into r.lt;
  insert into public.employees (org_id, employee_no, full_name, hire_date)
  values (r.org, 'E1', 'Satu', date '2020-01-01') returning id into r.emp;
  insert into public.work_shifts (org_id, code, name, start_time, end_time)
  values (r.org, 'PG', 'Pagi', '09:00', '18:00') returning id into r.ws;
  insert into t_bs select r.*;
end $$;

set local role authenticated;

do $$
declare d t_bs;
begin
  select * into d from t_bs;

  -- -------------------------------------------------------------------
  -- Leave bands
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a band that ends before it starts is refused',
    format('insert into public.leave_entitlement_bands (leave_type_id, service_years_from, service_years_to, days) values (%L, 5, 2, 16)', d.lt),
    '%leave_entitlement_bands_years_ck%', '23514');
  perform pg_temp.check_refused('and one that starts before nought',
    format('insert into public.leave_entitlement_bands (leave_type_id, service_years_from, service_years_to, days) values (%L, -1, 2, 8)', d.lt),
    '%leave_entitlement_bands_years_ck%', '23514');
  perform pg_temp.check_refused('and a band of fewer than no days',
    format('insert into public.leave_entitlement_bands (leave_type_id, service_years_from, service_years_to, days) values (%L, 0, 1, -3)', d.lt),
    '%leave_entitlement_bands_days_ck%', '23514');

  insert into public.leave_entitlement_bands (leave_type_id, service_years_from, service_years_to, days)
  values (d.lt, 0, 1, 8), (d.lt, 2, 4, 12), (d.lt, 5, 5, 0), (d.lt, 6, null, 16);
  perform pg_temp.check_eq('bands that run forward are kept, a one-year band and an open one among them',
    (select string_agg(service_years_from || '..' || coalesce(service_years_to::text, '') || '=' || days, ' '
                       order by service_years_from)
       from public.leave_entitlement_bands where leave_type_id = d.lt),
    '0..1=8.00 2..4=12.00 5..5=0.00 6..=16.00');
  perform pg_temp.check_eq('and the third year reads its band, not the default',
    app.leave_entitlement((select lt from public.leave_types lt where lt.id = d.lt),
                          date '2020-01-01', 2023), 12.00);

  -- -------------------------------------------------------------------
  -- Shift assignments
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a shift assignment that ends before it starts is refused',
    format('insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from, effective_to) values (%L, %L, %L, %L, %L)',
           d.org, d.emp, d.ws, pg_temp.today(), pg_temp.today() - 30),
    '%employee_shifts_dates_ck%', '23514');
  insert into public.employee_shifts (org_id, employee_id, shift_id, effective_from, effective_to)
  values (d.org, d.emp, d.ws, pg_temp.today() - 30, pg_temp.today() - 30),
         (d.org, d.emp, d.ws, pg_temp.today(), null);
  perform pg_temp.check_eq('one ending the day it starts is kept, and an open one',
    (select count(*) from public.employee_shifts where employee_id = d.emp)::int, 2);
end $$;

reset role;

rollback;
