-- =====================================================================
-- iAkauntan :: 0576 who is in the room
--
-- Eighth slice: the `chat_*` family, all twenty.
--
-- I called this one "ephemeral messaging" and meant it as a reason to
-- do it last. It is the right place in the order and the wrong reason.
-- Chat here crosses the boundary the whole rest of this system is
-- built on: two DIFFERENT COMPANIES talking to each other. Every
-- interesting decision in the family is about who is allowed in the
-- room, and they are careful in a way the word "chat" does not
-- suggest.
--
-- ---------------------------------------------------------------------
-- The rule the group functions are built on
--
-- A company is reachable only if every company already in the room has
-- agreed to a link with it -- `app.chat_can_join` checked against
-- everybody already added, so as a group grows EVERY PAIR in the room
-- has agreed. Not "the person who started it can vouch for anyone".
-- That is what stops a group being a way to put two companies who have
-- refused each other in the same conversation.
--
-- ---------------------------------------------------------------------
-- And the one about what is said
--
-- `chat_edit_message` will not let an administrator edit somebody
-- else's words. The body says why, and it is the kind of sentence
-- worth publishing rather than leaving in the source: there is no
-- version of this where somebody edits words another person is
-- recorded as having said.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Linking two companies
-- ---------------------------------------------------------------------

comment on function public.chat_request_link(uuid, uuid, text) is
  'Asks another company to allow chat between the two. Needs '
  '`can_admin` of YOUR OWN company -- one administrator cannot link two '
  'companies they do not both run. A rejected or revoked link may be '
  'asked for again, which is deliberately a different thing from '
  'pretending the first request never happened: the earlier answer '
  'stays on the record. Refuses a company linking to itself and one '
  'that does not exist.';

comment on function public.chat_decide_link(uuid, boolean) is
  'Answers a link request, approving or rejecting it. ONLY THE COMPANY '
  'THAT WAS ASKED MAY ANSWER -- the asking side cannot approve its own '
  'request. Refuses a link that is not pending, naming what it already '
  'is.';

comment on function public.chat_revoke_link(uuid) is
  'Ends a link between two companies. EITHER SIDE MAY REVOKE, because '
  'consent to be reachable is not something one party gets to hold the '
  'other to. Existing conversations stop being joinable; what was '
  'already said is not deleted.';

comment on function public.chat_set_access(uuid, uuid, boolean) is
  'Switches chat on or off for one person in one company. The person '
  'must be a member of that company. Note this is per company, not per '
  'account: somebody who works for two companies can have chat in one '
  'and not the other. Needs `can_admin`.';

-- ---------------------------------------------------------------------
-- Starting a conversation, and who can be in it
-- ---------------------------------------------------------------------

comment on function public.chat_start_direct(uuid, uuid, uuid) is
  'Opens or reuses the one-to-one conversation between two people, '
  'returning it. EXACTLY THOSE TWO AND NO THIRD -- calling again '
  'returns the same conversation rather than making another. Both '
  'people must have chat switched on in the company they are being '
  'addressed in, and the two companies must be linked. Refuses a '
  'conversation with yourself.';

comment on function public.chat_create_group(uuid, text, jsonb) is
  'Starts a named group and adds the members given. Each member''s '
  'company is checked against EVERYBODY ALREADY ADDED, which as the '
  'list grows means every pair in the room has agreed to a link -- not '
  'merely that the person starting it can reach each of them. That is '
  'what stops a group being a way to put two companies who have refused '
  'each other into one conversation. Everybody needs chat switched on, '
  'and a group needs a name and somebody in it.';

comment on function public.chat_add_participant(uuid, uuid, uuid) is
  'Adds somebody to a group. A DIRECT CONVERSATION CANNOT TAKE A THIRD '
  'PERSON: silently turning a private exchange into a room somebody '
  'else can read is not a feature, and the refusal says to start a '
  'group instead. The newcomer''s company must be linked to every '
  'company already in the room, and they must have chat switched on. '
  'You must be in the conversation yourself to add anybody to it.';

