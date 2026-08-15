-- =====================================================================
-- iAkauntan :: web push, without Firebase
--
-- 0141 built the register of devices on the assumption that a device
-- token is a Firebase token: one opaque string, and the sender knows
-- what to do with it. That is true for Android and iOS. It is not true
-- for a browser.
--
-- A browser subscription is three values, not one:
--
--   endpoint  the push service's URL for this installation — which is
--             also its identity, so it takes the place of the token
--   p256dh    the browser's public key
--   auth      a secret the browser generated
--
-- The last two are what the payload is encrypted to. Under RFC 8291 the
-- push service carries ciphertext it cannot read, which is the reason
-- this is worth doing properly rather than sending the notification in
-- clear and trusting an intermediary nobody here chose.
--
-- ---------------------------------------------------------------------
-- Why a web row without its keys is made impossible
--
-- The obvious shape is two nullable columns and a note asking the
-- client to fill them in. The failure that produces is silent: the row
-- registers, the person believes they have notifications, and the
-- sender skips them forever because there is nothing to encrypt to.
--
-- So it is a check constraint. A web device has both keys or it is not
-- registered, and the mistake surfaces at the moment somebody makes it.
-- =====================================================================

alter table public.device_tokens
  add column p256dh text,
  add column auth   text;

comment on column public.device_tokens.p256dh is
  'Browser subscriptions only: the client public key, base64url, 65 '
  'bytes uncompressed. Null on Android and iOS, which use FCM.';
comment on column public.device_tokens.auth is
  'Browser subscriptions only: the client auth secret, base64url, 16 '
  'bytes.';

alter table public.device_tokens
  add constraint device_tokens_web_keys check (
    case when platform = 'web'
         then p256dh is not null and auth is not null
         else p256dh is null and auth is null
    end);

-- ---------------------------------------------------------------------
-- Registering, now that a registration has two shapes
--
-- The signature changes, so the old one is dropped rather than left
-- beside this: two functions of the same name, one of which quietly
-- cannot register a browser, is exactly the ambiguity that produces a
-- device nobody can reach.
-- ---------------------------------------------------------------------
drop function if exists public.register_device(text, text, text);

create or replace function public.register_device(
  p_token text,
  p_platform text,
  p_label text default null,
  p_p256dh text default null,
  p_auth text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if p_token is null or length(btrim(p_token)) = 0 then
    raise exception 'A device token is required';
  end if;
  if p_platform not in ('android', 'ios', 'web') then
    raise exception 'Unknown platform: %', p_platform;
  end if;

  -- Said here as well as in the constraint, because the constraint's
  -- message names a constraint and this one names the mistake.
  if p_platform = 'web'
     and (nullif(btrim(coalesce(p_p256dh, '')), '') is null
          or nullif(btrim(coalesce(p_auth, '')), '') is null) then
    raise exception
      'A browser subscription needs its p256dh and auth keys, or there '
      'is nothing to encrypt the notification to';
  end if;
  if p_platform <> 'web' and (p_p256dh is not null or p_auth is not null) then
    raise exception 'Only a browser subscription carries encryption keys';
  end if;

  -- `on conflict (token)`, not `(user_id, token)`. One handset, one row,
  -- belonging to whoever is signed in on it now — see 0141.
  insert into public.device_tokens
    (user_id, token, platform, label, p256dh, auth)
  values (auth.uid(), btrim(p_token), p_platform,
          nullif(btrim(coalesce(p_label, '')), ''),
          nullif(btrim(coalesce(p_p256dh, '')), ''),
          nullif(btrim(coalesce(p_auth, '')), ''))
  on conflict (token) do update
     set user_id      = auth.uid(),
         platform     = excluded.platform,
         label        = coalesce(excluded.label, public.device_tokens.label),
         -- Replaced, not coalesced. A browser that re-subscribes gets
         -- fresh keys, and keeping the old ones would encrypt to a
         -- keypair the browser has thrown away.
         p256dh       = excluded.p256dh,
         auth         = excluded.auth,
         last_seen_at = now(),
         registered_at = case
           when public.device_tokens.user_id = auth.uid()
           then public.device_tokens.registered_at
           else now() end
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.register_device(text, text, text, text, text)
  from public, anon;
grant execute on function public.register_device(text, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Who gets told, and what to encrypt to
--
-- The return type gains two columns, so this is a drop and recreate.
-- The permission model is untouched and still not restated: it is the
-- same join through `chat_participants` that 0141 wrote, including
-- `app.chat_enabled(p.org_id, p.user_id)` with both arguments spelled
-- out — the one-argument form asks whether chat is on for nobody, and
-- under the service role that is false for everybody.
-- ---------------------------------------------------------------------
drop function if exists public.push_targets(uuid, uuid);

create or replace function public.push_targets(
  p_conversation_id uuid, p_exclude_user uuid default null)
returns table (
  user_id  uuid,
  token    text,
  platform text,
  p256dh   text,
  auth     text
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select d.user_id, d.token, d.platform, d.p256dh, d.auth
    from public.chat_participants p
    join public.device_tokens d on d.user_id = p.user_id
   where p.conversation_id = p_conversation_id
     and (p_exclude_user is null or p.user_id <> p_exclude_user)
     and app.chat_enabled(p.org_id, p.user_id)
   order by d.last_seen_at desc;
$$;

revoke all on function public.push_targets(uuid, uuid)
  from public, anon, authenticated;
