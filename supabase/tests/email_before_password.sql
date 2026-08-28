-- =====================================================================
-- iAkauntan :: the email, asked before the password
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/email_before_password.sql
--
-- `0347`. A company's door and an address pointed at a module are both
-- for a known set of people, so the form asks who is there before it
-- asks for a password.
--
-- This is an oracle and the migration says so at length. What is
-- asserted here is therefore of two kinds, and the second matters more:
--
--   * that it answers correctly at the two addresses that have a
--     question to ask; and
--   * that it answers *true for everybody* everywhere else — the bare
--     domain, a name nobody holds, a parked name, an address of ours
--     that opens the whole product. A yes-or-no that leaked at those
--     would turn the whole platform into a directory rather than four
--     addresses an operator pointed at somebody.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_admin  uuid := pg_temp.test_user();
  v_theirs uuid;
  v_other  uuid;
  v_hasnt  uuid;
  v_member uuid := pg_temp.another_user('ali@sinar.test');
  v_out    uuid := pg_temp.another_user('stranger@elsewhere.test');
  v_till   uuid := pg_temp.another_user('cashier@kedai.test');
  v_nopos  uuid := pg_temp.another_user('clerk@tiada.test');
  v_staff  uuid := pg_temp.another_user('operator-7@iakauntan.test');
  v_messy  uuid := pg_temp.another_user('  Untidy@Sinar.test  ');
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_theirs := pg_temp.test_org('Sinar Pintu Dua');
  v_other  := pg_temp.test_org('Kedai Till');
  v_hasnt  := pg_temp.test_org('Kedai Tiada Till Dua', array['sales']);

  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_reserve_subdomain('sinar-dua', v_theirs);
  perform public.platform_reserve_subdomain('till-dua', null, 'pos', '/till',
                                            null, 'admin');
  perform public.platform_reserve_subdomain('whole-thing', null, null, null,
                                            null, 'admin');
  perform public.platform_reserve_subdomain('parked-dua', null, null, null,
                                            null, 'reserved');

  insert into public.org_members (org_id, user_id, role, status) values
    (v_theirs, v_member, 'owner', 'active'),
    (v_other,  v_till,   'sales', 'active'),
    (v_hasnt,  v_nopos,  'owner', 'active'),
    (v_theirs, v_messy,  'sales', 'active');

  -- Nobody is signed in; this is answered before there is a session.
  perform pg_temp.sign_out();
  set local role anon;

  -- ------------------------------------------------------------------
  -- A company's door
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('their own person may go on to the password',
    public.may_sign_in_here('sinar-dua.iakauntan.com', 'ali@sinar.test'));
  perform pg_temp.check_true('somebody else''s may not',
    not public.may_sign_in_here('sinar-dua.iakauntan.com',
                                'stranger@elsewhere.test'));
  -- An address nobody has ever heard of and an address belonging to
  -- another company get the same answer, which is the whole of what
  -- keeps this from being a directory of the platform.
  perform pg_temp.check_true('and neither may an address that does not exist',
    not public.may_sign_in_here('sinar-dua.iakauntan.com',
                                'nobody-at-all@nowhere.test'));

  -- ------------------------------------------------------------------
  -- An address of ours, pointed at a module
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('somebody in a company with the module may',
    public.may_sign_in_here('till-dua.iakauntan.com', 'cashier@kedai.test'));
  perform pg_temp.check_true('somebody in a company without it may not',
    not public.may_sign_in_here('till-dua.iakauntan.com',
                                'clerk@tiada.test'));

  -- ------------------------------------------------------------------
  -- Everywhere that is not for anybody in particular
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the bare domain asks nobody anything',
    public.may_sign_in_here('iakauntan.com', 'stranger@elsewhere.test'));
  perform pg_temp.check_true('nor does a name nobody holds',
    public.may_sign_in_here('nosuchname.iakauntan.com',
                            'stranger@elsewhere.test'));
  perform pg_temp.check_true('nor a parked name',
    public.may_sign_in_here('parked-dua.iakauntan.com',
                            'stranger@elsewhere.test'));
  perform pg_temp.check_true('nor one of ours that opens the whole product',
    public.may_sign_in_here('whole-thing.iakauntan.com',
                            'stranger@elsewhere.test'));
  -- Including for an address that exists nowhere: a false here would
  -- turn the bare domain into a way to test whether somebody has an
  -- account at all.
  perform pg_temp.check_true('and the bare domain says nothing about a stranger',
    public.may_sign_in_here('iakauntan.com', 'nobody-at-all@nowhere.test'));

  -- ------------------------------------------------------------------
  -- An invitation nobody accepted is not a company you are in
  --
  -- The row exists and names the company; only `status` says whether
  -- the person ever answered. Without that word the door opens for
  -- everyone who was ever asked, including people who declined by
  -- ignoring it.
  -- ------------------------------------------------------------------
  reset role;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_theirs, v_out, 'sales', 'invited');
  set local role anon;
  perform pg_temp.check_true('an unaccepted invitation opens nothing',
    not public.may_sign_in_here('sinar-dua.iakauntan.com',
                                'stranger@elsewhere.test'));

  -- ------------------------------------------------------------------
  -- Spelling, and staff
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the address is matched as people type it',
    public.may_sign_in_here('sinar-dua.iakauntan.com', '  ALI@Sinar.test '));
  perform pg_temp.check_true('and an empty box is nobody',
    not public.may_sign_in_here('sinar-dua.iakauntan.com', ''));
  -- And the other side of it: an address stored with a stray space or a
  -- capital, which is what an operator typing somebody in produces.
  perform pg_temp.check_true('a stored address is tidied too',
    public.may_sign_in_here('sinar-dua.iakauntan.com', 'untidy@sinar.test'));

  reset role;
  insert into public.platform_admins (user_id) values (v_staff)
    on conflict do nothing;
  set local role anon;
  perform pg_temp.check_true('platform staff open an address of ours',
    public.may_sign_in_here('till-dua.iakauntan.com',
                            'operator-7@iakauntan.test'));
  reset role;
end $$;

rollback;
