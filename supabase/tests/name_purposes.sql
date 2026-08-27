-- =====================================================================
-- iAkauntan :: whose a name is, and whether it is in use
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/name_purposes.sql
--
-- `0344` splits what `0342` ran together. A name on our domain is a
-- company's door, or held by us and answering nothing, or ours and
-- open — and before this the second and third were the same row.
--
-- The failures worth catching are the ones that look like the feature
-- working:
--
--   * a reserved name that answers is a door into nothing, which is the
--     failure `0342` was written to end and this migration's `left
--     join` could quietly reintroduce;
--   * an admin address that does *not* answer is the feature missing
--     while the console says it is set;
--   * a company's door that stops being gated on `workspace_address`
--     is an address given away free, and it fails silently upward —
--     everything works, for everybody, including whoever did not pay;
--   * a parked name still carrying a module is a setting whose effect
--     nobody can ever see;
--   * and a purpose that disagrees with the company on the row is a
--     state nothing downstream can read honestly.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- What a name is, when nobody says
--
-- Every caller written before `0344` said nothing about purpose, so
-- what it means when nothing is said is a compatibility rule rather
-- than a default: a company on it made it a company's, and nothing on
-- it made it held.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_held uuid; v_theirs uuid;
begin
  v_org := pg_temp.test_org('Kedai Lama');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_held := public.platform_reserve_subdomain('parked');
  v_theirs := public.platform_reserve_subdomain('lama', v_org);

  perform pg_temp.check_eq('a name with nobody on it is held',
    (select purpose from public.org_subdomains where id = v_held), 'reserved');
  perform pg_temp.check_eq('and a name with a company on it is theirs',
    (select purpose from public.org_subdomains where id = v_theirs), 'company');
end $$;

-- ---------------------------------------------------------------------
-- An address of ours answers, with no company behind it
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_row record; v_count int;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_reserve_subdomain(
    'counter', null, 'pos', '/till', null, 'admin');

  select count(*) into v_count
    from public.workspace_by_host('counter.iakauntan.com');
  perform pg_temp.check_eq('an address of ours answers', v_count, 1);

  select * into v_row from public.workspace_by_host('counter.iakauntan.com');
  perform pg_temp.check_eq('and says it is ours', v_row.purpose, 'admin');
  perform pg_temp.check_eq('and carries the module', v_row.module_code, 'pos');
  perform pg_temp.check_eq('and the screen', v_row.landing_path, '/till');
  -- The sign-in screen reads this and falls through to the platform's
  -- own mark when it is null. A name here would be a company's name on
  -- an address no company has.
  perform pg_temp.check_true('with no company name on it',
                             v_row.name is null);
end $$;

-- ---------------------------------------------------------------------
-- And it needs nobody to have bought anything
--
-- The gate a company's door passes is `workspace_address`. There is no
-- company here to hold it, so there is nothing to fail — and an
-- entitlement check that reaches a null org id and answers false would
-- refuse every address of ours there could be.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_count int;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_reserve_subdomain(
    'kds', null, 'pos', null, null, 'admin');

  select count(*) into v_count
    from public.workspace_by_host('kds.iakauntan.com');
  perform pg_temp.check_eq('no subscription is needed for one of ours',
                           v_count, 1);
end $$;

-- ---------------------------------------------------------------------
-- A parked name answers nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_count int;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_reserve_subdomain('someday', null, null, null,
                                            null, 'reserved');

  select count(*) into v_count
    from public.workspace_by_host('someday.iakauntan.com');
  perform pg_temp.check_eq('a parked name is nobody''s door', v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- A company's door is still a company's door, and still gated
--
-- The `left join` is what makes an address of ours possible, and it is
-- also what could let a company's row past the conditions that used to
-- sit flat in the `where`. Both halves are asserted, because the one
-- that fails silently upward is the second: everything works, for
-- everybody, including a company that never bought an address.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_count int; v_row record;
begin
  v_org := pg_temp.test_org('Sinar Pintu');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_reserve_subdomain('pintu', v_org);

  select * into v_row from public.workspace_by_host('pintu.iakauntan.com');
  perform pg_temp.check_eq('a company''s door answers with its name',
                           v_row.name, 'Sinar Pintu');
  perform pg_temp.check_eq('and says whose kind it is',
                           v_row.purpose, 'company');

  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'workspace_address';

  select count(*) into v_count
    from public.workspace_by_host('pintu.iakauntan.com');
  perform pg_temp.check_eq('and stops when they stop paying for it',
                           v_count, 0);
end $$;

-- ---------------------------------------------------------------------
-- A parked name cannot be pointed anywhere
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_state text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_reserve_subdomain('parked-pointed', null, 'pos',
                                              null, null, 'reserved');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('a held name cannot open a module',
                           v_state, '22023');
end $$;

-- ---------------------------------------------------------------------
-- The company and the purpose cannot disagree
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_state text;
begin
  v_org := pg_temp.test_org('Kedai Bantah');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_reserve_subdomain('ours-theirs', v_org, null,
                                              null, null, 'admin');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('an address of ours cannot have a company on it',
                           v_state, '22023');

  begin
    perform public.platform_reserve_subdomain('theirs-nobody', null, null,
                                              null, null, 'company');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('and a company''s door has to name the company',
                           v_state, '22023');

  begin
    perform public.platform_reserve_subdomain('what-even', null, null,
                                              null, null, 'borrowed');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('and there is no fourth kind', v_state, '22023');
end $$;

-- ---------------------------------------------------------------------
-- Parking a name that was in use takes the module with it
--
-- Cleared rather than refused, because this is old state being tidied
-- rather than a contradiction inside one submission — the same
-- distinction the screen already follows when its module changes.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id uuid; v_row public.org_subdomains;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('busy', null, 'pos', '/till',
                                            null, 'admin');
  perform public.platform_update_reservation('subdomain', v_id, null, null,
                                             null, null, false, 'reserved');

  select * into v_row from public.org_subdomains where id = v_id;
  perform pg_temp.check_eq('parking it parks it', v_row.purpose, 'reserved');
  perform pg_temp.check_true('and the module goes',
                             v_row.module_code is null);
  perform pg_temp.check_true('and the screen with it',
                             v_row.landing_path is null);
end $$;

-- ---------------------------------------------------------------------
-- But parking it and pointing it in the same breath is refused
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id uuid; v_state text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('two-minds', null, null, null,
                                            null, 'admin');
  begin
    perform public.platform_update_reservation('subdomain', v_id, null, null,
                                               'pos', null, false, 'reserved');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('one submission cannot say both', v_state, '22023');
end $$;

-- ---------------------------------------------------------------------
-- Taking a name off a company makes it ours, not a contradiction
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_id uuid; v_row public.org_subdomains;
begin
  v_org := pg_temp.test_org('Kedai Pergi');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('pergi', v_org);

  -- `0342`'s release, with nothing said about purpose. Every call
  -- written before today looks like this one.
  perform public.platform_update_reservation('subdomain', v_id, null, null,
                                             null, null, true);
  select * into v_row from public.org_subdomains where id = v_id;
  perform pg_temp.check_true('releasing it lets the company go',
                             v_row.org_id is null);
  perform pg_temp.check_eq('and parks it, as release always meant',
                           v_row.purpose, 'reserved');
end $$;

-- ---------------------------------------------------------------------
-- Moving a company's name to one of ours drops the company by itself
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_id uuid; v_row public.org_subdomains;
begin
  v_org := pg_temp.test_org('Kedai Tukar');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('tukar', v_org);
  perform public.platform_update_reservation('subdomain', v_id, null, null,
                                             'pos', null, false, 'admin');

  select * into v_row from public.org_subdomains where id = v_id;
  perform pg_temp.check_eq('it becomes ours', v_row.purpose, 'admin');
  perform pg_temp.check_true('without being told twice to let go',
                             v_row.org_id is null);
  perform pg_temp.check_eq('and opens what it was pointed at',
                           v_row.module_code, 'pos');
end $$;

-- ---------------------------------------------------------------------
-- And a name cannot become a company's without one
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id uuid; v_state text;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('orphan', null, null, null,
                                            null, 'reserved');
  begin
    perform public.platform_update_reservation('subdomain', v_id, null, null,
                                               null, null, false, 'company');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('a door needs somebody behind it',
                           v_state, '22023');
end $$;

-- ---------------------------------------------------------------------
-- A mailbox has no purpose to set
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_id uuid; v_state text;
begin
  v_org := pg_temp.test_org('Kedai Surat');
  perform public.request_mailbox(v_org, 'surat');
  select id into v_id from public.org_mailboxes where org_id = v_org;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  begin
    perform public.platform_update_reservation('mailbox', v_id, null, null,
                                               null, null, false, 'admin');
    v_state := 'allowed';
  exception when others then
    v_state := sqlstate;
  end;
  perform pg_temp.check_eq('an address to write to is always a company''s',
                           v_state, '22023');
end $$;

-- ---------------------------------------------------------------------
-- The operator's list says which each one is
--
-- All three kinds, in the one place somebody goes to find out. A list
-- that cannot tell them apart is a screen where parking a name and
-- putting it to use look identical.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_purposes text[];
begin
  v_org := pg_temp.test_org('Kedai Senarai');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_reserve_subdomain('senarai-a', v_org);
  perform public.platform_reserve_subdomain('senarai-b', null, null, null,
                                            null, 'reserved');
  perform public.platform_reserve_subdomain('senarai-c', null, 'pos', null,
                                            null, 'admin');

  select array_agg(r.purpose order by r.name)
    into v_purposes
    from public.platform_reservations() r
   where r.name like 'senarai-%';

  perform pg_temp.check_eq('the list tells the three apart',
    array_to_string(v_purposes, ','), 'company,reserved,admin');
end $$;

rollback;
