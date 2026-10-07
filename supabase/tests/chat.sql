-- =====================================================================
-- iAkauntan :: chat
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/chat.sql
--
-- Chat is the only thing in this schema that crosses the company
-- boundary on purpose. Everything else answers "are you a member of
-- *this* organization?" and refuses the rest; chat says yes, sometimes,
-- to a named other company, for named people, after somebody with the
-- authority to agree has agreed. So the permission model is the feature,
-- and this file is mostly about what must *not* happen.
--
-- Three gates, all of which have to open:
--
--   the company has the module          org_modules
--   the person is switched on for it    chat_access
--   the two companies are linked        chat_links   (same company: no)
--
-- Every refusal below is paired with the thing that must still work.
-- An assertion that only checks "was this refused?" passes for any
-- reason a statement can fail — including a typo in the test, a missing
-- fixture, or a not-null violation on an unrelated column. That is not a
-- hypothetical: writing this feature, exactly that produced a confident
-- "refused, as it should be" from a probe that had never reached the
-- code it claimed to be testing.
--
-- Everything that touches a policy runs as `authenticated`: the
-- connection is a superuser and a superuser bypasses row level security.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A company with the chat module on. The module row may already exist —
-- a new organization is given one per platform module — so this forces
-- the value rather than assuming the shape of that seeding.
create or replace function pg_temp.chat_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v_org;

  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'chat', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end; $$;

-- ---------------------------------------------------------------------
-- The three gates
-- ---------------------------------------------------------------------
do $$
declare
  v_alice uuid := pg_temp.another_user('alice@chat.test');
  v_amir  uuid := pg_temp.another_user('amir@chat.test');
  v_bina  uuid := pg_temp.another_user('bina@chat.test');
  v_a uuid; v_b uuid; v_link uuid; v_conv uuid;
  v_ok boolean; v_n int; v_role text; v_state text;
begin
  v_a := pg_temp.chat_org('Chat A Sdn Bhd', v_alice);
  v_b := pg_temp.chat_org('Chat B Sdn Bhd', v_bina);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_amir, 'accountant', 'active', now());

  -- Something private in B, for the assertion further down that a chat
  -- link is not a key to the other company's books.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_b, 'C-SECRET', 'Pelanggan Sulit', 'customer');

  perform pg_temp.sign_in_as(v_alice);

  -- Gate 1 open, gate 2 shut. Buying chat for a company does not put
  -- anybody in it into a conversation.
  perform pg_temp.check_true('a company with the module still has nobody on it',
    not app.chat_enabled(v_a, v_alice));
  perform pg_temp.check_eq('so there is nobody to message',
    (select count(*) from public.chat_directory(v_a)), 0);

  -- Gate 2, opened one person at a time by an administrator.
  perform public.chat_set_access(v_a, v_alice, true);
  perform public.chat_set_access(v_a, v_amir, true);
  perform pg_temp.check_true('switched on, she may use chat',
    app.chat_enabled(v_a, v_alice));
  perform pg_temp.check_eq('and sees the colleague who is also switched on',
    (select count(*) from public.chat_directory(v_a)), 1);

  -- Gate 3. Bina is switched on at her own company, and that is not
  -- enough on its own.
  perform pg_temp.sign_in_as(v_bina);
  perform public.chat_set_access(v_b, v_bina, true);

  perform pg_temp.sign_in_as(v_alice);
  perform pg_temp.check_eq('an unlinked company is not in the directory',
    (select count(*) from public.chat_directory(v_a)), 1);

  begin
    perform public.chat_start_direct(v_a, v_bina, v_b);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  -- A caught exception rolls back to a savepoint, and `set_config(...,
  -- true)` goes with it. Sign in again or every later assertion is made
  -- by nobody.
  perform pg_temp.sign_in_as(v_alice);
  perform pg_temp.check_true('and cannot be messaged', not v_ok);

  -- ---------------------------------------------------------------
  -- Nobody approves their own request
  -- ---------------------------------------------------------------
  v_link := public.chat_request_link(v_a, v_b, 'We supply them');

  begin
    perform public.chat_decide_link(v_link, true);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_alice);
  perform pg_temp.check_true('the company that asked cannot answer', not v_ok);
  perform pg_temp.check_true('so they are still not linked',
    not app.chat_orgs_linked(v_a, v_b));

  -- The control: the company that was *asked* can.
  perform pg_temp.sign_in_as(v_bina);
  perform public.chat_decide_link(v_link, true);
  perform pg_temp.check_true('once the other side accepts, they are linked',
    app.chat_orgs_linked(v_a, v_b));

  perform pg_temp.sign_in_as(v_alice);
  perform pg_temp.check_eq('and the directory spans both companies',
    (select count(*) from public.chat_directory(v_a)), 2);

  -- ---------------------------------------------------------------
  -- Sent, delivered, read
  -- ---------------------------------------------------------------
  v_conv := public.chat_start_direct(v_a, v_bina, v_b);
  perform pg_temp.check_true('opening the same person again finds the thread',
    public.chat_start_direct(v_a, v_bina, v_b) = v_conv);

  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_alice, v_a, 'Selamat pagi');

  select state into v_state from public.chat_thread(v_conv) limit 1;
  perform pg_temp.check_true('a message with nobody at the other end is sent',
    v_state = 'sent');

  perform pg_temp.sign_in_as(v_bina);
  perform public.chat_typing_ping(v_conv, 30);
  perform public.chat_mark_delivered(v_conv);

  perform pg_temp.sign_in_as(v_alice);
  select state into v_state from public.chat_thread(v_conv) limit 1;
  perform pg_temp.check_true('once it reaches her device, delivered',
    v_state = 'delivered');
  perform pg_temp.check_eq('and she is shown as typing',
    (select count(*) from public.chat_who_is_typing(v_conv)), 1);

  perform pg_temp.sign_in_as(v_bina);
  perform public.chat_heartbeat(false);
  perform public.chat_mark_read(v_conv);
  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_bina, v_b, 'Pagi!');

  perform pg_temp.sign_in_as(v_alice);
  select state into v_state from public.chat_thread(v_conv)
   where is_mine limit 1;
  perform pg_temp.check_true('once she opens it, read', v_state = 'read');
  perform pg_temp.check_eq('and sending cleared her typing flag',
    (select count(*) from public.chat_who_is_typing(v_conv)), 0);

  -- Putting the phone down without sending.
  --
  -- `chat_typing_stop` clears the caller's own row and nobody else's,
  -- which is the whole of it and also the only way it can be wrong: a
  -- delete that forgot whose row it was would let one person switch off
  -- another's indicator, or clear the room every time anybody stopped
  -- typing.
  perform pg_temp.sign_in_as(v_bina);
  perform public.chat_typing_ping(v_conv, 30);
  perform pg_temp.sign_in_as(v_alice);
  perform pg_temp.check_eq('she starts typing again',
    (select count(*) from public.chat_who_is_typing(v_conv)), 1);

  perform public.chat_typing_stop(v_conv);
  perform pg_temp.check_eq('somebody else stopping does not clear hers',
    (select count(*) from public.chat_who_is_typing(v_conv)), 1);

  perform pg_temp.sign_in_as(v_bina);
  perform public.chat_typing_stop(v_conv);
  perform pg_temp.sign_in_as(v_alice);
  perform pg_temp.check_eq('and stopping her own does',
    (select count(*) from public.chat_who_is_typing(v_conv)), 0);

  select other_state into v_state
    from public.chat_my_conversations(v_a) where conversation_id = v_conv;
  perform pg_temp.check_true('a recent heartbeat reads as online',
    v_state = 'online');

  -- ---------------------------------------------------------------
  -- What the link does not open
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_amir);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_n
      from public.chat_messages where conversation_id = v_conv;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq(
    'a colleague outside the conversation sees none of it', v_n, 0);

  -- The one that matters most: agreeing to be talked to is not agreeing
  -- to be read.
  begin
    set local role authenticated;
    select count(*) into v_n from public.contacts where org_id = v_b;
  end;
  reset role;
  perform pg_temp.check_eq(
    'and a chat link is not a key to the other company''s books', v_n, 0);

  -- The control for both: the person it was actually sent to sees it.
  perform pg_temp.sign_in_as(v_bina);
  begin
    set local role authenticated;
    select count(*) into v_n
      from public.chat_messages where conversation_id = v_conv;
  end;
  reset role;
  perform pg_temp.check_eq('while the other party sees the conversation',
    v_n, 2);

  -- ---------------------------------------------------------------
  -- Switching somebody off takes the history, not just the door
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_alice);
  perform public.chat_set_access(v_a, v_alice, false);
  begin
    set local role authenticated;
    select count(*) into v_n
      from public.chat_messages where conversation_id = v_conv;
  end;
  reset role;
  perform pg_temp.check_eq('switched off, she can no longer read it', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- Files and voice notes
--
-- The bucket is keyed by conversation rather than by company, because a
-- file sent to a supplier is opened by somebody who is not a member of
-- the company that sent it — which is the one thing the `attachments`
-- bucket, keyed `<org_id>/…` since 0010, cannot express.
-- ---------------------------------------------------------------------
do $$
declare
  v_al uuid := pg_temp.another_user('al@file.test');
  v_bi uuid := pg_temp.another_user('bi@file.test');
  v_out uuid := pg_temp.another_user('out@file.test');
  v_a uuid; v_b uuid; v_link uuid; v_conv uuid; v_msg uuid;
  v_n int; v_ok boolean; v_role text; v_att jsonb;
begin
  v_a := pg_temp.chat_org('Fail A Sdn Bhd', v_al);
  v_b := pg_temp.chat_org('Fail B Sdn Bhd', v_bi);
  -- A colleague of the sender, switched on for chat, who is simply not
  -- in this conversation. The control that makes the last check mean
  -- something.
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_out, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_al);
  perform public.chat_set_access(v_a, v_al, true);
  perform public.chat_set_access(v_a, v_out, true);
  perform pg_temp.sign_in_as(v_bi);
  perform public.chat_set_access(v_b, v_bi, true);
  perform pg_temp.sign_in_as(v_al);
  v_link := public.chat_request_link(v_a, v_b, null);
  perform pg_temp.sign_in_as(v_bi);
  perform public.chat_decide_link(v_link, true);
  perform pg_temp.sign_in_as(v_al);
  v_conv := public.chat_start_direct(v_a, v_bi, v_b);

  -- A voice note carries no caption, which the original check refused.
  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body, kind)
  values (v_conv, v_al, v_a, '', 'voice') returning id into v_msg;
  insert into public.chat_attachments
    (message_id, conversation_id, file_name, storage_path, mime_type,
     file_size, duration_ms)
  values (v_msg, v_conv, 'note.m4a', v_conv::text || '/abc-note.m4a',
          'audio/mp4', 9100, 4200);

  -- And the relaxation is narrow: a text message that says nothing is
  -- still refused.
  begin
    insert into public.chat_messages
      (conversation_id, sender_id, sender_org_id, body, kind)
    values (v_conv, v_al, v_a, '   ', 'text');
    v_ok := true;
  exception when sqlstate '23514' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_al);
  perform pg_temp.check_true('an empty text message is still refused', not v_ok);

  -- A row whose path does not start with its own conversation would be a
  -- file nobody could open, because the bucket policy reads that segment.
  begin
    insert into public.chat_attachments
      (message_id, conversation_id, file_name, storage_path)
    values (v_msg, v_conv, 'x.pdf', gen_random_uuid()::text || '/x.pdf');
    v_ok := true;
  exception when sqlstate '23514' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_al);
  perform pg_temp.check_true('a path outside its own conversation is refused',
    not v_ok);

  select attachments into v_att from public.chat_thread(v_conv) limit 1;
  perform pg_temp.check_eq('the thread carries the attachment',
    jsonb_array_length(v_att), 1);
  perform pg_temp.check_true('with the duration the client recorded',
    (v_att -> 0 ->> 'duration_ms') = '4200');
  perform pg_temp.check_true('and the message reads as a voice note',
    (select kind from public.chat_thread(v_conv) limit 1) = 'voice');

  -- A photograph with no caption would otherwise show as a blank line in
  -- the list, which reads as a bug rather than as a picture.
  perform pg_temp.check_true('the conversation list names it',
    (select last_message from public.chat_my_conversations(v_a)
      where conversation_id = v_conv) = 'Voice note');

  perform pg_temp.sign_in_as(v_bi);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_n
      from public.chat_attachments where message_id = v_msg;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('the other company can reach the file', v_n, 1);

  perform pg_temp.sign_in_as(v_out);
  begin
    set local role authenticated;
    select count(*) into v_n
      from public.chat_attachments where message_id = v_msg;
  end;
  reset role;
  perform pg_temp.check_eq(
    'while a colleague outside the conversation cannot', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- A link takes no writes from the client
--
-- This is what 0135 settled on after two attempts at a policy. A
-- policy's `with check` sees the new row and cannot see the old one, so
-- "the side that asked may withdraw while pending" also let that side
-- write `status = 'approved'` — and pinning the allowed statuses did not
-- help either, because the new row can move `requested_by_org` and then
-- the test for "am I the side that was asked?" reads what the attacker
-- just wrote. There is no way to say "and this column did not change" in
-- a policy. So the table is readable and nothing more.
-- ---------------------------------------------------------------------
do $$
declare
  v_x uuid := pg_temp.another_user('x@chatlink.test');
  v_y uuid := pg_temp.another_user('y@chatlink.test');
  v_a uuid; v_b uuid; v_link uuid; v_ok boolean; v_n int; v_role text;
begin
  v_a := pg_temp.chat_org('Link X Sdn Bhd', v_x);
  v_b := pg_temp.chat_org('Link Y Sdn Bhd', v_y);

  perform pg_temp.sign_in_as(v_x);
  v_link := public.chat_request_link(v_a, v_b, null);

  -- Asserted on the outcome, not on the mechanism, and that distinction
  -- is the whole reason this reads oddly. An UPDATE against a table with
  -- row level security on and no UPDATE policy does not raise: it
  -- matches no rows and reports success having changed nothing. The
  -- first draft of this test asserted "the statement was refused" and
  -- failed — against a database where the link was, correctly, still
  -- pending. What matters is the status, not how Postgres declined.
  begin
    set local role authenticated;
    v_role := current_user;
    update public.chat_links set status = 'approved' where id = v_link;
  exception when others then null;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_x);
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'a company cannot approve its own request by writing the row',
    (select status from public.chat_links where id = v_link) = 'pending');

  -- An INSERT does raise, because there is a `with check` to fail
  -- against — but the assertion is still the outcome: no approved link
  -- exists between these two companies however the insert ended.
  begin
    set local role authenticated;
    insert into public.chat_links (org_a, org_b, requested_by_org, status)
    values (least(v_a, v_b), greatest(v_a, v_b), v_a, 'approved');
  exception when others then null;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_x);
  perform pg_temp.check_true('nor conjure an approved one',
    not app.chat_orgs_linked(v_a, v_b));

  -- Two controls, because "the write did nothing" is also what an inert
  -- fixture looks like. Reading is allowed, and the proper route still
  -- approves — so the refusals above are the absent write policies and
  -- not a table nobody can reach or a link that was never really there.
  begin
    set local role authenticated;
    select count(*) into v_n from public.chat_links where id = v_link;
  end;
  reset role;
  perform pg_temp.check_eq('while both sides can see the request', v_n, 1);

  perform pg_temp.sign_in_as(v_y);
  perform public.chat_decide_link(v_link, true);
  perform pg_temp.check_true('and the company that was asked can approve it',
    app.chat_orgs_linked(v_a, v_b));
