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

-- One clock, named once.
--
-- `check_test_clock.py` fails a file that uses both `current_date` and a
-- Kuala Lumpur date in code, because the two are a different day for
-- eight hours out of every twenty-four and a fixture built from one and
-- asserted against the other is red overnight and green by lunchtime.
-- This file used `current_date` throughout and gained KL dates when the
-- 0733 blocks arrived, so it is all on this instead -- and the
-- expression lives in one function rather than twenty call sites.
create or replace function pg_temp.today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Kuala_Lumpur')::date
$$;

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
  v_fresh := pg_temp.an_invoice(v_org, v_contact, 'INV-9');
  perform public.email_document(v_fresh, null, 'document_new', null,
    'queued', null, null, 'SEND-9');
  perform pg_temp.check_eq('a null share window takes the function''s 30 days',
    (select (expires_at::date - pg_temp.today())
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


rollback;
