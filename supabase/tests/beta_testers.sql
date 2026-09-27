-- =====================================================================
-- iAkauntan :: the beta list and the button it turns on
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/beta_testers.sql
--
-- `0663` adds a list of people who see a floating report button on
-- every screen. Being on it gates no data, so the interesting
-- assertions are not about what a tester can read. They are about
-- these three:
--
--   1. **Nobody can put themselves on it.** The table has no write
--      policy and every writer is guarded, and both halves need
--      saying: a guard on a function is worthless if the table is
--      writable underneath it.
--   2. **`am_i_a_beta_tester` answers about the CALLER.** It takes no
--      argument, which is the design, and this asserts that two
--      different signed-in people get two different answers rather
--      than the function reading whichever row it finds first.
--   3. **The console's list survives its own foreign keys.**
--      `added_by` is ON DELETE SET NULL, so a tester added by somebody
--      who has since left must still appear -- an inner join there
--      would drop rows from the console while leaving the button on
--      those testers' screens, which is the worst shape this feature
--      can fail in: invisible to the people who would fix it.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.make_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

-- ---------------------------------------------------------------------
-- Who may put somebody on the list
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_ordinary uuid; v_target uuid;
begin
  v_admin    := pg_temp.test_user();
  v_ordinary := pg_temp.another_user('ordinary@iakauntan.test');
  v_target   := pg_temp.another_user('tester@iakauntan.test');
  perform pg_temp.make_platform_admin(v_admin);

  -- An ordinary signed-in person, assigning somebody else.
  perform pg_temp.sign_in_as(v_ordinary);
  perform pg_temp.check_refused(
    'an ordinary user cannot put somebody on the beta list',
    format('select public.assign_beta_tester(%L)', v_target),
    '%Insufficient privileges%', '42501');

  -- And assigning THEMSELVES, which is the one that matters. A guard
  -- that only refused other people would be no guard at all.
  perform pg_temp.check_refused(
    'and cannot put themselves on it either',
    format('select public.assign_beta_tester(%L)', v_ordinary),
    '%Insufficient privileges%', '42501');

  perform pg_temp.sign_in_as(v_admin);
  perform public.assign_beta_tester(v_target, 'Trying the new till');
  perform pg_temp.check_true(
    'a platform administrator can',
    exists (select 1 from public.beta_testers where user_id = v_target));
end $$;

-- ---------------------------------------------------------------------
-- Going round the function, as a client role rather than as the owner
--
-- `pg_temp.sign_in_as` sets the JWT claim and nothing else: the session
-- is still `postgres`, which owns this table and is exempt from row
-- level security. So a `check_refused` on a direct insert passes as the
-- owner -- the insert SUCCEEDS -- and says nothing about the client.
-- Written that way first, and it failed with "it was not refused at
-- all", which is the good outcome.
--
-- `set local role` does not survive a `do` block, so it is issued at
-- the top level, following `audit_redaction.sql` and
-- `no_tenant_sees_another.sql`.
-- ---------------------------------------------------------------------
create temp table t_663 as
select pg_temp.test_user() as admin_user,
       pg_temp.another_user('direct@iakauntan.test') as tester;

-- The fixture has to be readable BY the client role too, or the block
-- below fails on "permission denied for table t_663" before it reaches
-- anything worth asserting. `audit_redaction.sql` grants for the same
-- reason.
grant select on t_663 to authenticated;

do $$
declare c record;
begin
  select * into c from t_663;
  perform pg_temp.make_platform_admin(c.admin_user);
  perform pg_temp.sign_in_as(c.admin_user);
  perform public.assign_beta_tester(c.tester, 'On the list already');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select tester from t_663),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_seen integer;
