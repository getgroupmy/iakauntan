-- =====================================================================
-- iAkauntan :: sent, delivered, read, online, idle, typing
--
-- Six states, and they are not six of the same thing. Three are facts
-- about a message and three are facts about a person, and the split
-- decides how each is stored.
--
-- ---------------------------------------------------------------------
-- The three about a message
--
--   sent       the row exists. There is nothing to store: a message
--              that reached the database has been sent, and until the
--              insert returns the client shows its own pending state.
--   delivered  it reached the other person's device.
--   read       they opened the conversation with it on screen.
--
-- Both of the last two are stored as one timestamp per participant
-- rather than a row per message per person. A conversation of ten
-- thousand messages does not need twenty thousand receipt rows to say
-- what two watermarks say: everything up to here arrived, everything up
-- to there was read. Receipts only ever move forward, which the writers
-- below enforce with `greatest`, because a message that has been read
-- cannot become unread by a stale request arriving late.
--
-- ---------------------------------------------------------------------
-- The three about a person
--
--   online   their app is open and they are using it
--   idle     their app is open and they are not
--   typing   they are typing, right now, in this conversation
--
-- None of these are facts, they are guesses with a shelf life, and the
-- shelf life is the whole design. `chat_presence` holds one row per
-- person that a heartbeat refreshes; nothing writes "offline", because
-- the interesting case is the app that stopped saying anything at all —
-- closed tab, dead battery, tunnel — and a client that has stopped
-- talking cannot report that it stopped. Online is therefore *derived*:
-- recent enough, and last said it was active.
--
-- Typing is the same shape with a much shorter fuse. It expires on its
-- own after a few seconds so a person who types a word and wanders off
-- does not appear to be typing until they come back.
--
-- ---------------------------------------------------------------------
-- Why this is in the database rather than in Realtime's presence
--
-- Supabase Realtime can carry presence and typing as ephemeral channel
-- state, which is cheaper — no writes at all — and is what a chat with
-- one room would use. It is not what this one uses, for two reasons.
--
-- The list of conversations shows a dot beside every person in it, and
-- with channel presence that means joining a channel per conversation
-- just to colour a dot. And a receipt has to survive a reload, so the
-- watermarks are in a table regardless; putting presence beside them
-- keeps one story rather than two.
--
-- The cost is honest: a heartbeat is a write every thirty seconds per
-- open app, and a typing notice is a write every few seconds while
-- somebody is actually typing — both throttled in the client, neither
-- per keystroke. If that ever becomes the expensive part, typing is the
-- piece to move to broadcast and nothing else has to change.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Delivered, alongside the read watermark that already existed
-- ---------------------------------------------------------------------
alter table public.chat_participants
  add column last_delivered_at timestamptz not null default 'epoch';

-- ---------------------------------------------------------------------
-- Presence
-- ---------------------------------------------------------------------
create type app.chat_presence_state as enum ('online', 'idle');

create table public.chat_presence (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  state        app.chat_presence_state not null default 'online',
  last_seen_at timestamptz not null default now()
);

-- How stale a heartbeat may be before the person is simply gone. Longer
-- than the client's interval by enough that one dropped beat does not
-- blink somebody offline.
create or replace function app.chat_presence_window()
returns interval language sql immutable as $$ select interval '75 seconds' $$;

-- ---------------------------------------------------------------------
-- Typing
--
-- One row per person per conversation, replaced rather than accumulated,
-- carrying its own expiry. Nothing has to clean it up on time: a row
-- past its expiry is not typing, and the next write overwrites it.
-- ---------------------------------------------------------------------
create table public.chat_typing (
  conversation_id uuid not null references public.chat_conversations(id)
                    on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  expires_at      timestamptz not null,
  primary key (conversation_id, user_id)
);

alter table public.chat_presence enable row level security;
alter table public.chat_typing enable row level security;

