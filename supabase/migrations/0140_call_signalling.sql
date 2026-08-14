-- =====================================================================
-- iAkauntan :: call signalling
--
-- Everything about a call except the audio and the video.
--
-- ---------------------------------------------------------------------
-- What this is and, more importantly, what it is not
--
-- A call has two halves. There is the *signalling* — somebody starts
-- one, other phones ring, people accept or decline, somebody hangs up,
-- and it is over — which is state, and state belongs here where the
-- permission model already lives. And there is the *media*, which is a
-- stream of packets between devices and has nothing to do with a
-- database.
--
-- This is the first half, complete. The second half needs a TURN server
-- for the roughly one connection in five that cannot go peer to peer,
-- and — for more than about four people — a media server, because a
-- mesh of N² streams collapses. Neither exists yet. The seam is
-- `room_name` below: the SFU is told to make a room by that name, each
-- participant is issued a token for it, and the token is minted by an
-- edge function holding the SFU's secret because the database must not.
--
-- So: nothing here places a call. It rings a phone, and records what
-- happened. Wired to an SFU it becomes a call; on its own it is an
-- honest half.
--
-- ---------------------------------------------------------------------
-- A call belongs to a conversation
--
-- Not to a list of people. That is the whole reason this is short: who
-- may be in a call is exactly who may be in the conversation, so every
-- question about permission is one that `app.is_chat_participant`
-- already answers — including the group rule from 0139, that everybody
-- present is somebody every company present agreed to. A call cannot
-- reach further than the thread it was started from.
--
-- ---------------------------------------------------------------------
-- Ringing is a deadline, not a state somebody has to clear
--
-- A phone that rings until the caller gives up is a phone that rings
-- forever when the caller's app is killed mid-call. So a ringing call
-- carries `ringing_until`, and a call past it that nobody answered is
-- missed — worked out when read rather than written by a timer that may
-- not run. `chat_expire_calls` tidies the rows afterwards for the sake
-- of the history; the answer does not depend on it having run.
-- =====================================================================

create type app.call_kind as enum ('voice', 'video');

create type app.call_status as enum
  ('ringing', 'live', 'ended', 'missed', 'declined');

create type app.call_member_state as enum
  ('ringing', 'joined', 'declined', 'left');

create table public.chat_calls (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id)
                    on delete cascade,
  started_by      uuid not null references auth.users(id),
  started_by_org  uuid not null references public.organizations(id),
  kind            app.call_kind not null default 'voice',
  status          app.call_status not null default 'ringing',
  -- What the media server will call the room. Generated here so both
  -- ends agree without another round trip, and opaque so it leaks
  -- nothing about who is in it.
  room_name       text not null default encode(gen_random_bytes(16), 'hex'),
  started_at      timestamptz not null default now(),
  ringing_until   timestamptz not null default now() + interval '45 seconds',
  answered_at     timestamptz,
  ended_at        timestamptz,
  end_reason      text
);

create index chat_calls_conversation_idx
  on public.chat_calls (conversation_id, started_at desc);

-- One live call per conversation. Two people pressing the button at the
-- same moment is not rare, and two calls in one thread is a room nobody
-- is in and a room everybody is confused by.
create unique index chat_calls_one_open_per_conversation
  on public.chat_calls (conversation_id)
  where status in ('ringing', 'live');

