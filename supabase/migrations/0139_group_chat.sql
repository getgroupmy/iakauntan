-- =====================================================================
-- iAkauntan :: more than two people
--
-- `chat_conversations` has carried `is_direct` and `title` since 0135
-- and `chat_participants` never limited a conversation to two, so a
-- group was always possible in the shape of the tables. Two things were
-- missing: a safe way to put people in one, and a conversation list that
-- can count.
--
-- ---------------------------------------------------------------------
-- Who may be added, which is the question groups introduce
--
-- A direct conversation asks one thing: are these two companies linked?
-- A group can ask it several times and get different answers, and the
-- obvious rule is wrong.
--
-- Say A and B are linked and A and C are linked, but B and C are not. A
-- has a room with B in it. If "may I add somebody?" is answered against
-- the *adder's* company, A can drop C into the room and C reads
-- everything B says — B never agreed to talk to C and is not asked.
-- That is not a corner case; it is the ordinary way a supplier and a
-- competitor end up in the same thread.
--
-- So the rule is: to join a conversation, your company must be linked to
-- *every* company already in it. Everybody in the room is somebody every
-- other company in the room agreed to. `app.chat_can_join` is that
-- sentence, and there is a test with A, B and C that fails if it stops
-- being true.
--
-- ---------------------------------------------------------------------
-- The list could not count
--
-- `chat_my_conversations` found "the other participant" with a join on
-- `user_id <> me.user_id`. With one other person that is a row; with
-- three it is three rows, and the same group appears three times in the
-- list with a different face on each. Latent since 0135 and impossible
-- to hit until now.
--
-- The fix separates two things that happened to coincide for a pair: the
-- *counterpart*, which only a direct conversation has, and the
-- *watermarks*, which are an aggregate over everybody else and always
-- were — `min(last_read_at)` already meant "read by all", which is the
-- right meaning for a group and an unremarkable one for a pair.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------
create or replace function app.chat_can_join(
  p_conversation_id uuid, p_org_id uuid)
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  -- Not exists an existing company that this one is not linked to.
  select not exists (
    select 1
      from (select distinct p.org_id
              from public.chat_participants p
             where p.conversation_id = p_conversation_id) existing
     where not app.chat_orgs_linked(p_org_id, existing.org_id));
$$;