-- `app.chat_orgs_linked` stays closed to clients; the presence policy
-- needs the same answer, so it gets a callable wrapper rather than the
-- policy reaching for something it may not execute. This is the mistake
-- 0135 made once already — a policy that names a function the caller
-- cannot run fails with "permission denied for function", from a screen
-- that gives no hint which function it meant.
--
-- Defined *before* the policy that names it, which is the other half of
-- the same lesson. A policy body is parsed and its functions resolved
-- when the policy is created, not when it is used, so a wrapper written
-- below the policy exists too late: `function app.chat_visible_org(uuid,
-- uuid) does not exist`, and the migration stops on statement seven.
create or replace function app.chat_visible_org(p_mine uuid, p_theirs uuid)
returns boolean language sql stable security definer
set search_path = public, app, pg_temp as $$
  select app.chat_orgs_linked(p_mine, p_theirs);
$$;

revoke all on function app.chat_visible_org(uuid, uuid) from public, anon;
grant execute on function app.chat_visible_org(uuid, uuid) to authenticated;

-- Presence is visible to people you could hold a conversation with —
-- which is the same list the directory shows, and not one person more.
-- Written only about yourself.
create policy chat_presence_select on public.chat_presence
  for select to authenticated
  using (user_id = auth.uid()
         or exists (select 1 from public.chat_participants p
                     where p.user_id = chat_presence.user_id
                       and app.is_chat_participant(p.conversation_id))
         or exists (select 1 from public.chat_access a
                     join public.chat_access mine
                       on mine.user_id = auth.uid() and mine.is_enabled
                    where a.user_id = chat_presence.user_id and a.is_enabled
                      and app.chat_visible_org(mine.org_id, a.org_id)));

create policy chat_presence_write on public.chat_presence
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy chat_typing_select on public.chat_typing
  for select to authenticated
  using (app.is_chat_participant(conversation_id));

create policy chat_typing_write on public.chat_typing
  for all to authenticated
  using (user_id = auth.uid() and app.is_chat_participant(conversation_id))
  with check (user_id = auth.uid()
              and app.is_chat_participant(conversation_id));

grant select, insert, update, delete on public.chat_presence to authenticated;
grant select, insert, update, delete on public.chat_typing to authenticated;

-- ---------------------------------------------------------------------
-- Writers
-- ---------------------------------------------------------------------

-- Called on a timer while the app is open, and once more when it is
-- backgrounded. `p_idle` is what the client knows and the server cannot:
-- whether anybody is actually looking.
create or replace function public.chat_heartbeat(p_idle boolean default false)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  insert into public.chat_presence (user_id, state, last_seen_at)
  values (auth.uid(),
          (case when p_idle then 'idle' else 'online' end)
            ::app.chat_presence_state,
          now())
  on conflict (user_id) do update
    set state = excluded.state, last_seen_at = excluded.last_seen_at
  where auth.uid() is not null;
$$;

revoke all on function public.chat_heartbeat(boolean) from public, anon;
grant execute on function public.chat_heartbeat(boolean) to authenticated;

-- Both watermarks only ever move forward.
create or replace function public.chat_mark_read(p_conversation_id uuid)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  update public.chat_participants
     set last_read_at = greatest(last_read_at, now()),
         last_delivered_at = greatest(last_delivered_at, now())
   where conversation_id = p_conversation_id and user_id = auth.uid();
$$;

-- Reaching the device is not the same as being looked at: the app calls
-- this when a message arrives while the conversation is not on screen.
create or replace function public.chat_mark_delivered(p_conversation_id uuid)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  update public.chat_participants
     set last_delivered_at = greatest(last_delivered_at, now())
   where conversation_id = p_conversation_id and user_id = auth.uid();
$$;

revoke all on function public.chat_mark_delivered(uuid) from public, anon;
grant execute on function public.chat_mark_delivered(uuid) to authenticated;

-- Throttled in the client to roughly one call every three seconds while
-- keys are actually being pressed.
create or replace function public.chat_typing_ping(
  p_conversation_id uuid, p_seconds integer default 6)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_chat_participant(p_conversation_id) then
    raise exception 'Not in this conversation' using errcode = '42501';
  end if;
  insert into public.chat_typing (conversation_id, user_id, expires_at)
  values (p_conversation_id, auth.uid(),
          now() + make_interval(secs => greatest(least(p_seconds, 30), 1)))
  on conflict (conversation_id, user_id) do update
    set expires_at = excluded.expires_at;