create table public.chat_call_participants (
  call_id    uuid not null references public.chat_calls(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  org_id     uuid not null references public.organizations(id) on delete cascade,
  state      app.call_member_state not null default 'ringing',
  joined_at  timestamptz,
  left_at    timestamptz,
  primary key (call_id, user_id)
);

alter table public.chat_calls enable row level security;
alter table public.chat_call_participants enable row level security;

-- Visible to the conversation, which is the same set of people the call
-- can reach. Writes go through the functions below: a call is a state
-- machine and a policy cannot express "and only from this state".
create policy chat_calls_select on public.chat_calls
  for select to authenticated
  using (app.is_chat_participant(conversation_id));

create policy chat_call_participants_select on public.chat_call_participants
  for select to authenticated
  using (exists (select 1 from public.chat_calls c
                  where c.id = call_id
                    and app.is_chat_participant(c.conversation_id)));

grant select on public.chat_calls to authenticated;
grant select on public.chat_call_participants to authenticated;

-- ---------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------
create or replace function public.chat_start_call(
  p_conversation_id uuid, p_kind text default 'voice')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_org uuid;
  v_id uuid;
  v_open uuid;
begin
  if not app.is_chat_participant(p_conversation_id) then
    raise exception 'You are not in this conversation' using errcode = '42501';
  end if;
  v_org := app.chat_participant_org(p_conversation_id, v_me);

  -- Somebody already started one. Joining it is the right answer, not a
  -- second call — this is what two people pressing at once looks like.
  select id into v_open from public.chat_calls
   where conversation_id = p_conversation_id
     and status in ('ringing', 'live')
     and (status = 'live' or ringing_until > now())
   limit 1;
  if v_open is not null then
    perform public.chat_join_call(v_open);
    return v_open;
  end if;

  -- Anything still marked ringing here is stale: past its deadline and
  -- never answered. Closed now so the unique index does not refuse the
  -- new call on behalf of one nobody is in.
  update public.chat_calls
     set status = 'missed', ended_at = coalesce(ended_at, ringing_until)
   where conversation_id = p_conversation_id
     and status = 'ringing' and ringing_until <= now();

  insert into public.chat_calls
    (conversation_id, started_by, started_by_org, kind)
  values (p_conversation_id, v_me, v_org,
          (case when p_kind = 'video' then 'video' else 'voice' end)
            ::app.call_kind)
  returning id into v_id;

  -- Everybody in the conversation is rung; the caller is already in.
  insert into public.chat_call_participants (call_id, user_id, org_id, state,
                                             joined_at)
  select v_id, p.user_id, p.org_id,
         (case when p.user_id = v_me then 'joined' else 'ringing' end)
           ::app.call_member_state,
         (case when p.user_id = v_me then now() end)
    from public.chat_participants p
   where p.conversation_id = p_conversation_id;

  return v_id;
end; $$;

revoke all on function public.chat_start_call(uuid, text) from public, anon;
grant execute on function public.chat_start_call(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Answering, refusing, leaving, ending
-- ---------------------------------------------------------------------
create or replace function public.chat_join_call(p_call_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_call public.chat_calls;
begin
  select * into v_call from public.chat_calls where id = p_call_id for update;
  if v_call.id is null then
    raise exception 'No such call' using errcode = 'P0002';
  end if;
  if not app.is_chat_participant(v_call.conversation_id) then
    raise exception 'You are not in this conversation' using errcode = '42501';
  end if;
  if v_call.status not in ('ringing', 'live') then
    raise exception 'That call is over' using errcode = '22023';
  end if;

  -- Somebody added to the conversation after the call began may still
  -- join it: they are a participant now, which is the only test.
  insert into public.chat_call_participants (call_id, user_id, org_id, state,
                                             joined_at)
  values (p_call_id, auth.uid(),
          app.chat_participant_org(v_call.conversation_id, auth.uid()),
          'joined', now())
  on conflict (call_id, user_id) do update
    set state = 'joined', joined_at = coalesce(
          public.chat_call_participants.joined_at, now()),
        left_at = null;

  -- The first person to answer turns ringing into a call.
  if v_call.status = 'ringing' then
    update public.chat_calls
       set status = 'live', answered_at = coalesce(answered_at, now())
     where id = p_call_id;
  end if;
end; $$;

revoke all on function public.chat_join_call(uuid) from public, anon;
grant execute on function public.chat_join_call(uuid) to authenticated;

create or replace function public.chat_decline_call(p_call_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_call public.chat_calls;
begin
  select * into v_call from public.chat_calls where id = p_call_id for update;
  if v_call.id is null or
     not app.is_chat_participant(v_call.conversation_id) then
    raise exception 'No such call' using errcode = 'P0002';
  end if;

  update public.chat_call_participants
     set state = 'declined', left_at = now()
   where call_id = p_call_id and user_id = auth.uid();

  -- In a pair, one refusal ends it. In a room it does not: the others
  -- are still talking, and hanging up on them because one person is busy
  -- would be a strange thing for software to do.
  if v_call.status = 'ringing'
     and not exists (select 1 from public.chat_call_participants
                      where call_id = p_call_id and state = 'joined'
                        and user_id <> v_call.started_by)
     and not exists (select 1 from public.chat_call_participants
                      where call_id = p_call_id and state = 'ringing')
  then
    update public.chat_calls
       set status = 'declined', ended_at = now(), end_reason = 'declined'
     where id = p_call_id;
  end if;
end; $$;

revoke all on function public.chat_decline_call(uuid) from public, anon;
grant execute on function public.chat_decline_call(uuid) to authenticated;

-- Leaving, which ends the call only when it empties. A group call
-- outlives whoever started it.
create or replace function public.chat_leave_call(p_call_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  update public.chat_call_participants
     set state = 'left', left_at = now()
   where call_id = p_call_id and user_id = auth.uid();

  update public.chat_calls
     set status = 'ended', ended_at = now(),
         end_reason = coalesce(end_reason, 'everybody left')
   where id = p_call_id
     and status in ('ringing', 'live')
     and not exists (select 1 from public.chat_call_participants
                      where call_id = p_call_id
                        and state in ('joined', 'ringing'));
end; $$;

revoke all on function public.chat_leave_call(uuid) from public, anon;
grant execute on function public.chat_leave_call(uuid) to authenticated;

-- Ending it for everybody, which only the person who started it may do.
create or replace function public.chat_end_call(p_call_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_call public.chat_calls;
begin
  select * into v_call from public.chat_calls where id = p_call_id for update;
  if v_call.id is null then
    raise exception 'No such call' using errcode = 'P0002';
  end if;
  if v_call.started_by <> auth.uid() then
    raise exception 'Only whoever started the call may end it for everybody'
      using errcode = '42501';
  end if;

  update public.chat_call_participants
     set state = 'left', left_at = coalesce(left_at, now())
   where call_id = p_call_id and state in ('joined', 'ringing');
  update public.chat_calls
     set status = 'ended', ended_at = now(),
         end_reason = coalesce(end_reason, 'ended by the caller')
   where id = p_call_id and status in ('ringing', 'live');
end; $$;

revoke all on function public.chat_end_call(uuid) from public, anon;
grant execute on function public.chat_end_call(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What is ringing, and what happened
-- ---------------------------------------------------------------------
create or replace function public.chat_active_call(p_conversation_id uuid)
returns table (
  id uuid,
  kind text,
  status text,
  room_name text,
  started_by uuid,
  started_by_name text,
  is_mine boolean,
  ringing_until timestamptz,
  joined integer,
  my_state text
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select c.id, c.kind::text, c.status::text, c.room_name, c.started_by,
         coalesce(pr.full_name, pr.email),
         c.started_by = auth.uid(),
         c.ringing_until,
         (select count(*)::int from public.chat_call_participants p
           where p.call_id = c.id and p.state = 'joined'),
         (select p.state::text from public.chat_call_participants p
           where p.call_id = c.id and p.user_id = auth.uid())
    from public.chat_calls c
    left join public.profiles pr on pr.id = c.started_by
   where c.conversation_id = p_conversation_id
     and app.is_chat_participant(p_conversation_id)
     -- Ringing past its deadline is not ringing, whether or not
     -- anything has got round to writing that down.
     and (c.status = 'live'
          or (c.status = 'ringing' and c.ringing_until > now()))
   limit 1;
$$;

revoke all on function public.chat_active_call(uuid) from public, anon;
grant execute on function public.chat_active_call(uuid) to authenticated;

-- Every phone this person should be ringing on, across every
-- conversation. What a client subscribes to in order to put an incoming
-- call on the screen.
--
-- The condition is on *this participant's* state, not on the call's, and
-- that distinction is the whole point in a room. The first draft asked
-- for calls whose status was still `ringing` — which is true until
-- somebody answers, and false immediately afterwards. In a pair that is
-- indistinguishable from correct. In a group of four it means the moment
-- one person picks up, the other two phones go quiet and they never
-- learn there was a call. A test with three people caught it.
--
-- Ringing still has a deadline, and it is the same one whether or not
-- anybody has answered: after `ringing_until` the phone stops, though
-- the call may well still be live and joinable from the thread.
create or replace function public.chat_incoming_calls()
returns table (
  id uuid,
  conversation_id uuid,
  conversation_title text,
  kind text,
  room_name text,
  started_by_name text,
  ringing_until timestamptz
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select c.id, c.conversation_id,
         coalesce(conv.title, coalesce(pr.full_name, pr.email)),
         c.kind::text, c.room_name,
         coalesce(pr.full_name, pr.email),
         c.ringing_until
    from public.chat_call_participants me
    join public.chat_calls c on c.id = me.call_id
    join public.chat_conversations conv on conv.id = c.conversation_id
    left join public.profiles pr on pr.id = c.started_by
   where me.user_id = auth.uid()
     and me.state = 'ringing'
     and c.status in ('ringing', 'live')
     and c.ringing_until > now()
     and app.is_chat_participant(c.conversation_id);
$$;

revoke all on function public.chat_incoming_calls() from public, anon;
grant execute on function public.chat_incoming_calls() to authenticated;

-- ---------------------------------------------------------------------
-- Tidying up
--
-- The reads above do not depend on this having run — a call past its
-- deadline already reads as not ringing. This is so the history says
-- "missed" rather than "ringing since Tuesday".
-- ---------------------------------------------------------------------
create or replace function public.chat_expire_calls()
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  with expired as (
    update public.chat_calls
       set status = 'missed',
           ended_at = coalesce(ended_at, ringing_until),
           end_reason = coalesce(end_reason, 'nobody answered')
     where status = 'ringing' and ringing_until <= now()
    returning id
  )
  select count(*) into v_n from expired;

  update public.chat_call_participants p
     set state = 'left', left_at = coalesce(left_at, now())
    from public.chat_calls c
   where c.id = p.call_id and c.status = 'missed' and p.state = 'ringing';

  return v_n;
end; $$;

-- Service role only: it decides for everybody at once, the same shape as
-- the other scheduled work.
revoke all on function public.chat_expire_calls() from public, anon,
  authenticated;

-- ---------------------------------------------------------------------
-- Live
--
-- The one table where "arrives without a reload" is not a convenience:
-- a phone that rings a minute late has not rung.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array['chat_calls', 'chat_call_participants']
  loop
    execute format('alter table public.%I replica identity full', v_table);
    if not exists (
      select 1 from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public' and c.relname = v_table)
    then
      execute format(
        'alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end $$;
