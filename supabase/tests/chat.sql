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

rollback;