end; $$;

revoke all on function public.chat_typing_ping(uuid, integer) from public, anon;
grant execute on function public.chat_typing_ping(uuid, integer) to authenticated;

-- Stopping is worth saying out loud rather than waiting out the expiry,
-- because the moment somebody sends the message is the moment the "…"
-- should go.
create or replace function public.chat_typing_stop(p_conversation_id uuid)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  delete from public.chat_typing
   where conversation_id = p_conversation_id and user_id = auth.uid();
$$;

revoke all on function public.chat_typing_stop(uuid) from public, anon;
grant execute on function public.chat_typing_stop(uuid) to authenticated;

-- Sending clears your own typing flag. Doing it in a trigger rather than
-- trusting the client means the "…" cannot outlive the message that
-- ended it, however the message got sent.
create or replace function app.clear_typing_on_send()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  delete from public.chat_typing
   where conversation_id = new.conversation_id and user_id = new.sender_id;
  return new;
end; $$;

create trigger clear_typing_on_send
  after insert on public.chat_messages
  for each row execute function app.clear_typing_on_send();

-- ---------------------------------------------------------------------
-- Readers
--
-- The three below gain columns, and `create or replace` cannot change
-- the row type a function returns — it fails with "cannot change return
-- type of existing function", which on a fresh stack means this
-- migration stops halfway rather than only on a database that already
-- had 0135. Dropped first, therefore, and recreated whole.
-- ---------------------------------------------------------------------
drop function if exists public.chat_my_conversations(uuid);
drop function if exists public.chat_thread(uuid, timestamptz, integer);
drop function if exists public.chat_directory(uuid);

