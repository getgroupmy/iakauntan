-- =====================================================================
-- iAkauntan :: the firm that keeps other people's books
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/firm_portfolio.sql
--
-- 0450 added a practice: a firm, its staff, and the companies it keeps
-- the books for. The decision the whole thing rests on is that
-- attaching a company grants access by writing ordinary `org_members`
-- rows rather than by widening `app.is_org_member`, so none of the
-- three hundred policies in this schema changes meaning.
--
-- These assertions are about the consequences of that decision, in the
-- order somebody would meet them: a firm exists, it gains a client, a
-- new person joins the office, the client takes the work elsewhere.
--
-- Two distinct people are needed and this suite hands out one --
-- `pg_temp.test_user()` returns the same fixture user every time and
-- that user owns every company `pg_temp.test_org` builds -- so the
-- second is created here.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A practice, and the person who started it
-- ---------------------------------------------------------------------
do $$
declare
  v_firm  uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_firm := public.create_firm('Kira & Rakan', '202601000123',
                               'hello@kira.test', '03-1234 5678');

  perform pg_temp.check_true('a firm can be started', v_firm is not null);

  select count(*) into v_n from public.firm_members
   where firm_id = v_firm and user_id = pg_temp.test_user()
     and role = 'partner' and status = 'active';
  perform pg_temp.check_eq(
    'and whoever starts it is a partner in it', v_n, 1);

  -- Or nobody could ever invite anybody to it.
  perform pg_temp.check_true('who may manage it',
    app.can_manage_firm(v_firm));

  perform pg_temp.check_eq('it appears in their own list',
    (select count(*)::integer from public.my_firms() f where f.id = v_firm),
    1);
end $$;

-- ---------------------------------------------------------------------
-- A client, and what appointing the firm actually does
-- ---------------------------------------------------------------------
do $$
declare
  v_firm   uuid;
  v_org    uuid;
  v_n      integer;
  v_role   app.member_role;
  v_staff  uuid;
  v_took   boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_firm := public.create_firm('Akaun Bersama');
  v_org  := pg_temp.test_org('Pelanggan Pertama Sdn Bhd');

  -- A member of staff who is not the client's owner. The fixture's one
  -- user owns every company it builds, so without this the firm's only
  -- person would already be a member in their own right and the
  -- appointment would have nothing to grant -- which is correct
  -- behaviour and a useless test.
  insert into auth.users (
    id, email, created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token, email_change, phone_change)
  values (gen_random_uuid(), 'staff-0450@iakauntan.test', now(), now(),
          '', '', '', '', '', '', '', '')
  returning id into v_staff;

  insert into public.firm_members (firm_id, user_id, role, status, joined_at)
  values (v_firm, v_staff, 'staff', 'active', now());

  perform public.attach_company_to_firm(v_org, v_firm, 'accountant');

  select count(*) into v_n from public.org_members
   where org_id = v_org and via_firm_id = v_firm;
  perform pg_temp.check_eq(
    'appointing a firm gives its people membership', v_n, 1);

  select role into v_role from public.org_members
   where org_id = v_org and via_firm_id = v_firm limit 1;
  perform pg_temp.check_eq('at the role the client chose',
    v_role::text, 'accountant');

  -- And the owner, who is also at the firm in this fixture, keeps the
  -- membership they already had rather than being demoted to it.
  perform pg_temp.check_eq('while the owner stays the owner',
    (select role::text from public.org_members
      where org_id = v_org and user_id = pg_temp.test_user()), 'owner');
  perform pg_temp.check_true('by their own right, not the firm''s',
    (select via_firm_id from public.org_members
      where org_id = v_org and user_id = pg_temp.test_user()) is null);

  -- The company records who keeps its books, which is what the
  -- portfolio is built on.
  perform pg_temp.check_eq('and the company knows who keeps its books',
    (select firm_id from public.organizations where id = v_org), v_firm);

  perform pg_temp.check_eq('the client appears in the portfolio',
    (select count(*)::integer from public.firm_portfolio(v_firm) p
      where p.org_id = v_org), 1);

  -- A practice keeps books. It does not quietly become the owner
  -- through the door marked bookkeeping.
  begin
    perform public.attach_company_to_firm(v_org, v_firm, 'owner');
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('a firm cannot make itself the owner',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- The new joiner, and the person who was there already
-- ---------------------------------------------------------------------
do $$
declare
  v_firm  uuid;
  v_org   uuid;
  v_other uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_firm := public.create_firm('Kira Tiga');
  v_org  := pg_temp.test_org('Pelanggan Kedua Sdn Bhd');
  perform public.attach_company_to_firm(v_org, v_firm, 'accounts_clerk');

  -- Somebody joins the office after the client was taken on. The point
  -- of a portfolio is that they do not have to be invited to forty
  -- companies one at a time.
  insert into auth.users (
    id, email, created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token, email_change, phone_change)
  values (gen_random_uuid(), 'joiner-0450@iakauntan.test', now(), now(),
          '', '', '', '', '', '', '', '')
  returning id into v_other;

  insert into public.firm_members
    (firm_id, user_id, role, status, joined_at)
  values (v_firm, v_other, 'staff', 'active', now());

  perform app.sync_firm_access(v_firm);

  select count(*) into v_n from public.org_members
   where org_id = v_org and user_id = v_other and via_firm_id = v_firm;
  perform pg_temp.check_eq(
    'a new joiner gets the firm''s clients', v_n, 1);

  perform pg_temp.check_eq('at the role that client agreed to',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_other), 'accounts_clerk');
