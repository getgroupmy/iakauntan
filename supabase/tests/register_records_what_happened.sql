-- =====================================================================
-- iAkauntan :: a register records what has happened (0896)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/register_records_what_happened.sql
--
-- The secretarial sheets will not pick a day after today for the dates
-- a register records; the tables took any. Each such column is tried
-- with tomorrow, as the owner with the role `authenticated`, which is
-- how the sheets write -- straight into the table.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_rr (org uuid, e uuid, cls uuid, a uuid, b uuid, officer uuid);
grant select on t_rr to authenticated;

-- The refusal for one column, dated tomorrow.
create or replace function pg_temp.rr_refused(p_what text, p_sql text, p_label text)
returns void language plpgsql as $$
begin
  perform pg_temp.check_refused(p_what, p_sql,
    format('"%s" is %s, a day that has not come yet. A register records what has happened: enter it on the day it does.',
           p_label, to_char(pg_temp.today() + 1, 'DD Mon YYYY')),
    '23514');
end $$;

do $$
declare r t_rr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Daftar Hari Ini Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'secretarial', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Hari Ini Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.e;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (r.org, r.e, 'ORD', 'Ordinary') returning id into r.cls;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Ahli A', '920415085566') returning id into r.a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Ahli B', '850922105533') returning id into r.b;
  insert into t_rr select r.*;
end $$;

set local role authenticated;

do $$
declare d t_rr; v_t date := pg_temp.today(); v_n date := pg_temp.today() + 1;
begin
  select * into d from t_rr;

  -- -------------------------------------------------------------------
  -- Members
  -- -------------------------------------------------------------------
  perform pg_temp.rr_refused('a share movement is not dated tomorrow',
    format('insert into public.corp_share_events (org_id, entity_id, share_class_id,
              event_type, event_date, to_person_id, quantity)
            values (%L, %L, %L, %L, %L, %L, 900)', d.org, d.e, d.cls, 'allotment', v_n, d.b),
    'Date of the movement');
  insert into public.corp_share_events (org_id, entity_id, share_class_id,
    event_type, event_date, to_person_id, quantity)
  values (d.org, d.e, d.cls, 'allotment', v_t, d.a, 100);
  perform pg_temp.check_eq('one dated today is entered, and is the register',
    (select string_agg(r.member_name || '=' || r.shares::numeric(20, 0), ', ')
       from public.corp_register_of_members(d.e) r), 'Ahli A=100');

  -- -------------------------------------------------------------------
  -- Officers
  -- -------------------------------------------------------------------
  perform pg_temp.rr_refused('nor an appointment',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
            values (%L, %L, %L, %L, %L)', d.org, d.e, d.b, 'director', v_n),
    'Appointed on');
  perform pg_temp.rr_refused('nor the consent behind it',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on,
              consent_received_on)
            values (%L, %L, %L, %L, %L, %L)', d.org, d.e, d.b, 'director', v_t, v_n),
    'Consent received');
  perform pg_temp.rr_refused('nor the declaration',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on,
              declaration_received_on)
            values (%L, %L, %L, %L, %L, %L)', d.org, d.e, d.b, 'director', v_t, v_n),
    'Declaration received');
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on,
    consent_received_on, declaration_received_on)
  values (d.org, d.e, d.a, 'director', v_t, v_t, v_t) returning id into d.officer;
  perform pg_temp.rr_refused('nor a cessation, written later',
    format('update public.corp_officers set resigned_on = %L where id = %L', v_n, d.officer),
    'Ceased on');
  update public.corp_officers set resigned_on = v_t where id = d.officer;
  perform pg_temp.check_eq('an officer appointed and ceasing today is kept',
    (select (appointed_on = v_t and resigned_on = v_t)::text
       from public.corp_officers where id = d.officer), 'true');

  -- -------------------------------------------------------------------
  -- Charges
  -- -------------------------------------------------------------------
  perform pg_temp.rr_refused('nor a charge',
    format('insert into public.corp_charges (org_id, entity_id, created_on, chargee_name)
            values (%L, %L, %L, %L)', d.org, d.e, v_n, 'Bank'),
    'Created on');
  perform pg_temp.rr_refused('nor its lodgement',
    format('insert into public.corp_charges (org_id, entity_id, created_on, registered_on, chargee_name)
            values (%L, %L, %L, %L, %L)', d.org, d.e, v_t, v_n, 'Bank'),
    'Lodged with SSM');
  perform pg_temp.rr_refused('nor its satisfaction',
    format('insert into public.corp_charges (org_id, entity_id, created_on, satisfied_on, chargee_name)
            values (%L, %L, %L, %L, %L)', d.org, d.e, v_t, v_n, 'Bank'),
    'Satisfied on');
  perform pg_temp.rr_refused('nor the memorandum of it',
    format('insert into public.corp_charges (org_id, entity_id, created_on, satisfied_on,
              satisfaction_filed_on, chargee_name)
            values (%L, %L, %L, %L, %L, %L)', d.org, d.e, v_t, v_t, v_n, 'Bank'),
    'Memorandum filed');
  insert into public.corp_charges (org_id, entity_id, created_on, registered_on,
    satisfied_on, satisfaction_filed_on, chargee_name)
  values (d.org, d.e, v_t, v_t, v_t, v_t, 'Bank');

  -- -------------------------------------------------------------------
  -- Beneficial owners, and people
  -- -------------------------------------------------------------------
  perform pg_temp.rr_refused('nor a beneficial owner''s notification',
    format('insert into public.corp_beneficial_owners (org_id, entity_id, person_id,
              holds_20pc_shares, notified_on)
            values (%L, %L, %L, true, %L)', d.org, d.e, d.b, v_n),
    'Notified on');
  perform pg_temp.rr_refused('nor their cessation',
    format('insert into public.corp_beneficial_owners (org_id, entity_id, person_id,
              holds_20pc_shares, notified_on, ceased_on)
            values (%L, %L, %L, true, %L, %L)', d.org, d.e, d.b, v_t, v_n),
    'Ceased on');
  insert into public.corp_beneficial_owners (org_id, entity_id, person_id,
    holds_20pc_shares, notified_on, ceased_on)
  values (d.org, d.e, d.a, true, v_t, v_t);
  perform pg_temp.rr_refused('nor anybody born tomorrow',
    format('update public.corp_persons set date_of_birth = %L where id = %L', v_n, d.b),
    'Date of birth');
  update public.corp_persons set date_of_birth = v_t where id = d.b;

  perform pg_temp.check_eq('and the charge, the owner and the birthday dated today are kept',
    (select count(*) from public.corp_charges where entity_id = d.e)::text || ' '
    || (select count(*) from public.corp_beneficial_owners where entity_id = d.e)::text || ' '
    || (select (date_of_birth = v_t)::text from public.corp_persons where id = d.b),
    '1 1 true');
end $$;

reset role;

rollback;