-- Who is typing in this conversation, other than you, right now.
create or replace function public.chat_who_is_typing(p_conversation_id uuid)
returns table (user_id uuid, full_name text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select t.user_id, coalesce(pr.full_name, pr.email)
    from public.chat_typing t
    left join public.profiles pr on pr.id = t.user_id
   where t.conversation_id = p_conversation_id
     and t.user_id <> auth.uid()
     and t.expires_at > now()
     and app.is_chat_participant(p_conversation_id);
$$;

revoke all on function public.chat_who_is_typing(uuid) from public, anon;
grant execute on function public.chat_who_is_typing(uuid) to authenticated;

-- The conversation list, now carrying the other person's presence and
-- how far they have got through what you sent them.
create or replace function public.chat_my_conversations(p_org_id uuid)
returns table (
  conversation_id uuid,
  is_direct boolean,
  title text,
  other_user_id uuid,
  other_name text,
  other_avatar_url text,
  other_org_id uuid,
  other_org_name text,
  is_cross_company boolean,
  last_message text,
  last_message_at timestamptz,
  unread integer,
  other_state text,
  other_last_seen_at timestamptz,
  -- Where the other side has got to in what you sent. The list uses
  -- these for the tick beside your own last message.
  their_delivered_at timestamptz,
  their_read_at timestamptz,
  they_are_typing boolean
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select c.id,
         c.is_direct,
         c.title,
         o.user_id,
         coalesce(pr.full_name, pr.email),
         pr.avatar_url,
         o.org_id,
         org.name,
         o.org_id <> me.org_id,
         (select m.body from public.chat_messages m
           where m.conversation_id = c.id and m.deleted_at is null
           order by m.created_at desc limit 1),
         c.last_message_at,
         (select count(*)::int from public.chat_messages m
           where m.conversation_id = c.id
             and m.sender_id <> auth.uid()
             and m.deleted_at is null
             and m.created_at > me.last_read_at),
         -- Derived, never stored: a heartbeat that stopped arriving is
         -- what "offline" actually looks like.
         case when pres.last_seen_at is null
                or pres.last_seen_at < now() - app.chat_presence_window()
              then 'offline' else pres.state::text end,
         pres.last_seen_at,
         o.last_delivered_at,
         o.last_read_at,
         exists (select 1 from public.chat_typing t
                  where t.conversation_id = c.id and t.user_id = o.user_id
                    and t.expires_at > now())
    from public.chat_participants me
    join public.chat_conversations c on c.id = me.conversation_id
    left join public.chat_participants o
      on o.conversation_id = c.id and o.user_id <> me.user_id
    left join public.profiles pr on pr.id = o.user_id
    left join public.organizations org on org.id = o.org_id
    left join public.chat_presence pres on pres.user_id = o.user_id
   where me.user_id = auth.uid()
     and me.org_id = p_org_id
     and app.chat_enabled(p_org_id, auth.uid())
   order by c.last_message_at desc;
$$;

revoke all on function public.chat_my_conversations(uuid) from public, anon;
grant execute on function public.chat_my_conversations(uuid) to authenticated;

-- The thread, with the state of each of your own messages worked out
-- against the furthest-behind of the other participants — so in a room
-- "read" means everybody, not somebody.
create or replace function public.chat_thread(
  p_conversation_id uuid, p_before timestamptz default null,
  p_limit integer default 50)
returns table (
  id uuid,
  sender_id uuid,
  sender_name text,
  sender_avatar_url text,
  sender_org_id uuid,
  body text,
  created_at timestamptz,
  edited_at timestamptz,
  is_mine boolean,
  -- 'sent', 'delivered' or 'read'. Null on messages that are not yours,
  -- because a receipt on somebody else's message means nothing.
  state text
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  with others as (
    select min(p.last_delivered_at) as delivered, min(p.last_read_at) as read
      from public.chat_participants p
     where p.conversation_id = p_conversation_id and p.user_id <> auth.uid()
  )
  select m.id, m.sender_id,
         coalesce(pr.full_name, pr.email),
         pr.avatar_url,
         m.sender_org_id,
         m.body, m.created_at, m.edited_at,
         m.sender_id = auth.uid(),
         case when m.sender_id <> auth.uid() then null
              when m.created_at <= o.read then 'read'
              when m.created_at <= o.delivered then 'delivered'
              else 'sent' end
    from public.chat_messages m
    cross join others o
    left join public.profiles pr on pr.id = m.sender_id
   where m.conversation_id = p_conversation_id
     and m.deleted_at is null
     and app.is_chat_participant(p_conversation_id)
     and (p_before is null or m.created_at < p_before)
   order by m.created_at desc
   limit greatest(least(coalesce(p_limit, 50), 200), 1);
$$;

revoke all on function public.chat_thread(uuid, timestamptz, integer)
  from public, anon;
grant execute on function public.chat_thread(uuid, timestamptz, integer)
  to authenticated;

-- The directory, with the same derived presence, so you can see who is
-- about before deciding whether to message or to telephone.
create or replace function public.chat_directory(p_org_id uuid)
returns table (
  user_id uuid,
  full_name text,
  email text,
  avatar_url text,
  org_id uuid,
  org_name text,
  is_cross_company boolean,
  state text,
  last_seen_at timestamptz
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select a.user_id,
         coalesce(pr.full_name, pr.email),
         pr.email,
         pr.avatar_url,
         a.org_id,
         o.name,
         a.org_id <> p_org_id,
         case when pres.last_seen_at is null
                or pres.last_seen_at < now() - app.chat_presence_window()
              then 'offline' else pres.state::text end,
         pres.last_seen_at
    from public.chat_access a
    join public.organizations o on o.id = a.org_id
    left join public.profiles pr on pr.id = a.user_id
    left join public.chat_presence pres on pres.user_id = a.user_id
   where a.is_enabled
     and a.user_id <> auth.uid()
     and app.chat_enabled(p_org_id, auth.uid())
     and app.chat_orgs_linked(p_org_id, a.org_id)
     and app.chat_enabled(a.org_id, a.user_id)
   order by (a.org_id <> p_org_id), coalesce(pr.full_name, pr.email);
$$;

revoke all on function public.chat_directory(uuid) from public, anon;
grant execute on function public.chat_directory(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Live
--
-- The receipts and the typing flags are only worth anything if they
-- arrive without a reload, which is the same argument as for the
-- messages themselves. `chat_participants` was already published in
-- 0135, which is what carries a watermark moving.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array['chat_typing', 'chat_presence']
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