end $$;


-- ---------------------------------------------------------------------
-- More than two people
--
-- The rule groups introduce, and the reason it is not the obvious one.
-- A is linked to B and A is linked to C, but B and C are not linked to
-- each other. If "may I add somebody?" were answered against the
-- adder's company, A could drop C into a room with B and C would read
-- everything B says — B never agreed to talk to C and is never asked.
-- That is how a supplier and a competitor end up in one thread.
--
-- So: to join, your company must be linked to *every* company already
-- in the room. The control is the same scenario once B and C do agree.
-- ---------------------------------------------------------------------
create or replace function pg_temp.chat_link(
  p_a uuid, p_ua uuid, p_b uuid, p_ub uuid)
returns void language plpgsql as $$
declare v_link uuid;
begin
  perform pg_temp.sign_in_as(p_ua);
  v_link := public.chat_request_link(p_a, p_b, null);
  perform pg_temp.sign_in_as(p_ub);
  perform public.chat_decide_link(v_link, true);
end; $$;

do $$
declare
  v_ua uuid := pg_temp.another_user('ua@group.test');
  v_ua2 uuid := pg_temp.another_user('ua2@group.test');
  v_ub uuid := pg_temp.another_user('ub@group.test');
  v_uc uuid := pg_temp.another_user('uc@group.test');
  v_a uuid; v_b uuid; v_c uuid; v_grp uuid; v_dm uuid;
  v_ok boolean; v_n int; v_role text;
