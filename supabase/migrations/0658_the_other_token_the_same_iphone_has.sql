-- =====================================================================
-- 0658 — the OTHER token the same iPhone has
--
-- `0657` added `transport` so an `ios` row could say whether it is a
-- Firebase registration or a direct APNs one. It has one value too few,
-- and the table has one column too few, and both gaps are only visible
-- once something actually registers a handset — which is what the
-- Flutter half of this commit does.
--
-- ## One iPhone, two Apple tokens
--
-- An iPhone reached directly holds TWO tokens, issued by two different
-- Apple services, neither usable in the other's place:
--
--   * the one from `didRegisterForRemoteNotificationsWithDeviceToken`,
--     addressed to `<bundle>`, which carries alerts and exists only
--     once the person has granted notification permission;
--   * the one from `PKPushRegistry`, addressed to `<bundle>.voip`,
--     which carries VoIP pushes, needs no permission at all, and is the
--     only thing that produces a full-screen CallKit ring.
--
-- Both are 32 hexadecimal bytes and NOTHING about either says which it
-- is. `0657`'s shape check admits both and its `apns` transport
-- describes both, so the sender it shipped would send a VoIP push to
-- whichever it found first. The three ways that fails:
--
--   * a VoIP push to the alert token is refused `DeviceTokenNotForTopic`,
--     so the call never rings;
--   * an alert to the VoIP token is refused `TopicDisallowed`;
--   * and worst, a VoIP push that DOES arrive at an app which then does
--     not report an incoming call to CallKit gets the app KILLED by
--     iOS, and killed often enough gets its PushKit registration
--     revoked. Routing wrongly does not cost a notification, it costs
--     the ability to receive calls at all.
--
-- So `apns_voip` is a fourth transport rather than a flag beside the
-- third, because everything that routes already routes on `transport`.
--
-- ## Two rows for one handset, and a column that says so
--
-- The alternative was a `voip_token` column beside `token`. Rejected:
-- the two tokens have independent lives — either can be rotated or
-- revoked without the other, and they arrive at different moments —
-- and `0141`'s one-row-per-token is what lets `forget_device_token`
-- drop exactly the registration Apple said was dead. A second column
-- would make a 410 ambiguous about which half to forget.
--
-- What two rows cost is that nothing joins them, and the sender needs
-- them joined: when a call rings a handset through CallKit, the SAME
-- handset must not also be sent an alert banner about it. Per-user is
-- not good enough — a person may carry an iPhone on this build and
-- another on an older one, and suppressing by user would silence the
-- second one's only chance of hearing about the call.
--
-- Hence `device_id`: `identifierForVendor`, stable for this app on this
-- handset, written by both registrations. It is not a secret and not an
-- advertising identifier; it changes when the app is uninstalled, which
-- is exactly when both tokens die anyway.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which handset a token belongs to
-- ---------------------------------------------------------------------
alter table public.device_tokens
  add column if not exists device_id text;

comment on column public.device_tokens.device_id is
  'Which handset this token came from, where the platform can say. '
  'iOS writes identifierForVendor and writes the SAME value on its '
  'alert row and its PushKit row, which is what lets the sender ring a '
  'phone through CallKit without also banner-ing it about the same '
  'call. Null for a browser, which has one row anyway, and null for '
  'anything registered before 0658. Not an identity: it is per-app, '
  'and it is gone when the app is. See 0658.';

create index if not exists device_tokens_device_idx
  on public.device_tokens (user_id, device_id)
  where device_id is not null;


-- ---------------------------------------------------------------------
-- The two constraints `0657` wrote, widened by one value
-- ---------------------------------------------------------------------
alter table public.device_tokens
  drop constraint if exists device_tokens_transport_platform;

alter table public.device_tokens
  add constraint device_tokens_transport_platform check (
    case platform
      when 'web'     then transport = 'web'
      when 'android' then transport = 'fcm'
      -- Three, now. Firebase, direct alerts, and PushKit.
      when 'ios'     then transport in ('fcm', 'apns', 'apns_voip')
      else false
    end);

alter table public.device_tokens
  drop constraint if exists device_tokens_apns_shape;

-- `not in`, not `<> 'apns'`. Written the other way this would have
-- waved a Firebase token straight through as `apns_voip`, which is the
-- exact mistake `0657` wrote the check to catch.
alter table public.device_tokens
  add constraint device_tokens_apns_shape check (
    transport not in ('apns', 'apns_voip')
    or token ~ '^[0-9a-fA-F]{64,}$');

