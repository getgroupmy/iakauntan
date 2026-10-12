-- =====================================================================
-- iAkauntan :: a class of shares stays with its company (0835)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/share_class_company_kept.sql
--
-- `corp_issued_capital` counts a class's allotments under the company
-- the class names; `corp_register_of_members` reads the movements under
-- the company they were recorded in. Before `0835` a class could be
-- moved to another company by an update, and the two disagreed: the
-- first company's register held shares its issued capital did not, and
-- the second's issued capital held shares nobody in its register did.
-- Asked as the owner with the role `authenticated`, as the share class
-- sheet asks, and then as the owner itself.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_sc (org uuid, other_org uuid, saham uuid, lain uuid,
  elsewhere uuid, ord uuid, pref uuid);
grant select on t_sc to authenticated;

-- A company's issued capital and register, as one line.
create or replace function pg_temp.books(p_entity uuid)
returns text language sql as $$
  select coalesce((select string_agg(c.share_class || '=' || c.shares::numeric(20, 0), ', '
                                     order by c.share_class)
                     from public.corp_issued_capital(p_entity) c
                    where c.shares <> 0), '-')
      || ' / '
      || coalesce((select string_agg(r.member_name || '=' || r.shares::numeric(20, 0), ', '
                                     order by r.member_name)
                     from public.corp_register_of_members(p_entity) r), '-');
$$;
grant execute on function pg_temp.books(uuid) to authenticated;

do $$
declare r t_sc; v_a uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Kelas Saham Sdn Bhd');
  r.other_org := pg_temp.test_org('Syarikat Lain Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'secretarial', true), (r.other_org, 'secretarial', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Saham Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.saham;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.org, 'Lain Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.lain;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (r.other_org, 'Jauh Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into r.elsewhere;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (r.org, r.saham, 'ORD', 'Ordinary') returning id into r.ord;
  -- One nothing has been allotted in, which is asked the same.
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (r.org, r.saham, 'PREF', 'Preference') returning id into r.pref;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Member A', '920415085566') returning id into v_a;
  insert into public.corp_share_events (org_id, entity_id, share_class_id,
    event_type, event_date, to_person_id, quantity)
  values (r.org, r.saham, r.ord, 'allotment', date '2026-01-01', v_a, 100);
  insert into t_sc select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_sc;
begin
  select * into d from t_sc;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('Saham''s books as recorded',
    pg_temp.books(d.saham), 'Ordinary=100 / Member A=100');

  -- What was measured.
  perform pg_temp.check_refused('a class with shares in it is not moved to another company',
    format('update public.corp_share_classes set entity_id = %L where id = %L', d.lain, d.ord),
    'Class ORD stays with the company it was created for.%', '23514');
  perform pg_temp.check_refused('nor is one with none',
    format('update public.corp_share_classes set entity_id = %L where id = %L', d.lain, d.pref),
    'Class PREF stays with the company it was created for.%', '23514');

  -- What the share class sheet writes is as before: everything, with
  -- the class's own company sent back.
  update public.corp_share_classes
     set entity_id = d.saham, code = 'ORD', name = 'Ordinary shares',
         currency = 'MYR', votes_per_share = 1, is_redeemable = false,
         rights = 'One vote a share'
   where id = d.ord;
  perform pg_temp.check_eq('the sheet still amends a class',
    (select name || ' / ' || rights from public.corp_share_classes where id = d.ord),
    'Ordinary shares / One vote a share');

  perform pg_temp.check_eq('so Saham''s books agree with themselves',
    pg_temp.books(d.saham), 'Ordinary shares=100 / Member A=100');
  perform pg_temp.check_eq('and Lain''s hold nothing of Saham''s',
    pg_temp.books(d.lain), '- / -');
end $$;

reset role;

-- Any writer: the owner too, and across tenants -- the company and the
-- tenant together, which the same-tenant key would otherwise let pass.
do $$
declare d t_sc;
begin
  select * into d from t_sc;
  perform pg_temp.check_refused('the owner does not move a class either',
    format('update public.corp_share_classes set org_id = %L, entity_id = %L where id = %L',
           d.other_org, d.elsewhere, d.pref),
    'Class PREF stays with the company it was created for.%', '23514');
end $$;

rollback;