begin
  v_a := pg_temp.chat_org('Group A Sdn Bhd', v_ua);
  v_b := pg_temp.chat_org('Group B Sdn Bhd', v_ub);
  v_c := pg_temp.chat_org('Group C Sdn Bhd', v_uc);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_ua2, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_ua);
  perform public.chat_set_access(v_a, v_ua, true);
  perform public.chat_set_access(v_a, v_ua2, true);
  perform pg_temp.sign_in_as(v_ub);
  perform public.chat_set_access(v_b, v_ub, true);
  perform pg_temp.sign_in_as(v_uc);
  perform public.chat_set_access(v_c, v_uc, true);

  perform pg_temp.chat_link(v_a, v_ua, v_b, v_ub);
  perform pg_temp.chat_link(v_a, v_ua, v_c, v_uc);

  perform pg_temp.sign_in_as(v_ua);
  v_grp := public.chat_create_group(v_a, 'Projek Baru',
    jsonb_build_array(
      jsonb_build_object('user_id', v_ua2, 'org_id', v_a),
      jsonb_build_object('user_id', v_ub,  'org_id', v_b)));
  perform pg_temp.check_eq('a group holds everybody put in it',
    (select count(*) from public.chat_participants
      where conversation_id = v_grp), 3);

  begin
    perform public.chat_add_participant(v_grp, v_uc, v_c);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_ua);
  perform pg_temp.check_true(
    'a company linked to the adder but not to everybody is refused',
    not v_ok);
  perform pg_temp.check_eq('so the room is unchanged',
    (select count(*) from public.chat_participants
      where conversation_id = v_grp), 3);

  -- The control: the same person, once their company has agreed with
  -- everybody in the room.
  perform pg_temp.chat_link(v_b, v_ub, v_c, v_uc);
  perform pg_temp.sign_in_as(v_ua);
  perform public.chat_add_participant(v_grp, v_uc, v_c);
  perform pg_temp.check_eq('and admitted once every pair has agreed',
    (select count(*) from public.chat_participants
      where conversation_id = v_grp), 4);

  -- The list bug groups would otherwise have: a join on "the other
  -- participant" returns one row per other person.
  perform pg_temp.check_eq('the group appears once in the list',
    (select count(*) from public.chat_my_conversations(v_a)
      where conversation_id = v_grp), 1);
  perform pg_temp.check_eq('counted correctly',
    (select member_count from public.chat_my_conversations(v_a)
      where conversation_id = v_grp), 4);
  perform pg_temp.check_true('and flagged as crossing companies',
    (select is_cross_company from public.chat_my_conversations(v_a)
      where conversation_id = v_grp));
  perform pg_temp.check_eq('everybody is listed with their company',
    (select count(*) from public.chat_members(v_grp)), 4);

  -- In a room, "read" means read by everybody, not by somebody.
  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body)
  values (v_grp, v_ua, v_a, 'Pagi semua');
  perform pg_temp.sign_in_as(v_ub);
  perform public.chat_mark_read(v_grp);
  perform pg_temp.sign_in_as(v_ua);
  perform pg_temp.check_true('one reader is not everybody',
    (select state from public.chat_thread(v_grp) where is_mine limit 1)
      = 'sent');

  perform pg_temp.sign_in_as(v_ua2);
  perform public.chat_mark_read(v_grp);
  perform pg_temp.sign_in_as(v_uc);
  perform public.chat_mark_read(v_grp);
  perform pg_temp.sign_in_as(v_ua);
  perform pg_temp.check_true('once all of them have, it reads as read',
    (select state from public.chat_thread(v_grp) where is_mine limit 1)
      = 'read');

  -- A private exchange cannot quietly become a room.
  v_dm := public.chat_start_direct(v_a, v_ub, v_b);
  begin
    perform public.chat_add_participant(v_dm, v_ua2, v_a);
    v_ok := true;
  exception when sqlstate '22023' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_ua);
  perform pg_temp.check_true('a direct conversation takes no third person',
    not v_ok);

  -- Leaving takes the room away, the same way being switched off does.
  perform pg_temp.sign_in_as(v_uc);
  perform public.chat_leave(v_grp);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_n
      from public.chat_messages where conversation_id = v_grp;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('somebody who leaves can no longer read it',
    v_n, 0);
  perform pg_temp.sign_in_as(v_ua);
  perform pg_temp.check_eq('and is out of the room',
    (select count(*) from public.chat_participants
      where conversation_id = v_grp), 3);
end $$;


-- ---------------------------------------------------------------------
-- Calls, or the half of a call that is state
--
-- Nothing here places a call: the media needs a TURN server and, past
-- about four people, a media server, and neither exists yet. This is
-- what rings a phone and records what happened.
--
-- The assertion that earned its keep is the third one. A room of three,
-- one person answers, and the other two phones must keep ringing —
-- asking for calls whose *status* is still `ringing` is indistinguishable
-- from correct in a pair and silently wrong in a group, because the
-- status changes the moment anybody picks up.
-- ---------------------------------------------------------------------
do $$
declare
  v_u1 uuid := pg_temp.another_user('c1@call.test');
  v_u2 uuid := pg_temp.another_user('c2@call.test');
  v_u3 uuid := pg_temp.another_user('c3@call.test');
  v_out uuid := pg_temp.another_user('cx@call.test');
  v_a uuid; v_grp uuid; v_call uuid; v_ok boolean; v_n int; v_role text;
begin
  v_a := pg_temp.chat_org('Call Co Sdn Bhd', v_u1);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_u2, 'accountant', 'active', now()),
         (v_a, v_u3, 'accountant', 'active', now()),
         (v_a, v_out, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_set_access(v_a, v_u1, true);
  perform public.chat_set_access(v_a, v_u2, true);
  perform public.chat_set_access(v_a, v_u3, true);
  perform public.chat_set_access(v_a, v_out, true);
  v_grp := public.chat_create_group(v_a, 'Panggilan',
    jsonb_build_array(jsonb_build_object('user_id', v_u2, 'org_id', v_a),
                      jsonb_build_object('user_id', v_u3, 'org_id', v_a)));

  v_call := public.chat_start_call(v_grp, 'video');
  perform pg_temp.check_true('a new call is ringing',
    (select status from public.chat_calls where id = v_call) = 'ringing');
  perform pg_temp.check_eq('everybody in the room is rung',
    (select count(*) from public.chat_call_participants
      where call_id = v_call), 3);
  perform pg_temp.check_true('and the caller is already in it',
    (select state from public.chat_call_participants
      where call_id = v_call and user_id = v_u1) = 'joined');
  perform pg_temp.check_true('with a room name for the media server',
    (select length(room_name) from public.chat_calls where id = v_call) = 32);

  -- Two people pressing at the same moment is one call, not two.
  perform pg_temp.sign_in_as(v_u2);
  perform pg_temp.check_true('pressing call again joins the same one',
    public.chat_start_call(v_grp, 'video') = v_call);
  perform pg_temp.check_true('and answering makes it live',
    (select status from public.chat_calls where id = v_call) = 'live');

  -- The one that matters in a room.
  perform pg_temp.sign_in_as(v_u3);
  perform pg_temp.check_eq(
    'a phone still rings after somebody else has answered',
    (select count(*) from public.chat_incoming_calls()), 1);
  perform pg_temp.sign_in_as(v_u2);
  perform pg_temp.check_eq('while whoever answered is not rung again',
    (select count(*) from public.chat_incoming_calls()), 0);

  -- A call reaches no further than the conversation it came from.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform public.chat_join_call(v_call);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_out);
  perform pg_temp.check_true('somebody outside the conversation cannot join',
    not v_ok);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_n from public.chat_calls where id = v_call;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('nor even see it', v_n, 0);

  -- The control.
  perform pg_temp.sign_in_as(v_u3);
  begin
    set local role authenticated;
    select count(*) into v_n from public.chat_calls where id = v_call;
  end;
  reset role;
  perform pg_temp.check_eq('while somebody in the room does', v_n, 1);

  -- One refusal does not hang up on everybody else.
  perform public.chat_decline_call(v_call);
  perform pg_temp.check_true('one refusal does not end a group call',
    (select status from public.chat_calls where id = v_call) = 'live');

  -- Only whoever started it may end it for everybody.
  perform pg_temp.sign_in_as(v_u2);
  begin
    perform public.chat_end_call(v_call);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_u2);
  perform pg_temp.check_true('somebody else cannot end it for everybody',
    not v_ok);

  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_end_call(v_call);
  perform pg_temp.check_true('the caller can', 
    (select status from public.chat_calls where id = v_call) = 'ended');
  perform pg_temp.check_eq('and nobody is left in it',
    (select count(*) from public.chat_call_participants
      where call_id = v_call and state in ('joined', 'ringing')), 0);
  perform pg_temp.check_eq('so nothing is active in the thread',
    (select count(*) from public.chat_active_call(v_grp)), 0);

  -- The unique index only bites while a call is open.
  v_call := public.chat_start_call(v_grp, 'voice');
  perform pg_temp.check_true('a fresh call may start afterwards',
    (select status from public.chat_calls where id = v_call) = 'ringing');

  -- Nobody answers. The deadline decides, not a timer that may not run.
  update public.chat_calls set ringing_until = now() - interval '1 second'
   where id = v_call;
  perform pg_temp.check_eq('a call past its deadline is not ringing',
    (select count(*) from public.chat_active_call(v_grp)), 0);
  perform pg_temp.sign_in_as(v_u3);
  perform pg_temp.check_eq('and no phone is ringing',
    (select count(*) from public.chat_incoming_calls()), 0);
  perform public.chat_expire_calls();
  perform pg_temp.check_true('the history says missed, not ringing',
    (select status from public.chat_calls where id = v_call) = 'missed');

  -- ------------------------------------------------------------------
  -- Hanging up
  --
  -- `chat_leave_call` was called by nothing, and it is the only one of
  -- these that decides something on its own: the last person out ends
  -- the call. Wrong in one direction it drops everybody when the first
  -- person hangs up; wrong in the other it leaves a call live in every
  -- window after the room is empty, with the next call refused by the
  -- unique index because this one never closed.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_u1);
  v_call := public.chat_start_call(v_grp, 'voice');
  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_join_call(v_call);
  perform pg_temp.sign_in_as(v_u3);
  perform public.chat_join_call(v_call);

  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_leave_call(v_call);
  perform pg_temp.check_true('one person hanging up leaves the call running',
    (select status from public.chat_calls where id = v_call) = 'live');
  perform pg_temp.check_true('and only that person is out of it',
    (select state from public.chat_call_participants
      where call_id = v_call and user_id = v_u2)::text = 'left');
  perform pg_temp.check_true('with a time against it',
    (select left_at is not null from public.chat_call_participants
      where call_id = v_call and user_id = v_u2));
  perform pg_temp.check_eq('the others are still in',
    (select count(*) from public.chat_call_participants
      where call_id = v_call and state in ('joined', 'ringing')), 2);

  perform pg_temp.sign_in_as(v_u3);
  perform public.chat_leave_call(v_call);
  perform pg_temp.check_true('still running while anybody is left',
    (select status from public.chat_calls where id = v_call) = 'live');

  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_leave_call(v_call);
  perform pg_temp.check_true('the last one out ends it',
    (select status from public.chat_calls where id = v_call) = 'ended');
  perform pg_temp.check_eq('and it says why', 
    (select end_reason from public.chat_calls where id = v_call),
    'everybody left');
  perform pg_temp.check_eq('so nothing is live in the thread',
    (select count(*) from public.chat_active_call(v_grp)), 0);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- The helpers named inside policies must be executable by
