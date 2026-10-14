-- =====================================================================
-- iAkauntan :: 0880 a conversation is changed by its functions
--
-- `0135` put every change to a chat conversation behind a function --
-- `chat_start_direct`, `chat_create_group`, `chat_add_participant`,
-- `chat_leave`, `chat_mark_read` and `chat_mark_delivered` -- and said
-- why: a policy cannot see the old row, so it cannot say "and this
-- column did not change". Its policies said the opposite. Any
-- participant could update the conversation, any column of it, and
-- anybody could update or delete their own participant row, any column
-- of it, under a comment that read "only ever to mark it read".
--
-- `chat_add_participant` refuses a third person on a direct
-- conversation by reading `is_direct`: "Silently turning a private
-- exchange into a room somebody else can read is not a feature."
--
-- Measured on 14 October 2026, locally, with the role `authenticated`:
-- one side of a direct conversation set `is_direct` false and then
-- added a colleague, who read the two people's history -- the other
-- side agreed to nothing. A participant rewrote their own row's
-- `org_id` to a company where chat is not switched on for them, past
-- `chat_can_join`. And a participant left a direct conversation by
-- deleting their row, which `chat_leave` refuses: "A direct
-- conversation cannot be left, only ignored."
--
-- Production held one conversation on 14 October: direct, two people.
--
-- Answered "only through its functions": insert, update and delete are
-- revoked from `authenticated` and `anon` on `chat_conversations`, and
-- update and delete on `chat_participants` (no policy ever admitted an
-- insert there; that is revoked too), and the policies that let them
-- in are dropped. Every writer is a definer: the six above,
-- `app.touch_conversation`, which moves `last_message_at` when a
-- message lands, and `demo_calling_pair`. The app writes neither table
-- directly. Both are read as before.
-- =====================================================================

revoke insert, update, delete on public.chat_conversations from authenticated, anon;
drop policy if exists chat_conversations_insert on public.chat_conversations;
drop policy if exists chat_conversations_update on public.chat_conversations;

revoke insert, update, delete on public.chat_participants from authenticated, anon;
drop policy if exists chat_participants_update on public.chat_participants;
drop policy if exists chat_participants_delete on public.chat_participants;