comment on function public.chat_leave(uuid) is
  'Leaves a group. A DIRECT CONVERSATION CANNOT BE LEFT, ONLY IGNORED '
  '-- there is no version of a two-person thread with one person in it. '
  'What was already said stays where it is.';

-- ---------------------------------------------------------------------
-- What was said
-- ---------------------------------------------------------------------

comment on function public.chat_edit_message(uuid, text) is
  'Edits your own message. YOUR OWN AND NOBODY ELSE''S -- not an '
  'administrator''s either, because there is no version of this where '
  'somebody edits words another person is recorded as having said. '
  'Refuses a deleted message, and refuses if your chat access has been '
  'withdrawn since: somebody switched off this morning does not get to '
  'spend the afternoon editing what they said with it.';

comment on function public.chat_delete_message(uuid) is
  'Takes back your own message. The body is EMPTIED, not hidden: any '
  'participant may select from `chat_messages` directly, so a body left '
  'in place behind a flag is a body still readable by the people it was '
  'taken back from. Attachment rows go with it. IDEMPOTENT -- deleting '
  'twice is what a double tap on a slow connection looks like, and it '
  'should not be an error.';

-- ---------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------

comment on function public.chat_start_call(uuid, text) is
  'Starts a voice or video call on a conversation, or RETURNS THE ONE '
  'ALREADY RUNNING: two people pressing the button at the same moment '
  'should end up in one call, not two. Anything still marked ringing '
  'from a previous attempt is past its deadline and never answered, and '
  'is closed here so the unique index does not refuse the new one.';

comment on function public.chat_join_call(uuid) is
  'Joins a call that is ringing or live. Refuses one that is over. '
  'Somebody added to the conversation after the call began may still '
  'join it -- membership of the conversation is the test, not having '
  'been there when it started.';

comment on function public.chat_leave_call(uuid) is
  'Leaves a call without ending it for anybody else. The call goes on '
  'as long as somebody is still in it.';

comment on function public.chat_end_call(uuid) is
  'Ends a call for everybody. ONLY WHOEVER STARTED IT MAY DO THIS -- '
  'anybody else leaves with `chat_leave_call` rather than hanging up on '
  'the room.';

comment on function public.chat_decline_call(uuid) is
  'Refuses a ringing call. IN A PAIR, ONE REFUSAL ENDS IT. IN A ROOM IT '
  'DOES NOT: the others are still talking, and hanging up on them '
  'because one person is busy would be a strange thing for software to '
  'do.';

-- ---------------------------------------------------------------------
-- Presence
--
-- The cheap, frequent calls. They are writes, so they are in the
-- surface and worth a line each; what matters about them is that none
-- of them is a claim anybody should read as evidence of anything.
-- ---------------------------------------------------------------------

comment on function public.chat_heartbeat(boolean) is
  'Says you are still here, and whether you have gone idle. Drives the '
  'online dot beside a name and nothing else -- it is not attendance, '
  'not activity monitoring, and nothing reads it as a record of when '
  'somebody was at their desk.';

comment on function public.chat_mark_read(uuid) is
  'Marks a conversation read up to now, which is what clears its unread '
  'count for you. Yours alone: it says nothing about whether anybody '
  'else has read it.';

comment on function public.chat_mark_delivered(uuid) is
  'Records that the messages in a conversation reached your device, '
  'which is the difference between the one tick and the two. Separate '
  'from read on purpose -- arriving on a phone is not somebody looking '
  'at it.';

comment on function public.chat_typing_ping(uuid, integer) is
  'Says you are typing, for a few seconds. Expires by itself, so a '
  'client that stops without saying so does not leave "typing…" on '
  'somebody else''s screen for ever. You must be in the conversation.';

comment on function public.chat_typing_stop(uuid) is
  'Says you have stopped typing, before the ping would have expired on '
  'its own -- what sending the message, or clearing the box, does.';