-- `authenticated`: a policy expression is evaluated as whoever is
-- running the query, and revoking one of these makes every read of every
-- chat table fail with "permission denied for function" — from a chat
-- window that simply never opens, naming nothing. 0135 shipped exactly
-- that and only a probe running as the right role caught it.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the participant test is callable by a member',
    has_function_privilege('authenticated',
      'app.is_chat_participant(uuid, uuid)', 'execute'));
  perform pg_temp.check_true('so is the access test',
    has_function_privilege('authenticated',
      'app.chat_enabled(uuid, uuid)', 'execute'));
  perform pg_temp.check_true('and the one that says which hat you wear',
    has_function_privilege('authenticated',
      'app.chat_participant_org(uuid, uuid)', 'execute'));

  -- This one is never named in a policy, so it stays shut.
  perform pg_temp.check_true('while the link test stays internal',
    not has_function_privilege('authenticated',
      'app.chat_orgs_linked(uuid, uuid)', 'execute'));

  perform pg_temp.check_true('none of it is open to anon',
    not has_function_privilege('anon',
      'public.chat_start_direct(uuid, uuid, uuid)', 'execute'));
  perform pg_temp.check_true('including the administration',
    not has_function_privilege('anon',
      'public.chat_set_access(uuid, uuid, boolean)', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- A trigger function is nobody's to call
--
-- 0120 closed this once on the claims trigger; 0135 and 0136 reopened it
-- twice by writing new trigger functions and forgetting that PostgreSQL
-- makes a new function executable by PUBLIC. 0137 revoked the class.
-- This asserts the class, so the next one is caught here rather than by
-- the allowlist in statutory.sql, which says only that *something* is
-- exposed.
-- ---------------------------------------------------------------------
do $$
declare v_open text;
begin
  select string_agg(p.proname, ', ') into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.prosecdef
     and p.prorettype = 'trigger'::regtype
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v_open is not null then
    raise exception 'FAIL trigger functions are callable: %', v_open;
  end if;
  raise notice 'ok   no trigger function is callable from the API';
end $$;

-- ---------------------------------------------------------------------
-- Editing and deleting a message (0144)
--
-- The assertion this file exists for is the first one: until 0144 a
-- client could rewrite the text of their own message through the
-- ordinary REST API, at any age, without setting `edited_at` — so the
-- reader saw new words with no mark on them. It is checked as
-- `authenticated` and checks that it was, because the connection here is
-- a superuser and a superuser is refused by nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_ana uuid := pg_temp.another_user('ana@edit.test');
  v_ben uuid := pg_temp.another_user('ben@edit.test');
  v_org uuid; v_conv uuid; v_msg uuid; v_other uuid; v_att uuid;
  v_refused boolean; v_body text; v_edited timestamptz; v_deleted boolean;
  v_role text; v_n int;
begin
  v_org := pg_temp.chat_org('Edit Test Sdn Bhd', v_ana);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_ben, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_ana);
  perform public.chat_set_access(v_org, v_ana, true);
  perform public.chat_set_access(v_org, v_ben, true);
  v_conv := public.chat_start_direct(v_org, v_ben, v_org);

  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_ana, v_org, 'the transfer is approved') returning id into v_msg;
  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_ben, v_org, 'noted') returning id into v_other;

  v_refused := false;
  begin
    set local role authenticated;
    v_role := current_user;
    update public.chat_messages set body = 'the transfer is cancelled'
     where id = v_msg;
  exception when insufficient_privilege then v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_ana);

  perform pg_temp.check_true('the raw update ran as a client, not as a superuser',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'a client cannot rewrite a message through the table — the whole '
    'reason this migration exists', v_refused);
  select body into v_body from public.chat_messages where id = v_msg;
  perform pg_temp.check_true('and the record still says what was said',
    v_body = 'the transfer is approved');

  -- The control for that refusal. Without it the assertion above would
  -- pass for a database in which nothing can be written at all.
  perform public.chat_edit_message(v_msg, '  the transfer is approved today  ');
  select body, edited_at into v_body, v_edited
    from public.chat_messages where id = v_msg;
  perform pg_temp.check_true('editing through the function works',
    v_body = 'the transfer is approved today');
  perform pg_temp.check_true(
    'and stamps the mark itself, rather than trusting the caller to',
    v_edited is not null);

  -- On the words. All three refusals below are 42501 and they are
  -- three different rules -- not yours, too late, not yours to delete
  -- -- so recording only that something failed passes when the wrong
  -- one fires, and passes with the rule under test deleted.
  perform pg_temp.check_refused(
    'nobody edits words another person is recorded as having said',
    format($q$ select public.chat_edit_message(%L, 'not noted') $q$, v_other),
    '%only edit your own messages%', '42501');
  -- `check_refused` catches, and a caught exception rolls back to a
  -- savepoint and takes the sign-in with it.
  perform pg_temp.sign_in_as(v_ana);

  update public.chat_messages set created_at = now() - interval '20 minutes'
   where id = v_msg;
  perform pg_temp.check_refused(
    'and a message past the window is not editable — by then it has been '
    'read',
    format($q$ select public.chat_edit_message(%L, 'rewritten much later') $q$,
           v_msg),
    '%can only be edited for%', '42501');
  perform pg_temp.sign_in_as(v_ana);
  select body into v_body from public.chat_messages where id = v_msg;
  perform pg_temp.check_true('so it still reads as it did',
    v_body = 'the transfer is approved today');

  -- ---------------------------------------------------------------
  -- Deleting: any age, keeps the row, takes the text and the file
  -- ---------------------------------------------------------------
  insert into public.chat_attachments (message_id, conversation_id, file_name,
    storage_path, mime_type, file_size)
  values (v_msg, v_conv, 'payslip.pdf', v_conv || '/payslip.pdf',
          'application/pdf', 10)
  returning id into v_att;

  perform public.chat_delete_message(v_msg);
  select body, deleted_at is not null into v_body, v_deleted
    from public.chat_messages where id = v_msg;
  perform pg_temp.check_true('the row stays, so the thread keeps its shape',
    v_body is not null);
  perform pg_temp.check_true('marked deleted', v_deleted);
  perform pg_temp.check_true(
    'and the text is gone rather than hidden — every participant may read '
    'this table directly, so hiding it would leave it there to be read',
    v_body = '');
  perform pg_temp.check_true(
    'the attachment row goes with it, so no signed URL can be minted',
    not exists (select 1 from public.chat_attachments where id = v_att));

  -- A double tap on a slow connection is not an error.
  perform public.chat_delete_message(v_msg);

  perform pg_temp.sign_in_as(v_ben);
  select count(*) into v_n from public.chat_thread(v_conv) t;
  perform pg_temp.check_eq(
    'both messages are still in the thread, because a message vanishing '
    'out of the middle of a conversation is what 0135 set out to avoid',
    v_n, 2);
  select t.deleted, t.body into v_deleted, v_body
    from public.chat_thread(v_conv) t where t.id = v_msg;
  perform pg_temp.check_true('the deleted one says so', v_deleted);
  perform pg_temp.check_true('and carries no words', v_body is null);

  select t.deleted into v_deleted
    from public.chat_thread(v_conv) t where t.id = v_other;
  perform pg_temp.check_true('while the other is untouched — the control',
    not v_deleted);

  perform pg_temp.check_refused(
    'and one person cannot take another''s message out of the record',
    format($q$ select public.chat_delete_message(%L) $q$, v_msg),
    '%only delete your own messages%', '42501');
  perform pg_temp.sign_in_as(v_ben);

  perform public.chat_delete_message(v_other);
  perform pg_temp.check_true('while his own deletes, which is the control '
    'for that refusal',
    (select deleted_at is not null from public.chat_messages where id = v_other));
end $$;

-- ---------------------------------------------------------------------
-- Withdrawing consent
--
-- `chat_revoke_link` is how a company that agreed to be talked to takes
-- that back, and it was called by nothing. Neither were `chat_links_for`
-- or `chat_access_list`, which are what the screen behind it reads.
--
-- What matters is not that the row comes back saying 'revoked'. It is
-- that the door shuts: the two companies stop being linked, the other
-- company leaves the directory, and nothing new can be started. And
-- that the door shuts only that far — 0135 says "history stays; what
-- stops is starting anything new", and a revocation that also blanked
-- the thread would destroy a record both sides may need.
-- ---------------------------------------------------------------------
do $$
declare
  v_ann  uuid := pg_temp.another_user('ann@revoke.test');
  v_azmi uuid := pg_temp.another_user('azmi@revoke.test');
  v_ben  uuid := pg_temp.another_user('ben@revoke.test');
  v_a uuid; v_b uuid; v_link uuid; v_conv uuid; v_ok boolean; r record;
