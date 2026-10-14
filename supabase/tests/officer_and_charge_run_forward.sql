-- =====================================================================
-- iAkauntan :: an officer and a charge run forward (0897)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/officer_and_charge_run_forward.sql
--
-- The officer and charge sheets refuse a cessation before the
-- appointment, a lodgement or satisfaction before the charge was
-- created, and a memorandum before the satisfaction; the tables took
-- all four. Written as the owner with the role `authenticated`,
-- straight into the tables, as the sheets write.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cf (org uuid, e uuid, a uuid, officer uuid, charge uuid);
grant select on t_cf to authenticated;

do $$
declare r t_cf;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Urutan Tarikh Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'secretarial', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Urutan Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Pengarah A', '920415085566') returning id into r.a;
  insert into t_cf select r.*;
end $$;

set local role authenticated;

do $$
declare d t_cf; v_d date := pg_temp.today() - 30;
begin
  select * into d from t_cf;

  -- -------------------------------------------------------------------
  -- An officer
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an officer does not cease before being appointed',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on, resigned_on)
            values (%L, %L, %L, %L, %L, %L)', d.org, d.e, d.a, 'director', v_d, v_d - 1),
    '%corp_officers_ceased_after_appointed_ck%', '23514');
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.a, 'director', v_d) returning id into d.officer;
  perform pg_temp.check_refused('nor when the cessation is written later',
    format('update public.corp_officers set resigned_on = %L where id = %L', v_d - 1, d.officer),
    '%corp_officers_ceased_after_appointed_ck%', '23514');
  update public.corp_officers set resigned_on = v_d where id = d.officer;
  perform pg_temp.check_eq('one ceasing the day of appointment is kept',
    (select (resigned_on = appointed_on)::text from public.corp_officers where id = d.officer),
    'true');

  -- -------------------------------------------------------------------
  -- A charge
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a charge is not lodged before it was created',
    format('insert into public.corp_charges (org_id, entity_id, created_on, registered_on, chargee_name)
            values (%L, %L, %L, %L, %L)', d.org, d.e, v_d, v_d - 1, 'Bank'),
    '%corp_charges_lodged_after_created_ck%', '23514');
  perform pg_temp.check_refused('nor satisfied before it was created',
    format('insert into public.corp_charges (org_id, entity_id, created_on, satisfied_on, chargee_name)
            values (%L, %L, %L, %L, %L)', d.org, d.e, v_d, v_d - 1, 'Bank'),
    '%corp_charges_satisfied_after_created_ck%', '23514');
  perform pg_temp.check_refused('nor its memorandum filed before the satisfaction',
    format('insert into public.corp_charges (org_id, entity_id, created_on, satisfied_on,
              satisfaction_filed_on, chargee_name)
            values (%L, %L, %L, %L, %L, %L)', d.org, d.e, v_d, v_d + 5, v_d + 4, 'Bank'),
    '%corp_charges_memorandum_after_satisfied_ck%', '23514');
  insert into public.corp_charges (org_id, entity_id, created_on, registered_on,
    satisfied_on, satisfaction_filed_on, chargee_name)
  values (d.org, d.e, v_d, v_d, v_d, v_d, 'Bank') returning id into d.charge;
  perform pg_temp.check_eq('one lodged, satisfied and filed on the day it was created is kept',
    (select count(*) from public.corp_charges where id = d.charge)::int, 1);
  insert into public.corp_charges (org_id, entity_id, created_on, chargee_name)
  values (d.org, d.e, v_d, 'Bank Kedua');
  perform pg_temp.check_eq('and one with no dates beyond its creation',
    (select count(*) from public.corp_charges where entity_id = d.e)::int, 2);
end $$;

reset role;

rollback;