revoke all on function app.chat_can_join(uuid, uuid) from public, anon;
grant execute on function app.chat_can_join(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Making one
--
-- Members arrive as [{"user_id": "...", "org_id": "..."}, ...] because
-- a person is only reachable *as* a member of a company — the same pair
-- the directory returns.
-- ---------------------------------------------------------------------
create or replace function public.chat_create_group(
  p_my_org uuid, p_title text, p_members jsonb)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
  v_member jsonb;
  v_user uuid;
  v_org uuid;
begin
  if v_me is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if not app.chat_enabled(p_my_org, v_me) then
    raise exception 'Chat is not switched on for you in this company'
      using errcode = '42501';
  end if;
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'A group needs a name' using errcode = '22023';
  end if;
  if jsonb_typeof(p_members) <> 'array'
     or jsonb_array_length(p_members) = 0 then
    raise exception 'A group needs somebody in it' using errcode = '22023';
  end if;

  insert into public.chat_conversations (is_direct, title, created_by)
  values (false, btrim(p_title), v_me) returning id into v_id;

  insert into public.chat_participants (conversation_id, user_id, org_id)
  values (v_id, v_me, p_my_org);

  for v_member in select * from jsonb_array_elements(p_members)
  loop
    v_user := (v_member ->> 'user_id')::uuid;
    v_org  := (v_member ->> 'org_id')::uuid;

    if not app.chat_enabled(v_org, v_user) then
      raise exception 'Chat is not switched on for one of those people'
        using errcode = '42501';
    end if;
    -- Checked against everybody already added, which as the list grows
    -- means every pair in the room has agreed.
    if not app.chat_can_join(v_id, v_org) then
      raise exception 'One of those companies is not linked to another '
        'company in this group' using errcode = '42501';
    end if;

    insert into public.chat_participants (conversation_id, user_id, org_id)
    values (v_id, v_user, v_org)
    on conflict (conversation_id, user_id) do nothing;
  end loop;

  return v_id;
end; $$;

revoke all on function public.chat_create_group(uuid, text, jsonb)
  from public, anon;
grant execute on function public.chat_create_group(uuid, text, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- Adding somebody later, and leaving
-- ---------------------------------------------------------------------
create or replace function public.chat_add_participant(
  p_conversation_id uuid, p_user_id uuid, p_org_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_chat_participant(p_conversation_id) then
    raise exception 'You are not in this conversation' using errcode = '42501';
  end if;
  if (select is_direct from public.chat_conversations
       where id = p_conversation_id) then
    -- Silently turning a private exchange into a room somebody else can
    -- read is not a feature. Start a group instead.
    raise exception 'A direct conversation cannot take a third person'
      using errcode = '22023';
  end if;
  if not app.chat_enabled(p_org_id, p_user_id) then
    raise exception 'Chat is not switched on for that person'
      using errcode = '42501';
  end if;
  if not app.chat_can_join(p_conversation_id, p_org_id) then
    raise exception 'Their company is not linked to every company in '
      'this conversation' using errcode = '42501';
  end if;

  insert into public.chat_participants (conversation_id, user_id, org_id)
  values (p_conversation_id, p_user_id, p_org_id)
  on conflict (conversation_id, user_id) do nothing;
end; $$;

revoke all on function public.chat_add_participant(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.chat_add_participant(uuid, uuid, uuid)
  to authenticated;

-- Leaving is already allowed by the delete policy on
-- `chat_participants`; this is the same thing with a name, so the client
-- does not have to know that leaving is a delete.
create or replace function public.chat_leave(p_conversation_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if (select is_direct from public.chat_conversations
       where id = p_conversation_id) then
    raise exception 'A direct conversation cannot be left, only ignored'
      using errcode = '22023';
  end if;
  delete from public.chat_participants
   where conversation_id = p_conversation_id and user_id = auth.uid();
end; $$;

revoke all on function public.chat_leave(uuid) from public, anon;
grant execute on function public.chat_leave(uuid) to authenticated;

-- Who is in the room, with their company named. A group that crosses a
-- boundary is exactly where "who can hear this?" needs answering
-- without leaving the conversation.
create or replace function public.chat_members(p_conversation_id uuid)
returns table (
  user_id uuid,
  full_name text,
  avatar_url text,
  org_id uuid,
  org_name text,
  is_me boolean,
  state text
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select p.user_id,
         coalesce(pr.full_name, pr.email),
         pr.avatar_url,
         p.org_id,
         o.name,
         p.user_id = auth.uid(),
         case when pres.last_seen_at is null
                or pres.last_seen_at < now() - app.chat_presence_window()
              then 'offline' else pres.state::text end
    from public.chat_participants p
    join public.organizations o on o.id = p.org_id
    left join public.profiles pr on pr.id = p.user_id
    left join public.chat_presence pres on pres.user_id = p.user_id
   where p.conversation_id = p_conversation_id
     and app.is_chat_participant(p_conversation_id)
   order by (p.user_id = auth.uid()) desc, coalesce(pr.full_name, pr.email);
$$;

revoke all on function public.chat_members(uuid) from public, anon;
grant execute on function public.chat_members(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The list, able to count
-- ---------------------------------------------------------------------
drop function if exists public.chat_my_conversations(uuid);

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
  member_count integer,
  last_message text,
  last_message_at timestamptz,
  unread integer,
  other_state text,
  other_last_seen_at timestamptz,
  their_delivered_at timestamptz,
  their_read_at timestamptz,
  they_are_typing boolean
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select c.id,
         c.is_direct,
         c.title,
         other.user_id,
         coalesce(pr.full_name, pr.email),
         pr.avatar_url,
         other.org_id,
         org.name,
         -- For a group: does anybody in it belong to another company?
         -- That is the flag worth showing, and it is not the same
         -- question as "is the one other person elsewhere".
         everyone.company_count > 1,
         everyone.member_count,
         (select case
                   when m.kind = 'voice' then 'Voice note'
                   when m.kind = 'file'
                     then coalesce(nullif(btrim(m.body), ''), 'File')
                   else m.body end
            from public.chat_messages m
           where m.conversation_id = c.id and m.deleted_at is null
           order by m.created_at desc limit 1),
         c.last_message_at,
         (select count(*)::int from public.chat_messages m
           where m.conversation_id = c.id
             and m.sender_id <> auth.uid()
             and m.deleted_at is null
             and m.created_at > me.last_read_at),
         case when pres.last_seen_at is null
                or pres.last_seen_at < now() - app.chat_presence_window()
              then 'offline' else pres.state::text end,
         pres.last_seen_at,
         -- Aggregates, not the counterpart's own row: in a group,
         -- "delivered" means to everybody and "read" means by everybody.
         -- For a pair these are the same number they always were.
         everyone.delivered,
         everyone.read,
         everyone.typing
    from public.chat_participants me
    join public.chat_conversations c on c.id = me.conversation_id
    -- Everybody but me, rolled up once per conversation. This is what
    -- stopped a three-person group appearing in the list three times.
    join lateral (
      select count(*)::int + 1 as member_count,
             count(distinct p.org_id) filter (
               where p.org_id <> me.org_id) + 1 as company_count,
             min(p.last_delivered_at) as delivered,
             min(p.last_read_at) as read,
             bool_or(exists (select 1 from public.chat_typing t
                              where t.conversation_id = c.id
                                and t.user_id = p.user_id
                                and t.expires_at > now())) as typing
        from public.chat_participants p
       where p.conversation_id = c.id and p.user_id <> me.user_id
    ) everyone on true
    -- The counterpart, which only a direct conversation has.
    left join lateral (
      select p.user_id, p.org_id
        from public.chat_participants p
       where p.conversation_id = c.id and p.user_id <> me.user_id
         and c.is_direct
       limit 1
    ) other on true
    left join public.profiles pr on pr.id = other.user_id
    left join public.organizations org on org.id = other.org_id
    left join public.chat_presence pres on pres.user_id = other.user_id
   where me.user_id = auth.uid()
     and me.org_id = p_org_id
     and app.chat_enabled(p_org_id, auth.uid())
   order by c.last_message_at desc;
$$;

revoke all on function public.chat_my_conversations(uuid) from public, anon;
grant execute on function public.chat_my_conversations(uuid) to authenticated;
