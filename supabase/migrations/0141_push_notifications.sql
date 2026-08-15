-- =====================================================================
-- iAkauntan :: push notifications
--
-- What makes a phone ring when the app is closed.
--
-- ---------------------------------------------------------------------
-- What this is for
--
-- 0140 built calling and 0135 built chat, and both share one limitation
-- that made them far less useful than they look: a call rings only on a
-- device that already has the app open, and a message arrives only where
-- somebody is already looking. The reason to ring somebody is that they
-- are doing something else, so that is close to saying it does not work.
--
-- This is the register of devices to reach, and the rules about who may
-- be reached. The sending is an edge function, because it holds a
-- credential and talks to Google, and neither belongs here.
--
-- ---------------------------------------------------------------------
-- A token belongs to a handset, not to a person
--
-- This is the part that is easy to get wrong and expensive to get wrong.
-- The token identifies an *installation*. When somebody signs out and a
-- colleague signs in on the same phone, Firebase hands back the same
-- token — and if the row is keyed on (user, token) rather than on the
-- token alone, both people now have a live registration for one handset.
-- The first person's messages then get pushed to a phone they no longer
-- hold, which in a system carrying payroll and bank details is not a
-- notification bug.
--
-- So `token` is unique on its own, and registering moves it. There is an
-- assertion for exactly this in `supabase/tests/push.sql`.
-- =====================================================================

create table public.device_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  -- The registration token from Firebase. Long, opaque, and rotated by
  -- the client whenever Google feels like it.
  token         text not null unique,
  platform      text not null check (platform in ('android', 'ios', 'web')),
  -- What the device calls itself, for a person looking at their own list
  -- and wondering which one "Pixel 7" is.
  label         text,
  registered_at timestamptz not null default now(),
  -- Touched every time the app starts. A token nobody has presented for
  -- months is an app that was uninstalled without telling anybody.
  last_seen_at  timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens (user_id);
create index device_tokens_stale_idx on public.device_tokens (last_seen_at);

alter table public.device_tokens enable row level security;

-- Your own devices, and nobody else's. Not even an administrator: the
-- list of handsets a person carries is not company data, and there is
-- nothing an administrator could do with it that they cannot do by
-- removing the person's access instead.
create policy device_tokens_select on public.device_tokens
  for select to authenticated
  using (user_id = auth.uid());

create policy device_tokens_delete on public.device_tokens
  for delete to authenticated
  using (user_id = auth.uid());

grant select, delete on public.device_tokens to authenticated;

-- ---------------------------------------------------------------------
-- Registering
--
-- No insert policy. Registration goes through the function below, which
-- is what makes "the token moves to whoever signed in last" a rule
-- rather than a convention the client is trusted to follow.
-- ---------------------------------------------------------------------
create or replace function public.register_device(
  p_token text, p_platform text, p_label text default null)
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

  -- `on conflict (token)`, not `(user_id, token)`. The whole point: one
  -- handset, one row, belonging to whoever is signed in on it now.
  insert into public.device_tokens (user_id, token, platform, label)
  values (auth.uid(), btrim(p_token), p_platform, nullif(btrim(coalesce(p_label, '')), ''))
  on conflict (token) do update
     set user_id      = auth.uid(),
         platform     = excluded.platform,
         label        = coalesce(excluded.label, public.device_tokens.label),
         last_seen_at = now(),
         -- Re-registered by somebody else is a new registration, not the
         -- continuation of the last person's.
         registered_at = case
           when public.device_tokens.user_id = auth.uid()
           then public.device_tokens.registered_at
           else now() end
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.register_device(text, text, text) from public, anon;
grant execute on function public.register_device(text, text, text) to authenticated;

-- Signing out. Best effort by nature — an app that is force-quit never
-- gets to call this — which is why the sender also prunes tokens the
-- push service rejects.
create or replace function public.unregister_device(p_token text)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  delete from public.device_tokens
   where token = btrim(p_token) and user_id = auth.uid();
$$;

revoke all on function public.unregister_device(text) from public, anon;
grant execute on function public.unregister_device(text) to authenticated;

-- ---------------------------------------------------------------------
-- Who gets told
--
-- Called by the edge function under the service role, never by a client:
-- it returns other people's device tokens, which is precisely the thing
-- the policies above exist to keep from being readable.
--
-- The permission model is not restated here. It is a join through
-- `chat_participants`, which is where 0135, 0138 and 0139 already put
-- it — module bought, person switched on, companies linked, actually in
-- this conversation. A second copy of those rules would be a second copy
-- free to disagree with the first.
-- ---------------------------------------------------------------------
create or replace function public.push_targets(
  p_conversation_id uuid, p_exclude_user uuid default null)
returns table (
  user_id  uuid,
  token    text,
  platform text
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select d.user_id, d.token, d.platform
    from public.chat_participants p
    join public.device_tokens d on d.user_id = p.user_id
   where p.conversation_id = p_conversation_id
     -- Never the person who caused it. Their own phone buzzing in their
     -- hand as they press send is the most reliably irritating bug in
     -- any chat application.
     and (p_exclude_user is null or p.user_id <> p_exclude_user)
     -- The module can be switched off after somebody joined a
     -- conversation, and a push is a message leaving the building.
     --
     -- Both arguments, explicitly. `app.chat_enabled`'s second parameter
     -- defaults to `auth.uid()`, and this runs under the service role
     -- where that is null — so the one-argument form asks "is chat on
     -- for nobody?", which is false for everyone, and the result is a
     -- push system that silently never pushes.
     and app.chat_enabled(p.org_id, p.user_id)
   order by d.last_seen_at desc;
$$;

revoke all on function public.push_targets(uuid, uuid) from public, anon, authenticated;

-- Tokens the push service has told us are dead. Also service-role only.
create or replace function public.forget_device_token(p_token text)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  delete from public.device_tokens where token = p_token;
$$;

revoke all on function public.forget_device_token(text) from public, anon, authenticated;

-- An app uninstalled without signing out leaves a row that will never be
-- delivered to again. Not scheduled here — it is a tidy-up, and nothing
-- depends on it having run.
create or replace function public.prune_device_tokens(p_older_than interval
  default interval '90 days')
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_count integer;
begin
  delete from public.device_tokens
   where last_seen_at < now() - p_older_than;
  get diagnostics v_count = row_count;
  return v_count;
end; $$;

revoke all on function public.prune_device_tokens(interval)
  from public, anon, authenticated;
