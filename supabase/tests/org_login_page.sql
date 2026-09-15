-- =====================================================================
-- iAkauntan :: the words over a company's own door
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/org_login_page.sql
--
-- `0348` gave the platform a second page of sign-in copy for workspace
-- addresses; `0349` gives it to the company whose address it is. What
-- is asserted here is the part that fails silently:
--
--   * a company's own words have to reach a visitor who has not signed
--     in. `workspace_by_host` is SECURITY DEFINER and anon-granted, so
--     a mistake here does not raise — the door simply keeps saying what
--     the platform wrote, and the operator who typed a heading is left
--     wondering whether the save worked;
--   * null has to mean "use the platform's". An empty string does not,
--     and the screen's `??` renders it as a blank line above the form;
--   * a company that never bought `workspace_address` must not be able
--     to write a page. It fails upward — everything appears to work for
--     somebody who is not paying for it;
--   * and neither must somebody who is not an owner or an admin of the
--     company, nor an owner of a *different* company. Anybody signed in
--     can call an RPC.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The words a company writes reach the door
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sinar Pintu Kata');
  v_title text; v_body text;
begin
  -- `decided_at` is not optional on an approved row: the table's
  -- `org_subdomains_decided` constraint ties the two together.
  insert into public.org_subdomains
    (org_id, subdomain, status, purpose, decided_at)
  values (v_org, 'sinarkata', 'approved', 'company', now());

  -- Nothing written yet: the door answers, and says nothing of its own.
  select w.login_title, w.login_body into v_title, v_body
    from public.workspace_by_host('sinarkata.iakauntan.com') w;
  perform pg_temp.check_true('a company that has written nothing has '
                             'nothing over its door',
                             v_title is null and v_body is null);

  perform public.org_save_login_page(v_org, 'Masuk ke Sinar',
                                     'Log masuk untuk teruskan ke');

  select w.login_title, w.login_body into v_title, v_body
    from public.workspace_by_host('sinarkata.iakauntan.com') w;
  perform pg_temp.check_eq('and what it writes is what the door says',
                           v_title, 'Masuk ke Sinar');
  perform pg_temp.check_eq('the lead-in too', v_body,
                           'Log masuk untuk teruskan ke');
end $$;

-- ---------------------------------------------------------------------
-- A stranger reads it, because a stranger is who it is for
--
-- The whole point of this page is that it is drawn before anybody has
-- signed in. A read that needs a session is a page nobody ever sees.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sinar Orang Luar');
  v_title text;
begin
  insert into public.org_subdomains
    (org_id, subdomain, status, purpose, decided_at)
  values (v_org, 'sinarluar', 'approved', 'company', now());
  perform public.org_save_login_page(v_org, 'Selamat kembali', null);

  perform pg_temp.sign_out();
  select w.login_title into v_title
    from public.workspace_by_host('sinarluar.iakauntan.com') w;
  perform pg_temp.check_eq('the door speaks to somebody with no session',
                           v_title, 'Selamat kembali');
end $$;

-- ---------------------------------------------------------------------
-- An emptied box is a null, not an empty string
--
-- Clearing a heading asks for the platform's wording back. An empty
-- string is not null, and the screen's `??` renders it — a blank line
-- where the heading was.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sinar Kosong');
  v_title text; v_body text;
begin
  perform public.org_save_login_page(v_org, 'Ada', 'Pun ada');
  perform public.org_save_login_page(v_org, '   ', null);

  select p.title, p.body into v_title, v_body
    from public.org_login_pages p where p.org_id = v_org;
  perform pg_temp.check_true('an emptied heading is null, not ""',
                             v_title is null);
  perform pg_temp.check_eq('and a field left out is left alone', v_body,
                           'Pun ada');
end $$;

-- ---------------------------------------------------------------------
-- A company with no address of its own has no page to write
--
-- This is the one that fails upward: without the check everything works
-- for a company that never bought the module, and nothing anywhere
-- says so.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Kedai Tiada Alamat', array['sales']);
begin
  -- On the words, not on 42501. All three refusals in this file are
  -- 42501 and the first is a DIFFERENT rule from the other two -- no
  -- web address at all, versus a member who is not an administrator.
  -- Asserting the code alone passes when the wrong one fires.
  perform pg_temp.check_refused('no address, no page to write',
    format($q$ select public.org_save_login_page(%L, 'Masuk', null) $q$,
           v_org),
    '%does not have its own web address%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- And nor may somebody who does not speak for the company
--
-- Two different people here, and the second is the one that matters:
-- an owner is an owner *of an organization*, and a rule that checks
-- the role without checking which company it is in is a rule that lets
-- every owner on the platform rewrite everybody's door.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sinar Tuan');
  v_outsider uuid := pg_temp.another_user('outsider-login@test.local');
  v_title text;
begin
  perform public.org_save_login_page(v_org, 'Sinar sahaja', null);

  perform pg_temp.sign_in_as(v_outsider);
  perform pg_temp.check_refused(
    'a stranger cannot rewrite a company''s door',
    format($q$ select public.org_save_login_page(%L, 'Bukan Sinar', null) $q$,
           v_org),
    '%Only an owner or an administrator may write%', '42501');

  select p.title into v_title
    from public.org_login_pages p where p.org_id = v_org;
  perform pg_temp.check_eq('and the door says what it said', v_title,
                           'Sinar sahaja');
end $$;

-- A member who is not an owner or an administrator is the same answer.
do $$
declare
  v_org uuid := pg_temp.test_org('Sinar Kerani');
  v_clerk uuid := pg_temp.another_user('clerk-login@test.local');
begin
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active')
  on conflict (org_id, user_id) do update set role = 'accounts_clerk',
                                              status = 'active';

  perform pg_temp.sign_in_as(v_clerk);
  -- The same message as the stranger above, and deliberately so: being
  -- inside the company is not the thing this rule asks about.
  perform pg_temp.check_refused('a clerk is a member, not a spokesman',
    format($q$ select public.org_save_login_page(%L, 'Kerani tulis', null) $q$,
           v_org),
    '%Only an owner or an administrator may write%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The table itself is shut to a stranger
--
-- The read above goes through a SECURITY DEFINER function on purpose.
-- The table behind it is not a public one: what a company has drafted
-- over its door is its own until the door draws it.
-- ---------------------------------------------------------------------
do $$
declare v_shut boolean := false; v_n integer;
begin
  perform pg_temp.sign_out();
  -- The role, and not just the claims. The test session is a superuser,
  -- which bypasses RLS entirely — an assertion that only cleared the
  -- JWT would pass against a table with no policy at all.
  set local role anon;
  begin
    select count(*) into v_n from public.org_login_pages;
  exception when insufficient_privilege then v_shut := true;
  end;
  reset role;
  perform pg_temp.check_true('the table is not a stranger''s to read',
                             v_shut);
end $$;

rollback;