begin
  select * into c from t_663;
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');

  -- What the app does on sign-in, through the policy rather than
  -- through the function. A grant AND a policy, which is `0662`'s
  -- lesson said forwards: the policy alone would leave this
  -- "permission denied for table".
  select count(*) into v_seen from public.beta_testers;
  perform pg_temp.check_eq('a tester reads their own row', v_seen, 1);

  -- And the write path, which has TWO independent locks on it: there
  -- is no INSERT grant, and there is no write policy. Postgres checks
  -- the table privilege before it reaches row level security, so it is
  -- the grant that speaks -- deterministically, which is why this can
  -- name the message rather than swallowing whatever came back.
  --
  -- The policy behind it is not decoration. Grant INSERT here one day
  -- for some other reason and RLS is what still refuses this.
  perform pg_temp.check_refused(
    'and cannot add a row to it',
    format('insert into public.beta_testers (user_id) values (%L)',
           c.tester),
    '%permission denied for table beta_testers%');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The question the app asks on sign-in
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_tester uuid; v_other uuid;
begin
  v_admin  := pg_temp.test_user();
  v_tester := pg_temp.another_user('onthelist@iakauntan.test');
  v_other  := pg_temp.another_user('offthelist@iakauntan.test');
  perform pg_temp.make_platform_admin(v_admin);

  perform pg_temp.sign_in_as(v_admin);
  perform public.assign_beta_tester(v_tester);

  -- Two people, two answers. The function takes no argument, so an
  -- implementation that read the table without filtering on auth.uid()
  -- would say true to both -- and every tester assertion would pass
  -- while the button appeared for the whole platform.
  perform pg_temp.sign_in_as(v_tester);
  perform pg_temp.check_eq(
    'somebody on the list is told so',
    public.am_i_a_beta_tester()::text, 'true');

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_eq(
    'and somebody who is not, is not',
    public.am_i_a_beta_tester()::text, 'false');

  -- Signed out. `auth.uid()` is null, and `exists` over a null
  -- comparison is false rather than an error -- worth pinning, because
  -- the shopfront calls this before anybody has signed in.
  perform pg_temp.sign_out();
  perform pg_temp.check_eq(
    'and nobody at all is not',
    public.am_i_a_beta_tester()::text, 'false');
end $$;

-- ---------------------------------------------------------------------
-- Taking somebody off
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_tester uuid; v_ordinary uuid;
begin
  v_admin    := pg_temp.test_user();
  v_tester   := pg_temp.another_user('removable@iakauntan.test');
  v_ordinary := pg_temp.another_user('nobody@iakauntan.test');
  perform pg_temp.make_platform_admin(v_admin);

  perform pg_temp.sign_in_as(v_admin);
  perform public.assign_beta_tester(v_tester);

  -- A tester cannot take themselves off either. Harmless if they
  -- could, and still the same table: a write path that opens one way
  -- opens both.
  perform pg_temp.sign_in_as(v_tester);
  perform pg_temp.check_refused(
    'a tester cannot take themselves off the list',
    format('select public.remove_beta_tester(%L)', v_tester),
    '%Insufficient privileges%', '42501');

  perform pg_temp.sign_in_as(v_ordinary);
  perform pg_temp.check_refused(
    'and neither can a bystander',
    format('select public.remove_beta_tester(%L)', v_tester),
    '%Insufficient privileges%', '42501');

  perform pg_temp.sign_in_as(v_admin);
  perform public.remove_beta_tester(v_tester);
  perform pg_temp.sign_in_as(v_tester);
  perform pg_temp.check_eq(
    'a platform administrator can, and the button goes',
    public.am_i_a_beta_tester()::text, 'false');
end $$;

-- ---------------------------------------------------------------------
-- Assigning twice
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_tester uuid;
begin
  v_admin  := pg_temp.test_user();
  v_tester := pg_temp.another_user('twice@iakauntan.test');
  perform pg_temp.make_platform_admin(v_admin);
  perform pg_temp.sign_in_as(v_admin);

  perform public.assign_beta_tester(v_tester, 'First reason');
  -- Not an error. The console shows who is already on the list, so
  -- somebody reaching here twice meant to change the reason.
  perform public.assign_beta_tester(v_tester, 'Second reason');
  perform pg_temp.check_eq(
    'assigning twice updates the note rather than failing',
    (select note from public.beta_testers where user_id = v_tester),
    'Second reason');

  -- And assigning with no note leaves the reason that was there,
  -- rather than blanking it.
  perform public.assign_beta_tester(v_tester);
  perform pg_temp.check_eq(
    'and assigning with no note keeps the one already written',
    (select note from public.beta_testers where user_id = v_tester),
    'Second reason');

  perform pg_temp.check_refused(
    'a uuid that is nobody is refused by name',
    format('select public.assign_beta_tester(%L)', gen_random_uuid()),
    '%No such user%', '23503');
end $$;

