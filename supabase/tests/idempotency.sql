-- =====================================================================
-- iAkauntan :: a retry that does not post twice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/idempotency.sql
--
-- 0307 added idempotency keys to the writes that create something. The
-- first block below is the defect it fixes, kept as a live assertion
-- rather than a paragraph: without a key, two identical calls to
-- `post_manual_journal` really do leave two entries in the ledger.
--
-- Asserted:
--
--   * the unguarded double-post, so the reason for all of this stays
--     visible and nobody "simplifies" the key away;
--   * a repeated key returns the first answer and does no second work;
--   * a key reused for a *different* request is refused, because
--     silently returning the first answer would hide a client bug;
--   * a key in flight is refused rather than executed twice;
--   * no key at all behaves exactly as before, which is what every
--     existing caller does;
--   * keys are scoped to one organization;
--   * the table is unreachable from the client;
--   * the sweep drops what is older than a day and keeps what is not.
--
-- Six mutants were run. Five died at the assertion they were aimed at:
-- never replaying, skipping the fingerprint check, treating an
-- in-flight key as finished, sweeping everything, and leaving the
-- table with Supabase's default grant to `authenticated`.
--
-- The sixth could not be written, and the reason is worth keeping.
-- Removing `org_id` from the key does not silently share keys between
-- tenants — it makes `on conflict (org_id, key)` match no constraint,
-- and the very first call raises "there is no unique or exclusion
-- constraint matching the ON CONFLICT specification". The scoping is
-- structural rather than asserted: it cannot degrade quietly, only
-- fail loudly, which is the better of the two.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- The clock now lives in `_helpers.sql`, which this file already
-- includes, so the local copy that used to sit here is gone. Its
-- reasoning moved with it.

-- Two postable accounts and an open year, which anything touching the
-- ledger needs.
create or replace function pg_temp.ledger_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  return v_org;
end $$;

create or replace function pg_temp.balanced_lines(p_org uuid)
returns jsonb language plpgsql as $$
declare v_dr uuid; v_cr uuid;
begin
  select id into v_dr from public.accounts
   where org_id = p_org and is_active and not is_group
     and account_type = 'asset' limit 1;
  select id into v_cr from public.accounts
   where org_id = p_org and is_active and not is_group
     and account_type = 'revenue' limit 1;
  return jsonb_build_array(
    jsonb_build_object('account_id', v_dr, 'debit', 100, 'credit', 0),
    jsonb_build_object('account_id', v_cr, 'debit', 0,   'credit', 100));
end $$;

-- ---------------------------------------------------------------------
-- The defect, without a key
--
-- This is what a dropped connection costs. The client cannot know
-- whether the first request landed, retries, and the ledger — which is
-- append-only by design — carries the entry twice.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; a uuid; b uuid;
begin
  v_org := pg_temp.ledger_org('Ulang Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  a := public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1');
  b := public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1');

  perform pg_temp.check_true(
    'without a key, an identical retry posts a second entry', a <> b);
  perform pg_temp.check_eq(
    'and the ledger carries both',
    (select count(*) from public.gl_entries where org_id = v_org)::numeric, 2);
end $$;

-- ---------------------------------------------------------------------
-- The same request, with a key
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; a uuid; b uuid;
begin
  v_org := pg_temp.ledger_org('Sekali Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  a := public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1', 'k-1');
  b := public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1', 'k-1');

  perform pg_temp.check_eq('a repeated key returns the first answer',
    a::text, b::text);
  -- The control that matters. Returning the same id while quietly
  -- posting again would satisfy the line above and be worse than the
  -- defect, because the duplicate would be harder to find.
  perform pg_temp.check_eq('and does no second work',
    (select count(*) from public.gl_entries where org_id = v_org)::numeric, 1);
end $$;

-- ---------------------------------------------------------------------
-- A key reused for a different request is a client bug, not a retry
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; v_id uuid;
begin
  v_org := pg_temp.ledger_org('Silap Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);
  v_id := public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1', 'k-2');

  begin
    perform public.post_manual_journal(
      v_org, pg_temp.today(), v_lines, 'Something else entirely', 'R-2', 'k-2');
    raise exception 'FAIL: a key was honoured for a different request';
  exception when sqlstate '22023' then
    raise notice 'ok   a key reused for a different request is refused';
  end;

  -- And the refusal did not damage what the key already stood for.
  perform pg_temp.check_eq('the original answer still stands',
    public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1', 'k-2')::text,
    v_id::text);
end $$;

-- ---------------------------------------------------------------------
-- A key still in flight
--
-- Claimed and not yet completed: the client retried before the first
-- call finished. "Ask again" is the honest answer; executing is not.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb;
begin
  v_org := pg_temp.ledger_org('Serentak Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  -- Stand in for a request that has claimed its key and not yet
  -- returned. A second connection cannot be opened inside a test that
  -- must roll back, so the claim is made directly.
  perform app.idempotency_begin(v_org, 'k-3', 'post_manual_journal',
    jsonb_build_object('entry_date', pg_temp.today(), 'lines', v_lines,
                       'description', 'Fi', 'reference', 'R-1'));

  begin
    perform public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'R-1', 'k-3');
    raise exception 'FAIL: a key in flight was executed a second time';
  exception when sqlstate '55006' then
    raise notice 'ok   a key still in progress is refused, not repeated';
  end;

  perform pg_temp.check_eq('and nothing was posted',
    (select count(*) from public.gl_entries where org_id = v_org)::numeric, 0);
end $$;

-- ---------------------------------------------------------------------
-- One key, two companies
--
-- Keys are generated by clients and clients collide. A key is only ever
-- honoured for the organization it was claimed under.
-- ---------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; a uuid; b uuid;
begin
  v_a := pg_temp.ledger_org('Satu Sdn Bhd');
  v_b := pg_temp.ledger_org('Dua Sdn Bhd');

  a := public.post_manual_journal(v_a, pg_temp.today(),
         pg_temp.balanced_lines(v_a), 'Fi', 'R-1', 'shared');
  b := public.post_manual_journal(v_b, pg_temp.today(),
         pg_temp.balanced_lines(v_b), 'Fi', 'R-1', 'shared');

  perform pg_temp.check_true(
    'one company''s key is not another company''s answer', a <> b);
  perform pg_temp.check_eq('and each posted its own entry',
    (select count(*) from public.gl_entries where org_id in (v_a, v_b))::numeric, 2);
end $$;

-- ---------------------------------------------------------------------
-- The table is the mechanism's, not the client's
--
-- Supabase's default privileges hand every new table to `authenticated`
-- whatever the migration asked for — 0299 exists because of exactly
-- that — so 0307 revokes them explicitly. Run as `authenticated`,
-- because a superuser bypasses all of this and would prove nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.ledger_org('Sulit Kunci Sdn Bhd');
  v_user uuid := pg_temp.another_user('nosy@kunci.test');
  v_role text; v_read boolean := false;
begin
  perform public.post_manual_journal(v_org, pg_temp.today(),
    pg_temp.balanced_lines(v_org), 'Fi', 'R-1', 'k-4');

  perform pg_temp.sign_in_as(v_user);
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      perform 1 from public.idempotency_keys limit 1;
      v_read := true;
    exception when insufficient_privilege then
      v_read := false;
    end;
  end;
  reset role;

  perform pg_temp.check_true('the privilege test ran as authenticated',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'the client cannot read other people''s idempotency keys', not v_read);
end $$;

-- ---------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; v_dropped integer;
begin
  v_org := pg_temp.ledger_org('Sapu Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  perform public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'old', 'k-old');
  update public.idempotency_keys set created_at = now() - interval '25 hours'
   where org_id = v_org and key = 'k-old';
  perform public.post_manual_journal(v_org, pg_temp.today(), v_lines, 'Fi', 'new', 'k-new');

  v_dropped := app.sweep_idempotency_keys(now() - interval '24 hours');

  perform pg_temp.check_eq('the sweep drops the key that timed out',
    v_dropped::numeric, 1);
  -- The control. A sweep that took everything would pass the line above
  -- and break every retry in flight.
  perform pg_temp.check_eq('and keeps the one still inside the window',
    (select count(*) from public.idempotency_keys where org_id = v_org)::numeric, 1);
  perform pg_temp.check_eq('the survivor is the recent one',
    (select key from public.idempotency_keys where org_id = v_org), 'k-new');
end $$;

-- ---------------------------------------------------------------------
-- A replay is still somebody asking
-- ---------------------------------------------------------------------
--
-- The wrappers are thin; the guard is inside the real function. So on
-- the first call a stranger is refused correctly, and on a replay the
-- real function is never called at all -- which is how somebody who was
-- not in the company got the stored result of a write, and how a key
-- they had merely guessed was confirmed to exist. See 0475.
-- ---------------------------------------------------------------------
do $$
declare
  v_org      uuid;
  v_a        uuid;
  v_b        uuid;
  v_stranger uuid;
  v_msg      text;
  v_took     boolean;
  v_lines    jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kunci Ulang Sdn Bhd');
  perform public.create_fiscal_year(
    v_org, date_trunc('year', pg_temp.today())::date);

  select id into v_a from public.accounts
   where org_id = v_org and account_type = 'expense'
     and not is_group and is_active order by code limit 1;
  select id into v_b from public.accounts
   where org_id = v_org and account_type = 'liability'
     and not is_group and is_active order by code limit 1;
  -- Nothing below proves anything without these.
  perform pg_temp.check_true('the fixture found two postable accounts',
    v_a is not null and v_b is not null);

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_a, 'debit', 100, 'credit', 0),
    jsonb_build_object('account_id', v_b, 'debit', 0, 'credit', 100));

  -- A member does the protected write, so there is a key to replay.
  perform public.post_manual_journal(
    v_org, pg_temp.today(), v_lines, 'A journal', null, 'REPLAY-1');
  perform pg_temp.check_eq('the member''s journal is there',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and description = 'A journal'), 1);

  -- Somebody who is not in this company at all.
  v_stranger := pg_temp.another_user('orang.luar@idem.test');
  perform pg_temp.sign_in_as(v_stranger);

  begin
    perform public.post_manual_journal(
      v_org, pg_temp.today(), v_lines, 'A journal', null, 'REPLAY-1');
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a stranger cannot replay somebody else''s key', not v_took);

  -- Same key, arguments that do not match. Before 0475 this answered
  -- `already used for a different request`, which tells somebody who
  -- guessed a key that it is real. The refusal has to be the membership
  -- one, and it has to arrive first.
  begin
    perform public.post_manual_journal(
      v_org, pg_temp.today(),
      jsonb_build_array(
        jsonb_build_object('account_id', v_a, 'debit', 999, 'credit', 0),
        jsonb_build_object('account_id', v_b, 'debit', 0, 'credit', 999)),
      'Something else', null, 'REPLAY-1');
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('and learns nothing from a key they guessed',
    not v_took and v_msg not like '%already used%');

  -- The guard that was already right, kept: a fresh key still reaches
  -- the real function and is refused there.
  begin
    perform public.post_manual_journal(
      v_org, pg_temp.today(), v_lines, 'Fresh', null, 'REPLAY-NEW');
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('and a fresh key is refused as it always was',
    not v_took);

  -- And a member is not caught by any of it.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('while the member replays their own key',
    public.post_manual_journal(
      v_org, pg_temp.today(), v_lines, 'A journal', null, 'REPLAY-1')
    is not null);
  perform pg_temp.check_eq('without writing it twice',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and description = 'A journal'), 1);
end $$;

-- =====================================================================
-- 0733 :: the four that still doubled
--
-- `0307` protected four writes. The six below were found by asking the
-- schema which client-reachable writes insert something and refuse
-- nothing -- and the first version of that question was asked with a
-- line-based `grep` over `repository.dart`, which missed every call site
-- that puts the function name on the line after `await callRpc(`: 192
-- functions found where there are 577. `email_receipt` is in this file
-- because of the corrected count and not the first one.
--
-- Each block asserts the same three things, and the FIRST of them is the
-- one that makes the other two mean anything: without a key, the second
-- call really does do the work twice. An assertion that only checked the
-- replay would pass just as well against a function that could not
-- double in the first place.
--
-- That is not a style preference. `save_payment_method` and
-- `create_layout_from_builtin` were in this file and in `0733`, both
-- ending in an unconditional insert when no id is passed, and the block
-- asserting the duplicate is what found they cannot duplicate: a UNIQUE
-- INDEX on `(org_id, lower(name))` refuses the second tap. Neither index
-- is in its table definition or in `pg_constraint`, so reading the
-- function bodies — which is how both got onto the list — could not have
-- found it. Both came out of the migration.
-- =====================================================================

create or replace function pg_temp.sendable_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org,
    pg_temp.today());
  insert into public.email_settings (org_id, is_enabled) values (v_org, true);
  return v_org;
end $$;

create or replace function pg_temp.a_customer(p_org uuid, p_code text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, p_code, 'Reachable Bhd', 'customer', 'ar@reachable.example')
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.an_invoice(
  p_org uuid, p_contact uuid, p_no text)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no,
          pg_temp.today(),
          pg_temp.today() + 30, p_contact,
          'MYR', 1, 500, 500, 500, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, 500, 500);
  perform public.post_sales_document(v_doc);
  return v_doc;
