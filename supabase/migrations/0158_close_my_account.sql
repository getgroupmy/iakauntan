-- =====================================================================
-- iAkauntan :: 0158 closing an account
--
-- There was no way for a person to remove themselves. Every screen could
-- add somebody, invite somebody, change what they may do — and nothing
-- could end it. For a system holding a national identity number, a bank
-- account, a date of birth and a salary, that is the gap that matters.
--
-- ---------------------------------------------------------------------
-- Why this anonymises rather than deletes
--
-- Not a compromise, and not laziness. `auth.users` is referenced by
-- about a hundred foreign keys and almost all of them are ON DELETE NO
-- ACTION: `gl_entries.posted_by`, `payroll_runs.approved_by`,
-- `corp_signatures.signed_by`, `fiscal_years.closed_by`. Those columns
-- are the audit trail. A journal that cannot say who posted it is not
-- evidence of anything, and a set of accounts whose trail has been
-- deleted is one nobody can rely on.
--
-- So deleting the row is not available: the database would refuse it,
-- and the two ways round that refusal — cascading the delete, or
-- nulling the trail — both destroy the record the Companies Act 2016
-- s.245 and the Income Tax Act 1967 s.82 require to be kept for seven
-- years.
--
-- What is actually personal data is the *identity*: name, email, phone,
-- avatar. That is scrubbed. What remains is a user id attached to
-- "Deleted user", which says a person did this without saying which
-- person — which is what anonymisation means, and is permitted under
-- PDPA 2010 where retention is required by other law.
--
-- Payroll and ledger records are a separate question and are not touched
-- here. An employee's payslip belongs to the employer's statutory
-- records, not to the account that happened to log in.
--
-- ---------------------------------------------------------------------
-- The one refusal
--
-- The sole owner of an organization cannot close their account. Doing so
-- would leave a company's books with nobody able to administer them, no
-- way to invite a replacement, and no way back in — an orphaned tenant
-- that only a platform administrator could rescue. Hand the ownership
-- over first. `my_account_deletion_blockers` says so before the button
-- is pressed rather than after.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What stands in the way, if anything
-- ---------------------------------------------------------------------
create or replace function public.my_account_deletion_blockers()
returns table (organization text, reason text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.name,
         'You are the only owner. Make somebody else an owner first, or '
         'the company is left with nobody who can administer it.'
    from public.org_members m
    join public.organizations o on o.id = m.org_id
   where m.user_id = auth.uid() and m.role = 'owner'
     and (select count(*) from public.org_members x
           where x.org_id = m.org_id and x.role = 'owner') = 1
   order by o.name;
$$;

revoke all on function public.my_account_deletion_blockers() from public, anon;
grant execute on function public.my_account_deletion_blockers() to authenticated;

-- ---------------------------------------------------------------------
-- Closing it
-- ---------------------------------------------------------------------
create or replace function public.delete_my_account()
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_user    uuid := auth.uid();
  v_blocked text;
  v_orgs    integer;
  v_tokens  integer;
  v_tag     text;
begin
  if v_user is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  select string_agg(b.organization, ', ') into v_blocked
    from public.my_account_deletion_blockers() b;

  if v_blocked is not null then
    raise exception
      'You are the only owner of %. Closing your account would leave the '
      'company with nobody who can administer it. Make somebody else an '
      'owner first.', v_blocked
      using errcode = '23514';
  end if;

  -- Unique, non-routable, and obviously not a real address. `.invalid`
  -- is reserved by RFC 2606 precisely so it can never resolve, which
  -- matters because the row keeps a UNIQUE constraint on email.
  v_tag := 'deleted-' || replace(v_user::text, '-', '') || '@deleted.invalid';

  -- Access first. If anything below fails the transaction rolls back, so
  -- order is presentational rather than load-bearing — but membership is
  -- the thing that actually grants sight of other people's data.
  delete from public.org_members where user_id = v_user;
  get diagnostics v_orgs = row_count;

  -- Push targets: a device that keeps receiving notifications for a
  -- closed account is the most visible way to get this wrong.
  delete from public.device_tokens where user_id = v_user;
  get diagnostics v_tokens = row_count;

  delete from public.chat_presence where user_id = v_user;
  delete from public.chat_typing where user_id = v_user;

  -- The identity.
  update public.profiles
     set full_name = 'Deleted user',
         email = null,
         phone = null,
         avatar_url = null,
         updated_at = now()
   where id = v_user;

  -- And in the auth schema, where the addressable copy lives. Banned
  -- rather than deleted: the row has to stay for the foreign keys, and
  -- `banned_until` is what GoTrue checks before issuing a token, so this
  -- shuts the door rather than merely emptying the nameplate.
  update auth.users
     set email = v_tag,
         phone = null,
         email_change = '',
         phone_change = '',
         raw_user_meta_data = '{}'::jsonb,
         banned_until = 'infinity'::timestamptz,
         updated_at = now()
   where id = v_user;

  -- Anything already issued stops working now rather than at expiry.
  delete from auth.sessions where user_id = v_user;
  delete from auth.refresh_tokens where user_id = v_user::text;

  return jsonb_build_object(
    'anonymised', true,
    'organizations_left', v_orgs,
    'devices_forgotten', v_tokens);
end $$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  'Anonymises the signed-in account: identity scrubbed from profiles and '
  'auth.users, membership and push tokens removed, sessions killed. The '
  'user row itself stays because a hundred audit columns reference it, '
  'and a ledger that cannot say who posted an entry is not a ledger.';
