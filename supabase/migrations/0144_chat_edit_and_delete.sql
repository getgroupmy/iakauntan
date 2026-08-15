-- =====================================================================
-- iAkauntan :: editing and deleting a message
--
-- The screen has rendered "· edited" beside a message since 0138 and
-- nothing has ever been able to set it. That is the small half of this.
--
-- ---------------------------------------------------------------------
-- The large half: history could be rewritten silently
--
-- 0135 gave `chat_messages` this policy, and it has been live since:
--
--   create policy chat_messages_update on public.chat_messages
--     for update to authenticated
--     using (sender_id = auth.uid())
--
-- Which says: you may update your own message. Every column of it, with
-- no time limit, and — this is the part that matters — without setting
-- `edited_at`, because a policy constrains *which rows* may be written
-- and not *what* is written to them.
--
-- So anybody with a session and the publishable key could rewrite the
-- text of a message they sent months ago, through the ordinary REST
-- API, and the reader would see the new words with no mark on them. The
-- badge the screen draws would stay dark, because the client that did
-- it never set the column that lights it.
--
-- No part of the application does this, which is why it has gone
-- unnoticed. The API is the application's surface whether or not the
-- app uses it. In a system whose chat carries payslips, bank details and
-- what was agreed about a payment, "he said the transfer was approved"
-- has to be a question about a record rather than about memory.
--
-- Same policy, same problem for `deleted_at`: a client could set it and
-- remove a message from the conversation entirely, at any age, leaving
-- nothing behind.
--
-- ---------------------------------------------------------------------
-- What replaces it
--
-- Two functions and no update policy at all. Both are SECURITY DEFINER,
-- both check that it is your own message, and neither takes the
-- bookkeeping on trust:
--
--   * editing is allowed for fifteen minutes and stamps `edited_at`
--     itself,
--   * deleting is allowed at any age, removes the text, and leaves the
--     row.
--
-- The asymmetry is deliberate. Deleting takes something out of the
-- record and says so where it stood. Editing replaces what the record
-- says, which is the operation worth bounding — after a quarter of an
-- hour, other people have read it and acted on it, and the honest way
-- to correct it is another message.
--
-- ---------------------------------------------------------------------
-- Why a deleted message stays in the thread
--
-- 0135 chose a soft delete and said why: "so the other side does not see
-- a message vanish out of the middle of a conversation they have already
-- read". Then `chat_thread` filtered on `deleted_at is null`, which
-- makes it vanish out of the middle of the conversation. The intention
-- was written down and the code did the opposite.
--
-- This is the code catching up with it. A deleted message keeps its
-- place and its author and says that it was deleted. What it does not
-- keep is the text: the select policy on `chat_messages` lets any
-- participant read the table directly, so a delete that only hid the
-- body would leave it there to be read by exactly the people it was
-- taken back from.
-- =====================================================================

-- Fifteen minutes. A function rather than a literal so the two places
-- that need it — the guard and any screen that wants to hide the menu —
-- cannot come to disagree.
create or replace function app.chat_edit_window()
returns interval language sql immutable as $$ select interval '15 minutes' $$;

-- 0138 relaxed this once already, to let a photograph be sent with no
-- caption. A deleted message needs the same room, for the same reason:
-- the constraint exists to stop an *empty message* being sent, and
-- neither of these is one.
alter table public.chat_messages drop constraint chat_messages_body_check;

alter table public.chat_messages
  add constraint chat_messages_body_check
  check (deleted_at is not null
         or kind <> 'text'
         or length(btrim(body)) > 0);