comment on column public.device_tokens.transport is
  'Which push service this token belongs to: web (RFC 8291 to the '
  'browser''s own push service), fcm (Firebase), apns (straight to '
  'Apple, alerts) or apns_voip (straight to Apple, PushKit). An iOS '
  'row may be any of the last three, and one directly-reached iPhone '
  'holds one apns row AND one apns_voip row — two tokens from two '
  'Apple services, neither usable in the other''s place, paired by '
  'device_id. See 0657 and 0658.';


-- ---------------------------------------------------------------------
-- Registering one
-- ---------------------------------------------------------------------
-- DROPPED and recreated, not replaced. `p_device_id` changes the
-- signature, and `create or replace` with a new signature OVERLOADS:
-- PostgREST would then resolve a call that omits the new argument to
-- the old function and register a handset nothing could pair. `0657`
-- paid for this lesson; the self-check at the bottom asserts it.
drop function if exists public.register_device(
  text, text, text, text, text, text);

create or replace function public.register_device(
  p_token text,
  p_platform text,
  p_label text default null,
  p_p256dh text default null,
  p_auth text default null,
  p_transport text default null,
  p_device_id text default null)
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
  -- caller written before that migration keeps working unchanged.
  v_transport := coalesce(
    nullif(btrim(coalesce(p_transport, '')), ''),
    case when p_platform = 'web' then 'web' else 'fcm' end);

  if v_transport not in ('web', 'fcm', 'apns', 'apns_voip') then
    raise exception 'Unknown transport: %', v_transport;
  end if;
  if p_platform = 'web' and v_transport <> 'web' then
    raise exception 'A browser is reached by web push and nothing else';
  end if;
  -- Before the platform checks below, so that the SPECIFIC mistake gets
  -- the specific sentence. An Android registration asking for
  -- `apns_voip` would otherwise be told about Firebase, which is true
  -- and answers a question nobody asked.
  if v_transport = 'apns_voip' and p_platform <> 'ios' then
    raise exception
      'PushKit is an Apple service. Only an iPhone has a VoIP token.';
  end if;
  if p_platform = 'android' and v_transport <> 'fcm' then
    raise exception
      'Android is reached through Firebase. There is no direct transport '
      'for it, unlike iOS.';
  end if;
  if p_platform = 'ios' and v_transport not in ('fcm', 'apns', 'apns_voip') then
    raise exception 'An iPhone is reached through Firebase or APNs';
  end if;
  if v_transport in ('apns', 'apns_voip')
     and btrim(p_token) !~ '^[0-9a-fA-F]{64,}$' then
    raise exception
      'That is not an APNs device token. One is at least 64 hexadecimal '
      'characters; a Firebase registration token is not, and registering '
      'it as APNs would be refused by Apple on every notification.';
  end if;

  insert into public.device_tokens
    (user_id, token, platform, label, p256dh, auth, transport, device_id)
  values (auth.uid(), btrim(p_token), p_platform,
          nullif(btrim(coalesce(p_label, '')), ''),
          nullif(btrim(coalesce(p_p256dh, '')), ''),
          nullif(btrim(coalesce(p_auth, '')), ''),
          v_transport,
          nullif(btrim(coalesce(p_device_id, '')), ''))
  on conflict (token) do update
     set user_id      = auth.uid(),
         platform     = excluded.platform,
         label        = coalesce(excluded.label, public.device_tokens.label),
         p256dh       = excluded.p256dh,
         auth         = excluded.auth,
         transport    = excluded.transport,
         -- Coalesced, not replaced. A token re-presented by a build
         -- that predates `0658` carries no device_id, and forgetting
         -- the one already recorded would unpair a handset that is
         -- still perfectly paired.
         device_id    = coalesce(excluded.device_id,
                                 public.device_tokens.device_id),
         last_seen_at = now(),
         registered_at = case
           when public.device_tokens.user_id = auth.uid()
           then public.device_tokens.registered_at
           else now() end
  returning id into v_id;

  return v_id;
end; $function$;

-- `anon` and `authenticated` BY NAME. A hosted project's default
-- privileges hand a newly created function in this schema an EXECUTE
-- grant held DIRECTLY by those roles, and revoking from the PUBLIC
-- pseudo-role does not touch a direct grant — which is what made CI
-- run 1941 refuse `0657`. See the note in `supabase/tests/_local_stack.sql`.
revoke all on function public.register_device(
  text, text, text, text, text, text, text) from public, anon;
