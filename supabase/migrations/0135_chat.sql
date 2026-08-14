-- =====================================================================
-- iAkauntan :: chat
--
-- The first thing in this schema that crosses the company boundary on
-- purpose. Every policy written before this one asks the same question —
-- "are you a member of *this* organization?" — and answers no to
-- everything else. Inter-company chat exists to say yes, sometimes, to a
-- named other company, for named people, after somebody with the
-- authority to agree to it has agreed to it.
--
-- That makes the permission model the whole feature, so it is written
-- out here before any of the tables.
--
-- ---------------------------------------------------------------------
-- Three gates, and all of them have to open
--
--   1. The company must have the module.        `org_modules`
--   2. The person must be switched on for it.   `chat_access`
--   3. The two companies must be allowed to
--      talk, unless they are the same company.  `chat_links`
--
-- Gate 2 is the one that was asked for and it is deliberately per
-- person, not per role: buying chat for a company does not put every
-- clerk in it into a conversation with a supplier. An administrator
-- turns it on for the people who need it, one at a time, and can turn it
-- off again — at which point that person stops seeing chat at all,
-- including the history, because access is checked on every read rather
-- than at the door.
--
-- Deliberately *not* also gated by access types (0127). Chat has one
-- switch and one place to look when somebody cannot use it. Two
-- overlapping mechanisms would mean an administrator who has turned chat
-- on for a person, and watched it stay off, with nothing on the screen
-- explaining which of the two said no.
--
-- ---------------------------------------------------------------------
-- Why a link is between companies, not between people
--
-- A person cannot invite themselves into another company's chat, and an
-- administrator cannot quietly wire their own staff to a competitor's:
-- the link is proposed by an administrator of one company and has to be
-- accepted by an administrator of the other. Nobody can approve their
-- own request. Platform staff can decide one, because somebody has to be
-- able to unstick it, and that is recorded in `decided_by` like any
-- other decision.
--
-- Same group is not a shortcut. 0132 was explicit that a group is a
-- name, not a key to the books, and the same holds here: two companies
-- with the same owner still ask and still accept. `kind` records which
-- of the two situations it was, so an administrator reviewing a list can
-- see at a glance that this one is the sister company and that one is a
-- supplier.
--
-- ---------------------------------------------------------------------
-- Recursion, which is what makes chat RLS hard
--
-- "You may read this conversation if you are a participant in it" is a
-- policy on `chat_participants` that has to read `chat_participants`,
-- and Postgres will recurse until it gives up. Every membership test
-- here therefore goes through a SECURITY DEFINER function, which runs as
-- the table owner and so is not itself subject to the policy. That is
-- the only reason those functions exist; they are not a convenience.
--
-- ---------------------------------------------------------------------
-- What crosses the boundary, exactly
--
-- Names and avatars of people you are in a conversation with, and
-- nothing else. `profiles` keeps the RLS it has; the readers below are
-- SECURITY DEFINER and return three columns by name. A chat link does
-- not make one company's contacts, documents or ledger visible to the
-- other, and there is a test that says so.
-- =====================================================================

create type app.chat_link_status as enum
  ('pending', 'approved', 'rejected', 'revoked');

create type app.chat_link_kind as enum ('group', 'external');

