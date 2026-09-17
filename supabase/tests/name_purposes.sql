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
  v_org uuid; v_held uuid; v_theirs uuid; v_used uuid;
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

  -- The third reading, and the one that cost a red deploy. A name held
  -- with no company but pointed at a module was an operator saying
  -- "this address opens the till" — admin use before there was a word
  -- for it. Reading it as parked loses what it was for, and then the
  -- constraint below refuses the row outright.
  v_used := public.platform_reserve_subdomain('inuse', null, 'pos', '/till');
  perform pg_temp.check_eq('and a name pointed somewhere is one of ours',
    (select purpose from public.org_subdomains where id = v_used), 'admin');
end $$;

-- ---------------------------------------------------------------------
-- The table refuses what the backfill had to be careful about
--
-- Asserted against the table rather than the function, because this is
-- the check that failed on the hosted project: the migration's own
-- backfill produced rows the migration's own constraint would not
-- accept, and no function was involved in either half.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_id uuid; v_direct boolean := false;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('firmly', null, 'pos', null,
                                            null, 'admin');
  begin
    update public.org_subdomains set purpose = 'reserved' where id = v_id;
  exception when check_violation then v_direct := true;
  end;
  perform pg_temp.check_true('a parked name pointed at a module cannot exist',
                             v_direct);
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
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- On the message as well as the code. Four different refusals in this
  -- file raise 22023, so asserting the sqlstate alone passes when the
  -- WRONG guard fires -- and would pass with this one deleted.
  perform pg_temp.check_refused('a held name cannot open a module',
    $q$ select public.platform_reserve_subdomain('parked-pointed', null,
          'pos', null, null, 'reserved') $q$,
    '%reserved name answers to nobody%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- The company and the purpose cannot disagree
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid;
begin
  v_org := pg_temp.test_org('Kedai Bantah');
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform pg_temp.check_refused(
    'an address of ours cannot have a company on it',
    format($q$ select public.platform_reserve_subdomain('ours-theirs', %L,
             null, null, null, 'admin') $q$, v_org),
    '%cannot have one on it%', '22023');

  perform pg_temp.check_refused(
    'and a company''s door has to name the company',
    $q$ select public.platform_reserve_subdomain('theirs-nobody', null, null,
          null, null, 'company') $q$,
    '%Choose the company this address belongs to%', '22023');

  perform pg_temp.check_refused('and there is no fourth kind',
    $q$ select public.platform_reserve_subdomain('what-even', null, null,
          null, null, 'borrowed') $q$,
    '%reserved, or ours to use%', '22023');
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
  v_id uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('two-minds', null, null, null,
                                            null, 'admin');
  perform pg_temp.check_refused('one submission cannot say both',
    format($q$ select public.platform_update_reservation('subdomain', %L,
             null, null, 'pos', null, false, 'reserved') $q$, v_id),
    '%reserved name answers to nobody%', '22023');
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
  v_id uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_id := public.platform_reserve_subdomain('orphan', null, null, null,
                                            null, 'reserved');
  perform pg_temp.check_refused('a door needs somebody behind it',
    format($q$ select public.platform_update_reservation('subdomain', %L,
             null, null, null, null, false, 'company') $q$, v_id),
    '%Choose the company this address belongs to%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- A mailbox has no purpose to set
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org uuid; v_id uuid;
begin
  v_org := pg_temp.test_org('Kedai Surat');
  perform public.request_mailbox(v_org, 'surat');
  select id into v_id from public.org_mailboxes where org_id = v_org;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform pg_temp.check_refused(
    'an address to write to is always a company''s',
    format($q$ select public.platform_update_reservation('mailbox', %L, null,
             null, null, null, false, 'admin') $q$, v_id),
    '%mailbox is always%', '22023');
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

-- ---------------------------------------------------------------------
-- Who may stand at a door with no company behind it
--
-- `0333`'s door policy asks whether somebody is on the company's team,
-- and the sign-in screen signs the session out again when the answer is
-- no. `0344` made addresses with no company, `app.is_org_member(null)`
-- is false, and so `pos.iakauntan.com` took a correct password, issued
-- a token, and logged straight back out — for everybody, whatever their
-- company was subscribed to.
--
-- The four rows below are the four kinds of address there now are, and
-- the only one that may refuse anybody is a company's.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin   uuid := pg_temp.test_user();
  v_org     uuid;
  v_member  uuid;
  v_outside uuid := pg_temp.another_user('nobody-in-particular@iakauntan.test');
begin
  v_org := pg_temp.test_org('Kedai Pintu');
  select auth.uid() into v_member;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_reserve_subdomain('pintu-theirs', v_org);
  perform public.platform_reserve_subdomain('pintu-ours', null, 'pos', null,
                                            null, 'admin');
  perform public.platform_reserve_subdomain('pintu-parked', null, null, null,
                                            null, 'reserved');

  perform pg_temp.sign_in_as(v_outside);

  -- The regression, stated as the thing that was broken: somebody with
  -- no connection to anything may use an address of ours, because there
  -- is no team there to not be on.
  perform pg_temp.check_true('anybody may use an address of ours',
    public.may_use_workspace('pintu-ours.iakauntan.com'));
  perform pg_temp.check_true('and a parked name refuses nobody either',
    public.may_use_workspace('pintu-parked.iakauntan.com'));

  -- And the half that must not have moved. This is the whole point of
  -- the policy, and widening it for two new kinds of address is exactly
  -- the change that could take it with them.
  perform pg_temp.check_true('but a stranger is still not on their team',
    not public.may_use_workspace('pintu-theirs.iakauntan.com'));

  perform pg_temp.sign_in_as(v_member);
  perform pg_temp.check_true('and their own people still are',
    public.may_use_workspace('pintu-theirs.iakauntan.com'));
end $$;

-- ---------------------------------------------------------------------
-- Whether the account signing in may open what the address opens
--
-- `0346`. The address says "the till"; the account may have no till.
-- Answered at the door so the sign-in form can say so and stay where it
-- is, rather than letting somebody in and then showing them a screen
-- that says no.
--
-- Null means nothing to refuse. Anything else is the module's own name,
-- because "not subscribed to a module" is not a sentence anybody can
-- act on.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin  uuid := pg_temp.test_user();
  v_has    uuid;
  v_hasnt  uuid;
  v_person uuid := pg_temp.another_user('till-person@iakauntan.test');
  v_bare   uuid := pg_temp.another_user('operator-6@iakauntan.test');
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_reserve_subdomain('counter-a', null, 'pos', '/till',
                                            null, 'admin');
  perform public.platform_reserve_subdomain('open-house', null, null, null,
                                            null, 'reserved');

  -- Everything is on for the first, and only the core modules for the
  -- second — `pos` is not one of them.
  v_has := pg_temp.test_org('Kedai Ada Till');
  v_hasnt := pg_temp.test_org('Kedai Tiada Till', array['sales']);

  insert into public.org_members (org_id, user_id, role, status)
  values (v_hasnt, v_person, 'owner', 'active');
  perform pg_temp.sign_in_as(v_person);

  perform pg_temp.check_eq('a company without the module is told which one',
    public.workspace_module_refusal('counter-a.iakauntan.com'),
    'Point of Sale');

  -- Three addresses that confine nothing. A refusal at any of them is
  -- the check running where it has nothing to check.
  perform pg_temp.check_true('a name that opens everything refuses nobody',
    public.workspace_module_refusal('open-house.iakauntan.com') is null);
  perform pg_temp.check_true('nor does an address nobody holds',
    public.workspace_module_refusal('nosuchname.iakauntan.com') is null);
  perform pg_temp.check_true('nor the bare domain',
    public.workspace_module_refusal('iakauntan.com') is null);

  -- An invitation nobody accepted is not a company you are in.
  insert into public.org_members (org_id, user_id, role, status)
  values (v_has, v_person, 'sales', 'invited');
  perform pg_temp.check_eq('an unaccepted invitation opens nothing',
    public.workspace_module_refusal('counter-a.iakauntan.com'),
    'Point of Sale');

  -- Belonging to one company that holds it is enough. The address names
  -- a module, not a company, and after signing in they will be in one
  -- of theirs — refusing on the strength of the other would be refusing
  -- a fact about a company they were not signing in to.
  update public.org_members set status = 'active'
   where org_id = v_has and user_id = v_person;
  perform pg_temp.check_true('one company with it is enough',
    public.workspace_module_refusal('counter-a.iakauntan.com') is null);

  -- An operator has to be able to open the address to see what the shop
  -- sees, and one with no company of their own holds no modules at all
  -- — so this has to be an operator who is in nothing. Asserted with
  -- `v_admin` first, it passed for the wrong reason: the helper's
  -- platform admin is also the owner of the company above, and was
  -- being let through as a member rather than as staff.
  perform pg_temp.sign_in_as(v_bare);
  perform pg_temp.check_eq('somebody in no company at all is refused',
    public.workspace_module_refusal('counter-a.iakauntan.com'),
    'Point of Sale');

  insert into public.platform_admins (user_id) values (v_bare)
    on conflict do nothing;
  perform pg_temp.check_true('but the same person as platform staff is not',
    public.workspace_module_refusal('counter-a.iakauntan.com') is null);
end $$;

rollback;
