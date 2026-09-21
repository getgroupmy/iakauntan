-- =====================================================================
-- iAkauntan :: 0657 reaching an iPhone without Google
--
-- `docs/push-notifications.md` has said since `0143` that iOS "can be
-- reached without Firebase at all, by addressing APNs directly with a
-- token-based `.p8` key -- and should be, because FCM cannot send the
-- PushKit VoIP push that a real CallKit incoming-call screen needs".
--
-- The sender for it is in this commit (`_shared/apns.ts`). What this
-- migration adds is the one fact the register could not previously
-- hold: WHICH SERVICE a row's token belongs to.
--
-- ---------------------------------------------------------------------
-- Why `platform` was not already enough
--
-- It was, while there were two transports and each owned a platform:
-- `web` meant a browser subscription, anything else meant Firebase. A
-- third breaks that, because `ios` now means either -- an FCM
-- registration token or a raw APNs device token, depending on how the
-- build was made -- and they are not interchangeable. Sending an FCM
-- token to APNs is `BadDeviceToken` forever, and the reverse is
-- `UNREGISTERED`. Both are silent: the notification is reported as
-- sent and nobody's phone makes a sound.
--
-- So `transport` is its own column rather than something inferred from
-- the token's shape at send time. The shape IS diagnostic -- an APNs
-- token is hex and an FCM one is not -- and it is used below as a
-- CHECK, which is the right place for it: a guard against a mistake,
-- not the mechanism. A router that guessed would misroute the first FCM
-- token that happened to be hexadecimal, and would do it silently.
--
-- ---------------------------------------------------------------------
-- Which transports a platform may have
--
--   web      -> web      and nothing else. A browser subscription is
--                        three values and RFC 8291 encryption.
--   android  -> fcm      and nothing else. There is no direct
--                        equivalent; that is Google's transport all the
--                        way down.
--   ios      -> fcm or apns.
--
-- Existing rows are backfilled to what they already are, so nothing
-- moves: every web row is `web` and every other row is `fcm`, which is
-- exactly what `send-push` has been doing with them.
--
-- ---------------------------------------------------------------------
-- The function is dropped and recreated rather than replaced
--
-- `register_device` gains a parameter, which changes its signature --
-- and `create or replace` with a new signature does not replace, it
-- OVERLOADS. PostgREST then picks between the two by matching parameter
-- names, so a client that omitted the new argument would silently
-- resolve to the old function and register a row with the default
-- transport. `0307`'s header has the same warning about its protected
-- calls, and the failure it describes is this one.
--
-- Dropping loses the grant, so it is given again below. That is the
-- whole cost and it is visible here rather than discovered later.
-- =====================================================================

alter table public.device_tokens
  add column if not exists transport text;

-- What they already are. `send-push` reads every non-web row as a
-- Firebase token today, so this records the status quo rather than
-- changing anybody's registration.
update public.device_tokens
   set transport = case when platform = 'web' then 'web' else 'fcm' end
 where transport is null;

alter table public.device_tokens
  alter column transport set default 'fcm',
  alter column transport set not null;

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'device_tokens_transport_platform') then
    alter table public.device_tokens
      add constraint device_tokens_transport_platform check (
        case platform
          when 'web'     then transport = 'web'
          when 'android' then transport = 'fcm'
          when 'ios'     then transport in ('fcm', 'apns')
          else false
        end);
  end if;

  -- The shape, as a guard and not as the router. An APNs device token
  -- is hexadecimal; an FCM registration token is not -- it carries a
  -- colon and base64url punctuation. Registering one as the other is
  -- the mistake this catches, and it is worth catching at the write
  -- because the read-time symptom is silence.
  --
  -- No upper bound on the length. Apple's tokens are 32 bytes today and
  -- Apple has reserved the right to lengthen them; a maximum would be
  -- this migration guessing at somebody else's future and refusing
  -- valid registrations the day it changed.
  if not exists (select 1 from pg_constraint
                  where conname = 'device_tokens_apns_shape') then
    alter table public.device_tokens
      add constraint device_tokens_apns_shape check (
        transport <> 'apns' or token ~ '^[0-9a-fA-F]{64,}$');
  end if;
end $do$;

comment on column public.device_tokens.transport is
  'Which push service this token belongs to: web (RFC 8291 to the '
  'browser''s own push service), fcm (Firebase), or apns (straight to '
  'Apple with a .p8). An iOS row may be either of the last two, which '
  'is why this is a column rather than inferred from the platform. '
  'See 0657.';


