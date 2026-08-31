-- =====================================================================
-- iAkauntan :: 0353 an invitation only its addressee can take
--
-- `accept_invitation` has had no caller since `0022`, and looking for
-- one found the reason it was better off that way. Reproduced on a
-- database, not reasoned about:
--
--   * a `viewer` — the least trusted role there is — signs in, and
--     under `org_members_select` reads every row of `org_members` for
--     their own company. `invite_token` is one of those columns. Nothing
--     masks it.
--   * `accept_invitation(token)` checks that the token exists, that the
--     row is still `invited`, and that it has not expired. It does not
--     check who is calling.
--   * so the viewer passes the token to anybody at all, and that person
--     — never invited, at an address nobody typed — becomes an `admin`
--     of the company, on a row still addressed to somebody else.
--
-- The unique key on `(org_id, user_id)` stops the viewer using it
-- themselves, which is luck rather than design: it means the escalation
-- needs a second account, and a second account costs nothing.
--
-- Two defences, because either alone leaves a hole worth having the
-- other for.
--
-- ## The token is stored hashed
--
-- `0070` established the idiom for exactly this, for the signing links
-- a corp-sec practice sends to people with no account:
-- `corp_signing_links.token_hash`, written through `app.corp_token_hash`,
-- with the raw token returned once and no way to read it back.
-- `org_members.invite_token` predates that migration by sixty-nine
-- numbers and never adopted it. It does now, under the same functions.
--
-- Existing rows are hashed in place. Nothing is lost: no invitation
-- e-mail has ever been sent and no screen has ever shown a token, so
-- there is no raw value anywhere for this to invalidate. Said plainly
-- because "we hashed your credentials in place" is normally a sentence
-- that breaks somebody.
--
-- ## And an invitation is addressed to a person
--
-- The hash alone would only mean the leak needs a different route — a
-- forwarded mail, a screenshot, a backup. So the second check is the
-- one that actually says what an invitation *is*: the address on it is
-- the person who may take it. `app.handle_new_user` has always worked
-- this way — it claims a pending invitation by matching `new.email` —
-- and this brings the other path in line with it.
--
-- Read from `auth.users` rather than `public.profiles`, following
-- `0235`: profiles is a copy, and a copy that has not caught up with an
-- address change would refuse the right person or admit the wrong one.
--
-- ## And the token now has somewhere to go
--
-- `invite_member` returns the raw token, once, so the person doing the
-- inviting has something to send. It returned the member id, which no
-- caller used. A row that adjusts an existing member's role returns
-- null: there is nothing to accept, they are already in.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Hash what is already there
-- ---------------------------------------------------------------------
--
-- Only the live ones. A spent invitation has `invite_token = null`
-- already, and `0284` is what made sure of that.
update public.org_members
   set invite_token = app.corp_token_hash(invite_token)
 where invite_token is not null
   and status = 'invited'
   -- 64 hex characters is what the digest looks like. Guards a re-run:
   -- hashing a hash would lock out an invitation that is still live.
   and invite_token !~ '^[0-9a-f]{64}$';

comment on column public.org_members.invite_token is
  'sha256 of the invitation token, never the token. Issued once by invite_member and matched by accept_invitation; readable by any member of the org, which is why it is a digest.';

-- ---------------------------------------------------------------------
-- Issuing, with something to send
-- ---------------------------------------------------------------------
--
-- The return type changes, so the old one is dropped rather than left
-- beside this — `0351`'s reasoning about overloads applies to a changed
-- return just as it does to an added argument, and more bluntly: two
-- functions of the same name cannot differ only in what they return.
drop function if exists public.invite_member(uuid, text, app.member_role);

create or replace function public.invite_member(
  p_org_id uuid, p_email text, p_role app.member_role)
returns text language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_existing uuid; v_existing_role app.member_role; v_invited uuid;
  v_email citext := lower(trim(p_email))::citext;
  v_token text;
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
    -- Nothing to accept. Returning a token here would be offering a
    -- link that leads to "you are already a member".
    return null;
  end if;

  v_token := app.corp_new_token();

  -- `on conflict (org_id, user_id) do nothing` is `0022`'s and stays.
  -- It never fires for an invitation — `user_id` is null and null is
  -- distinct from null in a unique index — so a second invitation to
  -- the same address makes a second row with its own token, which
  -- `invitations.sql` records and leaves alone. That is more clearly
  -- fine after this migration than before it: both links now demand
  -- the same address, so two live ones land in the same inbox and buy
  -- an attacker nothing.
  --
  -- The returning clause is what makes the token honest. If the insert
  -- ever did nothing, handing back a token that matches no row would be
  -- a link that fails when somebody clicks it.
  insert into public.org_members (
    org_id, invited_email, role, status, invited_by,
    invite_token, invite_expires_at)
  values (
    p_org_id, v_email, p_role, 'invited', auth.uid(),
    app.corp_token_hash(v_token), now() + interval '14 days')
  on conflict (org_id, user_id) do nothing
  returning id into v_invited;

  if v_invited is null then
    raise exception 'That invitation could not be recorded.';
  end if;

  return v_token;
end;
$$;

grant execute on function public.invite_member(uuid, text, app.member_role)
  to authenticated;

comment on function public.invite_member(uuid, text, app.member_role) is
  'Invites somebody into a company and returns the raw invitation token once. Null when the address was already a member and only their role changed.';

-- ---------------------------------------------------------------------
-- Accepting, by the person it was addressed to
-- ---------------------------------------------------------------------
create or replace function public.accept_invitation(p_token text)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_member public.org_members;
  v_email  citext;
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;

  select lower(u.email)::citext into v_email
    from auth.users u where u.id = auth.uid();

  select * into v_member from public.org_members
   where invite_token = app.corp_token_hash(p_token) and status = 'invited';

  if not found then
    raise exception 'That invitation is not valid';
  end if;
  if v_member.invite_expires_at < now() then
    raise exception 'That invitation has expired. Ask for a new one.';
  end if;

  -- The check this function was missing. An invitation names an address
  -- and that address is who may take it -- otherwise the token alone is
  -- the credential, and every member of the company can read it.
  --
  -- Deliberately the same sentence whether the address is wrong or the
  -- caller has no address at all: telling somebody which of the two it
  -- was tells them the invitation exists and who it is for.
  if v_email is null or v_email <> v_member.invited_email then
    raise exception 'That invitation was sent to somebody else. '
                    'Sign in as the address it was sent to.'
      using errcode = '42501';
  end if;

  -- Said as a sentence rather than left to the unique key on
  -- (org_id, user_id), which surfaces as a constraint name.
  if exists (select 1 from public.org_members m
              where m.org_id = v_member.org_id and m.user_id = auth.uid()) then
    raise exception 'You are already in that company.' using errcode = '23505';
  end if;

  update public.org_members
     set user_id = auth.uid(), status = 'active', joined_at = now(),
         invite_token = null
   where id = v_member.id;

  return v_member.org_id;
end;
$$;

grant execute on function public.accept_invitation(text) to authenticated;

comment on function public.accept_invitation(text) is
  'Takes up an invitation. The token is matched as a digest and the caller must be signed in as the address the invitation names.';
