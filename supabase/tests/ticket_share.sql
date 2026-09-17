-- =====================================================================
-- iAkauntan :: the customer replying to their own ticket
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/ticket_share.sql
--
-- `ticket_comments.author_contact_id` has existed since `0192`, with a
-- check constraint requiring exactly one author, and nothing has ever
-- written it: `add_ticket_comment` always sets `author_user_id`. The
-- requester half of every conversation was unreachable.
--
-- The three that make this correct rather than merely possible:
--
--   * an internal note never leaves the building — the boolean `0192`
--     itself calls the most dangerous one in a helpdesk;
--   * a customer's own message is not the company's first response, or
--     the SLA report shows a target met that nobody met;
--   * a reply takes the ticket off `pending`, so the clock that was
--     paused while the company waited starts again when the answer
--     arrives.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ts_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid; v_team uuid; v_pol uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'ticketing', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.ticket_teams (org_id, code, name, is_default)
  values (v_org, 'SVC', 'Service Desk', true) returning id into v_team;
  insert into public.sla_policies
    (org_id, code, name, business_hours_only, is_default, time_zone)
  values (v_org, 'STD', 'Standard', false, true, 'Asia/Kuala_Lumpur')
  returning id into v_pol;
  insert into public.sla_targets
    (org_id, policy_id, priority, response_minutes, resolution_minutes)
  values (v_org, v_pol, 'p3', 240, 2880);
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- Reading it, and what is left out
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.ts_org('Meja Bantuan Sdn Bhd');
  v_cust  uuid;
  v_tkt   uuid;
  v_token text;
  v_out   jsonb;
  v_said  text;
  v_n     integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Puan Aminah', 'customer') returning id into v_cust;

  v_tkt := public.create_ticket(v_org, 'The printer is offline',
    'It stopped this morning', null, 'p3', null, 'email', null, v_cust);

  perform public.add_ticket_comment(v_tkt,
    'Called the vendor, waiting on a part number', true);
  perform public.add_ticket_comment(v_tkt,
    'We have ordered the part, it arrives Thursday', false);

  v_token := public.share_ticket(v_tkt, 30, 'aminah@example.test');

  -- Read it as a stranger with the link, which is the whole point.
  perform pg_temp.sign_out();
  v_out := public.open_shared_ticket(v_token);

  perform pg_temp.check_eq('the link opens', v_out ->> 'state', 'open');
  perform pg_temp.check_eq('and shows the ticket',
    v_out -> 'ticket' ->> 'subject', 'The printer is offline');
  perform pg_temp.check_eq('and who it is for',
    v_out -> 'contact' ->> 'name', 'Puan Aminah');
  perform pg_temp.check_eq('and what state it is in',
    v_out -> 'ticket' ->> 'status', 'new');

  -- The assertion this function exists around.
  perform pg_temp.check_eq('one comment, not two',
    jsonb_array_length(v_out -> 'comments'), 1);
  perform pg_temp.check_eq('and it is the visible one',
    v_out -> 'comments' -> 0 ->> 'body',
    'We have ordered the part, it arrives Thursday');
  perform pg_temp.check_true('the internal note is nowhere in the answer',
    v_out::text not like '%waiting on a part number%');

  -- And nothing about who inside the company said it.
  perform pg_temp.check_true('no agent is named',
    not (v_out -> 'comments' -> 0 ? 'author_user_id'));

  -- A token nobody issued is not a token, and says nothing about which
  -- tokens are real.
  perform pg_temp.check_eq('a wrong token is simply invalid',
    public.open_shared_ticket('not-a-token') ->> 'state', 'invalid');

  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- Opening is recorded, because that is the only evidence the link
  -- reached anybody.
  select open_count into v_n from public.ticket_share_links
   where ticket_id = v_tkt and revoked_at is null;
  perform pg_temp.check_eq('the open is counted', v_n, 1);

  -- One live link at a time.
  perform public.share_ticket(v_tkt);
  select count(*)::integer into v_n from public.ticket_share_links
   where ticket_id = v_tkt and revoked_at is null;
  perform pg_temp.check_eq('reissuing leaves one live link', v_n, 1);
  perform pg_temp.sign_out();
  perform pg_temp.check_eq('and the old one stops working',
    public.open_shared_ticket(v_token) ->> 'state', 'revoked');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- A ticket raised by staff has a login already.
  begin
    perform public.share_ticket(
      public.create_ticket(v_org, 'Internal thing'));
    raise exception 'FAIL: a staff ticket was shared on a link';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a link is for a requester with no login',
    v_said like '%raised by a member of staff%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Replying, and the two clocks
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.ts_org('Balas Sdn Bhd');
  v_cust  uuid;
  v_tkt   uuid;
  v_token text;
  v_out   jsonb;
  v_t     public.tickets;
  v_c     public.ticket_comments;
  v_n     integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Encik Faizal', 'customer') returning id into v_cust;

  v_tkt := public.create_ticket(v_org, 'Cannot log in', 'Since Monday',
    null, 'p3', null, 'email', null, v_cust);
  v_token := public.share_ticket(v_tkt);

  -- Waiting on the customer: the clock is paused.
  perform public.transition_ticket(v_tkt, 'pending', 'Asked for a screenshot');
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true('the clock is paused while we wait',
    v_t.paused_at is not null);
  perform pg_temp.check_true('and nobody has answered them yet',
    v_t.first_response_at is null);

  perform pg_temp.sign_out();
  v_out := public.reply_to_shared_ticket(v_token,
    '  Here is the screenshot you asked for  ');
  perform pg_temp.check_eq('the reply lands', v_out ->> 'state', 'open');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  select * into v_c from public.ticket_comments
   where ticket_id = v_tkt and author_contact_id is not null;
  perform pg_temp.check_eq('written as the requester, not as staff',
    v_c.author_contact_id, v_cust);
  perform pg_temp.check_true('and not as a member',
    v_c.author_user_id is null);
  -- Unconditionally visible: a customer's own message landing as an
  -- internal note would be invisible to the person who sent it.
  perform pg_temp.check_true('and it is not an internal note',
    not v_c.is_internal);
  perform pg_temp.check_eq('with the body trimmed',
    v_c.body, 'Here is the screenshot you asked for');

  select * into v_t from public.tickets where id = v_tkt;
  -- The falsehood being prevented. The first-response target is a
  -- promise about how quickly the *company* would answer.
  perform pg_temp.check_true(
    'the customer answering is not the company answering',
    v_t.first_response_at is null);
  -- And the clock that was paused while we waited starts again.
  perform pg_temp.check_eq('the ticket comes back to us',
    v_t.status::text, 'open');
  perform pg_temp.check_true('and the clock is running again',
    v_t.paused_at is null);

  -- It shows up on their own link.
  perform pg_temp.sign_out();
  v_out := public.open_shared_ticket(v_token);
  perform pg_temp.check_eq('the requester sees their own message',
    jsonb_array_length(v_out -> 'comments'), 1);
  perform pg_temp.check_true('and it is marked as theirs',
    (v_out -> 'comments' -> 0 ->> 'mine')::boolean);

  -- An empty reply is not a reply, and is refused without writing one.
  perform pg_temp.check_eq('an empty reply is refused',
    public.reply_to_shared_ticket(v_token, '   ') ->> 'state', 'empty');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select count(*)::integer into v_n from public.ticket_comments
   where ticket_id = v_tkt;
  perform pg_temp.check_eq('and nothing was written', v_n, 1);

  -- Now the company answers, and that does stop the clock.
  perform public.add_ticket_comment(v_tkt, 'Reset, try again', false);
  select * into v_t from public.tickets where id = v_tkt;
  perform pg_temp.check_true('a member''s visible reply is the response',
    v_t.first_response_at is not null);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Replying to something already finished
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.ts_org('Buka Semula Sdn Bhd');
  v_cust  uuid;
  v_tkt   uuid;
  v_token text;
  v_t     public.tickets;
  v_out   jsonb;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Cik Nurul', 'customer') returning id into v_cust;

  v_tkt := public.create_ticket(v_org, 'Still broken', null, null, 'p3',
    null, 'email', null, v_cust);
  v_token := public.share_ticket(v_tkt);
  perform public.transition_ticket(v_tkt, 'resolved', 'Replaced the cable');
  perform public.transition_ticket(v_tkt, 'closed');

  -- What was written when it was resolved is addressed to the
  -- requester, so the requester is shown it. The internal notes behind
  -- it are not.
  perform pg_temp.sign_out();
  v_out := public.open_shared_ticket(v_token);
  perform pg_temp.check_eq('the resolution reaches the person it is about',
    v_out -> 'ticket' ->> 'resolution_note', 'Replaced the cable');

  v_out := public.reply_to_shared_ticket(v_token, 'It has happened again');
  perform pg_temp.check_eq('a reply on a closed ticket lands',
    v_out ->> 'state', 'open');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  select * into v_t from public.tickets where id = v_tkt;
  -- A customer saying "it has happened again" on a closed ticket is
  -- exactly what `reopened_count` is for.
  perform pg_temp.check_eq('and reopens it', v_t.status::text, 'open');
  perform pg_temp.check_eq('and is counted as a reopen',
    v_t.reopened_count, 1);
  perform pg_temp.check_true('the resolution date is cleared with it',
    v_t.resolved_at is null and v_t.closed_at is null);

  -- A cancelled ticket is finished for good, and its link stops
  -- resolving rather than reopening it.
  perform public.transition_ticket(v_tkt, 'cancelled', 'Duplicate');
  perform pg_temp.sign_out();
  perform pg_temp.check_eq('a cancelled ticket is withdrawn',
    public.open_shared_ticket(v_token) ->> 'state', 'withdrawn');
  perform pg_temp.check_eq('and takes no more replies',
    public.reply_to_shared_ticket(v_token, 'hello') ->> 'state', 'withdrawn');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Expiry, revocation, and who may issue one
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.ts_org('Tamat Tempoh Sdn Bhd');
  v_cust  uuid;
  v_tkt   uuid;
  v_token text;
  v_out   uuid := pg_temp.another_user('outsider@ts.test');
  v_said  text;
  v_n     integer;
  v_role  text;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Tuan Hakim', 'customer') returning id into v_cust;
  v_tkt := public.create_ticket(v_org, 'A question', null, null, 'p3',
    null, 'email', null, v_cust);
  v_token := public.share_ticket(v_tkt, 1);

  update public.ticket_share_links set expires_at = now() - interval '1 day'
   where ticket_id = v_tkt;
  perform pg_temp.sign_out();
  perform pg_temp.check_eq('an expired link says so',
    public.open_shared_ticket(v_token) ->> 'state', 'expired');
  perform pg_temp.check_eq('and takes no reply',
    public.reply_to_shared_ticket(v_token, 'hello') ->> 'state', 'expired');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- The attempt is still recorded: that somebody tried is worth as much
  -- as that somebody read it.
  select open_count into v_n from public.ticket_share_links
   where ticket_id = v_tkt;
  perform pg_temp.check_eq('and the attempt is counted anyway', v_n, 1);

  update public.ticket_share_links
     set expires_at = now() + interval '30 days' where ticket_id = v_tkt;
  perform pg_temp.check_eq('revoking says how many it revoked',
    public.revoke_ticket_share(v_tkt), 1);
  perform pg_temp.sign_out();
  perform pg_temp.check_eq('and the link stops',
    public.open_shared_ticket(v_token) ->> 'state', 'revoked');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- An outsider issues none, and revokes none.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform public.share_ticket(v_tkt);
    raise exception 'FAIL: an outsider shared a ticket';
  exception when sqlstate '42501' or sqlstate 'P0002' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not permitted to share a ticket',
    v_said like '%not permitted to share a ticket%');

  begin
    perform public.revoke_ticket_share(v_tkt);
    raise exception 'FAIL: an outsider revoked a ticket link';
  exception when sqlstate '42501' or sqlstate 'P0002' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor to revoke one',
    v_said like '%not permitted to revoke a ticket link%');

  -- And reads no token hashes, which is what the table would hand over
  -- if the policy were not there. Under the `authenticated` role on
  -- purpose: a DO block runs as the owner, and row level security does
  -- not apply to the owner — asserted as owner this passes with the
  -- policy dropped.
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*)::integer into v_n from public.ticket_share_links
     where ticket_id = v_tkt;
  end;
  reset role;
  perform pg_temp.check_eq('the check ran under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_eq('and an outsider sees no links at all', v_n, 0);

  -- The control: a member does see it, so the assertion above is about
  -- the policy rather than about the role having no privileges at all.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  begin
    set local role authenticated;
    select count(*)::integer into v_n from public.ticket_share_links
     where ticket_id = v_tkt;
  end;
  reset role;
  perform pg_temp.check_eq('while a member does', v_n, 1);

  perform pg_temp.sign_out();
end $$;

rollback;
