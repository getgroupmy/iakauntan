-- =====================================================================
-- iAkauntan :: who may put a logo in the logos bucket
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/logo_storage.sql
--
-- 0010 gave the bucket an insert policy keyed on the first path segment
-- being an organization id, and 0073 added update and delete to match.
-- Nothing ever asserted any of them, and 0290 then wrote the platform's
-- own logo to `landing/…` — where `'landing'::uuid` raises 22P02 rather
-- than evaluating to false, so the upload could never have worked and
-- the error named a cast instead of a permission.
--
-- 0291 fixes both halves. The half worth writing a test around is the
-- second one: a policy that raises is not a policy that refuses.
-- Permissive policies for one command are OR-ed and PostgreSQL does not
-- promise an order, so one that throws takes the statement down whatever
-- the others would have said.
--
-- Every write here runs under `set local role authenticated` and each
-- block asserts that it did, because the owner bypasses row level
-- security entirely.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.put_logo(p_name text)
returns text language plpgsql as $$
begin
  insert into storage.objects (bucket_id, name) values ('logos', p_name);
  return 'accepted';
exception
  when insufficient_privilege then return 'refused';
  when others then return 'raised ' || sqlstate;
end;
$$;

-- ---------------------------------------------------------------------
-- A company's own mark
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Logo Sdn Bhd');
  v_other uuid;
  v_role text; v_mine text; v_theirs text;
begin
  insert into public.organizations (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat Lain', 'lain-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          pg_temp.another_user('lain@iakauntan.test'))
  returning id into v_other;

  perform pg_temp.sign_in_as(pg_temp.test_user());
  set local role authenticated;
  v_role := current_user;
  v_mine := pg_temp.put_logo(v_org || '/logo');
  v_theirs := pg_temp.put_logo(v_other || '/logo');
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('an owner may upload their own company''s logo',
    v_mine, 'accepted');
  perform pg_temp.check_eq('and not another company''s', v_theirs, 'refused');
end $$;

-- ---------------------------------------------------------------------
-- A path the policy does not recognise is refused, not an error
--
-- The regression 0291 is about. Before it, any of these raised 22P02
-- from inside the policy — which is why the landing logo could not be
-- uploaded, and why adding a policy for it would not by itself have
-- helped.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Nama Pelik Sdn Bhd');
  v_role text; v_word text; v_empty text; v_partial text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  set local role authenticated;
  v_role := current_user;
  v_word    := pg_temp.put_logo('marketing/logo');
  v_empty   := pg_temp.put_logo('logo.png');
  v_partial := pg_temp.put_logo('not-a-uuid-at-all/logo');
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('a word where an organization should be is refused',
    v_word, 'refused');
  perform pg_temp.check_eq('so is a bare file name', v_empty, 'refused');
  perform pg_temp.check_eq('and so is something uuid-shaped but not a uuid',
    v_partial, 'refused');

  -- Said plainly, because "refused" above is the whole point: none of
  -- them may come back as an error, whatever the error would have been.
  perform pg_temp.check_eq('and none of the three raised instead of refusing',
    (select count(*) from (values (v_word), (v_empty), (v_partial)) t(r)
      where r like 'raised%'), 0);
end $$;

-- ---------------------------------------------------------------------
-- The platform's own mark, which no company owns
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Bukan Platform Sdn Bhd');
  v_role text; v_before text; v_after text; v_dark text;
begin
  -- An ordinary company owner first: being an owner somewhere is not
  -- being a platform administrator.
  delete from public.platform_admins where user_id = v_admin;
  perform pg_temp.sign_in_as(v_admin);
  set local role authenticated;
  v_role := current_user;
  v_before := pg_temp.put_logo('landing/logo');
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('a company owner cannot write the platform''s logo',
    v_before, 'refused');

  -- And now as one.
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  set local role authenticated;
  v_after := pg_temp.put_logo('landing/logo');
  v_dark  := pg_temp.put_logo('landing/logo-dark');
  reset role;

  perform pg_temp.check_eq('a platform administrator can', v_after, 'accepted');
  perform pg_temp.check_eq('and the dark one beside it', v_dark, 'accepted');

  -- The paths are fixed, so the second upload of the same logo is an
  -- update. 0073 learned this about the company logo: with an insert
  -- policy and no update policy, a company could upload a mark exactly
  -- once and changing its mind read as "the upload failed".
  perform pg_temp.sign_in_as(v_admin);
  set local role authenticated;
  update storage.objects set metadata = '{"v":2}'::jsonb
   where bucket_id = 'logos' and name = 'landing/logo';
  get diagnostics v_role = row_count;
  reset role;
  perform pg_temp.check_eq('and can replace it afterwards', v_role, '1');

  -- Being a platform administrator is not a way into everybody's books:
  -- the landing policies are scoped to the landing prefix and nothing
  -- else, so a company's own logo still needs that company's admin.
  perform pg_temp.sign_in_as(v_admin);
  set local role authenticated;
  v_before := pg_temp.put_logo(gen_random_uuid() || '/logo');
  reset role;
  perform pg_temp.check_eq(
    'and it is not a way into a company''s own bucket space',
    v_before, 'refused');
end $$;

rollback;
