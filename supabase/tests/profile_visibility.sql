-- =====================================================================
-- iAkauntan :: who can see whose profile
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/profile_visibility.sql
--
-- `public.profiles` carries a person's name, email, phone and avatar,
-- and its SELECT policy is
--
--     id = auth.uid() or app.shares_org_with(id)
--
-- so it is the rule that decides whether one company can enumerate
-- another company's people. Four test files write to `profiles`, all of
-- them as the database owner with row level security bypassed, and none
-- of them reads it as a person. The policy, and the function behind it,
-- had nothing on them.
--
-- Every read here runs under `set local role authenticated` and each
-- block asserts that it did, because the owner bypasses RLS and a test
-- that forgot the role would pass while proving nothing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A person with a profile, ready to be looked at.
create or replace function pg_temp.person(p_email text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid := pg_temp.another_user(p_email);
begin
  insert into public.profiles (id, full_name, email)
  values (v_id, p_name, p_email)
  on conflict (id) do update set full_name = excluded.full_name,
                                 email = excluded.email;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Your own, your colleague's, and nobody else's
-- ---------------------------------------------------------------------
do $$
declare
  v_org_a uuid; v_org_b uuid;
  v_me uuid; v_colleague uuid; v_stranger uuid;
  v_role text;
  v_self integer; v_mate integer; v_other integer; v_all integer;
begin
  v_org_a := pg_temp.test_org('Syarikat A');
  v_me := pg_temp.test_user();
  insert into public.profiles (id, full_name, email)
  values (v_me, 'Saya', 'saya@iakauntan.test')
  on conflict (id) do update set full_name = excluded.full_name;

  v_colleague := pg_temp.person('rakan@iakauntan.test', 'Rakan Sekerja');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org_a, v_colleague, 'accountant', 'active');

  -- Somebody in a different company entirely. Creating the company
  -- makes its creator an active owner, so no membership row is added
  -- here; adding one would collide.
  v_stranger := pg_temp.person('orang@lain.test', 'Orang Lain');
  insert into public.organizations (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat B', 'syarikat-b-' || gen_random_uuid(), 'sdn_bhd', 'MYR', v_stranger)
  returning id into v_org_b;
  perform pg_temp.check_eq('the other company has its owner, and only its owner',
    (select count(*) from public.org_members
      where org_id = v_org_b and user_id = v_stranger and status = 'active'), 1);

  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_self  from public.profiles where id = v_me;
    select count(*) into v_mate  from public.profiles where id = v_colleague;
    select count(*) into v_other from public.profiles where id = v_stranger;
    select count(*) into v_all   from public.profiles;
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('I can see myself', v_self, 1);
  perform pg_temp.check_eq('and the colleague I share a company with', v_mate, 1);
  perform pg_temp.check_eq('and not somebody from another company', v_other, 0);
  -- Stated as a total as well, because a policy that leaked a fourth
  -- person would satisfy all three counts above and only fail this.
  perform pg_temp.check_eq('and those two are the whole of what I can see',
    v_all, 2);
end $$;

-- ---------------------------------------------------------------------
-- Membership has to be live
--
-- `shares_org_with` requires `status = 'active'` on both sides. An
-- invitation that was never accepted, or a member who has been
-- suspended, is not a colleague — and the two sides are separate
-- conditions, so each is checked on its own.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_me uuid; v_pending uuid; v_suspended uuid;
  v_role text; v_sees_pending integer; v_sees_suspended integer;
begin
  v_org := pg_temp.test_org('Syarikat Ahli');
  v_me := pg_temp.test_user();

  v_pending := pg_temp.person('belum@iakauntan.test', 'Belum Terima');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_pending, 'accountant', 'invited');

  v_suspended := pg_temp.person('gantung@iakauntan.test', 'Digantung');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_suspended, 'accountant', 'suspended');

  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_sees_pending   from public.profiles where id = v_pending;
    select count(*) into v_sees_suspended from public.profiles where id = v_suspended;
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('an invitation nobody accepted is not a colleague',
    v_sees_pending, 0);
  perform pg_temp.check_eq('nor is a suspended member', v_sees_suspended, 0);
end $$;