end $$;

-- ---------------------------------------------------------------------
-- Taking the work elsewhere
-- ---------------------------------------------------------------------
do $$
declare
  v_firm  uuid;
  v_org   uuid;
  v_own   uuid;
  v_staff uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_firm := public.create_firm('Kira Empat');
  v_org  := pg_temp.test_org('Pelanggan Ketiga Sdn Bhd');

  -- Somebody the client invited themselves, before the firm ever
  -- appeared. This row is the whole reason `via_firm_id` exists.
  insert into auth.users (
    id, email, created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token, email_change, phone_change)
  values (gen_random_uuid(), 'bookkeeper-0450@iakauntan.test', now(), now(),
          '', '', '', '', '', '', '', '')
  returning id into v_own;

  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_own, 'accountant', 'active', now());

  -- And somebody at the firm who is nobody at the company.
  insert into auth.users (
    id, email, created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token, email_change, phone_change)
  values (gen_random_uuid(), 'staff4-0450@iakauntan.test', now(), now(),
          '', '', '', '', '', '', '', '')
  returning id into v_staff;

  insert into public.firm_members (firm_id, user_id, role, status, joined_at)
  values (v_firm, v_staff, 'staff', 'active', now());

  perform public.attach_company_to_firm(v_org, v_firm, 'accountant');

  select count(*) into v_n from public.org_members where org_id = v_org;
  perform pg_temp.check_eq('three people can see the books', v_n, 3);

  perform public.detach_company_from_firm(v_org);

  select count(*) into v_n from public.org_members
   where org_id = v_org and via_firm_id is not null;
  perform pg_temp.check_eq('detaching takes the firm''s access away', v_n, 0);

  select count(*) into v_n from public.org_members
   where org_id = v_org and user_id = v_own;
  perform pg_temp.check_eq(
    'and detaching leaves the client''s own people alone', v_n, 1);

  perform pg_temp.check_true('the owner is still the owner',
    exists (select 1 from public.org_members
             where org_id = v_org and role = 'owner' and status = 'active'));

  perform pg_temp.check_true('and the company keeps no firm',
    (select firm_id from public.organizations where id = v_org) is null);

  -- The books did not move. That is the point of the whole design: a
  -- company was never inside the firm, so there is nothing to extract.
  perform pg_temp.check_true('while its books stayed where they were',
    exists (select 1 from public.accounts where org_id = v_org));
end $$;

-- ---------------------------------------------------------------------
-- A firm you have nothing to do with
-- ---------------------------------------------------------------------
do $$
declare
  v_firm  uuid;
  v_org   uuid;
  v_other uuid;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- A practice run by somebody else entirely.
  insert into auth.users (
    id, email, created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token, email_change, phone_change)
  values (gen_random_uuid(), 'stranger-0450@iakauntan.test', now(), now(),
          '', '', '', '', '', '', '', '')
  returning id into v_other;

  insert into public.firms (name, slug, created_by)
  values ('Firma Orang Lain', 'firma-orang-lain', v_other)
  returning id into v_firm;

  insert into public.firm_members (firm_id, user_id, role, status, joined_at)
  values (v_firm, v_other, 'partner', 'active', now());

  v_org := pg_temp.test_org('Pelanggan Keempat Sdn Bhd');

  -- The caller owns this company, so `can_admin` passes. What must
  -- refuse them is the firm half: handing your books to a practice
  -- that has never heard of you is not an appointment.
  begin
    perform public.attach_company_to_firm(v_org, v_firm, 'accountant');
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a stranger cannot attach a company to a firm', not v_took);

  perform pg_temp.check_true('and nobody gained access by trying',
    not exists (select 1 from public.org_members
                 where org_id = v_org and via_firm_id = v_firm));
end $$;

-- ---------------------------------------------------------------------
-- The decision underneath all of it
--
-- If `app.is_org_member` ever learns about firms, every policy in the
-- schema changes meaning at once and none of the tests above would
-- notice. So it is asserted directly.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true(
    'membership is still membership, and knows nothing of firms',
    position('firm' in pg_get_functiondef(
      to_regprocedure('app.is_org_member(uuid)'))) = 0);

  perform pg_temp.check_true(
    'and a company may never record owner as the firm''s role',
    exists (select 1 from pg_constraint
             where conname = 'firm_role_is_not_owner'));
end $$;

rollback;
