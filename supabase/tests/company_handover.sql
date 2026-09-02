-- =====================================================================
-- iAkauntan :: handing a company over
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_handover.sql
--
-- 0450 let a practice keep other people's books. 0451 answers the
-- question that follows: what happens when the books go somewhere else,
-- or when the person holding them has stopped answering the telephone.
--
-- The `org_members` policies deliberately make an owner row
-- undeletable and undemotable by anybody but its owner, so a company
-- can never be orphaned. `transfer_company` is the one operation that
-- is allowed to move that row, and `platform_force_transfer` is the
-- only way past it when the owner has gone -- which is why most of
-- what is asserted here is about who is refused.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- An owner hands the company to somebody else
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_firm  uuid;
  v_new   uuid;
  v_staff uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Kedai Lama Sdn Bhd');
  v_firm := public.create_firm('Kira Lama');

  -- Somebody at the practice, so the appointment has access to remove
  -- rather than nothing to remove.
  v_staff := pg_temp.another_user('staff-0451@iakauntan.test');
  insert into public.firm_members (firm_id, user_id, role, status, joined_at)
  values (v_firm, v_staff, 'staff', 'active', now());

  perform public.attach_company_to_firm(v_org, v_firm, 'accountant');

  -- The person taking it on. They have an account already, which 0451
  -- requires: a company whose owner is an unaccepted invitation has no
  -- owner.
  v_new := pg_temp.another_user('taking-over-0451@iakauntan.test');

  perform public.transfer_company(v_org, 'taking-over-0451@iakauntan.test',
                                  'Sold the shop');

  perform pg_temp.check_eq('the new owner is the owner',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_new), 'owner');

  -- Not through the firm. An owner whose place is borrowed could be
  -- shown the door by a practice resigning.
  perform pg_temp.check_true('and holds it in their own right',
    (select via_firm_id from public.org_members
      where org_id = v_org and user_id = v_new) is null);

  perform pg_temp.check_eq('the old owner steps down to admin',
    (select role::text from public.org_members
      where org_id = v_org and user_id = pg_temp.test_user()), 'admin');

  perform pg_temp.check_true('there is exactly one owner afterwards',
    (select count(*) from public.org_members
      where org_id = v_org and role = 'owner') = 1);

  perform pg_temp.check_true('the company is nobody''s client any more',
    (select firm_id from public.organizations where id = v_org) is null);

  select count(*) into v_n from public.org_members
   where org_id = v_org and via_firm_id = v_firm;
  perform pg_temp.check_eq(
    'and the old practice''s people are not left logged in', v_n, 0);

  -- The books did not move, because they were never anywhere else.
  perform pg_temp.check_true('while the ledger stayed where it was',
    exists (select 1 from public.accounts where org_id = v_org));

  perform pg_temp.check_eq('the handover is on the record',
    (select count(*)::integer from public.company_transfer_history(v_org)), 1);

  perform pg_temp.check_eq('with the note that came with it',
    (select h.note from public.company_transfer_history(v_org) h limit 1),
    'Sold the shop');

  perform pg_temp.check_eq('and which practice was keeping the books',
    (select h.from_firm from public.company_transfer_history(v_org) h limit 1),
    'Kira Lama');
end $$;

-- ---------------------------------------------------------------------
-- Running a company is not owning it
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_admin uuid;
  v_other uuid;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Kedua Sdn Bhd');

  v_admin := pg_temp.another_user('admin-0451@iakauntan.test');
  v_other := pg_temp.another_user('outsider-0451@iakauntan.test');

  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_admin, 'admin', 'active', now());

  -- An administrator can do everything inside this company. Giving it
  -- away is not inside it.
  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.transfer_company(v_org, 'outsider-0451@iakauntan.test', null);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'an admin cannot give away what they do not own', not v_took);

  perform pg_temp.check_eq('so the owner is still the owner',
    (select role::text from public.org_members
      where org_id = v_org and user_id = pg_temp.test_user()), 'owner');

  perform pg_temp.check_true('and the outsider gained nothing by asking',
    not exists (select 1 from public.org_members
                 where org_id = v_org and user_id = v_other));
