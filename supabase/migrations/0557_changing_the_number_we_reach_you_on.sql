-- =====================================================================
-- iAkauntan :: 0557 changing the number we reach you on
--
-- `0554` asked for a mobile number at registration and nothing could
-- change it afterwards. `profiles_update` lets somebody write their own
-- row, so the column was reachable -- but reachable by a client that
-- decides for itself what goes in it, which is how the trunk-prefix
-- zero would come back the first time anything but the registration
-- form wrote a number.
--
-- So the same rule, once: `update_my_phone` takes the two halves the
-- form takes and puts them together with `app.phone_e164`, exactly as
-- `handle_new_user` does. The number in `profiles.phone` is E.164 or it
-- is null, whichever door it came through.
--
-- ---------------------------------------------------------------------
-- Who may
--
-- Only the account itself, and it is written `id = auth.uid()` rather
-- than taken as an argument. A function that accepted whose profile to
-- change would be a function somebody could point at a colleague.
--
-- What this does NOT do is ask for a password -- that is the screen's
-- job and it does it before calling this. The reason it is a screen's
-- job rather than a check in here is that PostgREST has one credential
-- for the whole session: by the time a request arrives, the caller has
-- already proved they hold the session, and the question worth asking
-- is whether the person AT THE KEYBOARD is the account holder or
-- somebody who walked past an unattended screen. That is answered by
-- re-entering the password, which GoTrue verifies, and it cannot be
-- answered from inside this function at all.
--
-- Changing an email address goes through GoTrue rather than here: it
-- is `auth.users.email`, it sends a confirmation link to the new
-- address, and it is guarded by the same password re-entry on the same
-- screen.
-- =====================================================================

create or replace function public.update_my_phone(
  p_dial text,
  p_national text)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_phone text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;

  -- Null is a deliberate answer: somebody removing the number they gave
  -- us. `app.phone_e164` answers null for an empty box, and storing
  -- that is how a number gets taken off a profile.
  v_phone := app.phone_e164(p_dial, p_national);

  -- What is NOT allowed is a number-shaped thing that cannot be
  -- dialled. A box with digits in it that comes back null from the
  -- rule above is a typo -- fifteen digits of country code, or a
  -- string of zeros -- and storing nothing while the screen says
  -- "saved" is the silent half of the fault `0554` was written about.
  if v_phone is null
     and regexp_replace(coalesce(p_national, ''), '[^0-9]', '', 'g') <> ''
  then
    raise exception 'That is not a number we can dial'
      using errcode = '22023';
  end if;

  update public.profiles
     set phone = v_phone,
         updated_at = now()
   where id = auth.uid();

  return v_phone;
end $$;

comment on function public.update_my_phone(text, text) is
  'Changes the caller''s own mobile number, through the same E.164 '
  'rule registration uses. 0557.';

revoke all on function public.update_my_phone(text, text)
  from public, anon;
grant execute on function public.update_my_phone(text, text)
  to authenticated;
