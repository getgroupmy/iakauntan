-- =====================================================================
-- iAkauntan :: a director is a person of eighteen (0899)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/director_of_eighteen.sql
--
-- Companies Act 2016 s.196(1)(a): a director is a natural person who
-- has attained eighteen. Nothing asked. Appointed as the owner with the
-- role `authenticated`, straight into the register, as the officer
-- sheet writes.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_de (org uuid, e uuid, adult uuid, eighteen uuid, minor uuid,
  unknown uuid, company uuid, principal uuid);
grant select on t_de to authenticated;

create or replace function pg_temp.de_person(p_org uuid, p_name text, p_kind text,
  p_born date)
returns uuid language sql as $$
  insert into public.corp_persons (org_id, kind, full_name, date_of_birth, registration_no)
  values (p_org, p_kind::app.corp_person_kind, p_name, p_born,
          case when p_kind = 'corporate' then '201901000001' end)
  returning id;
$$;

do $$
declare r t_de; v_t date := pg_temp.today();
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Lembaga Pengarah Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'secretarial', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Lembaga Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.e;
  r.adult    := pg_temp.de_person(r.org, 'Dewasa', 'individual', date '1980-05-01');
  r.eighteen := pg_temp.de_person(r.org, 'Lapan Belas Hari Ini', 'individual',
                  (v_t - interval '18 years')::date);
  r.minor    := pg_temp.de_person(r.org, 'Belum Cukup Umur', 'individual',
                  (v_t - interval '18 years')::date + 1);
  r.unknown  := pg_temp.de_person(r.org, 'Tiada Tarikh Lahir', 'individual', null);
  r.company  := pg_temp.de_person(r.org, 'Syarikat Induk Bhd', 'corporate', null);
  insert into t_de select r.*;
end $$;

set local role authenticated;

do $$
declare d t_de; v_t date := pg_temp.today();
begin
  select * into d from t_de;

  perform pg_temp.check_refused('a company is not appointed director',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
            values (%L, %L, %L, %L, %L)', d.org, d.e, d.company, 'director', v_t),
    'Syarikat Induk Bhd is a company, and a director is a natural person (Companies Act 2016, s.196(1)(a)).%',
    '23514');
  perform pg_temp.check_refused('nor somebody a day short of eighteen',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
            values (%L, %L, %L, %L, %L)', d.org, d.e, d.minor, 'director', v_t),
    format('Belum Cukup Umur was born on %s and is not yet eighteen on %s.%%',
           to_char((v_t - interval '18 years')::date + 1, 'DD Mon YYYY'), to_char(v_t, 'DD Mon YYYY')),
    '23514');

  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.adult, 'director', v_t) returning id into d.principal;
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.eighteen, 'director', v_t),
         (d.org, d.e, d.unknown, 'director', v_t);
  perform pg_temp.check_eq('an adult, one eighteen today, and one with no birthday on file are appointed',
    (select count(*) from public.corp_officers where entity_id = d.e and role = 'director')::int, 3);

  perform pg_temp.check_refused('nor is a minor an alternate director',
    format('insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on, alternate_for)
            values (%L, %L, %L, %L, %L, %L)', d.org, d.e, d.minor, 'alternate_director', v_t, d.principal),
    'Belum Cukup Umur was born on %', '23514');

  -- A company may hold other offices: an audit firm, for one.
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (d.org, d.e, d.company, 'auditor', v_t);
  perform pg_temp.check_refused('and an officer in another role is not made a director',
    format('update public.corp_officers set role = %L where person_id = %L and entity_id = %L',
           'director', d.company, d.e),
    'Syarikat Induk Bhd is a company%', '23514');
  perform pg_temp.check_refused('nor a director''s seat handed to a minor',
    format('update public.corp_officers set person_id = %L where id = %L', d.minor, d.principal),
    'Belum Cukup Umur was born on %', '23514');
  perform pg_temp.check_eq('so the board is as it was',
    (select string_agg(p.full_name, ', ' order by p.full_name)
       from public.corp_officers o join public.corp_persons p on p.id = o.person_id
      where o.entity_id = d.e and o.role = 'director'),
    'Dewasa, Lapan Belas Hari Ini, Tiada Tarikh Lahir');
end $$;

reset role;

rollback;