grant execute on function public.register_device(
  text, text, text, text, text, text, text) to authenticated;

-- Dropping the function dropped its COMMENT with it, and
-- `scripts/check_undocumented_writes.py` refuses a write function
-- without one.
comment on function public.register_device(
  text, text, text, text, text, text, text) is
  'Puts the calling user''s device on the push register, or moves an '
  'existing token to them. Refuses: anybody not signed in; a blank '
  'token; a platform that is not android, ios or web; a browser '
  'without both encryption keys, and a non-browser with either; a '
  'transport that does not belong to the platform (web push is only '
  'for browsers, Firebase is the only way to Android, PushKit is only '
  'on iOS); and a token whose shape says it belongs to the other Apple '
  'service. Absent transport means web for a browser and Firebase for '
  'anything else, which is what every caller written before 0657 '
  'meant. One row per token, so one directly-reached iPhone holds two '
  '— apns for alerts, apns_voip for calls — and p_device_id is what '
  'pairs them so the sender does not banner a phone about a call it is '
  'already ringing.';


-- ---------------------------------------------------------------------
-- Reading them, with the pairing
-- ---------------------------------------------------------------------
-- A set-returning function's OUT parameters ARE its return type, so
-- adding a column is a return type change and `create or replace`
-- refuses it outright. Dropped, recreated, and re-granted.
drop function if exists public.push_targets(uuid, uuid);

create or replace function public.push_targets(
  p_conversation_id uuid,
  p_exclude_user uuid default null)
returns table(
  user_id uuid,
  token text,
  platform text,
  transport text,
  device_id text,
  p256dh text,
  auth text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $function$
  select d.user_id, d.token, d.platform, d.transport, d.device_id,
         d.p256dh, d.auth
    from public.chat_participants p
    join public.device_tokens d on d.user_id = p.user_id
   where p.conversation_id = p_conversation_id
     and (p_exclude_user is null or p.user_id <> p_exclude_user)
     and app.chat_enabled(p.org_id, p.user_id)
   order by d.last_seen_at desc;
$function$;

revoke all on function public.push_targets(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.push_targets(uuid, uuid) to service_role;


-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare
  v_ok boolean;
  v_cols text[];
begin
  select pg_get_constraintdef(oid) like '%apns_voip%' into v_ok
    from pg_constraint where conname = 'device_tokens_transport_platform';
  if v_ok is not true then
    raise exception 'an iPhone still cannot hold a PushKit token';
  end if;

  select pg_get_constraintdef(oid) like '%apns_voip%' into v_ok
    from pg_constraint where conname = 'device_tokens_apns_shape';
  if v_ok is not true then
    raise exception
      'the APNs shape check does not cover VoIP tokens, so a Firebase '
      'token could be registered as one';
  end if;

  -- Replaced, not overloaded, on both.
  if (select count(*) from pg_proc
       where pronamespace = 'public'::regnamespace
         and proname = 'register_device') <> 1 then
    raise exception 'there is more than one register_device';
  end if;
  if (select count(*) from pg_proc
       where pronamespace = 'public'::regnamespace
         and proname = 'push_targets') <> 1 then
    raise exception 'there is more than one push_targets';
  end if;

  -- The sender pairs on this column, so it has to arrive.
  select array_agg(a.name) into v_cols
    from pg_proc p
    cross join lateral unnest(p.proargnames, p.proargmodes) as a(name, mode)
   where p.oid = 'public.push_targets(uuid, uuid)'::regprocedure
     and a.mode = 't';
  if v_cols is null or not ('device_id' = any(v_cols)) then
    raise exception 'push_targets cannot say which tokens share a handset';
  end if;

  -- Grants, both directions, on both functions. A dropped function
  -- takes its grants with it and this is exactly where they are lost.
  if not has_function_privilege('authenticated', 'public.register_device('
      'text, text, text, text, text, text, text)', 'execute') then
    raise exception 'nobody can register a device any more';
  end if;
  if has_function_privilege('authenticated', 'public.push_targets(uuid, uuid)',
                            'execute') then
    raise exception 'push_targets became readable by every signed-in user';
  end if;
  if not has_function_privilege('service_role',
                                'public.push_targets(uuid, uuid)', 'execute')
  then
    raise exception 'the sender can no longer read push_targets';
  end if;
end $do$;
