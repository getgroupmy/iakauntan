-- =====================================================================
-- iAkauntan :: files and voice notes
--
-- ---------------------------------------------------------------------
-- Why chat cannot use the attachments bucket
--
-- The `attachments` bucket has been keyed `<org_id>/<entity>/<file>`
-- since 0010, and its policies read the first path segment as the tenant
-- boundary: you may read an object if you are a member of the company
-- whose id starts the name. That is exactly right for a receipt on a
-- claim and exactly wrong for a file sent to a supplier, whose whole
-- point is that somebody outside the company opens it.
--
-- Putting chat files there would mean either loosening a policy that
-- guards every invoice attachment in the system, or writing the same
-- object twice under two prefixes. So chat gets its own bucket, keyed by
-- conversation instead of by company:
--
--   chat/<conversation_id>/<uuid>-<file name>
--
-- and the policy asks the one question that actually decides it — are
-- you in this conversation? — through `app.is_chat_participant`, which
-- already re-checks that chat is still switched on for you. Switching
-- somebody off takes the files with the history.
--
-- ---------------------------------------------------------------------
-- A file is a message, not a decoration
--
-- `chat_messages.body` was `not null` with a check that it is not blank,
-- which is right for typing and wrong for sending a photograph with
-- nothing to say about it. Rather than allow every message to be blank,
-- messages gain a `kind`: text still has to say something, a file or a
-- voice note need not. The caption, when there is one, is the body — so
-- search and the conversation preview keep working without knowing
-- anything about attachments.
--
-- ---------------------------------------------------------------------
-- What is not here
--
-- Nothing deletes the stored object when a message is deleted. The rows
-- go — `chat_attachments` cascades from the message — but the file stays
-- in the bucket, unreachable, until something sweeps it. That is the
-- same behaviour the main attachments bucket has had since 0010 and it
-- is not made worse here; it is written down because "the row is gone"
-- and "the bytes are gone" are different claims and only the first is
-- true.
-- =====================================================================

create type app.chat_message_kind as enum ('text', 'file', 'voice');

alter table public.chat_messages
  add column kind app.chat_message_kind not null default 'text';

-- Text still has to say something; a file or a voice note may arrive
-- with no caption at all.
alter table public.chat_messages drop constraint chat_messages_body_check;
alter table public.chat_messages
  add constraint chat_messages_body_check
  check (kind <> 'text' or length(btrim(body)) > 0);

create table public.chat_attachments (
  id              uuid primary key default gen_random_uuid(),
  message_id      uuid not null references public.chat_messages(id)
                    on delete cascade,
  -- Denormalised from the message on purpose. Every policy on this table
  -- asks "may you see this conversation?", and carrying the answer's
  -- subject here keeps that a single lookup rather than a join back
  -- through a table whose own policy asks the same question again.
  conversation_id uuid not null references public.chat_conversations(id)
                    on delete cascade,
  file_name       text not null,
  storage_path    text not null,
  mime_type       text,
  file_size       bigint,
  -- Voice notes only. Recorded by the client because the server never
  -- sees the audio: it is uploaded straight to storage.
  duration_ms     integer check (duration_ms is null or duration_ms >= 0),
  created_at      timestamptz not null default now(),
  -- The bucket's policies key on the first path segment, so a row whose
  -- path does not start with its own conversation would be a row nobody
  -- can open. Refused here rather than discovered on a broken thumbnail.
  check (storage_path like conversation_id::text || '/%')
);

create index chat_attachments_message_idx
  on public.chat_attachments (message_id);

alter table public.chat_attachments enable row level security;

create policy chat_attachments_select on public.chat_attachments
  for select to authenticated
  using (app.is_chat_participant(conversation_id));

-- Only onto your own message, and only while you may still speak.
create policy chat_attachments_insert on public.chat_attachments
  for insert to authenticated
  with check (app.is_chat_participant(conversation_id)
              and exists (select 1 from public.chat_messages m
                           where m.id = message_id
                             and m.sender_id = auth.uid()
                             and m.conversation_id = chat_attachments.conversation_id));

grant select, insert on public.chat_attachments to authenticated;

-- ---------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat', 'chat', false, 26214400)
on conflict (id) do nothing;

create policy chat_files_read on storage.objects
  for select to authenticated
  using (bucket_id = 'chat'
         and app.is_chat_participant(
               nullif(split_part(name, '/', 1), '')::uuid));

create policy chat_files_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'chat'
              and app.is_chat_participant(
                    nullif(split_part(name, '/', 1), '')::uuid));

-- Your own uploads only. `owner` is set by storage to whoever uploaded,
-- so a participant cannot tidy away somebody else's file.
create policy chat_files_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'chat'
         and owner = auth.uid()
         and app.is_chat_participant(
               nullif(split_part(name, '/', 1), '')::uuid));

-- ---------------------------------------------------------------------
-- Readers
--
-- Dropped and recreated: `create or replace` cannot change the row type
-- a function returns, which is the mistake 0136 made and CI caught.
-- ---------------------------------------------------------------------
drop function if exists public.chat_thread(uuid, timestamptz, integer);

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
  kind text,
  created_at timestamptz,
  edited_at timestamptz,
  is_mine boolean,
  state text,
  -- One array rather than a second round trip per message. A message
  -- has none or a few; the client renders what is here.
  attachments jsonb
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
         m.body,
         m.kind::text,
         m.created_at, m.edited_at,
         m.sender_id = auth.uid(),
         case when m.sender_id <> auth.uid() then null
              when m.created_at <= o.read then 'read'
              when m.created_at <= o.delivered then 'delivered'
              else 'sent' end,
         coalesce(
           (select jsonb_agg(jsonb_build_object(
                     'id', a.id,
                     'file_name', a.file_name,
                     'storage_path', a.storage_path,
                     'mime_type', a.mime_type,
                     'file_size', a.file_size,
                     'duration_ms', a.duration_ms)
                   order by a.created_at)
              from public.chat_attachments a where a.message_id = m.id),
           '[]'::jsonb)
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

-- The conversation list's one-line preview. A photograph with no caption
-- would otherwise show as a blank line, which reads as a bug.
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
  select c.id, c.is_direct, c.title, o.user_id,
         coalesce(pr.full_name, pr.email), pr.avatar_url,
         o.org_id, org.name, o.org_id <> me.org_id,
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
           where m.conversation_id = c.id and m.sender_id <> auth.uid()
             and m.deleted_at is null and m.created_at > me.last_read_at),
         case when pres.last_seen_at is null
                or pres.last_seen_at < now() - app.chat_presence_window()
              then 'offline' else pres.state::text end,
         pres.last_seen_at,
         o.last_delivered_at, o.last_read_at,
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
   where me.user_id = auth.uid() and me.org_id = p_org_id
     and app.chat_enabled(p_org_id, auth.uid())
   order by c.last_message_at desc;
$$;

revoke all on function public.chat_my_conversations(uuid) from public, anon;
grant execute on function public.chat_my_conversations(uuid) to authenticated;