end $$;

-- ---------------------------------------------------------------------
-- email_document: the side effect that leaves the building
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_contact uuid; v_doc uuid; v_fresh uuid; v_first uuid;
  v_again uuid; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sendable_org('Mailer Sdn Bhd');
  v_contact := pg_temp.a_customer(v_org, 'C-001');
  v_doc := pg_temp.an_invoice(v_org, v_contact, 'INV-1');

  -- The defect. Two sends with no key are two messages to the customer,
  -- and unlike a doubled journal nobody can reverse the second one.
  perform public.email_document(v_doc);
  perform public.email_document(v_doc);
  perform pg_temp.check_eq('without a key, a retry emails the customer twice',
    (select count(*)::integer from public.email_outbox where org_id = v_org), 2);

  -- With one, the second call returns the first answer and queues
  -- nothing.
  v_first := public.email_document(v_doc, null, 'document_new', null,
    'queued', null, null, 'SEND-1');
  v_again := public.email_document(v_doc, null, 'document_new', null,
    'queued', null, null, 'SEND-1');
  perform pg_temp.check_true('a replayed send returns the first message id',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and queues nothing the second time',
    (select count(*)::integer from public.email_outbox where org_id = v_org), 3);

  -- And the omitted-argument branch really omitted it.
  --
  -- `expires_at is not null` is NOT the assertion -- it was, and a mutant
  -- that passed the null straight through survived it. There are TWO
  -- defaults for this one number: `email_document`'s own `p_share_days
  -- default 30`, and `app.issue_share_token`'s
  -- `greatest(coalesce(p_valid_days, 45), 1)`. So passing null through
  -- does not fail and does not produce a null expiry -- it silently
  -- gives the customer a link good for 45 days instead of 30. The
  -- assertion has to be the number.
  -- Its own document, and that is the assertion working rather than
  -- tidiness. The share window was first checked on v_doc, ordered
  -- `created_at desc` to pick the keyed call's link out of the three --
  -- and `now()` DOES NOT MOVE INSIDE A TRANSACTION, so all three links
  -- carry the same `created_at` and the order was whatever the planner
  -- felt like. It kept returning a link minted by an unkeyed send, which
  -- goes through the 7-argument original and gets 30 whatever the wrapper
  -- does. The mutant that passes the null share window straight through
  -- survived that for two rounds.
  --
  -- A document sent ONLY with a key has exactly one link, and it is the
  -- wrapper's.
  --
  -- MEASURED AGAINST THE LINK'S OWN `created_at`, not against today.
  -- It was `expires_at::date - pg_temp.today()`, and that is a date in
  -- UTC minus a date in Kuala Lumpur: true for sixteen hours a day and
  -- short by one for the other eight. It passed every run of this
  -- tranche and first failed at 16:31 UTC, which is 00:31 the next day
  -- in KL -- `expires_at::date` had not moved and `pg_temp.today()`
  -- had. A green run proved nothing about the hour it did not run in.
  --
  -- `created_at` and `expires_at` are both `now()` in the same
  -- transaction and are cast with the same session time zone, so their
  -- difference is exactly the window at any hour. It still separates 30
  -- from the 45 that `app.issue_share_token` falls back to when the
  -- wrapper passes the null through, which is the only thing this
  -- assertion is for.
  v_fresh := pg_temp.an_invoice(v_org, v_contact, 'INV-9');
  perform public.email_document(v_fresh, null, 'document_new', null,
    'queued', null, null, 'SEND-9');
  perform pg_temp.check_eq('a null share window takes the function''s 30 days',
    (select (expires_at::date - created_at::date)
       from public.document_share_links where document_id = v_fresh), 30);

  -- A key reused for a different request is a client bug, not a retry.
  begin
    perform public.email_document(v_doc, 'someone@else.example',
      'document_new', null, 'queued', null, null, 'SEND-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different address is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- email_receipt
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_contact uuid; v_rcp uuid; v_first uuid; v_again uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sendable_org('Receipts Sdn Bhd');
  v_contact := pg_temp.a_customer(v_org, 'C-001');
  insert into public.receipts (org_id, receipt_no, contact_id, amount)
  values (v_org, 'RCP-1', v_contact, 500) returning id into v_rcp;

  perform public.email_receipt(v_rcp);
  perform public.email_receipt(v_rcp);
  perform pg_temp.check_eq('without a key, a receipt is emailed twice too',
    (select count(*)::integer from public.email_outbox where org_id = v_org), 2);

  v_first := public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
    null, null, 'RCP-SEND-1');
  v_again := public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
    null, null, 'RCP-SEND-1');
  perform pg_temp.check_true('a replayed receipt send returns the first id',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and queues nothing the second time',
    (select count(*)::integer from public.email_outbox where org_id = v_org), 3);
end $$;

-- ---------------------------------------------------------------------
-- bulk_email_documents: the first wrapper that returns ROWS
--
-- A replay that returned an empty set would pass any assertion that only
-- counted the outbox, so the rows themselves are asserted.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_contact uuid; v_a uuid; v_b uuid; v_n integer; v_rows integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.sendable_org('Batch Sdn Bhd');
  v_contact := pg_temp.a_customer(v_org, 'C-001');
  v_a := pg_temp.an_invoice(v_org, v_contact, 'INV-1');
  v_b := pg_temp.an_invoice(v_org, v_contact, 'INV-2');

  select count(*) into v_rows
    from public.bulk_email_documents(array[v_a, v_b], 'document_new',
                                     'BATCH-1');
  perform pg_temp.check_eq('a batch send reports a row per document', v_rows, 2);
  select count(*) into v_n from public.email_outbox where org_id = v_org;
  perform pg_temp.check_eq('and queues one message each', v_n::integer, 2);

  select count(*) into v_rows
    from public.bulk_email_documents(array[v_a, v_b], 'document_new',
                                     'BATCH-1');
  perform pg_temp.check_eq('a replayed batch reports the SAME rows, not none',
    v_rows, 2);
  perform pg_temp.check_eq('and queues nothing more',
    (select count(*)::integer from public.email_outbox where org_id = v_org), 2);
  perform pg_temp.check_true('the replayed rows still name the documents',
    (select bool_and(b.id in (v_a, v_b) and b.doc_no is not null)
       from public.bulk_email_documents(array[v_a, v_b], 'document_new',
                                        'BATCH-1') b));
end $$;



-- ---------------------------------------------------------------------
-- assign_ticket: the audit trail is what people read
--
-- No money moves here. What doubles is the ticket's history, which then
-- says the ticket was assigned twice to the same person.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_user uuid; v_ticket uuid;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);
  v_org := pg_temp.test_org('Helpdesk Sdn Bhd');
  -- `tickets_one_requester` wants exactly one of a user or a contact.
  insert into public.tickets
    (org_id, ticket_no, subject, requester_user_id)
  values (v_org, 'T-1', 'The printer again', v_user) returning id into v_ticket;

  perform public.assign_ticket(v_ticket, v_user);
  perform public.assign_ticket(v_ticket, v_user);
  perform pg_temp.check_eq('without a key, the history says it twice',
    (select count(*)::integer from public.ticket_events
      where ticket_id = v_ticket and event_type = 'assigned'), 2);

  perform public.assign_ticket(v_ticket, null, 'ASSIGN-1');
  perform public.assign_ticket(v_ticket, null, 'ASSIGN-1');
  perform pg_temp.check_eq('with one, it says it once',
    (select count(*)::integer from public.ticket_events
      where ticket_id = v_ticket and event_type = 'assigned'
        and to_value is null), 1);
end $$;


-- ---------------------------------------------------------------------
-- The create-or-amend family refuses a second create
--
-- `scripts/check_write_idempotency.py` excuses these eight with a
-- `unique:` verdict naming the index that refuses the duplicate. The
-- gate checks the index still EXISTS; it cannot check that the index
-- still bites, because whether it does depends on where the value in its
-- columns comes from. `save_payment_method` and
-- `create_layout_from_builtin` are excused the same way and
-- `import_sales_transactions` reaches its index through a required
-- argument -- while `create_bank_transfer` has an index of exactly the
-- same shape that does NOT bite, because `next_document_number` mints
-- the value and the second call gets the next one.
--
-- So each verdict is measured here rather than argued: call it twice,
-- creating both times, and expect the refusal. A verdict whose function
-- starts generating its own code instead of taking one fails this.
-- ---------------------------------------------------------------------
create or replace function pg_temp.refuses_a_repeat(p_label text, p_sql text)
returns void language plpgsql as $$
begin
  execute p_sql;
  begin
    execute p_sql;
    raise exception
      'FAIL: % created a second row where a unique index was supposed to '
      'refuse it, and check_write_idempotency.py excuses it on that '
      'basis', p_label;
  exception
    when unique_violation then
      raise notice 'ok   % is refused by its unique index', p_label;
    when others then
      -- Its own refusal, which is just as good and is what
      -- upsert_pos_tender_type does: "The code CSH2 is already Cash
      -- two's." `when others` rather than `when raise_exception`,
      -- because these refusals pick their own SQLSTATE --
      -- close_fiscal_year's "2026 is already closed" is not
      -- raise_exception and went uncaught. The FAIL above is re-raised
      -- so a function that really does double is not swallowed here.
      if sqlerrm like 'FAIL:%' then raise; end if;
      raise notice 'ok   % refuses it in its own words: %', p_label,
        left(sqlerrm, 48);
  end;
end $$;

do $$
declare v_org uuid; v_outlet uuid; v_fy uuid; v_operator uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Upsert Sdn Bhd', array['pos', 'inventory', 'crm']);
  v_fy := public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  select id into v_outlet from public.pos_outlets where org_id = v_org limit 1;
  if v_outlet is null then
    insert into public.pos_outlets (org_id, code, name)
    values (v_org, 'OUT1', 'Outlet') returning id into v_outlet;
  end if;
  insert into public.contacts (org_id, contact_type, code, name)
  values (v_org, 'supplier', 'OP1', 'Operator Sdn Bhd')
  returning id into v_operator;

  perform pg_temp.refuses_a_repeat('upsert_account', format(
    'select public.upsert_account(%L, %L, %L, %L, null, null, false, null, %L)',
    '4999', 'Sundry', 'expense', 'other_expense', v_org));

  perform pg_temp.refuses_a_repeat('upsert_pos_tender_type', format(
    'select public.upsert_pos_tender_type(null, %L, %L, %L, %L, null, null, '
    'true, false, false, 0, true)', v_org, 'CSH2', 'Cash two', 'cash'));

  perform pg_temp.refuses_a_repeat('upsert_pos_stall', format(
    'select public.upsert_pos_stall(null, %L, %L, %L, %L, 0, true)',
    v_outlet, 'ST1', 'Stall one', v_operator));

  perform pg_temp.refuses_a_repeat('upsert_scale_format', format(
    'select public.upsert_scale_format(null, %L, %L, %L, 5, 5, %L, null, true)',
    v_org, 'Weighed', '21', 'price_sen'));

  perform pg_temp.refuses_a_repeat('upsert_pos_modifier_group', format(
    'select public.upsert_pos_modifier_group(%L, %L, %L, 0, 1, null, 0, true, '
    'false)', v_org, 'MG1', 'Sauces'));

  perform pg_temp.refuses_a_repeat('upsert_kitchen_station', format(
    'select public.upsert_kitchen_station(%L, %L, %L, null, 0, false, true)',
    v_outlet, 'KS1', 'Grill'));

  perform pg_temp.refuses_a_repeat('upsert_pos_delivery_zone', format(
    'select public.upsert_pos_delivery_zone(null, %L, %L, null, 0, 0, null, '
    'null, 0, true)', v_outlet, 'Zone A'));

  perform pg_temp.refuses_a_repeat('upsert_budget', format(
    'select public.upsert_budget(null, %L, %L, %L, null, null)',
    v_org, v_fy, 'Budget 1'));

  -- And three of the `state:` verdicts, which are the cheap ones to
  -- stand up. The rest of that batch wants a posted document, a sent
  -- transfer or a hired applicant first, and their verdicts rest on the
  -- gate finding the refusal text in the body rather than on a fixture
  -- here.
  -- NEXT year, because this org already has this one -- the block
  -- created it. `refuses_a_repeat` needs a first call that succeeds.
  perform pg_temp.refuses_a_repeat('create_fiscal_year', format(
    'select public.create_fiscal_year(%L, %L)', v_org,
    (date_trunc('year', pg_temp.today()) + interval '1 year')::date));
  perform pg_temp.refuses_a_repeat('close_fiscal_year',
    format('select public.close_fiscal_year(%L)', v_fy));
  perform pg_temp.refuses_a_repeat('reopen_fiscal_year',
    format('select public.reopen_fiscal_year(%L)', v_fy));
end $$;


-- =====================================================================
-- 0734 :: four ways to pay an invoice twice
--
-- The first tranche where the duplicate is MONEY against a customer's
-- account. Each block does the unguarded double first, because that is
-- what makes the replay assertion mean anything -- and here the double
-- is not hypothetical: it is how these functions behaved until this
-- migration, and the figures below are the ones that were measured.
--
-- Nothing in the schema could have stopped it. There is no unique index
-- on `payment_allocations` and no "already allocated" check, because a
-- receipt may legitimately be applied to the same invoice twice, in two
-- instalments on two days. The database cannot tell that from a retry.
-- =====================================================================

create or replace function pg_temp.money_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100);
  perform pg_temp.test_bank_account(
    v_org, 'Current', 'current', 'MYR', 0, 0, '512345678901');
  return v_org;
end $$;

create or replace function pg_temp.a_posted_invoice(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (p_org, 'invoice', p_no, pg_temp.today(), pg_temp.today(),
          p_contact, 'draft', 'MYR', 1)
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work', 1, p_amount);
  perform public.post_sales_document(v_id);
  return v_id;
end $$;

create or replace function pg_temp.a_receipt(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric)
returns uuid language sql as $$
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (p_org, p_no, pg_temp.today(), p_contact,
          (select id from public.bank_accounts where org_id = p_org limit 1),
          'MYR', 1, p_amount, p_amount)
  returning id;
$$;

-- ---------------------------------------------------------------------
-- allocate_with_discount: the measurement that started this migration
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_cust uuid; v_inv uuid; v_rcp uuid; v_first uuid; v_again uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.money_org('Allocations Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_cust;
  v_inv := pg_temp.a_posted_invoice(v_org, v_cust, 'INV-1', 1000);
  v_rcp := pg_temp.a_receipt(v_org, v_cust, 'RCP-1', 1000);

  -- The defect, as measured: 300 twice takes 600 off a 1,000 invoice.
  perform public.allocate_with_discount(v_rcp, v_inv, 300, 0, pg_temp.today());
  perform public.allocate_with_discount(v_rcp, v_inv, 300, 0, pg_temp.today());
  perform pg_temp.check_eq('without a key, a retry allocates twice',
    (select count(*)::integer from public.payment_allocations
      where receipt_id = v_rcp), 2);
  perform pg_temp.check_eq('and the invoice is 300 further down than asked',
    (select balance_amount from public.sales_documents where id = v_inv),
    400);

  -- With one, the second call returns the first allocation and moves
  -- nothing.
  v_first := public.allocate_with_discount(v_rcp, v_inv, 100, 0,
    pg_temp.today(), 'ALLOC-1');
  v_again := public.allocate_with_discount(v_rcp, v_inv, 100, 0,
    pg_temp.today(), 'ALLOC-1');
  perform pg_temp.check_true('a replayed allocation returns the first one',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and makes no third allocation',
    (select count(*)::integer from public.payment_allocations
      where receipt_id = v_rcp), 3);
  perform pg_temp.check_eq('so the balance moved once, by 100',
    (select balance_amount from public.sales_documents where id = v_inv),
    300);

  -- A different amount under the same key is a client bug, not a retry.
  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 50, 0,
      pg_temp.today(), 'ALLOC-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different amount is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- allocate_payment_with_discount: the purchase side
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_supp uuid; v_bill uuid; v_pay uuid; v_first uuid; v_again uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.money_org('Payments Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'Pembekal', 'supplier') returning id into v_supp;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'bill', 'BILL-1', pg_temp.today(), pg_temp.today(),
          v_supp, 'draft', 'MYR', 1)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 1, 'Stationery', 1, 1000);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (v_org, 'PAY-1', pg_temp.today(), v_supp,
          (select id from public.bank_accounts where org_id = v_org limit 1),
          'MYR', 1, 1000, 1000)
  returning id into v_pay;

  perform public.allocate_payment_with_discount(v_pay, v_bill, 300, 0,
    pg_temp.today());
  perform public.allocate_payment_with_discount(v_pay, v_bill, 300, 0,
    pg_temp.today());
  perform pg_temp.check_eq('the purchase side doubles the same way',
    (select count(*)::integer from public.payment_allocations
      where payment_id = v_pay), 2);

  v_first := public.allocate_payment_with_discount(v_pay, v_bill, 100, 0,
    pg_temp.today(), 'PAY-ALLOC-1');
  v_again := public.allocate_payment_with_discount(v_pay, v_bill, 100, 0,
    pg_temp.today(), 'PAY-ALLOC-1');
  perform pg_temp.check_true('and a replay returns the first allocation',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('without a third',
    (select count(*)::integer from public.payment_allocations
      where payment_id = v_pay), 3);
end $$;

-- ---------------------------------------------------------------------
-- apply_deposit and knock_off
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_cust uuid; v_inv uuid; v_dep uuid; v_cn uuid;
  v_lines jsonb; v_first uuid; v_again uuid; v_n integer; v_again_n integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.money_org('Deposits Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_cust;
  v_inv := pg_temp.a_posted_invoice(v_org, v_cust, 'INV-1', 1000);

  v_dep := public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(),
    500, (select id from public.bank_accounts where org_id = v_org limit 1),
    '02', 'DEP-1', null);

  perform public.apply_deposit(v_dep, v_inv, 100, pg_temp.today());
  perform public.apply_deposit(v_dep, v_inv, 100, pg_temp.today());
  perform pg_temp.check_eq('without a key, a deposit applies twice',
    (select balance_amount from public.sales_documents where id = v_inv),
    800);

  v_first := public.apply_deposit(v_dep, v_inv, 100, pg_temp.today(),
    'DEP-APPLY-1');
  v_again := public.apply_deposit(v_dep, v_inv, 100, pg_temp.today(),
    'DEP-APPLY-1');
  perform pg_temp.check_true('a replayed deposit returns the first one',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and takes 100 off, not 200',
    (select balance_amount from public.sales_documents where id = v_inv),
    700);

  -- knock_off settles a batch and returns how many lines it settled. A
  -- replay must return the SAME COUNT: zero would read as "there was
  -- nothing to settle", which is the opposite of what happened.
  v_cn := pg_temp.a_posted_invoice(v_org, v_cust, 'CN-SRC', 1);
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'credit_note', 'CN-1', pg_temp.today(), pg_temp.today(),
          v_cust, 'draft', 'MYR', 1)
  returning id into v_cn;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_cn, 1, 'item',
          (select id from public.items where org_id = v_org and code = 'SVC'),
          'Credit', 1, 300);
  perform public.post_sales_document(v_cn);

  v_lines := jsonb_build_array(jsonb_build_object(
    'kind', 'credit_note', 'source_id', v_cn, 'invoice_id', v_inv,
    'amount', 50));

  perform public.knock_off(v_cust, v_lines);
  perform public.knock_off(v_cust, v_lines);
  perform pg_temp.check_eq('without a key, a knock-off batch lands twice',
    (select balance_amount from public.sales_documents where id = v_inv),
    600);

  v_n := public.knock_off(v_cust, v_lines, 'KNOCK-1');
  v_again_n := public.knock_off(v_cust, v_lines, 'KNOCK-1');
  perform pg_temp.check_eq('a replayed batch reports the same count', v_n, 1);
  perform pg_temp.check_eq('and not zero, which would read as "nothing to do"',
    v_again_n, 1);
  perform pg_temp.check_eq('and settles 50 once',
    (select balance_amount from public.sales_documents where id = v_inv),
    550);
end $$;


-- =====================================================================
-- 0735 :: a second ticket, a second link, a second transfer
--
-- Four shapes of harm, and the third one is new to this file: what
-- `escalate_ticket` duplicates is not a row but a STEP. It adds one to
-- `escalation_level`, so a retry escalates past the person it was meant
-- to reach and nothing on the ticket says it happened twice.
-- =====================================================================

do $$
declare
  v_org uuid; v_user uuid; v_cust uuid; v_ticket uuid; v_contact_ticket uuid;
  v_first uuid; v_again uuid; v_url text; v_url2 text; v_rep uuid;
  v_b1 uuid; v_b2 uuid; v_inv uuid; v_took boolean;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);
  v_org := pg_temp.test_org('Helpdesk Two Sdn Bhd',
    array['crm', 'ticketing', 'feedback', 'tax']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_cust;

  -- ---- create_ticket ----
  perform public.create_ticket(v_org, 'The printer again', null, null,
    'p3', 'incident', 'web', v_user, null, null);
  perform public.create_ticket(v_org, 'The printer again', null, null,
    'p3', 'incident', 'web', v_user, null, null);
  perform pg_temp.check_eq('without a key, one complaint raises two tickets',
    (select count(*)::integer from public.tickets where org_id = v_org), 2);

  v_first := public.create_ticket(v_org, 'And the scanner', null, null,
    'p3', 'incident', 'web', v_user, null, null, 'TICKET-1');
  v_again := public.create_ticket(v_org, 'And the scanner', null, null,
    'p3', 'incident', 'web', v_user, null, null, 'TICKET-1');
  perform pg_temp.check_true('a replayed complaint returns the first ticket',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and raises no third',
    (select count(*)::integer from public.tickets where org_id = v_org), 3);

  -- ---- escalate_ticket: a step, not a row ----
  v_ticket := v_first;
  perform public.escalate_ticket(v_ticket, 'hierarchic', null, v_user, 'Late');
  perform public.escalate_ticket(v_ticket, 'hierarchic', null, v_user, 'Late');
  perform pg_temp.check_eq('without a key, one escalation counts twice',
    (select escalation_level from public.tickets where id = v_ticket), 2);

  perform public.escalate_ticket(v_ticket, 'hierarchic', null, v_user,
    'Later', 'ESC-1');
  perform public.escalate_ticket(v_ticket, 'hierarchic', null, v_user,
    'Later', 'ESC-1');
  perform pg_temp.check_eq('with one, it counts once', 
    (select escalation_level from public.tickets where id = v_ticket), 3);

  -- ---- share_ticket: a second live token ----
  v_contact_ticket := public.create_ticket(v_org, 'Contact raised', null,
    null, 'p3', 'incident', 'web', null, v_cust, null, 'TICKET-2');
  perform public.share_ticket(v_contact_ticket, 30, 'x@example.test');
  perform public.share_ticket(v_contact_ticket, 30, 'x@example.test');
  perform pg_temp.check_eq('without a key, two links open the same ticket',
    (select count(*)::integer from public.ticket_share_links
      where ticket_id = v_contact_ticket), 2);

  v_url := public.share_ticket(v_contact_ticket, 30, 'y@example.test',
    'SHARE-T-1');
  v_url2 := public.share_ticket(v_contact_ticket, 30, 'y@example.test',
    'SHARE-T-1');
  perform pg_temp.check_true('a replayed share returns the SAME url',
    v_url is not null and v_url2 = v_url);
  perform pg_temp.check_eq('and mints no third token',
    (select count(*)::integer from public.ticket_share_links
      where ticket_id = v_contact_ticket), 3);

  -- ---- share_document ----
  v_inv := pg_temp.a_posted_invoice(v_org, v_cust, 'INV-1', 100);
  perform public.share_document(v_inv, 30, 'x@example.test');
  perform public.share_document(v_inv, 30, 'x@example.test');
  perform pg_temp.check_eq('without a key, two links open the same invoice',
    (select count(*)::integer from public.document_share_links
      where document_id = v_inv), 2);

  v_url := public.share_document(v_inv, 30, 'y@example.test', 'SHARE-D-1');
  v_url2 := public.share_document(v_inv, 30, 'y@example.test', 'SHARE-D-1');
  perform pg_temp.check_true('a replayed document share returns the same url',
    v_url is not null and v_url2 = v_url);
  perform pg_temp.check_eq('and mints no third token',
    (select count(*)::integer from public.document_share_links
      where document_id = v_inv), 3);

  -- ---- report_feedback ----
  perform public.report_feedback('It beeps', 'bug', null, null, null, null,
    v_org);
  perform public.report_feedback('It beeps', 'bug', null, null, null, null,
    v_org);
  perform pg_temp.check_eq('without a key, one complaint files two reports',
    (select count(*)::integer from public.feedback_reports
      where org_id = v_org), 2);

  v_rep := public.report_feedback('It whirrs', 'bug', null, null, null, null,
    v_org, 'FEEDBACK-1');
  perform pg_temp.check_true('a replayed report returns the first',
    public.report_feedback('It whirrs', 'bug', null, null, null, null,
      v_org, 'FEEDBACK-1') = v_rep);
  perform pg_temp.check_eq('and files no third',
    (select count(*)::integer from public.feedback_reports
      where org_id = v_org), 3);

  -- ---- create_bank_transfer ----
  perform pg_temp.test_bank_account(v_org, 'A', 'current', 'MYR', 5000, 5000,
    '111');
  perform pg_temp.test_bank_account(v_org, 'B', 'current', 'MYR', 0, 0, '222');
  select id into v_b1 from public.bank_accounts
   where org_id = v_org and name = 'A';
  select id into v_b2 from public.bank_accounts
   where org_id = v_org and name = 'B';

  perform public.create_bank_transfer(v_b1, v_b2, 100, pg_temp.today(),
    null, 0, null, null);
  perform public.create_bank_transfer(v_b1, v_b2, 100, pg_temp.today(),
    null, 0, null, null);
  perform pg_temp.check_eq('without a key, one transfer is drawn up twice',
    (select count(*)::integer from public.bank_transfers where org_id = v_org),
    2);

  v_first := public.create_bank_transfer(v_b1, v_b2, 200, pg_temp.today(),
    null, 0, null, null, 'XFER-1');
  v_again := public.create_bank_transfer(v_b1, v_b2, 200, pg_temp.today(),
    null, 0, null, null, 'XFER-1');
  perform pg_temp.check_true('a replayed transfer returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and draws up no third',
    (select count(*)::integer from public.bank_transfers where org_id = v_org),
    3);

  -- And the fingerprint still refuses a different amount under that key.
  begin
    perform public.create_bank_transfer(v_b1, v_b2, 999, pg_temp.today(),
      null, 0, null, null, 'XFER-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different amount is refused',
    not v_took);
end $$;


-- =====================================================================
-- 0736 :: the POS back office, and a double handful of points
--
-- Five create-or-amend functions with NO unique index behind them -- a
-- forecast line, a driver, a saved report, a schedule and a promotion are
-- all things a company may legitimately have two of with the same name,
-- so nothing can tell a second create from a dropped connection -- and
-- `adjust_loyalty_points`, where what doubles is a BALANCE.
-- =====================================================================

do $$
declare
  v_org uuid; v_outlet uuid; v_cust uuid; v_prog uuid; v_acct uuid;
  v_first uuid; v_again uuid; v_n integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Back Office Sdn Bhd',
    array['pos', 'inventory', 'crm', 'loyalty', 'cashflow', 'payroll']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  select id into v_outlet from public.pos_outlets where org_id = v_org limit 1;
  if v_outlet is null then
    insert into public.pos_outlets (org_id, code, name)
    values (v_org, 'OUT1', 'Outlet') returning id into v_outlet;
  end if;

  -- ---- upsert_cash_forecast_item ----
  perform public.upsert_cash_forecast_item(null, v_org, 'in', 'A grant', 100,
    pg_temp.today(), 'once', null, null);
  perform public.upsert_cash_forecast_item(null, v_org, 'in', 'A grant', 100,
    pg_temp.today(), 'once', null, null);
  perform pg_temp.check_eq('without a key, the forecast has the line twice',
    (select count(*)::integer from public.cash_forecast_items
      where org_id = v_org), 2);

  v_first := public.upsert_cash_forecast_item(null, v_org, 'in', 'A refund',
    50, pg_temp.today(), 'once', null, null, 'FORECAST-1');
  v_again := public.upsert_cash_forecast_item(null, v_org, 'in', 'A refund',
    50, pg_temp.today(), 'once', null, null, 'FORECAST-1');
  perform pg_temp.check_true('a replayed save returns the first line',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and adds no third',
    (select count(*)::integer from public.cash_forecast_items
      where org_id = v_org), 3);

  -- ---- upsert_pos_driver ----
  perform public.upsert_pos_driver(null, v_org, 'Pak Ali', null, null, null,
    v_outlet, null, true);
  perform public.upsert_pos_driver(null, v_org, 'Pak Ali', null, null, null,
    v_outlet, null, true);
  perform pg_temp.check_eq('without a key, two drivers of one name',
    (select count(*)::integer from public.pos_drivers where org_id = v_org), 2);

  v_first := public.upsert_pos_driver(null, v_org, 'Pak Samad', null, null,
    null, v_outlet, null, true, 'DRIVER-1');
  v_again := public.upsert_pos_driver(null, v_org, 'Pak Samad', null, null,
    null, v_outlet, null, true, 'DRIVER-1');
  perform pg_temp.check_true('a replayed driver returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and hires no third',
    (select count(*)::integer from public.pos_drivers where org_id = v_org), 3);

  -- The fingerprint, which is what tells a retry from a second driver.
  -- Without this assertion a wrapper that fingerprinted the id alone --
  -- null on every create -- passed everything above, because both keyed
  -- calls here send the same arguments. The mutant that did exactly that
  -- survived two rounds.
  declare v_took boolean;
  begin
    begin
      perform public.upsert_pos_driver(null, v_org, 'Pak Hassan', null, null,
        null, v_outlet, null, true, 'DRIVER-1');
      v_took := true;
    exception when sqlstate '22023' then v_took := false;
    end;
    perform pg_temp.check_true(
      'the same key for a different driver is refused', not v_took);
  end;

  -- ---- upsert_pos_report ----
  perform public.upsert_pos_report(v_org, 'Daily takings', 'sales',
    array['outlet'], array['net'], 'today', null, null, null, null, null,
    false, null, false, null);
  perform public.upsert_pos_report(v_org, 'Daily takings', 'sales',
    array['outlet'], array['net'], 'today', null, null, null, null, null,
    false, null, false, null);
  perform pg_temp.check_eq('without a key, two saved reports',
    (select count(*)::integer from public.pos_reports where org_id = v_org), 2);

  v_first := public.upsert_pos_report(v_org, 'By channel', 'sales',
    array['channel'], array['net'], 'today', null, null, null, null, null,
    false, null, false, null, 'REPORT-1');
  v_again := public.upsert_pos_report(v_org, 'By channel', 'sales',
    array['channel'], array['net'], 'today', null, null, null, null, null,
    false, null, false, null, 'REPORT-1');
  perform pg_temp.check_true('a replayed report returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and saves no third',
    (select count(*)::integer from public.pos_reports where org_id = v_org), 3);

  -- ---- upsert_pos_menu_schedule ----
  perform public.upsert_pos_menu_schedule(v_org, 'Breakfast', null, null,
    null, null, null, null, null, true);
  perform public.upsert_pos_menu_schedule(v_org, 'Breakfast', null, null,
    null, null, null, null, null, true);
  perform pg_temp.check_eq('without a key, two live schedules',
    (select count(*)::integer from public.pos_menu_schedules
      where org_id = v_org), 2);

  v_first := public.upsert_pos_menu_schedule(v_org, 'Supper', null, null,
    null, null, null, null, null, true, 'SCHEDULE-1');
  v_again := public.upsert_pos_menu_schedule(v_org, 'Supper', null, null,
    null, null, null, null, null, true, 'SCHEDULE-1');
  perform pg_temp.check_true('a replayed schedule returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and adds no third',
    (select count(*)::integer from public.pos_menu_schedules
      where org_id = v_org), 3);

  -- ---- upsert_pos_promotion ----
  perform public.upsert_pos_promotion(v_org, 'Ten off', 'percent_off', null,
    10, null, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, true);
  perform public.upsert_pos_promotion(v_org, 'Ten off', 'percent_off', null,
    10, null, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, true);
  perform pg_temp.check_eq('without a key, two promotions both running',
    (select count(*)::integer from public.pos_promotions where org_id = v_org),
    2);

  v_first := public.upsert_pos_promotion(v_org, 'Five off', 'percent_off',
    null, 5, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, null, true, 'PROMO-1');
  v_again := public.upsert_pos_promotion(v_org, 'Five off', 'percent_off',
    null, 5, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, null, true, 'PROMO-1');
  perform pg_temp.check_true('a replayed promotion returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and starts no third',
    (select count(*)::integer from public.pos_promotions where org_id = v_org),
    3);

  -- ---- adjust_loyalty_points: a balance, not a row ----
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_cust;
  insert into public.loyalty_programs (org_id, code, name)
  values (v_org, 'LP1', 'Points') returning id into v_prog;
  v_acct := public.enrol_loyalty_member(v_cust, null);

  perform public.adjust_loyalty_points(v_acct, 50, 'A goodwill');
  perform public.adjust_loyalty_points(v_acct, 50, 'A goodwill');
  perform pg_temp.check_eq('without a key, 50 points credit 100',
    app.loyalty_balance(v_acct), 100);

  -- It returns the BALANCE, not the adjustment, so the replay must hand
  -- back the same balance -- which is also the only way to tell a replay
  -- from a second credit by looking at the return value alone.
  v_n := public.adjust_loyalty_points(v_acct, 25, 'Another', 'POINTS-1');
  perform pg_temp.check_eq('a replayed adjustment returns the same balance',
    public.adjust_loyalty_points(v_acct, 25, 'Another', 'POINTS-1'), v_n);
  perform pg_temp.check_eq('so the balance is 125, not 150',
    app.loyalty_balance(v_acct), 125);

  -- And the two that were measured as safe, kept as assertions because a
  -- verdict the gate checks by TEXT is weaker than one it checks by
  -- behaviour.
  perform pg_temp.check_eq('enrol_loyalty_member returns the same account',
    public.enrol_loyalty_member(v_cust, null), v_acct);
  perform public.set_module_hidden(v_org, 'payroll', true);
  perform public.set_module_hidden(v_org, 'payroll', true);
  perform pg_temp.check_eq('and set_module_hidden leaves one row',
    (select count(*)::integer from public.org_modules
      where org_id = v_org and module_code = 'payroll'), 1);
end $$;




-- =====================================================================
-- 0737 :: four statutory papers, and a refund paid twice
--
-- The tranche where the duplicate is a document somebody ELSE holds, and
-- the first where it is money leaving a bank account. Each block makes
-- the duplicate happen first -- `0733`'s lesson, after two wrappers were
-- written for functions a unique index was already refusing -- and then
-- asserts the key stops it and that the key covers the ARGUMENTS, which
-- is `0736`'s lesson after a mutant lived on two identical calls.
-- =====================================================================

-- ---------------------------------------------------------------------
-- settle_deposit: 600 out of the bank for a 300 refund
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_c uuid; v_bank uuid; v_dep uuid; v_keyed uuid;
  v_first uuid; v_again uuid; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Deposits Twice Sdn Bhd',
    array['sales', 'purchases']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  perform pg_temp.test_bank_account(v_org, 'Current', 'current', 'MYR',
    9000, 9000, '7700001');
  select id into v_bank from public.bank_accounts where org_id = v_org limit 1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_c;

  insert into public.deposit_notes
    (org_id, deposit_no, deposit_date, kind, status, contact_id, currency,
     exchange_rate, amount, bank_account_id, balance_amount)
  values (v_org, 'DEP-1', pg_temp.today(), 'customer', 'open', v_c, 'MYR', 1,
          1000, v_bank, 1000) returning id into v_dep;

  -- The defect, as measured. A PARTIAL refund: the balance guard the
  -- function already has catches only a full settlement, and 300 twice
  -- is inside 1,000 both times.
  perform public.settle_deposit(v_dep, 'refund', 300, null, v_bank,
    pg_temp.today());
  perform public.settle_deposit(v_dep, 'refund', 300, null, v_bank,
    pg_temp.today());
  perform pg_temp.check_eq(
    'without a key, a 300 refund takes 600 off the deposit',
    (select balance_amount from public.deposit_notes where id = v_dep), 400);
  perform pg_temp.check_eq('and the note carries two events',
    (select count(*)::integer from public.deposit_events
      where deposit_id = v_dep), 2);

  -- With one.
  insert into public.deposit_notes
    (org_id, deposit_no, deposit_date, kind, status, contact_id, currency,
     exchange_rate, amount, bank_account_id, balance_amount)
  values (v_org, 'DEP-2', pg_temp.today(), 'customer', 'open', v_c, 'MYR', 1,
          1000, v_bank, 1000) returning id into v_keyed;

  v_first := public.settle_deposit(
    p_deposit := v_keyed, p_kind := 'refund', p_amount := 300,
    p_reason := null, p_bank := v_bank, p_date := pg_temp.today(),
    p_idempotency_key := 'DEP-REFUND-1');
  v_again := public.settle_deposit(
    p_deposit := v_keyed, p_kind := 'refund', p_amount := 300,
    p_reason := null, p_bank := v_bank, p_date := pg_temp.today(),
    p_idempotency_key := 'DEP-REFUND-1');
  perform pg_temp.check_true('a replayed refund returns the first entry',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and takes 300 off once',
    (select balance_amount from public.deposit_notes where id = v_keyed), 700);
  perform pg_temp.check_eq('and records one event',
    (select count(*)::integer from public.deposit_events
      where deposit_id = v_keyed), 1);

  -- The fingerprint covers the AMOUNT, not just the deposit. Two
  -- identical calls cannot prove that; a different amount under the same
  -- key is what proves it.
  begin
    perform public.settle_deposit(
      p_deposit := v_keyed, p_kind := 'refund', p_amount := 400,
      p_reason := null, p_bank := v_bank, p_date := pg_temp.today(),
      p_idempotency_key := 'DEP-REFUND-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different amount is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- create_withholding: a second certificate with its own LHDN deadline
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_sup uuid; v_bill uuid; v_code text; v_first uuid;
  v_again uuid; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Withhold Twice Sdn Bhd',
    array['purchases', 'tax']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'Pembekal', 'supplier') returning id into v_sup;
  select code into v_code from public.ref_withholding_types
   where is_active order by code limit 1;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'bill', 'BILL-1', pg_temp.today(), pg_temp.today(), v_sup,
          'draft', 'MYR', 1) returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item',
          (select id from public.items where org_id = v_org and code = 'SVC'),
          'Royalty', 1, 10000);
  perform public.post_purchase_document(v_bill);

  -- The defect: the certificate does not touch the bill's balance, so
  -- the over-withholding guard is as happy the second time as the first.
  perform public.create_withholding(v_bill, v_code, null, null, null);
  perform public.create_withholding(v_bill, v_code, null, null, null);
  perform pg_temp.check_eq('without a key, one bill gets two certificates',
    (select count(*)::integer from public.withholding_certificates
      where bill_id = v_bill), 2);
  perform pg_temp.check_eq('with two different numbers',
    (select count(distinct certificate_no)::integer
       from public.withholding_certificates where bill_id = v_bill), 2);

  v_first := public.create_withholding(
    p_bill_id := v_bill, p_wht_code := v_code, p_gross_amount := 1000,
    p_rate := null, p_cert_date := null,
    p_idempotency_key := 'WHT-1');
  v_again := public.create_withholding(
    p_bill_id := v_bill, p_wht_code := v_code, p_gross_amount := 1000,
    p_rate := null, p_cert_date := null,
    p_idempotency_key := 'WHT-1');
  perform pg_temp.check_true('a replayed certificate returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and raises no third',
    (select count(*)::integer from public.withholding_certificates
      where bill_id = v_bill), 3);

  begin
    perform public.create_withholding(
      p_bill_id := v_bill, p_wht_code := v_code, p_gross_amount := 2000,
      p_rate := null, p_cert_date := null,
      p_idempotency_key := 'WHT-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true(
    'the same key for a different gross amount is refused', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- revise_tax_estimate: two live CP204 revisions of one estimate
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_fy uuid; v_est uuid; v_keyed uuid; v_first uuid;
  v_again uuid; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Estimates Twice Sdn Bhd', array['tax']);
  v_fy := public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  v_est := public.open_tax_estimate(v_org, v_fy, 50000, null);

  perform public.revise_tax_estimate(v_est, 60000);
  perform public.revise_tax_estimate(v_est, 60000);
  perform pg_temp.check_eq('without a key, one revision is filed twice',
    (select count(*)::integer from public.tax_estimates
      where revises_id = v_est), 2);
  -- And both are live. Only the ORIGINAL was superseded, because the
  -- second call superseded the same row the first one did.
  perform pg_temp.check_eq('and both revisions are current',
    (select count(*)::integer from public.tax_estimates
      where revises_id = v_est and status <> 'superseded'), 2);

  v_keyed := public.open_tax_estimate(v_org, v_fy, 70000, null);
  v_first := public.revise_tax_estimate(
    p_estimate_id := v_keyed, p_estimated_tax := 80000,
    p_idempotency_key := 'CP204-REV-1');
  v_again := public.revise_tax_estimate(
    p_estimate_id := v_keyed, p_estimated_tax := 80000,
    p_idempotency_key := 'CP204-REV-1');
  perform pg_temp.check_true('a replayed revision returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and files no second',
    (select count(*)::integer from public.tax_estimates
      where revises_id = v_keyed), 1);

  begin
    perform public.revise_tax_estimate(
      p_estimate_id := v_keyed, p_estimated_tax := 90000,
      p_idempotency_key := 'CP204-REV-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different figure is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- submit_leave_request: two requests, and four days off a balance
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_user uuid; v_emp uuid; v_type uuid; v_first uuid;
  v_again uuid; v_took boolean;
  -- The day the leave below is counted from. Today, unless thirty days
  -- on is next year -- then 1 January, so every request falls in ONE
  -- leave year and the one balance below is the one they draw on. From
  -- early December they used to straddle two, and the second year had
  -- no entitlement (measured under a shifted clock: "Only -2.00 day(s)
  -- of Annual remain").
  v_base date := case
    when extract(year from pg_temp.today() + 30)
         = extract(year from pg_temp.today()) then pg_temp.today()
    else date_trunc('year', pg_temp.today() + 30)::date end;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);
  v_org := pg_temp.test_org('Leave Twice Sdn Bhd', array['hr', 'payroll']);
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, employment_status)
  values (v_org, 'E1', 'Pekerja', v_user, pg_temp.today() - 400, 'active')
  returning id into v_emp;
  insert into public.leave_types (org_id, code, name, is_paid, default_days)
  values (v_org, 'AL', 'Annual', true, 20) returning id into v_type;
  -- An entitlement, deliberately. WITHOUT one the balance is zero and the
  -- second request is refused for want of days -- which would look like
  -- a state guard and is nothing of the kind. The first probe of this
  -- function was green for that reason and proved nothing.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days)
  values (v_org, v_emp, v_type,
          extract(year from v_base)::integer, 20);

  perform public.submit_leave_request(v_org, v_type, v_base + 10,
    v_base + 11, 2, 'Trip', false, null, v_emp, null);
  perform public.submit_leave_request(v_org, v_type, v_base + 10,
    v_base + 11, 2, 'Trip', false, null, v_emp, null);
  perform pg_temp.check_eq('without a key, one request is filed twice',
    (select count(*)::integer from public.leave_requests
      where employee_id = v_emp), 2);
  -- The half nobody would see. Deleting the duplicate request does not
  -- put these two days back.
  perform pg_temp.check_eq(
    'and four days are pending against a two-day request',
    (select pending_days from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_type), 4);

  v_first := public.submit_leave_request(
    p_org_id := v_org, p_leave_type_id := v_type,
    p_start_date := v_base + 20, p_end_date := v_base + 21,
    p_total_days := 2, p_reason := 'Again', p_is_half_day := false,
    p_half_day_period := null, p_employee_id := v_emp,
    p_contact_while_away := null, p_idempotency_key := 'LEAVE-1');
  v_again := public.submit_leave_request(
    p_org_id := v_org, p_leave_type_id := v_type,
    p_start_date := v_base + 20, p_end_date := v_base + 21,
    p_total_days := 2, p_reason := 'Again', p_is_half_day := false,
    p_half_day_period := null, p_employee_id := v_emp,
    p_contact_while_away := null, p_idempotency_key := 'LEAVE-1');
  perform pg_temp.check_true('a replayed request returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and files no third',
    (select count(*)::integer from public.leave_requests
      where employee_id = v_emp), 3);
  perform pg_temp.check_eq('and the balance moves by two, not four',
    (select pending_days from public.leave_balances
      where employee_id = v_emp and leave_type_id = v_type), 6);

  begin
    perform public.submit_leave_request(
      p_org_id := v_org, p_leave_type_id := v_type,
      p_start_date := v_base + 20, p_end_date := v_base + 22,
      p_total_days := 3, p_reason := 'Again', p_is_half_day := false,
      p_half_day_period := null, p_employee_id := v_emp,
      p_contact_while_away := null, p_idempotency_key := 'LEAVE-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a longer trip is refused',
    not v_took);

  -- AND ONE WHERE ONLY `total_days` MOVES. The assertion above varies the
  -- end date as well, so `end_date` in the fingerprint kills it on its
  -- own: the mutant that drops `total_days` SURVIVED that assertion and
  -- is killed by this one. Same two days, half a day claimed against
  -- them -- which is a correction somebody really does make, and under a
  -- retried key it would be silently ignored.
  begin
    perform public.submit_leave_request(
      p_org_id := v_org, p_leave_type_id := v_type,
      p_start_date := v_base + 20, p_end_date := v_base + 21,
      p_total_days := 1.5, p_reason := 'Again', p_is_half_day := false,
      p_half_day_period := null, p_employee_id := v_emp,
      p_contact_while_away := null, p_idempotency_key := 'LEAVE-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true(
    'the same key for the same days but a different count is refused',
    not v_took);

  -- `p_is_half_day` is the one argument whose default is FALSE and not
  -- null, and `leave_requests.is_half_day` is NOT NULL. A wrapper that
  -- passed the null straight through would raise 23502 on a caller who
  -- omitted the flag -- which is every caller before 0737. This is the
  -- assertion for the `coalesce(p_is_half_day, false)` inside it; without
  -- it the coalesce could be deleted and nothing here would notice,
  -- because every other call in this block sends a real boolean.
  v_first := public.submit_leave_request(
    p_org_id := v_org, p_leave_type_id := v_type,
    p_start_date := v_base + 30, p_end_date := v_base + 30,
    p_total_days := 1, p_reason := 'Whole day', p_is_half_day := null,
    p_half_day_period := null, p_employee_id := v_emp,
    p_contact_while_away := null, p_idempotency_key := 'LEAVE-WHOLE-DAY');
  perform pg_temp.check_true(
    'a null half-day flag files a whole day rather than raising',
    (select not is_half_day from public.leave_requests where id = v_first));
end $$;

-- ---------------------------------------------------------------------
-- 0737's eight verdicts, measured
--
-- Five refuse by name, so `refuses_a_repeat` is enough. Three do not
-- raise at all -- they return early or find nothing left to do -- and a
-- silent repeat can only be caught by counting, which is what the last
-- three assertions do.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_c uuid; v_bank uuid; v_pdc uuid; v_user uuid;
  v_from uuid; v_to uuid; v_item uuid; v_tr uuid; v_m uuid; v_p uuid;
  v_ticket uuid; v_inv uuid; v_line uuid; v_rev uuid; v_run uuid;
  v_n integer;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);
  v_org := pg_temp.test_org('Verdicts 0737 Sdn Bhd',
    array['sales', 'purchases', 'inventory', 'legal', 'timesheets',
          'ticketing', 'crm', 'fixed_assets', 'accounting']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  -- Things below are dated yesterday, which on 1 January is last year.
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  perform pg_temp.test_bank_account(v_org, 'Current', 'current', 'MYR',
    9000, 9000, '7700002');
  select id into v_bank from public.bank_accounts where org_id = v_org limit 1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_c;

  -- clear_pdc and bounce_pdc: the first call moves `status` out of
  -- ('held','deposited') and the guard is on that set.
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, status, contact_id, cheque_no, cheque_date,
     amount, bank_account_id)
  values (v_org, 'PDC-1', 'incoming', 'held', v_c, '100001',
          pg_temp.today(), 500, v_bank) returning id into v_pdc;
  perform pg_temp.refuses_a_repeat('clear_pdc', format(
    'select public.clear_pdc(%L, %L, %L)', v_pdc, pg_temp.today(), v_bank));

  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, status, contact_id, cheque_no, cheque_date,
     amount, bank_account_id)
  values (v_org, 'PDC-2', 'incoming', 'held', v_c, '100002',
          pg_temp.today(), 500, v_bank) returning id into v_pdc;
  perform pg_temp.refuses_a_repeat('bounce_pdc', format(
    'select public.bounce_pdc(%L, %L, %L)', v_pdc, 'No funds',
    pg_temp.today()));

  -- receive_stock_transfer: `status <> 'sent'` after the first receipt.
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'WH1', 'Utama', true) returning id into v_from;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'WH2', 'Cawangan') returning id into v_to;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price, cost_price)
  values (v_org, 'ITM', 'Barang', 'stock', true, 50, 20)
  returning id into v_item;
  insert into public.stock_transfers
    (org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id,
     status)
  values (v_org, 'TR-1', pg_temp.today(), v_from, v_to, 'sent')
  returning id into v_tr;
  insert into public.stock_transfer_lines
    (org_id, transfer_id, line_no, item_id, quantity, uom_code,
     sent_quantity, sent_unit_cost)
  values (v_org, v_tr, 1, v_item, 10, 'C62', 10, 20);
  perform pg_temp.refuses_a_repeat('receive_stock_transfer', format(
    'select public.receive_stock_transfer(%L, %L::jsonb)', v_tr, '[]'));

  -- bill_matter_time and bill_project_time: the first call sets
  -- `is_billed`, and the "no unbilled time" check runs BEFORE the
  -- invoice is inserted, so the second writes nothing at all.
  insert into public.matters
    (org_id, matter_no, name, client_id, hourly_rate,
     responsible_solicitor, fee_earner)
  values (v_org, 'M-1', 'Perbicaraan', v_c, 400, v_user, v_user)
  returning id into v_m;
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_m, v_user, pg_temp.today(), 'Drafting', 120, 400, 800,
          true, false);
  perform pg_temp.refuses_a_repeat('bill_matter_time', format(
    'select public.bill_matter_time(%L, %L, %L, null)', v_m,
    pg_temp.today() - 1, pg_temp.today()));

  insert into public.projects (org_id, code, name, contact_id)
  values (v_org, 'P-1', 'Projek', v_c) returning id into v_p;
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_p, v_user, pg_temp.today(), 'Build', 120, 300, 600,
          true, false);
  perform pg_temp.refuses_a_repeat('bill_project_time', format(
    'select public.bill_project_time(%L, %L, %L, null)', v_p,
    pg_temp.today() - 1, pg_temp.today()));

  -- transition_ticket: `if v_t.status = p_to then return` -- no raise, so
  -- only a count says the second call wrote nothing.
  v_ticket := public.create_ticket(v_org, 'The printer', null, null, 'p3',
    'incident', 'web', v_user, null, null);
  perform public.transition_ticket(v_ticket, 'pending'::app.ticket_status,
    'note');
  perform public.transition_ticket(v_ticket, 'pending'::app.ticket_status,
    'note');
  select count(*)::integer into v_n from public.ticket_events
   where ticket_id = v_ticket and event_type = 'status';
  perform pg_temp.check_eq(
    'transition_ticket to the status it is already in writes no event',
    v_n, 1);

  -- recognise_revenue: walks periods WHERE gl_entry_id IS NULL and fills
  -- that column in, so the second sweep finds nothing.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'invoice', 'INV-R', pg_temp.today(), pg_temp.today(), v_c,
          'draft', 'MYR', 1) returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Retainer', 1, 1200)
  returning id into v_line;
  perform public.post_sales_document(v_inv);
  select id into v_rev from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group
   limit 1;
  insert into public.revenue_schedule_periods
    (org_id, document_id, line_id, revenue_account_id, period_end, amount)
  values (v_org, v_inv, v_line, v_rev, pg_temp.today() - 1, 100);
  perform pg_temp.check_eq('recognise_revenue releases one period',
    public.recognise_revenue(v_org, pg_temp.today()), 1);
  perform pg_temp.check_eq('and a second sweep releases none',
    public.recognise_revenue(v_org, pg_temp.today()), 0);

  -- run_depreciation: the charge is the gap between where the asset
  -- should be and where it is, which is zero on a retry at the same
  -- date; the function then deletes the empty run it opened.
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months, status)
  values (v_org, 'FA-1', 'Van', pg_temp.today() - 400, 12000, 0,
          'straight_line', 60, 'active');
  v_run := public.run_depreciation(v_org, pg_temp.today());
  perform pg_temp.check_true('run_depreciation posts a run', v_run is not null);
  perform pg_temp.check_true('and a retry at the same date posts none',
    public.run_depreciation(v_org, pg_temp.today()) is null);
  perform pg_temp.check_eq('leaving one run, not two',
    (select count(*)::integer from public.depreciation_runs
      where org_id = v_org), 1);
end $$;




-- =====================================================================
-- 0738 :: the last eight, and the key that was already there
--
-- The tranche that takes the census to ZERO. Each wrapper block makes the
-- duplicate happen first, then asserts the key stops it, then varies
-- EXACTLY ONE field of the payload under the same key -- 0737's lesson,
-- after a mutant lived because the assertion meant to catch it moved two
-- fields at once.
-- =====================================================================

-- Two fixtures, built once and used by several blocks below.
create or replace function pg_temp.shop_0738(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name); v_wh uuid; v_c uuid; v_o uuid;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos', 'accounting', 'inventory',
    'memberships']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'W', 'Store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type,
    credit_limit, credit_hold)
  values (v_org, 'REG', 'Encik Zaid', 'customer', 5000, false)
  returning id into v_c;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KOPI', 'Kopi', 'service', false, 'C62', 5.00),
         (v_org, 'GYM', 'Keahlian', 'service', false, 'C62', 100.00);
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'K', 'Kedai', 'retail', v_wh, v_c, false)
  returning id into v_o;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_o, 'C1', 'Counter');
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, false);
  perform pg_temp.a_till(v_org);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true);
  perform public.open_pos_shift(
    (select id from public.pos_registers where org_id = v_org), 100.00);
  insert into public.pos_memberships
    (org_id, code, name, item_id, period, sessions_included, is_active)
  values (v_org, 'M1', 'Bulanan',
    (select id from public.items where org_id = v_org and code = 'GYM'),
    'monthly', 10, true);
  insert into public.pos_tables (org_id, outlet_id, code, name)
  values (v_org, v_o, 'T1', 'Meja 1');
  return v_org;
end $$;

create or replace function pg_temp.a_bill_0738(p_org uuid, p_no text)
returns uuid language plpgsql as $$
declare v_sup uuid; v_id uuid;
begin
  select id into v_sup from public.contacts
   where org_id = p_org and contact_type = 'supplier' limit 1;
  if v_sup is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'S-REC', 'Tuan Rumah', 'supplier') returning id into v_sup;
  end if;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (p_org, 'bill', p_no, pg_temp.today(), pg_temp.today(), v_sup,
          'draft', 'MYR', 1) returning id into v_id;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org limit 1),
          'Sewa', 1, 1000);
  perform public.post_purchase_document(v_id);
  return v_id;
end $$;

create or replace function pg_temp.inv_0738(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name,
  array['inventory', 'purchases', 'accounting', 'forecasting']);
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'W', 'Store', true);
  insert into public.items (org_id, code, name, item_type, track_inventory,
    uom_code, unit_price, cost_price)
  values (v_org, 'ITM', 'Barang', 'stock', true, 'C62', 50, 20),
         (v_org, 'OUT', 'Keluaran', 'stock', true, 'C62', 10, 5);
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- create_recurring_document: a machine that bills twice a month for ever
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_c uuid; v_inv uuid; v_second uuid; v_first uuid;
  v_again uuid; v_took boolean; v_bill uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Recurring Twice Sdn Bhd',
    array['sales', 'accounting']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.items (org_id, code, name, item_type, track_inventory,
    unit_price) values (v_org, 'SVC', 'Service', 'service', false, 100);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_c;
  v_inv := pg_temp.a_posted_invoice(v_org, v_c, 'INV-1', 100);

  perform public.create_recurring_document(v_inv, 'Bulanan', 'monthly',
    pg_temp.today(), 1, null, null, false, false);
  perform public.create_recurring_document(v_inv, 'Bulanan', 'monthly',
    pg_temp.today(), 1, null, null, false, false);
  perform pg_temp.check_eq(
    'without a key, one schedule is set up twice',
    (select count(*)::integer from public.recurring_documents
      where org_id = v_org), 2);
  -- Both live, which is what makes this the worst of the thirty: it goes
  -- on producing a second invoice every month until somebody notices.
  perform pg_temp.check_eq('and both are active',
    (select count(*)::integer from public.recurring_documents
      where org_id = v_org and is_active), 2);

  v_second := pg_temp.a_posted_invoice(v_org, v_c, 'INV-2', 100);
  v_first := public.create_recurring_document(
    p_document_id := v_second, p_name := 'Bulanan', p_frequency := 'monthly',
    p_start_date := pg_temp.today(), p_interval_count := 1,
    p_end_date := null, p_max_occurrences := null, p_auto_post := false,
    p_auto_email := false, p_idempotency_key := 'REC-1');
  v_again := public.create_recurring_document(
    p_document_id := v_second, p_name := 'Bulanan', p_frequency := 'monthly',
    p_start_date := pg_temp.today(), p_interval_count := 1,
    p_end_date := null, p_max_occurrences := null, p_auto_post := false,
    p_auto_email := false, p_idempotency_key := 'REC-1');
  perform pg_temp.check_true('a replayed set-up returns the first schedule',
    v_first is not null and v_again = v_first);
  -- `recurring_documents` keeps no document_id: the schedule carries a
  -- `template` snapshotted from the document it was made from. Counted by
  -- name instead, which is what distinguishes the two set-ups here.
  perform pg_temp.check_eq('and sets up no second',
    (select count(*)::integer from public.recurring_documents
      where org_id = v_org and id = v_first), 1);
  perform pg_temp.check_eq('leaving three schedules, not four',
    (select count(*)::integer from public.recurring_documents
      where org_id = v_org), 3);

  -- One field, and the one that would change what the customer is billed.
  begin
    perform public.create_recurring_document(
      p_document_id := v_second, p_name := 'Bulanan',
      p_frequency := 'quarterly', p_start_date := pg_temp.today(),
      p_interval_count := 1, p_end_date := null, p_max_occurrences := null,
      p_auto_post := false, p_auto_email := false,
      p_idempotency_key := 'REC-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true(
    'the same key for a different frequency is refused', not v_took);

  -- A RECURRING BILL, not an invoice. The wrapper reads the organization
  -- from sales_documents and then from purchase_documents, in the order
  -- the inner function tries them, and until this assertion existed the
  -- mutant that deleted the second lookup SURVIVED: the key was simply
  -- never claimed for a bill and nothing noticed.
  perform pg_temp.a_bill_0738(v_org, 'BILL-REC');
  select d.id into v_bill from public.purchase_documents d
   where d.org_id = v_org and d.doc_no = 'BILL-REC';
  v_first := public.create_recurring_document(
    p_document_id := v_bill, p_name := 'Sewa pejabat',
    p_frequency := 'monthly', p_start_date := pg_temp.today(),
    p_interval_count := 1, p_end_date := null, p_max_occurrences := null,
    p_auto_post := false, p_auto_email := false,
    p_idempotency_key := 'REC-BILL-1');
  v_again := public.create_recurring_document(
    p_document_id := v_bill, p_name := 'Sewa pejabat',
    p_frequency := 'monthly', p_start_date := pg_temp.today(),
    p_interval_count := 1, p_end_date := null, p_max_occurrences := null,
    p_auto_post := false, p_auto_email := false,
    p_idempotency_key := 'REC-BILL-1');
  perform pg_temp.check_true(
    'a replayed recurring BILL returns the first schedule too',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('leaving four schedules, not five',
    (select count(*)::integer from public.recurring_documents
      where org_id = v_org), 4);
end $$;

-- ---------------------------------------------------------------------
-- run_item_conversion: the first physical quantity to double
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_in uuid; v_out uuid; v_wh uuid; v_conv uuid; v_keyed uuid;
  v_first numeric; v_again numeric; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.inv_0738('Conversions Twice Sdn Bhd');
  select id into v_in  from public.items where org_id = v_org and code = 'ITM';
  select id into v_out from public.items where org_id = v_org and code = 'OUT';
  select id into v_wh  from public.warehouses where org_id = v_org limit 1;
  v_conv := public.upsert_item_conversion(null, v_org, 'CV1', 'Pecah', v_in,
    1, 'C62', jsonb_build_array(jsonb_build_object('item', v_out,
    'quantity', 5, 'share', 100)), true);
  insert into public.stock_levels (org_id, item_id, warehouse_id, quantity)
  values (v_org, v_in, v_wh, 100)
  on conflict (item_id, warehouse_id) do update set quantity = 100;

  perform public.run_item_conversion(v_conv, 1, v_wh);
  perform public.run_item_conversion(v_conv, 1, v_wh);
  -- Two output movements. One box became twenty bottles instead of ten,
  -- and the shelf now disagrees with the ledger.
  perform pg_temp.check_eq(
    'without a key, the stock is converted twice',
    (select count(*)::integer from public.stock_movements
      where org_id = v_org and item_id = v_out), 2);

  v_keyed := public.upsert_item_conversion(null, v_org, 'CV2', 'Pecah lagi',
    v_in, 1, 'C62', jsonb_build_array(jsonb_build_object('item', v_out,
    'quantity', 5, 'share', 100)), true);
  v_first := public.run_item_conversion(
    p_conversion := v_keyed, p_times := 1, p_warehouse := v_wh,
    p_idempotency_key := 'CONV-1');
  v_again := public.run_item_conversion(
    p_conversion := v_keyed, p_times := 1, p_warehouse := v_wh,
    p_idempotency_key := 'CONV-1');
  perform pg_temp.check_true('a replayed conversion returns the same value',
    v_first is not null and v_again = v_first);
  -- `source_id` is the conversion, so the keyed run's movements are
  -- countable apart from the unkeyed pair above.
  perform pg_temp.check_eq('and converts the stock once',
    (select count(*)::integer from public.stock_movements
      where org_id = v_org and item_id = v_out and source_id = v_keyed), 1);

  begin
    perform public.run_item_conversion(
      p_conversion := v_keyed, p_times := 2, p_warehouse := v_wh,
      p_idempotency_key := 'CONV-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for twice as many is refused',
    not v_took);
end $$;


-- ---------------------------------------------------------------------
-- create_payroll_run
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_user uuid; v_period uuid; v_second uuid; v_first uuid;
  v_again uuid; v_took boolean;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);
  v_org := pg_temp.test_org('Payroll Twice Sdn Bhd',
    array['hr', 'payroll', 'accounting']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, employment_status,
     basic_salary)
  values (v_org, 'E1', 'Pekerja', v_user, pg_temp.today() - 400, 'active',
          3000);
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, 'P1', date_trunc('month', pg_temp.today())::date,
          (date_trunc('month', pg_temp.today())
             + interval '1 month -1 day')::date,
          pg_temp.today()) returning id into v_period;
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, 'P2', (date_trunc('month', pg_temp.today())
                          + interval '1 month')::date,
          (date_trunc('month', pg_temp.today())
             + interval '2 month -1 day')::date,
          pg_temp.today() + 31) returning id into v_second;

  -- This measured "without a key, one pay period gets two payroll runs,
  -- with two run numbers burnt" -- 0738's reason for the key. `0769`
  -- refuses a second live run for a period outright, keyed or not, so
  -- the double cannot happen now and the measurement is of the refusal.
  perform public.create_payroll_run(v_org, v_period, 'Bulan ini');
  perform pg_temp.check_refused(
    'without a key, a second run for the period is refused (0769)',
    format('select public.create_payroll_run(%L, %L, %L)',
           v_org, v_period, 'Bulan ini'),
    'Pay period P1 already has payroll run %', '23505');
  perform pg_temp.check_eq('so one run, and one run number burnt',
    (select count(distinct run_no)::integer from public.payroll_runs
      where org_id = v_org), 1);

  v_first := public.create_payroll_run(
    p_org_id := v_org, p_period_id := v_second, p_description := 'Bulan depan',
    p_idempotency_key := 'PAYRUN-1');
  v_again := public.create_payroll_run(
    p_org_id := v_org, p_period_id := v_second, p_description := 'Bulan depan',
    p_idempotency_key := 'PAYRUN-1');
  perform pg_temp.check_true('a replayed run returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and opens no second',
    (select count(*)::integer from public.payroll_runs
      where org_id = v_org and period_id = v_second), 1);

  begin
    perform public.create_payroll_run(
      p_org_id := v_org, p_period_id := v_period,
      p_description := 'Bulan depan', p_idempotency_key := 'PAYRUN-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for another period is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- upsert_bank_account
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_first uuid; v_again uuid; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Banks Twice Sdn Bhd', array['accounting']);

  perform public.upsert_bank_account('Akaun Semasa', 'Maybank', 'MBB',
    '512345678901', 'current', 'MYR', null, null, v_org);
  perform public.upsert_bank_account('Akaun Semasa', 'Maybank', 'MBB',
    '512345678901', 'current', 'MYR', null, null, v_org);
  perform pg_temp.check_eq(
    'without a key, one bank account is saved twice',
    (select count(*)::integer from public.bank_accounts where org_id = v_org),
    2);
  -- Each got its own GL account too, so the chart carries two.
  perform pg_temp.check_eq('each with its own ledger account',
    (select count(distinct account_id)::integer from public.bank_accounts
      where org_id = v_org), 2);

  v_first := public.upsert_bank_account(
    p_name := 'Akaun Kedua', p_bank_name := 'CIMB', p_bank_code := 'CIMB',
    p_account_number := '712345678901', p_account_type := 'current',
    p_currency := 'MYR', p_account_id := null, p_id := null,
    p_org_id := v_org, p_idempotency_key := 'BANK-1');
  v_again := public.upsert_bank_account(
    p_name := 'Akaun Kedua', p_bank_name := 'CIMB', p_bank_code := 'CIMB',
    p_account_number := '712345678901', p_account_type := 'current',
    p_currency := 'MYR', p_account_id := null, p_id := null,
    p_org_id := v_org, p_idempotency_key := 'BANK-1');
  perform pg_temp.check_true('a replayed save returns the first account',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and saves no third',
    (select count(*)::integer from public.bank_accounts where org_id = v_org),
    3);

  begin
    perform public.upsert_bank_account(
      p_name := 'Akaun Kedua', p_bank_name := 'CIMB', p_bank_code := 'CIMB',
      p_account_number := '799999999999', p_account_type := 'current',
      p_currency := 'MYR', p_account_id := null, p_id := null,
      p_org_id := v_org, p_idempotency_key := 'BANK-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true(
    'the same key for a different account number is refused', not v_took);

  -- AN AMEND, with p_org_id NULL -- which is what the client sends when
  -- p_id names a row, so the organization has to come off the ROW. The
  -- mutant that reads p_org_id instead claimed no key at all here and
  -- SURVIVED every assertion above, because all of them create.
  v_again := public.upsert_bank_account(
    p_name := 'Akaun Kedua, dinamakan semula', p_bank_name := 'CIMB',
    p_bank_code := 'CIMB', p_account_number := '712345678901',
    p_account_type := 'current', p_currency := 'MYR', p_account_id := null,
    p_id := v_first, p_org_id := null, p_idempotency_key := 'BANK-AMEND-1');
  perform pg_temp.check_true('an amend returns the row it amended',
    v_again = v_first);
  perform pg_temp.check_eq('and renames it',
    (select name from public.bank_accounts where id = v_first),
    'Akaun Kedua, dinamakan semula');
  begin
    perform public.upsert_bank_account(
      p_name := 'Nama ketiga', p_bank_name := 'CIMB', p_bank_code := 'CIMB',
      p_account_number := '712345678901', p_account_type := 'current',
      p_currency := 'MYR', p_account_id := null, p_id := v_first,
      p_org_id := null, p_idempotency_key := 'BANK-AMEND-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and the amend key was really claimed, so a different name is refused',
    not v_took);
  perform pg_temp.check_eq('leaving the first amend''s name in place',
    (select name from public.bank_accounts where id = v_first),
    'Akaun Kedua, dinamakan semula');
end $$;

-- ---------------------------------------------------------------------
-- chat_create_group
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_me uuid; v_them uuid; v_members jsonb; v_first uuid;
  v_again uuid; v_took boolean;
begin
  v_me := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Chat Twice Sdn Bhd', array['chat']);
  v_them := pg_temp.another_user('rakan-0738@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_them, 'employee', 'active') on conflict do nothing;
  insert into public.chat_access (org_id, user_id, is_enabled)
  values (v_org, v_me, true), (v_org, v_them, true) on conflict do nothing;
  perform pg_temp.sign_in_as(v_me);
  v_members := jsonb_build_array(
    jsonb_build_object('user_id', v_them, 'org_id', v_org));

  perform public.chat_create_group(v_org, 'Projek', v_members);
  perform public.chat_create_group(v_org, 'Projek', v_members);
  perform pg_temp.check_eq('without a key, one group is created twice',
    (select count(*)::integer from public.chat_conversations c
      where not c.is_direct
        and exists (select 1 from public.chat_participants p
                     where p.conversation_id = c.id and p.org_id = v_org)), 2);

  v_first := public.chat_create_group(
    p_my_org := v_org, p_title := 'Projek Dua', p_members := v_members,
    p_idempotency_key := 'GROUP-1');
  v_again := public.chat_create_group(
    p_my_org := v_org, p_title := 'Projek Dua', p_members := v_members,
    p_idempotency_key := 'GROUP-1');
  perform pg_temp.check_true('a replayed group returns the first',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and creates no third',
    (select count(*)::integer from public.chat_conversations c
      where not c.is_direct
        and exists (select 1 from public.chat_participants p
                     where p.conversation_id = c.id and p.org_id = v_org)), 3);

  begin
    perform public.chat_create_group(
      p_my_org := v_org, p_title := 'Projek Tiga', p_members := v_members,
      p_idempotency_key := 'GROUP-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different name is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- upsert_landed_cost_run
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_first uuid; v_again uuid; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.inv_0738('Landed Twice Sdn Bhd');

  perform public.upsert_landed_cost_run(null, v_org, pg_temp.today(),
    '[]'::jsonb, '[]'::jsonb, 'Nota');
  perform public.upsert_landed_cost_run(null, v_org, pg_temp.today(),
    '[]'::jsonb, '[]'::jsonb, 'Nota');
  perform pg_temp.check_eq('without a key, one run is saved twice',
    (select count(*)::integer from public.landed_cost_runs
      where org_id = v_org), 2);

  v_first := public.upsert_landed_cost_run(
    p_id := null, p_org := v_org, p_date := pg_temp.today(),
    p_bills := '[]'::jsonb, p_charges := '[]'::jsonb, p_notes := 'Keyed',
    p_idempotency_key := 'LANDED-1');
  v_again := public.upsert_landed_cost_run(
    p_id := null, p_org := v_org, p_date := pg_temp.today(),
    p_bills := '[]'::jsonb, p_charges := '[]'::jsonb, p_notes := 'Keyed',
    p_idempotency_key := 'LANDED-1');
  perform pg_temp.check_true('a replayed save returns the first run',
    v_first is not null and v_again = v_first);
  perform pg_temp.check_eq('and saves no third',
    (select count(*)::integer from public.landed_cost_runs
      where org_id = v_org), 3);

  begin
    perform public.upsert_landed_cost_run(
      p_id := null, p_org := v_org, p_date := pg_temp.today() - 1,
      p_bills := '[]'::jsonb, p_charges := '[]'::jsonb, p_notes := 'Keyed',
      p_idempotency_key := 'LANDED-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for another date is refused',
    not v_took);
end $$;


-- ---------------------------------------------------------------------
-- join_pos_queue and upsert_pos_menu_link: two TABLE-returning wrappers
--
-- The replay has to rebuild every column from the stored result. A
-- wrapper that returned an empty set would pass any assertion that only
-- counted rows in the table, which is why the RETURNED values are
-- asserted here as well.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_outlet uuid; v_table uuid; v_first record; v_again record;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.shop_0738('Queue Twice Sdn Bhd');
  select id into v_outlet from public.pos_outlets where org_id = v_org;
  select id into v_table from public.pos_tables where outlet_id = v_outlet;

  perform public.join_pos_queue(v_outlet, 2, 'Puan Siti', null, null);
  perform public.join_pos_queue(v_outlet, 2, 'Puan Siti', null, null);
  perform pg_temp.check_eq(
    'without a key, one party at the door takes two ticket numbers',
    (select count(*)::integer from public.pos_queue_entries
      where outlet_id = v_outlet), 2);

  -- `app.pos_queue_quote` returns NULL until THREE parties have been
  -- seated, and the first draft of this block asserted
  -- `v_again.quoted_minutes = v_first.quoted_minutes` while both were
  -- null -- which is null, not true, and failed. The honest fix is not a
  -- null-safe comparison but a fixture that produces a real quote, so a
  -- wrapper that dropped the column from its stored result comes back
  -- null on the replay and the assertion catches it.
  insert into public.pos_queue_entries
    (org_id, outlet_id, ticket_no, queue_date, party_size, status,
     joined_at, seated_at)
  select v_org, v_outlet, 100 + g, pg_temp.today(), 4, 'seated',
         now() - interval '40 minutes', now() - interval '20 minutes'
    from generate_series(1, 3) g;

  select * into v_first from public.join_pos_queue(
    p_outlet := v_outlet, p_party := 4, p_name := 'Encik Ali',
    p_phone := null, p_note := null, p_idempotency_key := 'QUEUE-1');
  select * into v_again from public.join_pos_queue(
    p_outlet := v_outlet, p_party := 4, p_name := 'Encik Ali',
    p_phone := null, p_note := null, p_idempotency_key := 'QUEUE-1');
  perform pg_temp.check_true('a replayed join returns the same entry',
    v_first.entry_id is not null and v_again.entry_id = v_first.entry_id);
  -- The number on the customer's slip of paper, which is the whole point.
  perform pg_temp.check_eq('and the SAME ticket number',
    v_again.ticket_no, v_first.ticket_no);
  perform pg_temp.check_true('and a quote was given at all',
    v_first.quoted_minutes is not null);
  perform pg_temp.check_eq('and the replay repeats it',
    v_again.quoted_minutes, v_first.quoted_minutes);
  perform pg_temp.check_eq('and takes no third number',
    (select count(*)::integer from public.pos_queue_entries
      where outlet_id = v_outlet and status = 'waiting'), 3);

  begin
    perform public.join_pos_queue(
      p_outlet := v_outlet, p_party := 6, p_name := 'Encik Ali',
      p_phone := null, p_note := null, p_idempotency_key := 'QUEUE-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a bigger party is refused',
    not v_took);

  -- ---- upsert_pos_menu_link ----
  perform public.upsert_pos_menu_link(v_outlet,
    'table'::app.pos_menu_link_kind, v_table, null, 'Meja 1', null, false,
    null, true);
  perform public.upsert_pos_menu_link(v_outlet,
    'table'::app.pos_menu_link_kind, v_table, null, 'Meja 1', null, false,
    null, true);
  perform pg_temp.check_eq(
    'without a key, two live links open the same table',
    (select count(*)::integer from public.pos_menu_links
      where outlet_id = v_outlet), 2);

  select * into v_first from public.upsert_pos_menu_link(
    p_outlet := v_outlet, p_kind := 'table'::app.pos_menu_link_kind,
    p_table := v_table, p_register := null, p_label := 'Meja 1 lagi',
    p_expires := null, p_single := false, p_id := null, p_active := true,
    p_idempotency_key := 'LINK-1');
  select * into v_again from public.upsert_pos_menu_link(
    p_outlet := v_outlet, p_kind := 'table'::app.pos_menu_link_kind,
    p_table := v_table, p_register := null, p_label := 'Meja 1 lagi',
    p_expires := null, p_single := false, p_id := null, p_active := true,
    p_idempotency_key := 'LINK-1');
  perform pg_temp.check_true('a replayed link returns the first',
    v_first.id is not null and v_again.id = v_first.id);
  -- The token is the half that matters: a second one is a second way in.
  perform pg_temp.check_true('and the SAME token',
    v_first.token is not null and v_again.token = v_first.token);
  perform pg_temp.check_eq('and mints no third link',
    (select count(*)::integer from public.pos_menu_links
      where outlet_id = v_outlet), 3);

  begin
    perform public.upsert_pos_menu_link(
      p_outlet := v_outlet, p_kind := 'table'::app.pos_menu_link_kind,
      p_table := v_table, p_register := null, p_label := 'Meja 2',
      p_expires := null, p_single := false, p_id := null, p_active := true,
      p_idempotency_key := 'LINK-1');
    v_took := true;
  exception when sqlstate '22023' then v_took := false;
  end;
  perform pg_temp.check_true('the same key for a different label is refused',
    not v_took);
end $$;

-- ---------------------------------------------------------------------
-- open_pos_sale: the key that was already there
--
-- Not a wrapper. `app.open_pos_sale_internal` resumes the sale whose
-- `client_uuid` matches, and the till passed none, so two taps left two
-- parked bills. `check_idempotent_calls.py` now refuses a call site that
-- drops it; this asserts the server half it depends on.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_reg uuid; v_cu uuid := gen_random_uuid(); a uuid; b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.shop_0738('Till Twice Sdn Bhd');
  select id into v_reg from public.pos_registers where org_id = v_org;

  perform public.open_pos_sale(v_reg, null, null);
  perform public.open_pos_sale(v_reg, null, null);
  perform pg_temp.check_eq(
    'with no client_uuid, two taps leave two parked bills',
    (select count(*)::integer from public.pos_sales where org_id = v_org), 2);

  a := public.open_pos_sale(v_reg, null, v_cu);
  b := public.open_pos_sale(v_reg, null, v_cu);
  perform pg_temp.check_true('with one, the second resumes the first',
    a is not null and b = a);
  perform pg_temp.check_eq('and opens no third bill',
    (select count(*)::integer from public.pos_sales where org_id = v_org), 3);
  -- A different uuid is a different bill, which is what a till needs: a
  -- cashier really can have two orders open at once.
  perform pg_temp.check_true('a different client_uuid opens a new bill',
    public.open_pos_sale(v_reg, null, gen_random_uuid()) <> a);
end $$;

-- ---------------------------------------------------------------------
-- 0738's eighteen verdicts, measured
--
-- Six refused by a unique index, five handing back what is there, three
-- state guards, two natural, two that repeat on purpose. The last five
-- cannot raise, so they are counted.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_user uuid; v_c uuid; v_item uuid; v_wh uuid; v_sup uuid;
  v_run uuid; v_line uuid; v_sale uuid; v_mem uuid; v_sub uuid;
  v_lineid uuid; v_cycle uuid; v_period uuid; v_payrun uuid; v_conv uuid;
  v_them uuid; v_doc uuid; v_reg uuid; v_tender uuid; v_cu uuid;
  n integer; a uuid; b uuid; v_dr uuid; v_cr uuid;
begin
  v_user := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_user);

  -- ---- unique: open_matter, upsert_item_conversion ----
  v_org := pg_temp.test_org('Verdicts 0738 Sdn Bhd',
    array['legal', 'inventory', 'purchases', 'accounting', 'forecasting',
          'hr', 'payroll', 'einvoice']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Klien', 'customer') returning id into v_c;
  perform pg_temp.refuses_a_repeat('open_matter', format(
    'select public.open_matter(%L, %L, %L, %L, null, null, %L, %L, null, 0, '
    'null)', v_org, 'M-1', 'Fail', v_c, v_user, v_user));

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'W', 'Store', true) returning id into v_wh;
  insert into public.items (org_id, code, name, item_type, track_inventory,
    uom_code, unit_price, cost_price)
  values (v_org, 'ITM', 'Barang', 'stock', true, 'C62', 50, 20)
  returning id into v_item;
  insert into public.items (org_id, code, name, item_type, track_inventory,
    uom_code, unit_price, cost_price)
  values (v_org, 'OUT', 'Keluaran', 'stock', true, 'C62', 10, 5);
  perform pg_temp.refuses_a_repeat('upsert_item_conversion', format(
    'select public.upsert_item_conversion(null, %L, %L, %L, %L, 1, %L, '
    '%L::jsonb, true)', v_org, 'CV1', 'Pecah', v_item, 'C62',
    jsonb_build_array(jsonb_build_object('item',
      (select id from public.items where org_id = v_org and code = 'OUT'),
      'quantity', 5, 'share', 100))::text));

  -- ---- state: open_appraisal_cycle ----
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, employment_status,
     basic_salary)
  values (v_org, 'E1', 'Pekerja', v_user, pg_temp.today() - 400, 'active',
          3000);
  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end, status)
  values (v_org, 'FY26', pg_temp.today() - 300, pg_temp.today() - 10, 'draft')
  returning id into v_cycle;
  perform pg_temp.check_eq('open_appraisal_cycle appraises everybody once',
    public.open_appraisal_cycle(v_cycle), 1);
  perform pg_temp.check_eq('and a retry appraises nobody',
    public.open_appraisal_cycle(v_cycle), 0);

  -- ---- natural: calculate_payroll_run replaces the payslips ----
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, 'P1', date_trunc('month', pg_temp.today())::date,
          (date_trunc('month', pg_temp.today())
             + interval '1 month -1 day')::date,
          pg_temp.today()) returning id into v_period;
  v_payrun := public.create_payroll_run(v_org, v_period, 'Bulan');
  perform public.calculate_payroll_run(v_payrun);
  perform public.calculate_payroll_run(v_payrun);
  perform pg_temp.check_eq(
    'calculate_payroll_run rebuilds the payslips rather than adding to them',
    (select count(*)::integer from public.payslips where run_id = v_payrun),
    1);

  -- ---- state: run_recurring_journals_for advances next_run_date ----
  select id into v_dr from public.accounts where org_id = v_org
    and account_type = 'asset' and not is_group limit 1;
  select id into v_cr from public.accounts where org_id = v_org
    and account_type = 'revenue' and not is_group limit 1;
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, next_run_date, template, auto_post,
     is_active)
  values (v_org, 'Sewa', 'monthly', pg_temp.today(), pg_temp.today(),
    jsonb_build_object('lines', jsonb_build_array(
      jsonb_build_object('account_id', v_dr, 'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_cr, 'debit', 0, 'credit', 100)),
      'description', 'Sewa bulanan'), true, true);
  perform pg_temp.check_eq('run_recurring_journals_for posts one journal',
    public.run_recurring_journals_for(v_org, pg_temp.today()), 1);
  perform pg_temp.check_eq('and a second sweep posts none',
    public.run_recurring_journals_for(v_org, pg_temp.today()), 0);

  -- ---- existing: ensure_default_warehouse, create_item_variants ----
  perform pg_temp.check_true('ensure_default_warehouse returns the same store',
    public.ensure_default_warehouse(v_org)
      = public.ensure_default_warehouse(v_org));
  perform public.create_item_variants(v_item,
    jsonb_build_object('Saiz', jsonb_build_array('S', 'M')));
  perform public.create_item_variants(v_item,
    jsonb_build_object('Saiz', jsonb_build_array('S', 'M')));
  perform pg_temp.check_eq(
    'create_item_variants finds the variant it already made',
    (select count(*)::integer from public.items
      where org_id = v_org and parent_item_id = v_item), 2);

  -- ---- natural: create_po_from_suggestions nets off its own output ----
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'Pembekal', 'supplier') returning id into v_sup;
  update public.items set preferred_supplier_id = v_sup where id = v_item;
  v_run := public.run_inventory_forecast(v_org, v_wh, pg_temp.today());
  update public.forecast_lines
     set suggested_qty = 10, supplier_id = v_sup, state = 'order_now'
   where run_id = v_run and item_id = v_item returning id into v_line;
  if v_line is not null then
    perform public.create_po_from_suggestions(v_org,
      jsonb_build_array(jsonb_build_object('line_id', v_line,
        'quantity', 10)), pg_temp.today() + 7, v_wh);
    select count(*)::integer into n from public.purchase_documents
     where org_id = v_org and doc_type = 'purchase_order';
    perform pg_temp.check_eq('create_po_from_suggestions raises one order',
      n, 1);
    perform public.create_po_from_suggestions(v_org,
      jsonb_build_array(jsonb_build_object('line_id', v_line,
        'quantity', 10)), pg_temp.today() + 7, v_wh);
    perform pg_temp.check_eq(
      'and a retry raises none, because the draft order is netted off',
      (select count(*)::integer from public.purchase_documents
        where org_id = v_org and doc_type = 'purchase_order'), 1);
  end if;

  -- ---- existing: create_supplier_from_received_einvoice ----
  insert into public.received_einvoices
    (org_id, myinvois_uuid, myinvois_long_id, doc_no, issue_date, type_code,
     currency, supplier_name, supplier_tin, supplier_id_type,
     supplier_id_value, payable_amount, raw, payload_hash, status)
  values (v_org, gen_random_uuid()::text, 'L1', 'INV-X', pg_temp.today(),
          '01', 'MYR', 'Pembekal Jauh', 'C1234567890', 'BRN',
          '202601000001', 100, '{}'::jsonb, 'h-0738', 'received')
  returning id into v_doc;
  a := public.create_supplier_from_received_einvoice(v_doc);
  b := public.create_supplier_from_received_einvoice(v_doc);
  perform pg_temp.check_true(
    'create_supplier_from_received_einvoice returns the supplier it made',
    a is not null and b = a);

  -- ---- repeats: next_document_number, run_inventory_forecast ----
  perform pg_temp.check_true(
    'next_document_number hands out a different number each time, by design',
    public.next_document_number(v_org, 'invoice')
      <> public.next_document_number(v_org, 'invoice'));
  perform pg_temp.check_true(
    'and a re-run forecast is a new forecast, also by design',
    public.run_inventory_forecast(v_org, v_wh, pg_temp.today()) <> v_run);

  -- ---- the POS verdicts, in a shop ----
  v_org := pg_temp.shop_0738('Verdicts POS 0738 Sdn Bhd');
  select id into v_reg from public.pos_registers where org_id = v_org;
  select id into v_item from public.items
   where org_id = v_org and code = 'KOPI';
  select id into v_c from public.contacts where org_id = v_org and code = 'REG';
  select id into v_mem from public.pos_memberships where org_id = v_org;
  select id into v_tender from public.pos_tender_types where org_id = v_org;

  -- natural: void_pos_sale_line deletes the line it voids.
  v_sale := public.open_pos_sale(v_reg, null, gen_random_uuid());
  v_lineid := public.add_pos_sale_line(v_sale, v_item, 1, 5.00);
  perform pg_temp.refuses_a_repeat('void_pos_sale_line', format(
    'select public.void_pos_sale_line(%L, %L::app.pos_void_reason, %L)',
    v_lineid, 'item_issue', 'jatuh'));

  -- state: void_pos_sale refuses a bill that is already voided.
  v_sale := public.open_pos_sale(v_reg, null, gen_random_uuid());
  perform public.add_pos_sale_line(v_sale, v_item, 1, 5.00);
  perform pg_temp.refuses_a_repeat('void_pos_sale', format(
    'select public.void_pos_sale(%L, %L::app.pos_void_reason, %L)',
    v_sale, 'item_issue', 'tutup'));

  -- unique: start_membership and cover_line_with_membership. BOTH were
  -- read as doubling and both are refused by an index -- the sixth and
  -- seventh time in this programme that reading a body was wrong.
  v_sale := public.open_pos_sale(v_reg, v_c, gen_random_uuid());
  perform public.add_pos_sale_line(v_sale,
    (select id from public.items where org_id = v_org and code = 'GYM'),
    1, 100);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_tender, 'amount', 100)));
  perform pg_temp.refuses_a_repeat('start_membership',
    format('select public.start_membership(%L, %L)', v_sale, v_mem));
  select id into v_sub from public.pos_membership_subscriptions
   where org_id = v_org limit 1;

  v_sale := public.open_pos_sale(v_reg, v_c, gen_random_uuid());
  v_lineid := public.add_pos_sale_line(v_sale, v_item, 1, 5.00);
  perform pg_temp.refuses_a_repeat('cover_line_with_membership', format(
    'select public.cover_line_with_membership(%L, %L)', v_lineid, v_sub));

  -- existing: ingest_offline_sales deduplicates on the till's own uuid.
  v_cu := gen_random_uuid();
  perform public.ingest_offline_sales(v_reg, jsonb_build_array(
    jsonb_build_object('client_uuid', v_cu,
      'lines', jsonb_build_array(jsonb_build_object(
        'item_id', v_item, 'quantity', 1, 'unit_price', 5)),
      'tenders', jsonb_build_array(jsonb_build_object(
        'type', v_tender, 'amount', 5)))));
  select count(*)::integer into n from public.pos_sales where org_id = v_org;
  perform public.ingest_offline_sales(v_reg, jsonb_build_array(
    jsonb_build_object('client_uuid', v_cu,
      'lines', jsonb_build_array(jsonb_build_object(
        'item_id', v_item, 'quantity', 1, 'unit_price', 5)),
      'tenders', jsonb_build_array(jsonb_build_object(
        'type', v_tender, 'amount', 5)))));
  perform pg_temp.check_eq(
    'a replayed offline sync lands the sale once',
    (select count(*)::integer from public.pos_sales where org_id = v_org), n);

  -- existing: chat_start_direct finds the pair it already has.
  v_org := pg_temp.test_org('Verdicts Chat 0738 Sdn Bhd', array['chat']);
  v_them := pg_temp.another_user('rakan-verdict-0738@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_them, 'employee', 'active') on conflict do nothing;
  insert into public.chat_access (org_id, user_id, is_enabled)
  values (v_org, v_user, true), (v_org, v_them, true) on conflict do nothing;
  perform pg_temp.sign_in_as(v_user);
  perform pg_temp.check_true(
    'chat_start_direct returns the conversation those two already have',
    public.chat_start_direct(v_org, v_them, v_org)
      = public.chat_start_direct(v_org, v_them, v_org));
end $$;

rollback;