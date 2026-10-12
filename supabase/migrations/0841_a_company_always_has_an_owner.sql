-- =====================================================================
-- iAkauntan :: 0841 a company always has an owner
--
-- `0720` names the invariant -- "a company always has an owner", since a
-- company with no owner is one nobody can close or hand over -- and
-- `0451` says the policies keep it: "A company can never be orphaned".
-- Both are true of the platform's functions and of `transfer_company`.
-- Neither is true of `0284`'s update policy, which lets an owner update
-- their own row and lets an admin update anybody's but the owner's,
-- asking nothing of the columns. And `0839`, which shut the insert, left
-- the update as the other way to put somebody in a seat.
--
-- Measured on 12 October 2026, locally, with the role `authenticated`.
-- As the sole owner: demoting themselves to admin was accepted, and the
-- company had no owner; suspending themselves was accepted, and it had
-- no active one; pointing their own row at another account was
-- accepted -- the company handed over with no `company_transfers` row
-- and without the recipient being asked. As an admin: a pending
-- invitation's row pointed at their own second account and made active
-- was accepted, the invitation never accepted; an invitation's
-- fortnight stretched to ten years was accepted. The team screen writes
-- `role` and nothing else; every function that writes a membership is a
-- definer.
--
-- Answered "guard the seat and the owner": a trigger refuses a client's
-- own statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- that changes whose seat a membership is (`org_id`, `user_id`,
-- `invited_email`), the invitation behind it (`invited_by`,
-- `invite_token`, `invite_expires_at`, `joined_at`) or the firm it came
-- through (`via_firm_id`), and one that would leave a company with no
-- active owner. A role, a status and an access type are changed as
-- before, so long as an active owner remains. NOT security definer: a
-- definer would always answer "the owner".
--
-- Production held nineteen companies on 12 October, each with an active
-- owner; no membership was suspended and no invitation outlived its
-- fortnight.
-- =====================================================================

create or replace function app.a_company_always_has_an_owner()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',
    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',
    'via_firm_id'];
  v_new jsonb;
  v_old jsonb;
  v_col text;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  v_new := to_jsonb(new);
  v_old := to_jsonb(old);
  foreach v_col in array c_seat loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'The % of a membership is set when somebody is invited, accepts '
        'or is handed the company, not by hand.',
        v_col
        using errcode = '42501';
    end if;
  end loop;

  -- The caller passed `can_admin`, so every member of the company is
  -- theirs to see.
  if old.role = 'owner' and old.status = 'active'
     and (new.role <> 'owner' or new.status <> 'active')
     and not exists (select 1 from public.org_members m
                      where m.org_id = old.org_id and m.id <> old.id
                        and m.role = 'owner' and m.status = 'active') then
    raise exception
      'This is the company''s only owner, and a company always has one. '
      'Ownership is handed over with transfer_company, which leaves the '
      'outgoing owner an admin.'
      using errcode = '42501';
  end if;
  return new;
end $$;

revoke all on function app.a_company_always_has_an_owner()
  from public, anon, authenticated;

comment on function app.a_company_always_has_an_owner() is
  'Before an update on org_members: refuses a client''s own statement '
  'that changes org_id, user_id, invited_email, invited_by, '
  'invite_token, invite_expires_at, joined_at or via_firm_id, or that '
  'leaves the company with no active owner. The invitation and '
  'handover functions pass. 0841.';

create trigger a_company_always_has_an_owner
  before update on public.org_members
  for each row execute function app.a_company_always_has_an_owner();