-- ---------------------------------------------------------------------
-- The console's list
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_leaver uuid; v_tester uuid; v_ordinary uuid;
  v_rows integer;
begin
  v_admin    := pg_temp.test_user();
  v_leaver   := pg_temp.another_user('leaver@iakauntan.test');
  v_tester   := pg_temp.another_user('listed@iakauntan.test');
  v_ordinary := pg_temp.another_user('curious@iakauntan.test');
  perform pg_temp.make_platform_admin(v_admin);
  perform pg_temp.make_platform_admin(v_leaver);

  perform pg_temp.sign_in_as(v_leaver);
  perform public.assign_beta_tester(v_tester, 'Added by somebody leaving');

  perform pg_temp.sign_in_as(v_ordinary);
  perform pg_temp.check_refused(
    'an ordinary user cannot read the beta list',
    'select * from public.beta_testers_list()',
    '%Insufficient privileges%', '42501');

  perform pg_temp.sign_in_as(v_admin);
  select count(*) into v_rows from public.beta_testers_list()
   where user_id = v_tester;
  perform pg_temp.check_eq(
    'a platform administrator sees the row', v_rows, 1);

  -- THE ONE. `added_by` is ON DELETE SET NULL, so the person who added
  -- a tester can leave. An inner join to their profile would drop the
  -- tester from the console while the button stayed on their screen --
  -- a privilege nobody can see to revoke.
  delete from auth.users where id = v_leaver;
  select count(*) into v_rows from public.beta_testers_list()
   where user_id = v_tester;
  perform pg_temp.check_eq(
    'and still sees it after the person who added them has gone',
    v_rows, 1);
end $$;

-- ---------------------------------------------------------------------
-- The picker behind the console's search box
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_target uuid; v_ordinary uuid;
  v_rows integer; v_beta boolean;
begin
  v_admin    := pg_temp.test_user();
  v_target   := pg_temp.another_user('findme@iakauntan.test');
  v_ordinary := pg_temp.another_user('snooper@iakauntan.test');
  perform pg_temp.make_platform_admin(v_admin);

  update public.profiles set full_name = 'Siti Rahmah' where id = v_target;

  perform pg_temp.sign_in_as(v_ordinary);
  perform pg_temp.check_refused(
    'an ordinary user cannot search the platform''s people',
    'select * from public.search_platform_users(''siti'')',
    '%Insufficient privileges%', '42501');

  perform pg_temp.sign_in_as(v_admin);
  select count(*) into v_rows
    from public.search_platform_users('siti') where user_id = v_target;
  perform pg_temp.check_eq('a platform administrator finds them by name',
    v_rows, 1);

  select count(*) into v_rows
    from public.search_platform_users('findme') where user_id = v_target;
  perform pg_temp.check_eq('and by e-mail', v_rows, 1);

  -- One letter comes back with nothing. A directory of every user on
  -- the platform is not what a search box is for, and the refusal is
  -- silent because "keep typing" is what an empty result already says.
  select count(*) into v_rows from public.search_platform_users('s');
  perform pg_temp.check_eq('one character returns nothing', v_rows, 0);
  select count(*) into v_rows from public.search_platform_users('');
  perform pg_temp.check_eq('and so does an empty search', v_rows, 0);
  select count(*) into v_rows from public.search_platform_users(null);
  perform pg_temp.check_eq('and so does no search at all', v_rows, 0);

  -- The flag the console draws a tick from. Without it the picker
  -- offers somebody who is already on the list, and the only way to
  -- find out is to add them twice.
  select is_beta into v_beta
    from public.search_platform_users('siti') where user_id = v_target;
  perform pg_temp.check_eq('somebody not on the list is marked so',
    v_beta::text, 'false');

  perform public.assign_beta_tester(v_target);
  select is_beta into v_beta
    from public.search_platform_users('siti') where user_id = v_target;
  perform pg_temp.check_eq('and somebody on it is marked so too',
    v_beta::text, 'true');

  -- The limit is clamped rather than trusted. A caller asking for a
  -- thousand gets fifty; one asking for zero gets one, not an empty
  -- result that reads as "nobody by that name".
  select count(*) into v_rows
    from public.search_platform_users('siti', 0);
  perform pg_temp.check_true('a limit of zero still returns somebody',
    v_rows >= 1);
end $$;

rollback;