-- ---------------------------------------------------------------------
-- Editing
-- ---------------------------------------------------------------------
create or replace function public.chat_edit_message(
  p_message_id uuid, p_body text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_sender uuid;
  v_conversation uuid;
  v_created timestamptz;
  v_deleted timestamptz;
  v_kind text;
begin
  select m.sender_id, m.conversation_id, m.created_at, m.deleted_at,
         m.kind::text
    into v_sender, v_conversation, v_created, v_deleted, v_kind
    from public.chat_messages m where m.id = p_message_id;

  if v_sender is null then
    raise exception 'No such message';
  end if;

  -- Your own, and nobody else's. Not an administrator's either: there is
  -- no version of this where somebody edits words another person is
  -- recorded as having said.
  if v_sender <> auth.uid() then
    raise exception 'You can only edit your own messages'
      using errcode = '42501';
  end if;

  if v_deleted is not null then
    raise exception 'That message was deleted' using errcode = '42501';
  end if;

  -- Still switched on for you. Somebody whose chat access was withdrawn
  -- this morning does not get to spend the afternoon editing what they
  -- said with it.
  if not app.is_chat_participant(v_conversation) then
    raise exception 'You are not in that conversation' using errcode = '42501';
  end if;

  if v_created < now() - app.chat_edit_window() then
    raise exception
      'A message can only be edited for % after it is sent. Send another '
      'one instead — the first has been read by now.',
      app.chat_edit_window()
      using errcode = '42501';
  end if;

  if v_kind = 'text' and length(btrim(coalesce(p_body, ''))) = 0 then
    raise exception 'An edited message cannot be empty. Delete it instead.';
  end if;

  update public.chat_messages
     set body = btrim(coalesce(p_body, '')),
         -- Set here, not by the caller. This is the whole point: the
         -- mark that says the words changed is not something the client
         -- that changed them gets to decide about.
         edited_at = now()
   where id = p_message_id;
end; $$;

revoke all on function public.chat_edit_message(uuid, text) from public, anon;
grant execute on function public.chat_edit_message(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Deleting
-- ---------------------------------------------------------------------
create or replace function public.chat_delete_message(p_message_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_sender uuid;
  v_conversation uuid;
begin
  select m.sender_id, m.conversation_id into v_sender, v_conversation
    from public.chat_messages m where m.id = p_message_id;

  if v_sender is null then
    raise exception 'No such message';
  end if;
  if v_sender <> auth.uid() then
    raise exception 'You can only delete your own messages'
      using errcode = '42501';
  end if;
  if not app.is_chat_participant(v_conversation) then
    raise exception 'You are not in that conversation' using errcode = '42501';
  end if;

  -- Idempotent: deleting twice is what a double tap on a slow connection
  -- looks like, and it should not be an error.
  update public.chat_messages
     set deleted_at = coalesce(deleted_at, now()),
         -- Emptied, not hidden. Any participant may select from this
         -- table directly, so a body left in place is a body still
         -- readable by the people it was taken back from.
         body = ''
   where id = p_message_id;

  -- The attachment rows go with it. A signed URL is minted from
  -- `storage_path`, so removing the row is what actually makes the file
  -- unreachable through the application; the object itself is deleted
  -- best effort by the client, which is the only thing that can talk to
  -- storage.
  delete from public.chat_attachments where message_id = p_message_id;
end; $$;

revoke all on function public.chat_delete_message(uuid) from public, anon;
grant execute on function public.chat_delete_message(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- And the door those two replace
--
-- Dropped rather than narrowed. A policy cannot say "and you must stamp
-- `edited_at` while you do it", which is the only version of this that
-- would be safe, so there is no update policy at all — every edit goes
-- through the functions above.
-- ---------------------------------------------------------------------
drop policy if exists chat_messages_update on public.chat_messages;

revoke update on public.chat_messages from authenticated;

-- ---------------------------------------------------------------------
-- The thread, with the tombstone 0135 intended
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
  deleted boolean,
  is_mine boolean,
  state text,
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
         case when m.deleted_at is null then m.body else null end,
         m.kind::text,
         m.created_at, m.edited_at,
         m.deleted_at is not null,
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
     and app.is_chat_participant(p_conversation_id)
     and (p_before is null or m.created_at < p_before)
   order by m.created_at desc
   limit greatest(least(coalesce(p_limit, 50), 200), 1);
$$;

revoke all on function public.chat_thread(uuid, timestamptz, integer)
  from public, anon;
grant execute on function public.chat_thread(uuid, timestamptz, integer)
  to authenticated;