end $$;

-- ---------------------------------------------------------------------
-- Handed to nobody, and handed to yourself
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Ketiga Sdn Bhd');

  begin
    perform public.transfer_company(v_org, 'nobody-at-all@iakauntan.test', null);
    v_took := true;
  exception when sqlstate 'P0002' then v_took := false;
  end;
  perform pg_temp.check_true('a company cannot be handed to nobody', not v_took);

  perform pg_temp.check_eq('and the owner did not step down for nothing',
    (select role::text from public.org_members
      where org_id = v_org and user_id = pg_temp.test_user()), 'owner');

  perform pg_temp.check_eq('nor was the refusal recorded as a handover',
    (select count(*)::integer from public.company_transfers where org_id = v_org),
    0);

  begin
    perform public.transfer_company(v_org, 'fixture@iakauntan.test', null);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('nor handed to the person already holding it',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- The way out when the owner has gone
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_admin  uuid;
  v_new    uuid;
  v_took   boolean;
  v_why    text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Keempat Sdn Bhd');

  v_new   := pg_temp.another_user('rescuer-0451@iakauntan.test');
  v_admin := pg_temp.another_user('operator-0451@iakauntan.test');

  -- An ordinary member of the platform is not the platform.
  perform pg_temp.sign_in_as(v_new);
  begin
    perform public.platform_force_transfer(
      v_org, 'rescuer-0451@iakauntan.test', 'because I would like it');
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a stranger cannot force a company out of its owner''s hands', not v_took);

  insert into public.platform_admins (user_id, note)
  values (v_admin, 'For the test');
  perform pg_temp.sign_in_as(v_admin);

  -- An escape hatch with no record is indistinguishable from a back
  -- door, so the reason is not optional.
  begin
    perform public.platform_force_transfer(
      v_org, 'rescuer-0451@iakauntan.test', '   ');
    v_took := true;
  exception when sqlstate '23514' then
    v_took := false;
    v_why  := sqlerrm;
  end;
  perform pg_temp.check_true('a forced handover says why in writing', not v_took);

  -- And is told so. The check constraint underneath refuses a blank
  -- reason as well, so this assertion holds either way -- but what an
  -- operator reads is the difference between being asked for a reason
  -- and being shown a constraint name.
  perform pg_temp.check_true('and is asked for one in words it can act on',
    v_why like 'Say why.%');

  perform public.platform_force_transfer(
    v_org, 'rescuer-0451@iakauntan.test',
    'Owner unreachable for 6 months; SSM filing due');

  perform pg_temp.check_eq('and then the company has an owner again',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_new), 'owner');

  perform pg_temp.check_eq('the one who could not be reached steps down',
    (select role::text from public.org_members
      where org_id = v_org and user_id = pg_temp.test_user()), 'admin');

  perform pg_temp.check_eq('the reason is kept',
    (select forced_reason from public.company_transfers
      where org_id = v_org limit 1),
    'Owner unreachable for 6 months; SSM filing due');

  perform pg_temp.check_eq('and so is who did it',
    (select forced_by from public.company_transfers
      where org_id = v_org limit 1), v_admin);
end $$;

-- ---------------------------------------------------------------------
-- Who may read the record
--
-- The handover history is the company's, not the outgoing owner's and
-- not the public's.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_new   uuid;
  v_third uuid;
  v_read  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kedai Kelima Sdn Bhd');
  v_new := pg_temp.another_user('reader-0451@iakauntan.test');
  perform public.transfer_company(v_org, 'reader-0451@iakauntan.test', null);

  v_third := pg_temp.another_user('nosy-0451@iakauntan.test');
  perform pg_temp.sign_in_as(v_third);
  begin
    perform * from public.company_transfer_history(v_org);
    v_read := true;
  exception when sqlstate '42501' then v_read := false;
  end;
  perform pg_temp.check_true(
    'somebody with nothing to do with the company reads nothing', not v_read);

  perform pg_temp.sign_in_as(v_new);
  perform pg_temp.check_eq('the new owner can see how they got it',
    (select count(*)::integer from public.company_transfer_history(v_org)), 1);
end $$;

rollback;
