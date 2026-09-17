-- =====================================================================
-- iAkauntan :: 0563 the door that was never shut
--
-- `0018` seeded `platform_settings` with `signup_enabled`, described in
-- its own row as "Allow new self-service registrations". Nothing has
-- ever read it. An operator could switch it off in the console, see it
-- saved, and registrations would carry on exactly as before -- which is
-- worse than not having the switch, because the switch is believed.
--
-- `0298` found the same shape in `nav_grouping` and its title says it:
-- the menu setting nobody could read. This is that, on the one setting
-- where being wrong about it means strangers getting accounts during
-- the hour somebody thought they had stopped them.
--
-- ---------------------------------------------------------------------
-- Where it has to be enforced
--
-- In the trigger on `auth.users`, not in the form. A form that hides
-- its own button is a suggestion: the sign-up endpoint is public, it is
-- the same endpoint whether a button was drawn or not, and anybody who
-- has ever opened the page has everything they need to call it.
--
-- `app.handle_new_user` is the one thing that runs on every account
-- however it was made, so it is where the answer belongs. Raising in it
-- fails the insert, and the account is not created.
--
-- ---------------------------------------------------------------------
-- What closing it does NOT close
--
-- An invitation. Somebody invited by a company has been let in by
-- somebody who was entitled to let them in, and "we are not taking new
-- registrations" was never about them -- a firm that closes public
-- sign-up still adds its own staff. The trigger already looks for a
-- pending invitation in the next statement down, to claim it; the same
-- lookup answers this.
--
-- In date, deliberately, and the same definition of in-date the claim
-- uses one statement later. An expired invitation that still opened a
-- closed door would be a way in that outlives the decision to offer it.
--
-- ---------------------------------------------------------------------
-- What the operator gives up
--
-- While it is off, an account can only be made by invitation --
-- including by platform staff, who make one the same way everybody
-- else's is made. That is the honest reading of the switch and it is
-- said here so that whoever turns it off is not surprised by it: the
-- way to make an account while the door is shut is to open the door.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Is the door open
--
-- Missing reads as open. A setting nobody has written, or a row
-- somebody deleted, must not be the thing that stops a business
-- registering -- the failure of a lookup should never be indis-
-- tinguishable from a decision.
-- ---------------------------------------------------------------------
create or replace function app.signups_open()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select (value ->> 'enabled')::boolean
       from public.platform_settings
      where key = 'signup_enabled'),
    true);
$$;

comment on function app.signups_open() is
  'Whether self-service registration is on. Missing reads as open: a '
  'lookup that failed must not look like a decision. 0563.';

revoke all on function app.signups_open() from public, anon;
grant execute on function app.signups_open() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- And what to say when it is shut
--
-- The operator's own words where they wrote any. "We are closed" with
-- no reason reads as a fault, and somebody who thinks the site is
-- broken comes back tomorrow and tries again; somebody told why does
-- not.
-- ---------------------------------------------------------------------
create or replace function app.signup_closed_message()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    nullif(btrim((select value ->> 'message'
                    from public.platform_settings
                   where key = 'signup_enabled')), ''),
    'We are not taking new registrations at the moment. If somebody at '
    'a company that already uses iAkauntan invites you, that invitation '
    'still works.');
$$;

comment on function app.signup_closed_message() is
  'What to tell somebody who cannot register. The operator''s own words '
  'where they wrote any. 0563.';

revoke all on function app.signup_closed_message() from public, anon;
grant execute on function app.signup_closed_message()
  to authenticated, service_role;

-- Room for those words. `maintenance_mode` is `{enabled, message}` and
-- this becomes the same shape, which is also the shape the console
-- already draws as a switch with a note beside it.
update public.platform_settings
   set value = value || jsonb_build_object('message', '')
 where key = 'signup_enabled'
   and jsonb_typeof(value) = 'object'
   and not (value ? 'message');

-- ---------------------------------------------------------------------
-- The trigger
--
-- Restated from `0558`'s version with one block added at the top.
-- Everything below it -- the profile, the salutation and phone, the
-- three-way reading of `use_kind`, claiming the invitation -- is
-- unchanged.
-- ---------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- The door, before anything is written. An invitation opens it: the
  -- same rows, and the same "still in date", that the claim below uses.
  if not app.signups_open()
     and not exists (select 1
                       from public.org_members m
                      where m.invited_email = new.email
                        and m.user_id is null
                        and m.status = 'invited'
                        and (m.invite_expires_at is null
                             or m.invite_expires_at > now())) then
    raise exception '%', app.signup_closed_message()
      using errcode = '42501';
  end if;

  insert into public.profiles (id, email, full_name, avatar_url,
                               salutation, phone, country_code, state_code,
                               use_kind)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url',
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'salutation', '')), ''),
    -- The form sends the two halves and the database puts them
    -- together, so the trunk-prefix zero is dropped by the same rule
    -- whoever is registering somebody.
    app.phone_e164(new.raw_user_meta_data ->> 'phone_dial',
                   new.raw_user_meta_data ->> 'phone_national'),
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'country_code', '')), ''),
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'state_code', '')), ''),
    -- Anything that is not one of the two answers is no answer at all.
    -- The constraint would refuse it and take the whole registration
    -- with it, and a sign-up that fails because a client sent a word
    -- nobody recognises is a worse outcome than a question asked twice.
    case
      when new.raw_user_meta_data ->> 'use_kind' in ('personal', 'business')
        then new.raw_user_meta_data ->> 'use_kind'
      else null
    end
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

-- ---------------------------------------------------------------------
-- And the form is told, so it does not have to be refused to find out
--
-- The trigger is what enforces it; this is so nobody fills in eight
-- fields to be told at the end. `signup_reference` is `0554`'s, already
-- granted to `anon`, and already the one call that form makes before it
-- draws.
--
-- Whether registration is open is not a secret: anybody learns it by
-- pressing the button once.
-- ---------------------------------------------------------------------
create or replace function public.signup_reference()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'signups_open', app.signups_open(),
    -- Null while it is open, so a form cannot accidentally draw the
    -- closed notice from a field that is always populated.
    'signups_closed_message',
      case when app.signups_open() then null
           else app.signup_closed_message() end,
    'dial_codes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', c.code, 'name', c.name,
               'alpha2', c.alpha2, 'dial_code', c.dial_code)
             order by c.name), '[]'::jsonb)
        from public.ref_countries c
       where c.is_active
         and coalesce(c.dial_code, '') <> ''),
    'salutations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', s.code, 'name', s.name,
               'grouping', s.grouping, 'note', s.note)
             order by s.sort_order, s.name), '[]'::jsonb)
        from public.salutations s
       where s.is_active),
    -- The thirteen states and three federal territories. Offered only
    -- where they mean something -- the form draws a box instead
    -- outside Malaysia -- but sent always, because the country can be
    -- changed after the list has loaded and a second round trip to
    -- fetch sixteen rows would draw an empty picker in the meantime.
    'states', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', st.code, 'name', st.name)
             order by st.code), '[]'::jsonb)
        from public.ref_states st));
$$;

revoke all on function public.signup_reference() from public;
grant execute on function public.signup_reference() to anon, authenticated;