begin
  v_a := pg_temp.chat_org('Revoke A Sdn Bhd', v_ann);
  v_b := pg_temp.chat_org('Revoke B Sdn Bhd', v_ben);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_azmi, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_ann);
  perform public.chat_set_access(v_a, v_ann, true);
  perform public.chat_set_access(v_a, v_azmi, true);
  perform pg_temp.sign_in_as(v_ben);
  perform public.chat_set_access(v_b, v_ben, true);

  -- -----------------------------------------------------------------
  -- What each side is shown while it is pending
  --
  -- These two flags decide which button a screen draws. Backwards, and
  -- the company that asked is invited to approve its own request — the
  -- one thing the whole design exists to prevent, arriving as a button.
  -- -----------------------------------------------------------------
  perform pg_temp.sign_in_as(v_ann);
  v_link := public.chat_request_link(v_a, v_b, 'We supply them');

  select * into r from public.chat_links_for(v_a) where id = v_link;
  perform pg_temp.check_true('the asking side is told it asked', r.we_asked);
  perform pg_temp.check_true('and is not waiting on itself', not r.awaiting_us);
  perform pg_temp.check_eq('and is shown the other company, not its own',
    r.other_org_id, v_b);
  perform pg_temp.check_eq('by name', r.other_org_name, 'Revoke B Sdn Bhd');
  perform pg_temp.check_eq('as a request nobody has answered', r.status, 'pending');

  perform pg_temp.sign_in_as(v_ben);
  select * into r from public.chat_links_for(v_b) where id = v_link;
  perform pg_temp.check_true('the asked side is told it did not ask',
    not r.we_asked);
  perform pg_temp.check_true('and that it is the one holding it up',
    r.awaiting_us);
  perform pg_temp.check_eq('and is shown the other company',
    r.other_org_id, v_a);

  perform public.chat_decide_link(v_link, true);
  select * into r from public.chat_links_for(v_b) where id = v_link;
  perform pg_temp.check_true('answering it stops it waiting on anybody',
    not r.awaiting_us);
  perform pg_temp.check_eq('and it says so', r.status, 'approved');

  -- Something to have a history of.
  perform pg_temp.sign_in_as(v_ann);
  v_conv := public.chat_start_direct(v_a, v_ben, v_b);
  insert into public.chat_messages
    (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_ann, v_a, 'Invois bulan ini sudah dihantar');
  perform pg_temp.check_eq('the two companies are talking',
    (select count(*) from public.chat_thread(v_conv)), 1);

  -- -----------------------------------------------------------------
  -- Who may end it
  -- -----------------------------------------------------------------
  perform pg_temp.sign_in_as(v_azmi);
  begin
    perform public.chat_revoke_link(v_link);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_azmi);
  perform pg_temp.check_true('an accountant may not end a company link',
    not v_ok);
  perform pg_temp.check_true('so it is still on',
    app.chat_orgs_linked(v_a, v_b));

  begin
    perform public.chat_revoke_link(gen_random_uuid());
    v_ok := true;
  exception when sqlstate 'P0002' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_ben);
  perform pg_temp.check_true('a link that does not exist is refused', not v_ok);

  -- Either side may, without asking. Here it is the side that agreed,
  -- which is the case that matters: consent has to be withdrawable by
  -- whoever gave it.
  perform public.chat_revoke_link(v_link);

  -- -----------------------------------------------------------------
  -- What that closes, and what it leaves alone
  -- -----------------------------------------------------------------
  perform pg_temp.check_true('the companies are no longer linked',
    not app.chat_orgs_linked(v_a, v_b));

  perform pg_temp.sign_in_as(v_ann);
  perform pg_temp.check_eq('the other company leaves the directory',
    (select count(*) from public.chat_directory(v_a)), 1);

  begin
    perform public.chat_start_direct(v_a, v_ben, v_b);
    v_ok := true;
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_ann);
  perform pg_temp.check_true('and nothing new can be started', not v_ok);

  -- 0135's promise, and the reason `app.is_chat_participant` asks about
  -- the person rather than about the link.
  perform pg_temp.check_eq('but what was said is still there',
    (select count(*) from public.chat_thread(v_conv)), 1);

  -- -----------------------------------------------------------------
  -- Asking again
  -- -----------------------------------------------------------------
  v_link := public.chat_request_link(v_a, v_b, 'Second time');
  perform pg_temp.check_eq('a revoked link can be asked for again',
    (select status from public.chat_links_for(v_a) where id = v_link), 'pending');
  perform pg_temp.check_true('and asking is not agreeing',
    not app.chat_orgs_linked(v_a, v_b));

  -- -----------------------------------------------------------------
  -- Who is switched on
  -- -----------------------------------------------------------------
  select * into r from public.chat_access_list(v_a) where user_id = v_azmi;
  perform pg_temp.check_true('the list says who is switched on', r.is_enabled);
  perform pg_temp.check_eq('and what they are here as', r.role, 'accountant');
  perform pg_temp.check_eq('it covers everybody in the company',
    (select count(*) from public.chat_access_list(v_a)), 2);

  -- It is a company's own list of who may speak for it. An accountant
  -- gets nothing rather than an error, because the screen asks this on
  -- load and an error banner is the wrong answer to a question about
  -- what to draw.
  perform pg_temp.sign_in_as(v_azmi);
  perform pg_temp.check_eq('and only an administrator sees it',
    (select count(*) from public.chat_access_list(v_a)), 0);
  perform pg_temp.sign_in_as(v_ann);
  perform pg_temp.check_eq('nor does it leak another company''s',
    (select count(*) from public.chat_access_list(v_b)), 0);

  -- And the link list is the same shape of answer: a company's own
  -- relationships, empty to anybody outside it. Both of these read a
  -- named organization's rows, so the check is on the argument rather
  -- than on the caller's own company — pass somebody else's id and it
  -- has to come back with nothing.
  perform pg_temp.check_eq('a company sees its own links',
    (select count(*) from public.chat_links_for(v_a)), 1);
  perform pg_temp.check_eq('and none of a company it does not belong to',
    (select count(*) from public.chat_links_for(v_b)), 0);
end $$;

-- ---------------------------------------------------------------------
-- Editing and deleting, rule by rule
--
-- A sweep of `0144`'s two functions left seven mutants alive: a message
-- that is not there, a deleted message edited back to life, a message
-- edited to nothing, a second deletion moving the date the first one
-- set, and somebody whose chat was switched off still editing and
-- deleting -- none of which the block above tried.
-- ---------------------------------------------------------------------
do $$
declare
  v_ana uuid := pg_temp.another_user('ana@edit-rules.test');
  v_ben uuid := pg_temp.another_user('ben@edit-rules.test');
  v_org uuid; v_conv uuid; v_m1 uuid; v_m2 uuid; v_m3 uuid;
begin
  v_org := pg_temp.chat_org('Edit Rules Sdn Bhd', v_ana);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_ben, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_ana);
  perform public.chat_set_access(v_org, v_ana, true);
  perform public.chat_set_access(v_org, v_ben, true);
  v_conv := public.chat_start_direct(v_org, v_ben, v_org);
  insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_ana, v_org, 'one') returning id into v_m1;
  insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_ana, v_org, 'two') returning id into v_m2;
  insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body)
  values (v_conv, v_ana, v_org, 'three') returning id into v_m3;

  perform pg_temp.check_refused('a message that is not there cannot be edited',
    format('select public.chat_edit_message(%L, %L)', gen_random_uuid(), 'x'),
    '%No such message%');
  perform pg_temp.sign_in_as(v_ana);
  perform pg_temp.check_refused('nor deleted',
    format('select public.chat_delete_message(%L)', gen_random_uuid()),
    '%No such message%');
  perform pg_temp.sign_in_as(v_ana);

  perform pg_temp.check_refused('a message is not edited down to nothing',
    format('select public.chat_edit_message(%L, %L)', v_m2, '   '),
    '%cannot be empty%');
  perform pg_temp.sign_in_as(v_ana);

  perform public.chat_delete_message(v_m1);
  perform pg_temp.check_refused('a deleted message is not edited back',
    format('select public.chat_edit_message(%L, %L)', v_m1, 'back again'),
    '%was deleted%', '42501');
  perform pg_temp.sign_in_as(v_ana);
  -- Deleted an hour ago, deleted again now: still an hour ago.
  update public.chat_messages set deleted_at = now() - interval '1 hour' where id = v_m1;
  perform public.chat_delete_message(v_m1);
  perform pg_temp.check_eq('deleting again does not move when it was deleted',
    (select deleted_at::text from public.chat_messages where id = v_m1),
    (now() - interval '1 hour')::text);

  -- Chat switched off for her: her own words are no longer hers to touch.
  perform public.chat_set_access(v_org, v_ana, false);
  perform pg_temp.check_refused('somebody whose chat was switched off cannot edit',
    format('select public.chat_edit_message(%L, %L)', v_m3, 'changed'),
    '%not in that conversation%', '42501');
  perform pg_temp.sign_in_as(v_ana);
  perform pg_temp.check_refused('nor delete',
    format('select public.chat_delete_message(%L)', v_m3),
    '%not in that conversation%', '42501');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Ending a call, rule by rule
