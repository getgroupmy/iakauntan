-- =====================================================================
-- iAkauntan :: 0555 where the person registering is
--
-- `0554` gave registration a title and a dialable mobile number. This
-- gives it a country and a state, and keeps the dialling code and the
-- country as one answer rather than two that can disagree.
--
-- ---------------------------------------------------------------------
-- One question, not two
--
-- The form asked for a dialling code. A dialling code IS a country --
-- +60 is Malaysia and nothing else -- so asking for both invites a
-- profile that says Singapore and carries a Malaysian number. The
-- screen asks which country, and the number's prefix follows it.
--
-- Malaysia and Kuala Lumpur to begin with, for the reason
-- `home_country.dart` gives about the setup form: this is a Malaysian
-- product, and the commonest answer should be the one already there.
-- `14` is Wilayah Persekutuan Kuala Lumpur in `ref_states`, seeded in
-- `0011`.
--
-- ---------------------------------------------------------------------
-- Where they go
--
-- On the profile, beside the title and the number. `profiles` is what
-- this product knows about a PERSON -- their name, how to address them,
-- how to ring them -- as distinct from `organizations`, which is what
-- it knows about a company's books. Somebody can keep books for a
-- company in another country, and neither answer overwrites the other.
--
-- `state_code` holds a `ref_states` code inside Malaysia and whatever
-- was typed outside it, which is the arrangement `create_organization`
-- already uses and for the same reason: the column is free text, so
-- both are honest, and what would not be is storing a Malaysian code
-- for a Thai province.
--
-- ---------------------------------------------------------------------
-- And the list the form needs
--
-- `signup_reference()` grows a third list. The registration form is
-- still the one screen with no session behind it, so `ref_states` is
-- as unreachable there as `ref_countries` was, and the answer is the
-- same one: the function is already on `statutory.sql`'s anon
-- allowlist, already returns nothing but public facts, and gains one
-- more list of them.
-- =====================================================================

alter table public.profiles
  add column if not exists country_code text,
  add column if not exists state_code text;

comment on column public.profiles.country_code is
  'Where this person is, in the three letters ref_countries uses. '
  'Theirs, not their company''s. 0555.';

comment on column public.profiles.state_code is
  'A ref_states code inside Malaysia, and whatever was typed outside '
  'it. 0555.';

-- ---------------------------------------------------------------------
-- The three lists, before there is a session
-- ---------------------------------------------------------------------
create or replace function public.signup_reference()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
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

comment on function public.signup_reference() is
  'The dialling codes, salutations and Malaysian states the '
  'registration form offers, readable with no session because that '
  'form has none. 0554, 0555.';

revoke all on function public.signup_reference() from public;
grant execute on function public.signup_reference() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Carrying all four onto the profile
--
-- Restated from the built definition, as `0554` restated it from
-- `0001`'s: this function also claims pending invitations, and
-- rebuilding it from anything but what is running would drop that.
-- ---------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url,
                               salutation, phone, country_code, state_code)
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
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'state_code', '')), '')
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
end $$;
