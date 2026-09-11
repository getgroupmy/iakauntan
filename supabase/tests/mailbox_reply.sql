-- =====================================================================
-- iAkauntan :: answering the mail
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mailbox_reply.sql
--
-- `0560` lets a person answer something that arrived at one of the
-- company's addresses. Two things in it are worth asserting and the
-- rest is arithmetic-free plumbing:
--
--   * sending AS an address is at least as guarded as reading it. The
--     recipient sees that address's name over the words, so a rule that
--     let a colleague send from `aisyah@` would be worse than one that
--     let them read it.
--
--   * sent mail is as private as the mailbox it left from. `0095`'s
--     policy was `is_org_member`, which is right for an invoice and
--     wrong for a reply: half a conversation is enough to reconstruct
--     the other half, and `0559` would have been protecting the
--     question while the answer sat in the open.
--
-- Owner bypasses RLS, so everything that tests a policy runs as
-- `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The fixture: one company, two people, a shared address and one each
-- ---------------------------------------------------------------------
do $$
declare
  v_owner  uuid;
  v_clerk  uuid;
  v_org    uuid;
  v_shared uuid;
  v_mine   uuid;
  v_theirs uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Balas Mel Sdn Bhd', array['mailbox']);

  v_clerk := pg_temp.another_user('clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active');

  insert into public.org_mailboxes
    (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (v_org, 'sales', 'approved', now(), false, null)
  returning id into v_shared;

  insert into public.org_mailboxes
    (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (v_org, 'aisyah', 'approved', now(), true, v_owner)
  returning id into v_mine;

  insert into public.org_mailboxes
    (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (v_org, 'meiling', 'approved', now(), true, v_clerk)
  returning id into v_theirs;

  insert into public.inbound_emails
    (org_id, mailbox_id, message_id, from_email, to_email, subject, body_text)
  values
    (v_org, v_shared, '<m-shared@example.com>', 'customer@example.com',
     'sales@iakauntan.com', 'A quotation, please', 'For fifty units.'),
    (v_org, v_mine, '<m-mine@example.com>', 'customer@example.com',
     'aisyah@iakauntan.com', 'About your invoice', 'Which month is this?'),
    (v_org, v_theirs, '<m-theirs@example.com>', 'customer@example.com',
     'meiling@iakauntan.com', 'Something personal', 'Between us.');

  create temporary table fixture on commit drop as
  select v_org as org, v_owner as owner, v_clerk as clerk,
         v_shared as shared, v_mine as mine, v_theirs as theirs;
end $$;

-- ---------------------------------------------------------------------
-- Sending from the company's own address
-- ---------------------------------------------------------------------
do $$
declare
  f     record;
  v_row public.email_outbox;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);

  v_row := public.send_from_mailbox(
    f.shared, 'Customer@Example.com ', 'Your quotation', 'Fifty units, RM 400.');

  -- The address is built from the mailbox, not taken from the caller,
  -- so `0328`'s trigger has nothing left to refuse.
  perform pg_temp.check_eq('a message goes out from the address it was sent from',
    v_row.from_email::text, 'sales@iakauntan.com');
  perform pg_temp.check_eq('queued, never sent from in here',
    v_row.status, 'queued');
  perform pg_temp.check_eq('and the address is folded and trimmed',
    v_row.to_email, 'customer@example.com');
  perform pg_temp.check_true('with nothing threaded onto it',
    v_row.in_reply_to is null and v_row.thread_refs is null);
end $$;

-- ---------------------------------------------------------------------
-- Replying to something that arrived
-- ---------------------------------------------------------------------
do $$
declare
  f        record;
  v_parent uuid;
  v_row    public.email_outbox;
begin
  select * into f from fixture;
  select id into v_parent from public.inbound_emails where mailbox_id = f.mine;

  perform pg_temp.sign_in_as(f.owner);
  v_row := public.send_from_mailbox(
    f.mine, 'customer@example.com', 'Re: About your invoice',
    'August, and it is attached.', v_parent);

  -- Without these two headers the answer opens a new conversation
  -- beside the question in the recipient's mail client, which is how a
  -- thread becomes two threads nobody can follow.
  perform pg_temp.check_eq('a reply names the message it answers',
    v_row.in_reply_to, '<m-mine@example.com>');
  perform pg_temp.check_eq('in both headers, which are not the same header',
    v_row.thread_refs, '<m-mine@example.com>');
  perform pg_temp.check_eq('and leaves from the address it arrived at',
    v_row.from_email::text, 'aisyah@iakauntan.com');
end $$;

-- ---------------------------------------------------------------------
-- Sending as somebody else
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.clerk);

  -- THE ASSERTION THIS FILE EXISTS FOR. A colleague who could send
  -- from this address could write to a customer over somebody's own
  -- name, which is a worse thing than reading their mail.
  perform pg_temp.check_refused(
    'a colleague cannot send as somebody',
    format('select public.send_from_mailbox(%L, %L, %L, %L)',
           f.mine, 'customer@example.com', 'Hello', 'Signed, not me.'),
    '%not your mailbox%', '42501');

  -- And the company's own address is the company's, as it was before.
  perform pg_temp.check_true('but can send from the company''s address',
    (public.send_from_mailbox(f.shared, 'customer@example.com',
                              'Your order', 'Shipped today.')).id is not null);
end $$;

-- ---------------------------------------------------------------------
-- Reading is not writing
-- ---------------------------------------------------------------------
do $$
declare
  f        record;
  v_auditor uuid;
begin
  select * into f from fixture;
  v_auditor := pg_temp.another_user('auditor@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (f.org, v_auditor, 'auditor', 'active');

  perform pg_temp.sign_in_as(v_auditor);
  -- An auditor reads the company's mail and does not answer it. Mail
  -- leaving over the company's name is on the far side of the same line
  -- that stops them raising an invoice.
  perform pg_temp.check_refused(
    'a read-only member cannot send',
    format('select public.send_from_mailbox(%L, %L, %L, %L)',
           f.shared, 'customer@example.com', 'Hello', 'From the auditor.'),
    '%permission to send%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- A reply joins the conversation it came from
-- ---------------------------------------------------------------------
do $$
declare
  f        record;
  v_theirs uuid;
begin
  select * into f from fixture;
  select id into v_theirs from public.inbound_emails where mailbox_id = f.theirs;

  perform pg_temp.sign_in_as(f.clerk);
  -- Meiling can read that message and is sending from a different
  -- address. Threading it here would put her reply under a conversation
  -- that arrived somewhere else.
  perform pg_temp.check_refused(
    'a reply cannot be threaded into another mailbox''s conversation',
    format('select public.send_from_mailbox(%L, %L, %L, %L, %L)',
           f.shared, 'customer@example.com', 'Re:', 'Threaded wrongly.',
           v_theirs),
    '%did not arrive at this address%', '22023');

  -- A message id that is nobody's answers the same way, so the refusal
  -- cannot be read as an oracle for which ids exist.
  perform pg_temp.check_refused(
    'and neither can one that does not exist',
    format('select public.send_from_mailbox(%L, %L, %L, %L, %L)',
           f.shared, 'customer@example.com', 'Re:', 'Threaded nowhere.',
           gen_random_uuid()),
    '%did not arrive at this address%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- What is refused before anybody is told it was sent
-- ---------------------------------------------------------------------
do $$
declare
  f     record;
  v_new uuid;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);

  perform pg_temp.check_refused(
    'a name without a domain is not an address',
    format('select public.send_from_mailbox(%L, %L, %L, %L)',
           f.shared, 'customer', 'Hello', 'Nowhere to go.'),
    '%not an email address%', '22023');

  perform pg_temp.check_refused(
    'nor is an empty box',
    format('select public.send_from_mailbox(%L, %L, %L, %L)',
           f.shared, '   ', 'Hello', 'Nowhere to go.'),
    '%not an email address%', '22023');

  perform pg_temp.check_refused(
    'and an empty message is not sent',
    format('select public.send_from_mailbox(%L, %L, %L, %L)',
           f.shared, 'customer@example.com', 'Hello', '   '),
    '%needs something in it%', '22023');

  -- Asked for is not granted, which `0328` already says about queueing
  -- a row directly and this says about the door in front of it.
  insert into public.org_mailboxes (org_id, local_part, status)
  values (f.org, 'pending', 'requested') returning id into v_new;
  perform pg_temp.check_refused(
    'an address still waiting cannot send',
    format('select public.send_from_mailbox(%L, %L, %L, %L)',
           v_new, 'customer@example.com', 'Hello', 'Too early.'),
    '%not been approved%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- And what was sent is as private as what arrived
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;

  -- With `0095`'s policy this is 1. Everything else in this file still
  -- passes with the policy reverted.
  perform pg_temp.check_eq('a colleague cannot read what somebody sent',
    (select count(*) from public.email_outbox where mailbox_id = f.mine),
    0::bigint);

  perform pg_temp.check_eq('and reads what was sent from the shared one',
    (select count(*) from public.email_outbox where mailbox_id = f.shared),
    2::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- An invoice is still the company's
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  -- Every row queued before `0560` carries no mailbox, and this is the
  -- assertion that they did not quietly become unreadable when the
  -- policy grew a second clause.
  insert into public.email_outbox (org_id, to_email, subject, body)
  values (f.org, 'customer@example.com', 'Invoice INV-1', 'Attached.');

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  perform pg_temp.check_eq('a document''s mail is read by everybody who works here',
    (select count(*) from public.email_outbox
      where mailbox_id is null and org_id = f.org), 1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- The conversation, in one list
-- ---------------------------------------------------------------------
do $$
declare
  f     record;
  v_all record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;

  select count(*) as n,
         count(*) filter (where direction = 'out') as out_n
    into v_all
    from public.mailbox_thread(f.mine);

  perform pg_temp.check_eq('one mailbox holds both directions',
    v_all.n, 2::bigint);
  perform pg_temp.check_eq('and one of them left',
    v_all.out_n, 1::bigint);

  -- Invoker rights, so the list is the policies' answer and not a
  -- second copy of them.
  reset role;
  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  perform pg_temp.check_eq('and somebody else''s holds nothing for a colleague',
    (select count(*) from public.mailbox_thread(f.mine)), 0::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- And the picker offers only what sending will accept
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  -- The company's address and her own, and not Aisyah's -- a picker
  -- that offered it would put somebody in front of a refusal with a
  -- message already written.
  perform pg_temp.check_eq('a clerk is offered two addresses',
    (select count(*) from public.my_mailboxes(f.org)), 2::bigint);
  perform pg_temp.check_eq('and never somebody else''s',
    (select count(*) from public.my_mailboxes(f.org) where id = f.mine),
    0::bigint);
  perform pg_temp.check_eq('their own comes first',
    (select local_part from public.my_mailboxes(f.org) limit 1), 'meiling');
  reset role;

  -- An address still waiting on the platform is not one to write from.
  perform pg_temp.check_eq('and nothing that has not been approved',
    (select count(*) from public.my_mailboxes(f.org)
      where status <> 'approved'), 0::bigint);
end $$;

rollback;