--
-- A sweep of `0140`'s `chat_end_call` left seven mutants alive. The one
-- call it was tried on had only people still in it, no reason already
-- recorded, no second call anywhere, and was live: so nothing said the
-- call it ends is dated, that whoever declined is not marked as having
-- left, that an earlier leaving time or reason is kept, that another
-- call is left alone, or that a call already over is not ended again.
-- ---------------------------------------------------------------------
do $$
declare
  v_u1 uuid := pg_temp.another_user('e1@endcall.test');
  v_u2 uuid := pg_temp.another_user('e2@endcall.test');
  v_u3 uuid := pg_temp.another_user('e3@endcall.test');
  v_a uuid; v_g1 uuid; v_g2 uuid; v_call uuid; v_other uuid;
  v_earlier timestamptz := now() - interval '1 hour';
begin
  v_a := pg_temp.chat_org('End Call Sdn Bhd', v_u1);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_u2, 'accountant', 'active', now()),
         (v_a, v_u3, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_set_access(v_a, v_u1, true);
  perform public.chat_set_access(v_a, v_u2, true);
  perform public.chat_set_access(v_a, v_u3, true);
  v_g1 := public.chat_create_group(v_a, 'Satu',
    jsonb_build_array(jsonb_build_object('user_id', v_u2, 'org_id', v_a),
                      jsonb_build_object('user_id', v_u3, 'org_id', v_a)));
  v_g2 := public.chat_create_group(v_a, 'Dua',
    jsonb_build_array(jsonb_build_object('user_id', v_u2, 'org_id', v_a)));

  perform pg_temp.check_refused('a call that is not there says so',
    format('select public.chat_end_call(%L)', gen_random_uuid()), '%No such call%', 'P0002');
  perform pg_temp.sign_in_as(v_u1);

  v_call := public.chat_start_call(v_g1, 'voice');
  v_other := public.chat_start_call(v_g2, 'voice');
  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_start_call(v_g1, 'voice');           -- answers
  perform pg_temp.sign_in_as(v_u3);
  perform public.chat_decline_call(v_call);
  -- Already marked with a leaving time and a reason, as a dropped line
  -- would leave them.
  update public.chat_call_participants set left_at = v_earlier
   where call_id = v_call and user_id = v_u2;
  update public.chat_calls set end_reason = 'network dropped' where id = v_call;

  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_end_call(v_call);
  perform pg_temp.check_eq('an ended call is dated',
    (select ended_at::text from public.chat_calls where id = v_call), now()::text);
  perform pg_temp.check_eq('a reason already recorded is kept',
    (select end_reason from public.chat_calls where id = v_call), 'network dropped');
  perform pg_temp.check_eq('a leaving time already recorded is kept',
    (select left_at::text from public.chat_call_participants
      where call_id = v_call and user_id = v_u2), v_earlier::text);
  perform pg_temp.check_eq('somebody who declined is still somebody who declined',
    (select state::text from public.chat_call_participants
      where call_id = v_call and user_id = v_u3), 'declined');
  perform pg_temp.check_eq('and the call in the other room is still ringing',
    (select status::text from public.chat_calls where id = v_other), 'ringing');
  perform pg_temp.check_eq('with its people still in it',
    (select count(*) from public.chat_call_participants
      where call_id = v_other and state in ('joined', 'ringing')), 2);

  -- A call already over is not ended a second time.
  update public.chat_calls set status = 'missed', ended_at = v_earlier where id = v_call;
  perform public.chat_end_call(v_call);
  perform pg_temp.check_eq('a missed call stays missed',
    (select status::text || ' ' || ended_at::text from public.chat_calls where id = v_call),
    'missed ' || v_earlier::text);
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Making a group, rule by rule
--
-- A sweep of `0139`'s `chat_create_group` left seven mutants alive --
-- every guard it has. Groups here were only ever made by somebody
-- switched on, with a name, with members switched on, from one company.
-- So nothing said that somebody signed out, or switched off, cannot make
-- one; that it needs a name and a member; that the name is kept as
-- meant; that a member switched off is not added; or -- the one that
-- reaches across a tenancy -- that somebody from a company not linked
-- for chat is not added either.
-- ---------------------------------------------------------------------
do $$
declare
  v_a1 uuid := pg_temp.another_user('a1@groups.test');
  v_a2 uuid := pg_temp.another_user('a2@groups.test');
  v_a3 uuid := pg_temp.another_user('a3@groups.test');
  v_b1 uuid := pg_temp.another_user('b1@groups.test');
  v_a uuid; v_b uuid; v_grp uuid;
begin
  v_a := pg_temp.chat_org('Kumpulan A Sdn Bhd', v_a1);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_a2, 'accountant', 'active', now()),
         (v_a, v_a3, 'accountant', 'active', now());
  v_b := pg_temp.chat_org('Kumpulan B Sdn Bhd', v_b1);
  perform pg_temp.sign_in_as(v_b1);
  perform public.chat_set_access(v_b, v_b1, true);
  perform pg_temp.sign_in_as(v_a1);
  perform public.chat_set_access(v_a, v_a1, true);
  perform public.chat_set_access(v_a, v_a2, true);
  -- a3 is never switched on.

  perform pg_temp.sign_out();
  perform pg_temp.check_refused('nobody signed in makes a group',
    format('select public.chat_create_group(%L, %L, %L::jsonb)', v_a, 'G',
      jsonb_build_array(jsonb_build_object('user_id', v_a2, 'org_id', v_a))),
    '%Not signed in%', '42501');
  perform pg_temp.sign_in_as(v_a3);
  perform pg_temp.check_refused('nor somebody whose chat is off',
    format('select public.chat_create_group(%L, %L, %L::jsonb)', v_a, 'G',
      jsonb_build_array(jsonb_build_object('user_id', v_a2, 'org_id', v_a))),
    '%not switched on for you%', '42501');

  perform pg_temp.sign_in_as(v_a1);
  perform pg_temp.check_refused('a group needs a name',
    format('select public.chat_create_group(%L, %L, %L::jsonb)', v_a, '   ',
      jsonb_build_array(jsonb_build_object('user_id', v_a2, 'org_id', v_a))),
    '%needs a name%', '22023');
  perform pg_temp.sign_in_as(v_a1);
  perform pg_temp.check_refused('and somebody in it',
    format('select public.chat_create_group(%L, %L, %L::jsonb)', v_a, 'G', '[]'),
    '%needs somebody in it%', '22023');
  perform pg_temp.sign_in_as(v_a1);
  perform pg_temp.check_refused('a member whose chat is off is not added',
    format('select public.chat_create_group(%L, %L, %L::jsonb)', v_a, 'G',
      jsonb_build_array(jsonb_build_object('user_id', v_a3, 'org_id', v_a))),
    '%not switched on for one of those people%', '42501');
  perform pg_temp.sign_in_as(v_a1);
  perform pg_temp.check_refused(
    'nor somebody from a company not linked for chat, though their chat is on',
    format('select public.chat_create_group(%L, %L, %L::jsonb)', v_a, 'G',
      jsonb_build_array(jsonb_build_object('user_id', v_a2, 'org_id', v_a),
                        jsonb_build_object('user_id', v_b1, 'org_id', v_b))),
    '%not linked%', '42501');

  perform pg_temp.sign_in_as(v_a1);
  v_grp := public.chat_create_group(v_a, '  Pasukan Akaun  ',
    jsonb_build_array(jsonb_build_object('user_id', v_a2, 'org_id', v_a)));
  perform pg_temp.check_eq('a group''s name is kept as meant',
    (select title from public.chat_conversations where id = v_grp), 'Pasukan Akaun');
  perform pg_temp.check_eq('and it holds its creator and its member',
    (select count(*) from public.chat_participants where conversation_id = v_grp), 2);
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Starting a direct conversation, rule by rule
--
-- A sweep of `0135`'s `chat_start_direct` left nine mutants alive. Every
-- pair here was two switched-on people in linked companies with no
-- other conversation between them: so being signed out or switched off,
-- talking to oneself, a group or a conversation with somebody else
-- standing in for the pair's, and speaking for another company were all
-- unasserted -- and the sweep turned up 0757: yourself under your other
-- company passed the self check and failed on a primary key.
--
-- One is EQUIVALENT: reusing a "direct" conversation with more than two
-- people in it. There is no such conversation -- `chat_add_participant`
-- refuses a third person on a direct one, and a client cannot insert a
-- participant.
-- ---------------------------------------------------------------------
do $$
declare
  v_a1 uuid := pg_temp.another_user('a1@direct.test');
  v_a2 uuid := pg_temp.another_user('a2@direct.test');
  v_a3 uuid := pg_temp.another_user('a3@direct.test');
  v_b1 uuid := pg_temp.another_user('b1@direct.test');
  v_a uuid; v_b uuid; v_grp uuid; v_dm uuid; v_dm2 uuid; v_cross uuid;
