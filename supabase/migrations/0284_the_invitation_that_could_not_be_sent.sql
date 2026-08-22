-- =====================================================================
-- iAkauntan :: 0284 the invitation that could not be sent
--
-- Two faults in public.invite_member, which is how anybody is let into
-- a company. Neither has ever been exercised: no test called it, so
-- both have sat here since 0022.
--
-- 1. It cannot issue an invitation at all.
--
--    The token comes from `encode(gen_random_bytes(24), 'hex')`, and
--    gen_random_bytes is pgcrypto, which on a Supabase database lives
--    in the `extensions` schema. The function is pinned to
--    `set search_path = public, app, pg_temp`, which cannot see it, so
--    the insert dies with
--
--      function gen_random_bytes(integer) does not exist
--
--    This repository already knows the rule and wrote it down in 0070:
--    "gen_random_bytes() is pgcrypto and so out of reach here; two v4
--    UUIDs give 122 bits each from the same CSPRNG." 0069, 0185 and
--    0223 all work around the same thing. 0022 predates the lesson.
--
--    The fix is app.corp_new_token(), which is that workaround, already
--    in `app` and so already on this function's search_path. It yields
--    244 bits where the dead call asked for 192.
--
-- 2. An admin can demote the owner, and nothing can undo it.
--
--    Inviting somebody who is already a member is treated as a change
--    of role:
--
--      select m.id into v_existing ... where pr.email = v_email;
--      if v_existing is not null then
--        update public.org_members set role = p_role where id = v_existing;
--
--    with no regard for what that member is now. app.can_admin is owner
--    or admin, so any admin can call invite_member with the owner's own
--    email address and a role of `viewer`, and the owner becomes a
--    viewer. Confirmed on the harness: the fixture owner went from
--    `owner` to `viewer` in one call by an admin.
--
--    It does not undo. invite_member refuses to hand out `owner`
--    ("Ownership is transferred, not invited"), and no other function
--    in the schema sets a member's role to owner -- the only other
--    place the value appears is close_my_account, which reads it. A
--    company whose owner is demoted has no owner and no way back
--    through the application.
--
--    The same sentence the function already uses for the other half of
--    this rule covers it: an owner's role is not something an invite
--    changes. Demoting an owner, if it is ever wanted, is a transfer of
--    ownership and needs a function that says so, with the checks a
--    transfer deserves.
-- =====================================================================

create or replace function public.invite_member(
  p_org_id uuid, p_email text, p_role app.member_role)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid; v_existing uuid; v_existing_role app.member_role;
  v_email citext := lower(trim(p_email))::citext;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin can invite people' using errcode = '42501';
  end if;
  if p_role = 'owner' then
    raise exception 'Ownership is transferred, not invited';
  end if;
  if v_email is null or v_email = '' then
    raise exception 'An email address is required';
  end if;

  -- Already a member? Just adjust their role -- unless they are the
  -- owner, whose role an invitation does not get to change.
  select m.id, m.role into v_existing, v_existing_role
    from public.org_members m
    join public.profiles pr on pr.id = m.user_id
   where m.org_id = p_org_id and pr.email = v_email;

  if v_existing is not null then
    if v_existing_role = 'owner' then
      raise exception
        'Ownership is transferred, not invited. % already owns this company.',
        v_email using errcode = '42501';
    end if;
    update public.org_members set role = p_role where id = v_existing;
    return v_existing;
  end if;

  insert into public.org_members (
    org_id, invited_email, role, status, invited_by,
    invite_token, invite_expires_at)
  values (
    p_org_id, v_email, p_role, 'invited', auth.uid(),
    -- Not gen_random_bytes: pgcrypto is in `extensions`, which this
    -- function's pinned search_path cannot see. app.corp_new_token is
    -- 0070's answer to the same problem.
    app.corp_new_token(), now() + interval '14 days')
  on conflict (org_id, user_id) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from a newly created
-- function, so the grant is written back after every re-create.
grant execute on function public.invite_member(uuid, text, app.member_role)
  to authenticated;

-- ---------------------------------------------------------------------
-- 3. And the same demotion, without going through the function at all
--
-- Fixing invite_member only closes one door. org_members is a table
-- `authenticated` holds UPDATE on, and its policy is:
--
--   org_members_update  for update  using (app.can_admin(org_id))
--
-- with no WITH CHECK, so the USING expression governs the new row too.
-- org_id does not change, so an admin may set any member's role to
-- anything. Confirmed on the harness under `set local role
-- authenticated`: an admin demoted the owner, and promoted themselves
-- to owner, by direct update.
--
-- The delete policy beside it already knows the rule:
--
--   org_members_delete  using (app.can_admin(org_id)
--                              and role <> 'owner'::app.member_role)
--
-- and it works -- deleting the owner's row while they are still the
-- owner is refused. What the update policy allows is the two-step way
-- round it: demote the owner, then delete the viewer they have become.
--
-- The replacement says both halves out loud:
--
--   USING       an admin may update any member's row except the
--               owner's; an owner may update their own.
--   WITH CHECK  a row may only come out of the update as `owner` if
--               the caller is already an owner themselves.
--
-- So an admin can still administer the team, an owner can still edit
-- their own membership, an owner can still make a co-owner, and
-- neither an admin promoting themselves nor an admin demoting the
-- owner survives. Demoting an owner remains what the exception above
-- calls it: a transfer of ownership, which wants a function of its own
-- rather than a role update nobody checked.
-- ---------------------------------------------------------------------

drop policy if exists org_members_update on public.org_members;
create policy org_members_update on public.org_members
  for update to authenticated
  using (app.can_admin(org_id)
         and (role <> 'owner'::app.member_role or user_id = auth.uid()))
  with check (app.can_admin(org_id)
              and (role <> 'owner'::app.member_role
                   or app.has_org_role(org_id,
                        array['owner']::app.member_role[])));

-- ---------------------------------------------------------------------
-- 4. The expiry that signing up walks straight past
--
-- accept_invitation refuses an invitation whose fortnight has run out.
-- It is not the only way in. app.handle_new_user, the trigger on
-- auth.users since 0001, claims pending invitations the moment somebody
-- signs up at the invited address:
--
--   update public.org_members
--      set user_id = new.id, status = 'active', joined_at = now()
--    where invited_email = new.email
--      and user_id is null
--      and status = 'invited';
--
-- No expiry test. An invitation issued eighteen months ago, never
-- accepted and long forgotten, still hands over the role it was issued
-- with on the day that address signs up. The 14 day limit is real on
-- one path and decorative on the other, which is worse than not having
-- one, because the expiry is what everybody reasons about when they
-- decide it is safe to invite somebody.
--
-- This was found by writing the test: the file asserted that an expired
-- invitation stays `invited` and it came back `active`, having been
-- claimed at signup before accept_invitation ever saw it.
--
-- The claim also left invite_token in place. accept_invitation will not
-- take it again -- it looks for `status = 'invited'` -- but a spent
-- credential sitting in a column is a credential somebody has to
-- explain later, and clearing it costs one line.
--
-- Everything else in the function is 0001's, unchanged.
-- ---------------------------------------------------------------------

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;

  -- Claim any pending invitations addressed to this e-mail -- but only
  -- ones still in date. accept_invitation has always refused an expired
  -- invitation; this path used to take it anyway. A null expiry is
  -- honoured for rows raised before invite_member set one.
  update public.org_members
     set user_id  = new.id,
         status   = 'active',
         joined_at = now(),
         invite_token = null
   where invited_email = new.email
     and user_id is null
     and status = 'invited'
     and (invite_expires_at is null or invite_expires_at > now());

  return new;
end;
$$;