-- ---------------------------------------------------------------------
-- Registering one
-- ---------------------------------------------------------------------
drop function if exists public.register_device(text, text, text, text, text);

create or replace function public.register_device(
  p_token text,
  p_platform text,
  p_label text default null,
  p_p256dh text default null,
  p_auth text default null,
  p_transport text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $function$
declare
  v_id uuid;
  v_transport text;
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

  -- 0657. Absent means what the platform has always meant, so every
  -- caller written before this migration keeps working unchanged: a
  -- browser is a browser, and anything else was Firebase.
  v_transport := coalesce(
    nullif(btrim(coalesce(p_transport, '')), ''),
    case when p_platform = 'web' then 'web' else 'fcm' end);

  if v_transport not in ('web', 'fcm', 'apns') then
    raise exception 'Unknown transport: %', v_transport;
  end if;
  -- Named rather than left to the constraint, because the three wrong
  -- combinations have three different causes and a constraint name
  -- describes none of them.
  if p_platform = 'web' and v_transport <> 'web' then
    raise exception 'A browser is reached by web push and nothing else';
  end if;
  if p_platform = 'android' and v_transport <> 'fcm' then
    raise exception
      'Android is reached through Firebase. There is no direct transport '
      'for it, unlike iOS.';
  end if;
  if p_platform = 'ios' and v_transport not in ('fcm', 'apns') then
    raise exception 'An iPhone is reached through Firebase or APNs';
  end if;
  -- And the shape, so the refusal names the likely mistake rather than
  -- a check constraint. Registering an FCM token as an APNs one
  -- produces BadDeviceToken forever, silently.
  if v_transport = 'apns' and btrim(p_token) !~ '^[0-9a-fA-F]{64,}$' then
    raise exception
      'That is not an APNs device token. One is at least 64 hexadecimal '
      'characters; a Firebase registration token is not, and registering '
      'it as APNs would be refused by Apple on every notification.';
  end if;

  -- `on conflict (token)`, not `(user_id, token)`. One handset, one row,
  -- belonging to whoever is signed in on it now — see 0141.
  insert into public.device_tokens
    (user_id, token, platform, label, p256dh, auth, transport)
  values (auth.uid(), btrim(p_token), p_platform,
          nullif(btrim(coalesce(p_label, '')), ''),
          nullif(btrim(coalesce(p_p256dh, '')), ''),
          nullif(btrim(coalesce(p_auth, '')), ''),
          v_transport)
  on conflict (token) do update
     set user_id      = auth.uid(),
         platform     = excluded.platform,
         label        = coalesce(excluded.label, public.device_tokens.label),
         -- Replaced, not coalesced. A browser that re-subscribes gets
         -- fresh keys, and keeping the old ones would encrypt to a
         -- keypair the browser has thrown away.
         p256dh       = excluded.p256dh,
         auth         = excluded.auth,
         -- 0657. Replaced for the same reason: a build that moved from
         -- Firebase to a direct APNs registration hands back a
         -- different kind of token, and keeping the old transport would
         -- send it to the wrong Apple forever.
         transport    = excluded.transport,
         last_seen_at = now(),
         registered_at = case
           when public.device_tokens.user_id = auth.uid()
           then public.device_tokens.registered_at
           else now() end
  returning id into v_id;

  return v_id;
end; $function$;

-- Dropping the old signature dropped its grant AND its comment with it.
-- The comment is not decoration: `scripts/check_undocumented_writes.py`
-- refuses a write function without one, on the argument that a
-- parameter list tells a caller nothing about what the function
-- refuses. It caught this within the minute.
--
-- `anon` and `authenticated` BY NAME, not just `public`. A hosted
-- project's default privileges hand a newly created function in this
-- schema an EXECUTE grant held directly by those roles, and revoking
-- from the PUBLIC pseudo-role does not touch a direct grant. `0141`
-- and `0143` both write all three out; the first version of this
-- migration wrote only `public` and CI refused it -- see the note in
-- `supabase/tests/_local_stack.sql`, which this failure settled.
revoke all on function public.register_device(
  text, text, text, text, text, text) from public, anon;
grant execute on function public.register_device(
  text, text, text, text, text, text) to authenticated;

comment on function public.register_device(
  text, text, text, text, text, text) is
  'Records a device to send push notifications to, and returns its '
  'row. Keyed ON THE TOKEN, not on the pair of user and token: one '
  'handset is one row, belonging to whoever is signed in on it now, so '
  'a colleague signing in on a shared tablet takes the row over rather '
  'than adding a second and getting the first person''s notifications '
  '(0141). A browser subscription must bring its `p256dh` and `auth` '
  'keys or there is nothing to encrypt the notification to, and a '
  'phone must not bring them; on a re-subscribe the keys are REPLACED '
  'rather than merged, because a browser that re-subscribes has thrown '
  'the old keypair away. Platform is android, ios or web. '
  'Transport (0657) is web, fcm or apns and says which service the '
  'token belongs to: absent it is web for a browser and fcm for '
  'anything else, which is what every caller written before 0657 '
  'meant. A browser must be web and Android must be fcm; only iOS has '
  'the choice. An apns token has to be at least 64 hexadecimal '
  'characters, because a Firebase token registered as an APNs one is '
  'refused by Apple on every notification and says nothing here.';


-- ---------------------------------------------------------------------
-- Who to reach, and how
-- ---------------------------------------------------------------------
--
-- Restated with `transport` added and nothing else changed. It still
-- does not restate the permission model: it joins through
-- `chat_participants`, which is where `0135`, `0138` and `0139` put it.
--
-- Dropped first, like `register_device` above and for a stricter
-- reason: a set-returning function's OUT parameters ARE its return
-- type, so adding a column is a return type change and `create or
-- replace` refuses it outright rather than overloading. Its grant goes
-- with it and is given again below.
drop function if exists public.push_targets(uuid, uuid);

create or replace function public.push_targets(
  p_conversation_id uuid,
  p_exclude_user uuid default null)
returns table(
  user_id uuid,
  token text,
  platform text,
  transport text,
  p256dh text,
  auth text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $function$
  select d.user_id, d.token, d.platform, d.transport, d.p256dh, d.auth
    from public.chat_participants p
    join public.device_tokens d on d.user_id = p.user_id
   where p.conversation_id = p_conversation_id
     and (p_exclude_user is null or p.user_id <> p_exclude_user)
     and app.chat_enabled(p.org_id, p.user_id)
   order by d.last_seen_at desc;
$function$;

-- All three named, exactly as `0141` and `0143` name them. The sender
-- reads this with the service role and a client must not read it at
-- all; a default grant left in place would hand every signed-in user
-- the list of everybody's handsets.
revoke all on function public.push_targets(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.push_targets(uuid, uuid) to service_role;


-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_cols text[];
begin
  -- The sender routes on this column, so it has to arrive.
  select array_agg(a.name) into v_cols
    from pg_proc p
    cross join lateral unnest(p.proargnames, p.proargmodes)
         as a(name, mode)
   where p.oid = 'public.push_targets(uuid, uuid)'::regprocedure
     and a.mode = 't';
  if v_cols is null or not ('transport' = any(v_cols)) then
    raise exception 'push_targets does not say which service a token is for';
  end if;

  -- A client cannot read it. `0141` made that true and a restated
  -- function is exactly where it would be lost.
  if has_function_privilege('authenticated', 'public.push_targets(uuid, uuid)',
                            'execute') then
    raise exception 'push_targets became readable by every signed-in user';
  end if;
  if not has_function_privilege('service_role',
                                'public.push_targets(uuid, uuid)', 'execute')
  then
    raise exception 'the sender can no longer read push_targets';
  end if;

  -- And that dropping `register_device` did not take its grant away
  -- for good, which would leave nobody able to turn notifications on.
  if not has_function_privilege(
       'authenticated',
       'public.register_device(text, text, text, text, text, text)',
       'execute') then
    raise exception 'nobody can register a device any more';
  end if;

  -- Exactly one `register_device`. Two would be `create or replace`
  -- having overloaded rather than replaced, which is the failure this
  -- migration's header is about: PostgREST would resolve a call with no
  -- transport to the old one.
  if (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'register_device') <> 1 then
    raise exception 'there is more than one register_device';
  end if;

  -- Nothing moved. Every row that existed is on the transport the
  -- sender was already using for it.
  if exists (select 1 from public.device_tokens
              where transport <> case when platform = 'web'
                                      then 'web' else 'fcm' end
                and transport <> 'apns') then
    raise exception 'an existing registration changed transport';
  end if;
end $do$;