begin
  v_a := pg_temp.chat_org('Terus A Sdn Bhd', v_a1);
  v_b := pg_temp.chat_org('Terus B Sdn Bhd', v_b1);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_a2, 'accountant', 'active', now()),
         (v_a, v_a3, 'accountant', 'active', now()),
         (v_b, v_a1, 'accountant', 'active', now());
  perform pg_temp.chat_link(v_a, v_a1, v_b, v_b1);
  perform pg_temp.sign_in_as(v_a1);
  perform public.chat_set_access(v_a, v_a1, true);
  perform public.chat_set_access(v_a, v_a2, true);
  perform pg_temp.sign_in_as(v_b1);
  perform public.chat_set_access(v_b, v_b1, true);
  perform public.chat_set_access(v_b, v_a1, true);
  -- a3 is never switched on.

  perform pg_temp.sign_out();
  perform pg_temp.check_refused('nobody signed in starts a conversation',
    format('select public.chat_start_direct(%L, %L, %L)', v_a, v_a2, v_a),
    '%Not signed in%', '42501');
  perform pg_temp.sign_in_as(v_a1);
  perform pg_temp.check_refused('nobody talks to themselves',
    format('select public.chat_start_direct(%L, %L, %L)', v_a, v_a1, v_a),
    '%with yourself%', '22023');
  -- Nor under their other company (0757). Before it, this passed the
  -- check and failed on the participants' primary key, unreadably.
  perform pg_temp.check_refused('nor to themselves under their other company',
    format('select public.chat_start_direct(%L, %L, %L)', v_a, v_a1, v_b),
    '%with yourself%', '22023');
  perform pg_temp.sign_in_as(v_a3);
  perform pg_temp.check_refused('somebody switched off starts nothing',
    format('select public.chat_start_direct(%L, %L, %L)', v_a, v_a2, v_a),
    '%not switched on for you%', '42501');
  perform pg_temp.sign_in_as(v_a1);
  perform pg_temp.check_refused('nor is anybody switched off talked to',
    format('select public.chat_start_direct(%L, %L, %L)', v_a, v_a3, v_a),
    '%not switched on for that person%', '42501');
  perform pg_temp.sign_in_as(v_a1);

  -- A group of exactly these two is not their direct conversation.
  v_grp := public.chat_create_group(v_a, 'Berdua',
    jsonb_build_array(jsonb_build_object('user_id', v_a2, 'org_id', v_a)));
  v_dm := public.chat_start_direct(v_a, v_a2, v_a);
  perform pg_temp.check_true('a group of two is not the pair''s direct conversation',
    v_dm <> v_grp and (select is_direct from public.chat_conversations where id = v_dm));
  perform pg_temp.check_eq('and pressing again finds the same one',
    public.chat_start_direct(v_a, v_a2, v_a), v_dm);

  -- Speaking for B to a2 is a different conversation from speaking for A.
  perform pg_temp.sign_in_as(v_a1);
  v_dm2 := public.chat_start_direct(v_b, v_a2, v_a);
  perform pg_temp.check_true('speaking for another company is another conversation',
    v_dm2 <> v_dm);
  -- And a conversation with a2 is not one with b1.
  perform pg_temp.check_true('nor is a conversation with somebody else',
    public.chat_start_direct(v_a, v_b1, v_b) not in (v_dm, v_dm2));
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Adding to a group, rule by rule
--
-- A sweep of `0139`'s `chat_add_participant` left two mutants alive:
-- nothing tried adding somebody to a group from OUTSIDE it, nor adding
-- somebody whose chat is switched off. The first is a room's membership
-- decided by somebody who is not in the room.
-- ---------------------------------------------------------------------
do $$
declare
  v_u1 uuid := pg_temp.another_user('u1@addto.test');
  v_u2 uuid := pg_temp.another_user('u2@addto.test');
  v_out uuid := pg_temp.another_user('out@addto.test');
  v_off uuid := pg_temp.another_user('off@addto.test');
  v_new uuid := pg_temp.another_user('new@addto.test');
  v_a uuid; v_grp uuid;