-- ---------------------------------------------------------------------
-- Gate 2: who in this company may use chat at all
-- ---------------------------------------------------------------------
create table public.chat_access (
  org_id     uuid not null references public.organizations(id)
               on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  is_enabled boolean not null default true,
  enabled_by uuid references auth.users(id),
  enabled_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- ---------------------------------------------------------------------
-- Gate 3: which companies may talk to each other
--
-- The pair is stored in a fixed order so that "is there a link between
-- these two" is one lookup rather than two, and so the unique constraint
-- actually prevents a duplicate proposed from the other end.
-- `requested_by_org` keeps the direction that ordering throws away.
-- ---------------------------------------------------------------------
create table public.chat_links (
  id            uuid primary key default gen_random_uuid(),
  org_a         uuid not null references public.organizations(id)
                  on delete cascade,
  org_b         uuid not null references public.organizations(id)
                  on delete cascade,
  kind          app.chat_link_kind not null default 'external',
  status        app.chat_link_status not null default 'pending',
  requested_by_org uuid not null references public.organizations(id)
                     on delete cascade,
  requested_by  uuid references auth.users(id),
  decided_by    uuid references auth.users(id),
  decided_at    timestamptz,
  note          text,
  created_at    timestamptz not null default now(),
  check (org_a < org_b),
  check (requested_by_org in (org_a, org_b)),
  unique (org_a, org_b)
);

-- ---------------------------------------------------------------------
-- The conversations themselves
-- ---------------------------------------------------------------------
create table public.chat_conversations (
  id          uuid primary key default gen_random_uuid(),
  -- A direct conversation is between exactly two people and is found
  -- again rather than duplicated; a room has a title and a list.
  is_direct   boolean not null default true,
  title       text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  -- Maintained by trigger so the list can be ordered without reading
  -- every message.
  last_message_at timestamptz not null default now()
);

create table public.chat_participants (
  conversation_id uuid not null references public.chat_conversations(id)
                    on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  -- Which company this person is here *as*. A person who belongs to two
  -- companies is two different participants as far as permission goes,
  -- and this is the column that says which hat they had on.
  org_id          uuid not null references public.organizations(id)
                    on delete cascade,
  joined_at       timestamptz not null default now(),
  last_read_at    timestamptz not null default 'epoch',
  primary key (conversation_id, user_id)
);

create index chat_participants_user_idx
  on public.chat_participants (user_id);

create table public.chat_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id)
                    on delete cascade,
  sender_id       uuid not null references auth.users(id),
  sender_org_id   uuid not null references public.organizations(id),
  body            text not null check (length(btrim(body)) > 0),
  created_at      timestamptz not null default now(),
  edited_at       timestamptz,
  -- Soft, so the other side does not see a message vanish out of the
  -- middle of a conversation they have already read.
  deleted_at      timestamptz
);

create index chat_messages_conversation_idx
  on public.chat_messages (conversation_id, created_at desc);

-- ---------------------------------------------------------------------
-- The three gates, as functions
-- ---------------------------------------------------------------------

