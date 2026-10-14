-- =====================================================================
-- iAkauntan :: a secretary is a resident of eighteen (0900)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/secretary_resident_of_eighteen.sql
--
-- Companies Act 2016 s.235: a company secretary is a natural person of
-- at least eighteen whose principal or only place of residence is in
-- Malaysia. Appointed as the owner with the role `authenticated`,
-- straight into the register, as the officer sheet writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_se (org uuid, e uuid, adult uuid, eighteen uuid, minor uuid,
  unknown uuid, company uuid, abroad uuid);
grant select on t_se to authenticated;

create or replace function pg_temp.se_person(p_org uuid, p_name text, p_kind text,
  p_born date, p_resident boolean default true)
returns uuid language sql as $$
  insert into public.corp_persons (org_id, kind, full_name, date_of_birth, registration_no,
                                   is_resident_in_malaysia)
  values (p_org, p_kind::app.corp_person_kind, p_name, p_born,
          case when p_kind = 'corporate' then '201901000002' end, p_resident)
  returning id;
$$;

do $$
declare r t_se; v_t date := pg_temp.today();
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Setiausaha Syarikat Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'secretarial', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Setiausaha Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.e;
  r.adult    := pg_temp.se_person(r.org, 'Setiausaha Dewasa', 'individual', date '1975-01-20');
  r.eighteen := pg_temp.se_person(r.org, 'Lapan Belas Hari Ini', 'individual',
                  (v_t - interval '18 years')::date);
  r.minor    := pg_temp.se_person(r.org, 'Belum Cukup Umur', 'individual',
                  (v_t - interval '18 years')::date + 1);
  r.unknown  := pg_temp.se_person(r.org, 'Tiada Tarikh Lahir', 'individual', null);
  r.company  := pg_temp.se_person(r.org, 'Syarikat Setiausaha Bhd', 'corporate', null);
  r.abroad   := pg_temp.se_person(r.org, 'Tinggal Di Luar', 'individual', date '1975-01-20', false);
  insert into t_se select r.*;
end $$;

set local role authenticated;

do $$
declare d t_se; v_t date := pg_temp.today();
begin
  select * into d from t_se;

  perform pg_temp.check_refused('a company is not appointed secretary',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
            values (%L, %L, %L, %L, %L)', d.org, d.e, d.company, 'secretary', v_t),
    'Syarikat Setiausaha Bhd is a company, and a secretary is a natural person (Companies Act 2016, s.235).',
    '23514');
  perform pg_temp.check_refused('nor somebody a day short of eighteen',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
            values (%L, %L, %L, %L, %L)', d.org, d.e, d.minor, 'secretary', v_t),
    format('Belum Cukup Umur was born on %s and is not yet eighteen on %s. A secretary must be at least eighteen (Companies Act 2016, s.235).',
           to_char((v_t - interval '18 years')::date + 1, 'DD Mon YYYY'), to_char(v_t, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_refused('nor somebody living abroad',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
            values (%L, %L, %L, %L, %L)', d.org, d.e, d.abroad, 'secretary', v_t),
    'Tinggal Di Luar is recorded as not resident in Malaysia, and a secretary''s principal or only place of residence is in Malaysia (Companies Act 2016, s.235).',
    '23514');

  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.adult, 'secretary', v_t),
         (d.org, d.e, d.eighteen, 'secretary', v_t),
         (d.org, d.e, d.unknown, 'secretary', v_t);
  perform pg_temp.check_eq('an adult, one eighteen today, and one with no birthday on file are appointed',
    (select count(*) from public.corp_officers where entity_id = d.e and role = 'secretary')::int, 3);

  -- Residence is the secretary's rule, not every director's: s.196(2)
  -- asks for one resident director, not that each be one.
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.abroad, 'director', v_t);
  perform pg_temp.check_eq('somebody living abroad may still be a director',
    (select count(*) from public.corp_officers
      where entity_id = d.e and role = 'director' and person_id = d.abroad)::int, 1);
  perform pg_temp.check_refused('but a director living abroad is not made secretary',
    format('update public.corp_officers set role = %L where person_id = %L and entity_id = %L',
           'secretary', d.abroad, d.e),
    'Tinggal Di Luar is recorded as not resident in Malaysia%', '23514');

  -- And a company still may audit.
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.company, 'auditor', v_t);
  perform pg_temp.check_eq('a company is still appointed auditor',
    (select count(*) from public.corp_officers
      where entity_id = d.e and role = 'auditor' and person_id = d.company)::int, 1);
end $$;

reset role;

rollback;