begin
  v_a := pg_temp.chat_org('Tambah Ahli Sdn Bhd', v_u1);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_u2, 'accountant', 'active', now()),
         (v_a, v_out, 'accountant', 'active', now()),
         (v_a, v_off, 'accountant', 'active', now()),
         (v_a, v_new, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_set_access(v_a, v_u1, true);
  perform public.chat_set_access(v_a, v_u2, true);
  perform public.chat_set_access(v_a, v_out, true);
  perform public.chat_set_access(v_a, v_new, true);
  v_grp := public.chat_create_group(v_a, 'Dalam',
    jsonb_build_array(jsonb_build_object('user_id', v_u2, 'org_id', v_a)));

  perform pg_temp.sign_in_as(v_out);
  perform pg_temp.check_refused('somebody outside a group cannot add people to it',
    format('select public.chat_add_participant(%L, %L, %L)', v_grp, v_new, v_a),
    '%not in this conversation%', '42501');
  perform pg_temp.sign_in_as(v_u1);
  perform pg_temp.check_refused('nor is anybody added whose chat is off',
    format('select public.chat_add_participant(%L, %L, %L)', v_grp, v_off, v_a),
    '%not switched on for that person%', '42501');
  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_add_participant(v_grp, v_new, v_a);
  perform pg_temp.check_eq('while somebody in it adds somebody switched on',
    (select count(*) from public.chat_participants where conversation_id = v_grp), 3);
  perform pg_temp.sign_out();
end $$;


-- ---------------------------------------------------------------------
-- Answering, refusing and hanging up, rule by rule
--
-- A sweep of `0140`'s `chat_join_call`, `chat_decline_call` and
-- `chat_leave_call` left fifteen mutants alive. The one call above that
-- anybody declined was a live call in a room, so the rule the comment
-- on `chat_decline_call` is about -- IN A PAIR, ONE REFUSAL ENDS IT --
-- had never once run: a refusal that ended nothing passed. Nobody
-- joined a call that was over or not there, rejoined after leaving, was
-- still being rung when the caller hung up, or hung up on a call that
-- had already ended some other way. `0139`'s `chat_leave` had one
-- survivor too: nothing tried to leave a direct conversation.
-- ---------------------------------------------------------------------
do $$
declare
  v_u1 uuid := pg_temp.another_user('u1@answer.test');
  v_u2 uuid := pg_temp.another_user('u2@answer.test');
  v_u3 uuid := pg_temp.another_user('u3@answer.test');
  v_out uuid := pg_temp.another_user('out@answer.test');
  v_late uuid := pg_temp.another_user('late@answer.test');
  v_a uuid; v_grp uuid; v_dm uuid; v_call uuid;
  v_earlier timestamptz := now() - interval '1 hour';
begin
  v_a := pg_temp.chat_org('Jawab Panggilan Sdn Bhd', v_u1);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_u2, 'accountant', 'active', now()),
         (v_a, v_u3, 'accountant', 'active', now()),
         (v_a, v_out, 'accountant', 'active', now()),
         (v_a, v_late, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_set_access(v_a, v_u1, true);
  perform public.chat_set_access(v_a, v_u2, true);
  perform public.chat_set_access(v_a, v_u3, true);
  perform public.chat_set_access(v_a, v_out, true);
  perform public.chat_set_access(v_a, v_late, true);
  v_grp := public.chat_create_group(v_a, 'Bilik',
    jsonb_build_array(jsonb_build_object('user_id', v_u2, 'org_id', v_a),
                      jsonb_build_object('user_id', v_u3, 'org_id', v_a)));
  v_dm := public.chat_start_direct(v_a, v_u2, v_a);

  -- Joining.
  perform pg_temp.check_refused('a call that is not there cannot be joined',
    format('select public.chat_join_call(%L)', gen_random_uuid()),
    '%No such call%', 'P0002');
  perform pg_temp.sign_in_as(v_u1);
  v_call := public.chat_start_call(v_grp, 'voice');
  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_join_call(v_call);
  perform pg_temp.check_eq('whoever answers is in the call',
    (select state::text from public.chat_call_participants
      where call_id = v_call and user_id = v_u2), 'joined');
  perform pg_temp.check_eq('and the call says when it was answered',
    (select answered_at::text from public.chat_calls where id = v_call),
    now()::text);

  -- Back in after hanging up: the first answer still stands.
  update public.chat_call_participants set joined_at = v_earlier
   where call_id = v_call and user_id = v_u2;
  perform public.chat_leave_call(v_call);
  perform public.chat_join_call(v_call);
  perform pg_temp.check_eq('somebody who hangs up and rejoins is in again',
    (select state::text from public.chat_call_participants
      where call_id = v_call and user_id = v_u2), 'joined');
  perform pg_temp.check_eq('from when they first answered',
    (select joined_at::text from public.chat_call_participants
      where call_id = v_call and user_id = v_u2), v_earlier::text);
  perform pg_temp.check_true('and no longer marked as gone',
    (select left_at is null from public.chat_call_participants
      where call_id = v_call and user_id = v_u2));

  -- Somebody added after the call began was never rung, so joining is
  -- the first row they have in it -- the INSERT, not the conflict.
  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_add_participant(v_grp, v_late, v_a);
  perform pg_temp.sign_in_as(v_late);
  perform public.chat_join_call(v_call);
  perform pg_temp.check_eq('somebody added mid-call who joins is in it',
    (select state::text from public.chat_call_participants
      where call_id = v_call and user_id = v_late), 'joined');

  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_end_call(v_call);
  -- Out of the room again, so the room below is the three it was.
  perform pg_temp.sign_in_as(v_late);
  perform public.chat_leave(v_grp);
  -- A pair is not a room: there is no leaving it, only ignoring it.
  perform pg_temp.sign_in_as(v_u2);
  perform pg_temp.check_refused('a direct conversation cannot be left',
    format('select public.chat_leave(%L)', v_dm),
    '%cannot be left, only ignored%', '22023');
  perform pg_temp.sign_in_as(v_u2);
  perform pg_temp.check_eq('and both people are still in it',
    (select count(*) from public.chat_participants where conversation_id = v_dm), 2);
  perform pg_temp.sign_in_as(v_u3);
  perform pg_temp.check_refused('a call that is over cannot be joined',
    format('select public.chat_join_call(%L)', v_call),
    '%That call is over%', '22023');

  -- Refusing in a room: nothing ends while somebody is still being rung.
  perform pg_temp.sign_in_as(v_u1);
  v_call := public.chat_start_call(v_grp, 'voice');
  perform pg_temp.sign_in_as(v_out);
  perform pg_temp.check_refused('somebody outside the room cannot refuse its call',
    format('select public.chat_decline_call(%L)', v_call),
    '%No such call%', 'P0002');
  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_decline_call(v_call);
  perform pg_temp.check_eq('a refusal is dated',
    (select left_at::text from public.chat_call_participants
      where call_id = v_call and user_id = v_u2), now()::text);
  -- EQUIVALENT, for the sweep: dropping the test for somebody who has
  -- ANSWERED from this refusal. While a call is ringing nobody but the
  -- caller can have answered -- `chat_join_call` turns it live in the
  -- same locked transaction, and clients may only select these tables --
  -- so that half of the condition is never what keeps a call open.
  perform pg_temp.check_eq('one refusal while another phone rings ends nothing',
    (select status::text from public.chat_calls where id = v_call), 'ringing');
  perform pg_temp.sign_in_as(v_u3);
  perform public.chat_decline_call(v_call);
  perform pg_temp.check_eq('the last refusal in a room does',
    (select status::text from public.chat_calls where id = v_call), 'declined');

  -- Refusing in a pair.
  perform pg_temp.sign_in_as(v_u1);
  v_call := public.chat_start_call(v_dm, 'voice');
  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_decline_call(v_call);
  perform pg_temp.check_eq('in a pair, one refusal ends it',
    (select status::text from public.chat_calls where id = v_call), 'declined');
  perform pg_temp.check_eq('dated',
    (select ended_at::text from public.chat_calls where id = v_call), now()::text);
  perform pg_temp.check_eq('and saying why',
    (select end_reason from public.chat_calls where id = v_call), 'declined');

  -- The caller is still marked in it. Hanging up now is hanging up on a
  -- call that is already over, which must not rewrite how it ended.
  perform pg_temp.sign_in_as(v_u1);
  perform public.chat_leave_call(v_call);
  perform pg_temp.check_eq('hanging up on a refused call leaves it refused',
    (select status::text from public.chat_calls where id = v_call), 'declined');

  -- Hanging up while the others are still being rung.
  v_call := public.chat_start_call(v_grp, 'voice');
  perform public.chat_leave_call(v_call);
  perform pg_temp.check_eq('a phone still ringing keeps the call open',
    (select status::text from public.chat_calls where id = v_call), 'ringing');

  -- And the last one out keeps a reason already recorded.
  update public.chat_calls set end_reason = 'network dropped' where id = v_call;
  perform pg_temp.sign_in_as(v_u2);
  perform public.chat_decline_call(v_call);
  perform pg_temp.sign_in_as(v_u3);
  perform public.chat_join_call(v_call);
  perform public.chat_leave_call(v_call);
  perform pg_temp.check_eq('the last one out ends it',
    (select status::text from public.chat_calls where id = v_call), 'ended');
  perform pg_temp.check_eq('without overwriting a reason already recorded',
    (select end_reason from public.chat_calls where id = v_call),
    'network dropped');
  perform pg_temp.sign_out();
end $$;


-- ---------------------------------------------------------------------
-- Suspended, closed and closed down: out of the chat as out of all else
--
-- `0758`. `app.chat_enabled` asked only that an `org_members` row
-- EXISTED, so a member an administrator had suspended went on reading
-- the conversation, sending into it and starting calls -- while every
-- other guard, asking for 'active', had already shut them out. The same
-- went for a closed company and a closed account. Each case below is
-- paired with the same person let back in, so a refusal for some other
-- reason cannot pass for this one.
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@suspend.test');
  v_gone uuid := pg_temp.another_user('gone@suspend.test');
  v_third uuid := pg_temp.another_user('third@suspend.test');
  v_a uuid; v_x uuid; v_dm uuid; v_n int; v_role text; v_ok boolean;
begin
  v_a := pg_temp.chat_org('Digantung Sdn Bhd', v_boss);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_gone, 'accountant', 'active', now()),
         (v_a, v_third, 'accountant', 'active', now());
  -- Still active somewhere else, so being suspended HERE is the only
  -- thing that can say no: a membership in another company is not one
  -- in this.
  v_x := pg_temp.chat_org('Syarikat Lain Sdn Bhd', v_third);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_x, v_gone, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_boss);
  perform public.chat_set_access(v_a, v_boss, true);
  perform public.chat_set_access(v_a, v_gone, true);
  perform public.chat_set_access(v_a, v_third, true);
  v_dm := public.chat_start_direct(v_a, v_gone, v_a);
  insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body)
  values (v_dm, v_boss, v_a, 'Laporan bulan ini');

  -- The control: an active member reads it.
  perform pg_temp.sign_in_as(v_gone);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_n from public.chat_messages where conversation_id = v_dm;
  end;
  reset role;
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('an active member reads the conversation', v_n, 1);

  -- Suspended.
  update public.org_members set status = 'suspended'
   where org_id = v_a and user_id = v_gone;
  perform pg_temp.check_true('a suspended member has no chat',
    app.chat_enabled(v_a, v_gone) is false);
  perform pg_temp.sign_in_as(v_gone);
  begin
    set local role authenticated;
    select count(*) into v_n from public.chat_messages where conversation_id = v_dm;
    begin
      insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body)
      values (v_dm, v_gone, v_a, 'Masih di sini');
      v_ok := true;
    exception when insufficient_privilege then v_ok := false;
    end;
  end;
  reset role;
  perform pg_temp.check_eq('nor reads what was said to them', v_n, 0);
  perform pg_temp.check_true('nor says anything more', not v_ok);
  perform pg_temp.check_refused('nor rings anybody from it',
    format('select public.chat_start_call(%L, %L)', v_dm, 'voice'),
    '%not in this conversation%', '42501');
  perform pg_temp.sign_in_as(v_third);
  perform pg_temp.check_refused('and nobody opens a new conversation with them',
    format('select public.chat_start_direct(%L, %L, %L)', v_a, v_gone, v_a),
    '%not switched on for that person%', '42501');

  -- Let back in: the same person, the same conversation.
  update public.org_members set status = 'active'
   where org_id = v_a and user_id = v_gone;
  perform pg_temp.check_true('reinstated, they have chat again',
    app.chat_enabled(v_a, v_gone) is true);

  -- A closed company.
  update public.organizations set deleted_at = now() where id = v_a;
  perform pg_temp.check_true('nobody chats in a closed company',
    app.chat_enabled(v_a, v_gone) is false);
  update public.organizations set deleted_at = null where id = v_a;
  perform pg_temp.check_true('and reopened, they do',
    app.chat_enabled(v_a, v_gone) is true);

  -- A closed account.
  update public.profiles set deleted_at = now() where id = v_gone;
  perform pg_temp.check_true('a closed account has no chat',
    app.chat_enabled(v_a, v_gone) is false);
  perform pg_temp.check_true('while the colleague beside it still does',
    app.chat_enabled(v_a, v_third) is true);
  update public.profiles set deleted_at = null where id = v_gone;

  -- The first gate, which nothing above reaches: the company has chat.
  update public.org_modules set is_enabled = false
   where org_id = v_a and module_code = 'chat';
  perform pg_temp.check_true('a company with chat switched off has none',
    app.chat_enabled(v_a, v_gone) is false);
  update public.org_modules set is_enabled = true, expires_at = now() - interval '1 day'
   where org_id = v_a and module_code = 'chat';
  perform pg_temp.check_true('nor one whose chat has run out',
    app.chat_enabled(v_a, v_gone) is false);
  update public.org_modules set expires_at = now() + interval '1 day'
   where org_id = v_a and module_code = 'chat';
  perform pg_temp.check_true('while one paid up to tomorrow does',
    app.chat_enabled(v_a, v_gone) is true);
  update public.org_modules set is_enabled = false
   where org_id = v_x and module_code = 'chat';
  perform pg_temp.check_true('and another company switching it off is not this one',
    app.chat_enabled(v_a, v_gone) is true);
  perform pg_temp.sign_out();
end $$;

rollback;
