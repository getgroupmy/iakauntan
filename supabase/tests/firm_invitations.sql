-- =====================================================================
-- iAkauntan :: inviting somebody into the practice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/firm_invitations.sql
--
-- `firm_portfolio.sql` asserts what a joiner can see once they are in
-- the firm, and makes them with a direct insert. That leaves the only
-- way the app has of putting somebody there -- `invite_firm_member`,
-- which `firms_repository.dart` calls and nothing else -- with no
-- assertion on it at all. It raised 42804 on every call from 0450 to
-- 0483 and nothing said so.
--
-- These assertions go through the function, for the two cases it is
-- written to tell apart: an address that already answers to an account,
-- and one that does not yet.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- The invitation as one line, or the message it refused with.
create or replace function pg_temp.invite(
  p_firm uuid, p_email text, p_role text default 'staff')
returns text language plpgsql as $$
declare v_id uuid; v_row public.firm_members;
begin
  v_id := public.invite_firm_member(p_firm, p_email, p_role::app.firm_role);
  select * into v_row from public.firm_members where id = v_id;
  return v_row.role::text || ' ' || v_row.status::text
      || case when v_row.user_id is null then ' (no account)'
              else ' (joined)' end;
exception when others then return SQLERRM;
end $$;

do $$
declare
  v_firm   uuid;
  v_org    uuid;
  v_joiner uuid;
  v_n      integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_firm := public.create_firm('Kira Invitations', '202601000999',
                               'hello@kira-invite.test', '03-1234 0000');
  v_org  := pg_temp.test_org('Pelanggan Jemputan Sdn Bhd');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform public.attach_company_to_firm(v_org, v_firm, 'accounts_clerk');

  -- Somebody who already banks with us.
  v_joiner := pg_temp.another_user('joiner-0483@iakauntan.test');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.check_eq(
    'a colleague who already has an account can be invited',
    pg_temp.invite(v_firm, 'joiner-0483@iakauntan.test', 'manager'),
    'manager active (joined)');

  perform pg_temp.check_true('and is a member from the moment they are invited',
    (select joined_at is not null from public.firm_members
      where firm_id = v_firm and user_id = v_joiner));

  select count(*) into v_n from public.org_members
   where org_id = v_org and user_id = v_joiner and via_firm_id = v_firm;
  perform pg_temp.check_eq(
    'who gets the firm''s clients without being invited to each one',
    v_n, 1);
  perform pg_temp.check_eq('at the role that client agreed to',
    (select role::text from public.org_members
      where org_id = v_org and user_id = v_joiner), 'accounts_clerk');

  -- The address of somebody who has not signed up yet. The row is the
  -- invitation itself: no account to point at, and a token to answer.
  perform pg_temp.check_eq('an address with no account is invited, not joined',
    pg_temp.invite(v_firm, 'baru-0483@iakauntan.test'),
    'staff invited (no account)');
  perform pg_temp.check_true('and it carries a token that expires',
    (select invite_token is not null and invite_expires_at > now()
       from public.firm_members
      where firm_id = v_firm
        and invited_email = 'baru-0483@iakauntan.test'));
  perform pg_temp.check_true('and no company access, because nobody to give it to',
    not exists (select 1 from public.org_members
                 where org_id = v_org and via_firm_id = v_firm
                   and user_id is null));

  -- Promoting somebody already in the office.
  perform pg_temp.check_eq(
    'inviting somebody again changes what they are, not how many they are',
    pg_temp.invite(v_firm, 'joiner-0483@iakauntan.test', 'partner'),
    'partner active (joined)');
  select count(*) into v_n from public.firm_members
   where firm_id = v_firm and user_id = v_joiner;
  perform pg_temp.check_eq('still one row for them', v_n, 1);

  -- An address is the one thing an invitation cannot do without.
  perform pg_temp.check_eq('an invitation needs an address',
    pg_temp.invite(v_firm, '   '), 'An invitation needs an address.');

  -- And who may send one.
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-0483@iakauntan.test'));
  perform pg_temp.check_eq('somebody who does not run the firm may not invite',
    pg_temp.invite(v_firm, 'sesiapa-0483@iakauntan.test'),
    'Only a partner or manager may invite');

  raise notice 'firm invitations: all assertions passed';
end $$;

rollback;