-- Gate 1 and 2 together: this company bought chat, and this person is
-- switched on for it.
create or replace function app.chat_enabled(
  p_org_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select exists (
           select 1 from public.org_modules m
            where m.org_id = p_org_id and m.module_code = 'chat'
              and m.is_enabled
              and (m.expires_at is null or m.expires_at > now()))
     and exists (
           select 1 from public.chat_access a
            where a.org_id = p_org_id and a.user_id = p_user_id
              and a.is_enabled)
     and exists (
           select 1 from public.org_members om
            where om.org_id = p_org_id and om.user_id = p_user_id);
$$;

-- Gate 3. The same company always may; two different ones need a link
-- that somebody accepted.
create or replace function app.chat_orgs_linked(p_org_a uuid, p_org_b uuid)
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select p_org_a = p_org_b
      or exists (
           select 1 from public.chat_links l
            where l.status = 'approved'
              and l.org_a = least(p_org_a, p_org_b)
              and l.org_b = greatest(p_org_a, p_org_b));
$$;

-- The recursion breaker. Being a participant is not enough on its own:
-- access is re-checked here, so switching somebody off takes the
-- conversations away rather than leaving them readable.
create or replace function app.is_chat_participant(
  p_conversation_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select exists (
    select 1
      from public.chat_participants p
     where p.conversation_id = p_conversation_id
       and p.user_id = p_user_id
       and app.chat_enabled(p.org_id, p_user_id));
$$;

-- Which company somebody is in a conversation *as*. SECURITY DEFINER for
-- the same reason as the one above: a policy on `chat_messages` that
-- read `chat_participants` directly would be subject to that table's own
-- policy, which calls back into this one.
create or replace function app.chat_participant_org(
  p_conversation_id uuid, p_user_id uuid default auth.uid())
returns uuid
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select p.org_id from public.chat_participants p
   where p.conversation_id = p_conversation_id and p.user_id = p_user_id;
$$;

-- These three are named inside the policies below, and a policy
-- expression is evaluated as whoever is running the query — so
-- `authenticated` has to be able to execute them or every read of every
-- chat table fails with "permission denied for function", which is not a
-- sentence anybody would connect to a chat window that will not open.
--
-- Worth being explicit that this is not a hole. Each one already answers
-- only about the caller by default, and the answers are booleans about
-- rows the caller is being tested against anyway; what they protect is
-- the recursion, not the secret.
revoke all on function app.chat_enabled(uuid, uuid) from public, anon;
revoke all on function app.is_chat_participant(uuid, uuid) from public, anon;
revoke all on function app.chat_participant_org(uuid, uuid) from public, anon;
grant execute on function app.chat_enabled(uuid, uuid) to authenticated;
grant execute on function app.is_chat_participant(uuid, uuid) to authenticated;
grant execute on function app.chat_participant_org(uuid, uuid) to authenticated;

-- This one is only ever called from inside the SECURITY DEFINER
-- functions, never from a policy, so it stays shut.
revoke all on function app.chat_orgs_linked(uuid, uuid) from public, anon,
  authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.chat_access enable row level security;
alter table public.chat_links enable row level security;
alter table public.chat_conversations enable row level security;
alter table public.chat_participants enable row level security;
alter table public.chat_messages enable row level security;

-- Your own switch, or all of them if you administer the company.
create policy chat_access_select on public.chat_access
  for select to authenticated
  using (user_id = auth.uid() or app.can_admin(org_id)
         or app.is_platform_admin());

create policy chat_access_write on public.chat_access
  for all to authenticated
  using (app.can_admin(org_id) or app.is_platform_admin())
  with check (app.can_admin(org_id) or app.is_platform_admin());

-- A link is visible to both sides — you cannot accept what you cannot
-- see — and to platform staff.
create policy chat_links_select on public.chat_links
  for select to authenticated
  using (app.is_org_member(org_a) or app.is_org_member(org_b)
         or app.is_platform_admin());

-- Read only, deliberately. There is no insert or update policy on this
-- table at all: proposing, deciding and ending a link all go through the
-- SECURITY DEFINER functions below.
--
-- The first draft did have them, and both were wrong in the same way. A
-- policy's `with check` sees the *new* row, so "the side that asked may
-- withdraw while it is still pending" let the asking side write
-- `status = 'approved'` themselves — approving their own request, which
-- is the one thing the whole design exists to prevent. Tightening the
-- check to a list of allowed statuses did not fix it either: the new row
-- can also move `requested_by_org` to the other company, and then the
-- test for "am I the side that was asked?" reads the value the attacker
-- just wrote and says yes.
--
-- There is no way to express "and this column did not change" in a
-- policy, because RLS cannot see the old row from `with check`. So the
-- table takes no writes from the client and the functions, which can
-- lock the row and compare against what is actually stored, do the work.

create policy chat_conversations_select on public.chat_conversations
  for select to authenticated
  using (app.is_chat_participant(id));

create policy chat_conversations_insert on public.chat_conversations
  for insert to authenticated
  with check (created_by = auth.uid());

create policy chat_conversations_update on public.chat_conversations
  for update to authenticated
  using (app.is_chat_participant(id))
  with check (app.is_chat_participant(id));

create policy chat_participants_select on public.chat_participants
  for select to authenticated
  using (app.is_chat_participant(conversation_id));

-- Only your own row, and only ever to mark it read.
create policy chat_participants_update on public.chat_participants
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Leaving is allowed; removing somebody else is not.
create policy chat_participants_delete on public.chat_participants
  for delete to authenticated
  using (user_id = auth.uid());

create policy chat_messages_select on public.chat_messages
  for select to authenticated
  using (app.is_chat_participant(conversation_id));

-- Sending. Four conditions, none of them redundant: it is from you, you
-- are in the conversation, chat is still switched on for you, and the
-- company you are speaking for is the one you joined this conversation
-- as — not merely one you happen to belong to. Somebody who is in two
-- companies would otherwise be able to put the wrong letterhead on a
-- message, and in a conversation that crosses a company boundary the
-- letterhead is most of the meaning.
create policy chat_messages_insert on public.chat_messages
  for insert to authenticated
  with check (sender_id = auth.uid()
              and app.is_chat_participant(conversation_id)
              and app.chat_enabled(sender_org_id, auth.uid())
              and sender_org_id = app.chat_participant_org(conversation_id));

create policy chat_messages_update on public.chat_messages
  for update to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'chat_access', 'chat_conversations', 'chat_participants', 'chat_messages'
  ]
  loop
    execute format(
      'grant select, insert, update, delete on public.%I to authenticated',
      v_table);
  end loop;
end $$;

-- Reading only. Every write to this table goes through a function, for
-- the reason set out above the policies.
grant select on public.chat_links to authenticated;

-- ---------------------------------------------------------------------
-- Keeping the list orderable
-- ---------------------------------------------------------------------
create or replace function app.touch_conversation()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  update public.chat_conversations
     set last_message_at = new.created_at
   where id = new.conversation_id;
  return new;
end; $$;

create trigger touch_conversation
  after insert on public.chat_messages
  for each row execute function app.touch_conversation();

-- ---------------------------------------------------------------------
-- Starting a conversation
--
-- The only way to add somebody to one. Left to the client, adding a
-- participant would be an insert whose `with check` had to re-derive all
-- three gates for a row that names two people and two companies; here it
-- is one function that says no once, clearly.
--
-- A direct conversation is found rather than duplicated, so opening the
-- same colleague twice does not produce two threads with half the
-- history in each.
-- ---------------------------------------------------------------------
create or replace function public.chat_start_direct(
  p_my_org uuid, p_other_user uuid, p_other_org uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if v_me = p_other_user and p_my_org = p_other_org then
    raise exception 'You cannot start a conversation with yourself'
      using errcode = '22023';
  end if;
  if not app.chat_enabled(p_my_org, v_me) then
    raise exception 'Chat is not switched on for you in this company'
      using errcode = '42501';
  end if;
  if not app.chat_enabled(p_other_org, p_other_user) then
    raise exception 'Chat is not switched on for that person'
      using errcode = '42501';
  end if;
  if not app.chat_orgs_linked(p_my_org, p_other_org) then
    raise exception 'These companies are not linked for chat'
      using errcode = '42501';
  end if;

  -- Exactly these two people, and no third.
  select c.id into v_id
    from public.chat_conversations c
   where c.is_direct
     and exists (select 1 from public.chat_participants p
                  where p.conversation_id = c.id and p.user_id = v_me
                    and p.org_id = p_my_org)
     and exists (select 1 from public.chat_participants p
                  where p.conversation_id = c.id and p.user_id = p_other_user
                    and p.org_id = p_other_org)
     and (select count(*) from public.chat_participants p
           where p.conversation_id = c.id) = 2
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.chat_conversations (is_direct, created_by)
  values (true, v_me) returning id into v_id;

  insert into public.chat_participants (conversation_id, user_id, org_id)
  values (v_id, v_me, p_my_org), (v_id, p_other_user, p_other_org);

  return v_id;
end; $$;

revoke all on function public.chat_start_direct(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.chat_start_direct(uuid, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Reading: what crosses the boundary is named here and nowhere else
-- ---------------------------------------------------------------------
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
  unread integer
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
             and m.created_at > me.last_read_at)
    from public.chat_participants me
    join public.chat_conversations c on c.id = me.conversation_id
    -- The other side of a direct conversation. Left join so a room, or
    -- a conversation somebody has left, still appears.
    left join public.chat_participants o
      on o.conversation_id = c.id and o.user_id <> me.user_id
    left join public.profiles pr on pr.id = o.user_id
    left join public.organizations org on org.id = o.org_id
   where me.user_id = auth.uid()
     and me.org_id = p_org_id
     and app.chat_enabled(p_org_id, auth.uid())
   order by c.last_message_at desc;
$$;

revoke all on function public.chat_my_conversations(uuid) from public, anon;
grant execute on function public.chat_my_conversations(uuid) to authenticated;

-- Who you may start a conversation with: colleagues, plus everybody in
-- a company yours has an approved link with. Both ends switched on.
create or replace function public.chat_directory(p_org_id uuid)
returns table (
  user_id uuid,
  full_name text,
  email text,
  avatar_url text,
  org_id uuid,
  org_name text,
  is_cross_company boolean
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select a.user_id,
         coalesce(pr.full_name, pr.email),
         pr.email,
         pr.avatar_url,
         a.org_id,
         o.name,
         a.org_id <> p_org_id
    from public.chat_access a
    join public.organizations o on o.id = a.org_id
    left join public.profiles pr on pr.id = a.user_id
   where a.is_enabled
     and a.user_id <> auth.uid()
     and app.chat_enabled(p_org_id, auth.uid())
     and app.chat_orgs_linked(p_org_id, a.org_id)
     and app.chat_enabled(a.org_id, a.user_id)
   order by (a.org_id <> p_org_id), coalesce(pr.full_name, pr.email);
$$;

revoke all on function public.chat_directory(uuid) from public, anon;
grant execute on function public.chat_directory(uuid) to authenticated;

-- The sender's name, for the thread. Same rule: only for a conversation
-- you are in.
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
  is_mine boolean
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select m.id, m.sender_id,
         coalesce(pr.full_name, pr.email),
         pr.avatar_url,
         m.sender_org_id,
         m.body, m.created_at, m.edited_at,
         m.sender_id = auth.uid()
    from public.chat_messages m
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

create or replace function public.chat_mark_read(p_conversation_id uuid)
returns void
language sql security definer
set search_path = public, app, pg_temp as $$
  update public.chat_participants
     set last_read_at = now()
   where conversation_id = p_conversation_id and user_id = auth.uid();
$$;

revoke all on function public.chat_mark_read(uuid) from public, anon;
grant execute on function public.chat_mark_read(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Administration
-- ---------------------------------------------------------------------

-- Switch a colleague on or off. Rows are kept rather than deleted so
-- "who turned this on, and when" survives being turned off again.
create or replace function public.chat_set_access(
  p_org_id uuid, p_user_id uuid, p_enabled boolean)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not (app.can_admin(p_org_id) or app.is_platform_admin()) then
    raise exception 'You may not change who can use chat'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.org_members
                  where org_id = p_org_id and user_id = p_user_id) then
    raise exception 'That person is not a member of this company'
      using errcode = '22023';
  end if;

  insert into public.chat_access (org_id, user_id, is_enabled, enabled_by)
  values (p_org_id, p_user_id, p_enabled, auth.uid())
  on conflict (org_id, user_id) do update
    set is_enabled = excluded.is_enabled,
        enabled_by = excluded.enabled_by,
        enabled_at = now();
end; $$;

revoke all on function public.chat_set_access(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.chat_set_access(uuid, uuid, boolean)
  to authenticated;

-- Everybody in the company and whether they are switched on, so the
-- administrator has one list rather than a list and a gap.
create or replace function public.chat_access_list(p_org_id uuid)
returns table (
  user_id uuid,
  full_name text,
  email text,
  role text,
  is_enabled boolean
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select om.user_id,
         coalesce(pr.full_name, pr.email),
         coalesce(pr.email, om.invited_email),
         om.role::text,
         coalesce(a.is_enabled, false)
    from public.org_members om
    left join public.profiles pr on pr.id = om.user_id
    left join public.chat_access a
      on a.org_id = om.org_id and a.user_id = om.user_id
   where om.org_id = p_org_id
     and om.user_id is not null
     and (app.can_admin(p_org_id) or app.is_platform_admin())
   order by coalesce(pr.full_name, pr.email);
$$;

revoke all on function public.chat_access_list(uuid) from public, anon;
grant execute on function public.chat_access_list(uuid) to authenticated;

-- Propose a link to another company. `kind` is worked out here rather
-- than trusted from the client, because "this is our sister company" is
-- a claim about the group and the group is in the database.
create or replace function public.chat_request_link(
  p_my_org uuid, p_target_org uuid, p_note text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
  v_kind app.chat_link_kind;
  v_existing public.chat_links;
begin
  if not (app.can_admin(p_my_org) or app.is_platform_admin()) then
    raise exception 'You may not link this company for chat'
      using errcode = '42501';
  end if;
  if p_my_org = p_target_org then
    raise exception 'A company is already linked to itself'
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.organizations where id = p_target_org) then
    raise exception 'No such company' using errcode = 'P0002';
  end if;

  select case when exists (
           select 1 from public.organizations a, public.organizations b
            where a.id = p_my_org and b.id = p_target_org
              and a.group_id is not null and a.group_id = b.group_id)
         then 'group' else 'external' end into v_kind;

  select * into v_existing from public.chat_links
   where org_a = least(p_my_org, p_target_org)
     and org_b = greatest(p_my_org, p_target_org);

  if v_existing.id is not null then
    if v_existing.status = 'approved' then
      raise exception 'These companies are already linked'
        using errcode = '23505';
    end if;
    -- A rejected or revoked link can be asked for again, which is a
    -- different thing from pretending the first request never happened.
    update public.chat_links
       set status = 'pending', requested_by_org = p_my_org,
           requested_by = auth.uid(), kind = v_kind, note = p_note,
           decided_by = null, decided_at = null, created_at = now()
     where id = v_existing.id;
    return v_existing.id;
  end if;

  insert into public.chat_links
    (org_a, org_b, kind, status, requested_by_org, requested_by, note)
  values (least(p_my_org, p_target_org), greatest(p_my_org, p_target_org),
          v_kind, 'pending', p_my_org, auth.uid(), p_note)
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function public.chat_request_link(uuid, uuid, text)
  from public, anon;
grant execute on function public.chat_request_link(uuid, uuid, text)
  to authenticated;

-- Accept or refuse one. The check that matters is the `<>`: the company
-- that asked is not the company that may answer.
create or replace function public.chat_decide_link(
  p_link_id uuid, p_approve boolean)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_link public.chat_links;
  v_other uuid;
begin
  select * into v_link from public.chat_links where id = p_link_id for update;
  if v_link.id is null then
    raise exception 'No such link' using errcode = 'P0002';
  end if;
  if v_link.status <> 'pending' then
    raise exception 'That link is already %', v_link.status
      using errcode = '22023';
  end if;

  v_other := case when v_link.requested_by_org = v_link.org_a
                  then v_link.org_b else v_link.org_a end;

  if not (app.can_admin(v_other) or app.is_platform_admin()) then
    raise exception 'Only the company that was asked may answer'
      using errcode = '42501';
  end if;

  -- The cast is load-bearing. A bare literal is `unknown` and Postgres
  -- coerces it to the column's type; a CASE over two literals resolves
  -- to `text` first, and there is no implicit text-to-enum assignment.
  update public.chat_links
     set status = (case when p_approve then 'approved' else 'rejected' end)
                    ::app.chat_link_status,
         decided_by = auth.uid(), decided_at = now()
   where id = p_link_id;
end; $$;

revoke all on function public.chat_decide_link(uuid, boolean)
  from public, anon;
grant execute on function public.chat_decide_link(uuid, boolean)
  to authenticated;

-- Ending one. Either side may, without asking, because consent to be
-- talked to has to be withdrawable by the side that gave it. History
-- stays; what stops is starting anything new.
create or replace function public.chat_revoke_link(p_link_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_link public.chat_links;
begin
  select * into v_link from public.chat_links where id = p_link_id for update;
  if v_link.id is null then
    raise exception 'No such link' using errcode = 'P0002';
  end if;
  if not (app.can_admin(v_link.org_a) or app.can_admin(v_link.org_b)
          or app.is_platform_admin()) then
    raise exception 'You may not end this link' using errcode = '42501';
  end if;

  update public.chat_links
     set status = 'revoked', decided_by = auth.uid(), decided_at = now()
   where id = p_link_id;
end; $$;

revoke all on function public.chat_revoke_link(uuid) from public, anon;
grant execute on function public.chat_revoke_link(uuid) to authenticated;

-- Both directions in one list, with the other company named and a flag
-- saying whether this one is waiting on us or on them.
create or replace function public.chat_links_for(p_org_id uuid)
returns table (
  id uuid,
  other_org_id uuid,
  other_org_name text,
  kind text,
  status text,
  we_asked boolean,
  awaiting_us boolean,
  note text,
  created_at timestamptz
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select l.id,
         case when l.org_a = p_org_id then l.org_b else l.org_a end,
         o.name,
         l.kind::text,
         l.status::text,
         l.requested_by_org = p_org_id,
         l.status = 'pending' and l.requested_by_org <> p_org_id,
         l.note,
         l.created_at
    from public.chat_links l
    join public.organizations o
      on o.id = case when l.org_a = p_org_id then l.org_b else l.org_a end
   where (l.org_a = p_org_id or l.org_b = p_org_id)
     and app.is_org_member(p_org_id)
   order by (l.status = 'pending') desc, l.created_at desc;
$$;

revoke all on function public.chat_links_for(uuid) from public, anon;
grant execute on function public.chat_links_for(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Live
--
-- Realtime applies row level security when deciding who is sent a row,
-- and the policies above are already narrower than org membership — a
-- message goes to participants of that conversation and nobody else. So
-- publishing these adds no exposure; it is what makes it chat rather
-- than a message board you have to reload.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array['chat_messages', 'chat_participants']
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

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order)
values ('chat', 'Chat',
        'Message colleagues, sister companies and linked companies',
        false, 0, 96)
on conflict (code) do nothing;