-- ---------------------------------------------------------------------
-- And the reader's own membership has to be live too
--
-- The other half of the same condition: somebody whose membership has
-- been suspended stops seeing the company's people, rather than keeping
-- the view they had. Asserted separately because `mine.status` and
-- `theirs.status` are two conditions and dropping either leaves the
-- other passing.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_leaver uuid;
  v_role text; v_sees integer;
begin
  v_org := pg_temp.test_org('Syarikat Bekas');
  v_owner := pg_temp.test_user();
  insert into public.profiles (id, full_name, email)
  values (v_owner, 'Pemilik', 'pemilik@iakauntan.test')
  on conflict (id) do update set full_name = excluded.full_name;

  v_leaver := pg_temp.person('keluar@iakauntan.test', 'Sudah Keluar');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_leaver, 'accountant', 'active');

  -- While they are still here.
  perform pg_temp.sign_in_as(v_leaver);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_sees from public.profiles where id = v_owner;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('a member sees the owner', v_sees, 1);

  -- And once they are not.
  update public.org_members set status = 'suspended'
   where org_id = v_org and user_id = v_leaver;
  perform pg_temp.sign_in_as(v_leaver);
  begin
    set local role authenticated;
    select count(*) into v_sees from public.profiles where id = v_owner;
  end;
  reset role;
  perform pg_temp.check_eq('and stops when their own membership is suspended',
    v_sees, 0);
end $$;

-- ---------------------------------------------------------------------
-- Sharing a company is not permission to change somebody
--
-- The SELECT policy is wide by design — a colleague's name has to
-- appear on an approval queue. UPDATE and INSERT are not: both are
-- `id = auth.uid()`, so seeing a colleague is not editing one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_me uuid; v_colleague uuid;
  v_role text; v_changed integer; v_inserted integer;
  v_nobody uuid;
begin
  v_org := pg_temp.test_org('Syarikat Sunting');
  v_me := pg_temp.test_user();
  v_colleague := pg_temp.person('kawan@iakauntan.test', 'Nama Asal');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_colleague, 'accountant', 'active');

  perform pg_temp.sign_in_as(v_me);
  begin
    set local role authenticated;
    v_role := current_user;
    -- No error: the row is simply not visible to the UPDATE, so nothing
    -- matches and nothing changes.
    update public.profiles set full_name = 'Nama Baru' where id = v_colleague;
    get diagnostics v_changed = row_count;
    insert into public.profiles (id, full_name, email)
    values (v_me, 'Saya', 'saya2@iakauntan.test')
    on conflict (id) do nothing;
    get diagnostics v_inserted = row_count;
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('renaming a colleague changes nothing', v_changed, 0);
  perform pg_temp.check_eq('and the colleague still has their own name',
    (select full_name from public.profiles where id = v_colleague), 'Nama Asal');

  -- A profile for somebody who is not you is refused outright rather
  -- than silently skipped, because INSERT has a `with check`.
  --
  -- The subject is a real user, not an invented uuid: `profiles.id`
  -- references `auth.users`, so an invented one is refused by the
  -- foreign key and the policy is never consulted. The first version of
  -- this assertion did exactly that and passed for the wrong reason.
  --
  -- Every auth user already has a profile — `on_auth_user_created`
  -- makes one — and that row's primary key would refuse the insert
  -- before the policy did, which is the second way this assertion
  -- passed for the wrong reason. So the profile is cleared first: the
  -- key is free, the foreign key is satisfied, and the `with check` is
  -- the only thing left that can say no.
  v_nobody := pg_temp.another_user('orang-lain-lagi@iakauntan.test');
  delete from public.profiles where id = v_nobody;
  perform pg_temp.sign_in_as(v_me);
  declare v_ok boolean := false;
  begin
    begin
      set local role authenticated;
      insert into public.profiles (id, full_name, email)
      values (v_nobody, 'Orang Baru', 'baru@iakauntan.test');
    exception when insufficient_privilege then v_ok := true;
    end;
    reset role;
    perform pg_temp.check_true('a profile cannot be created for anybody else', v_ok);
    perform pg_temp.check_eq('and none was created', (select count(*)
      from public.profiles where id = v_nobody), 0);
  end;
end $$;

rollback;
