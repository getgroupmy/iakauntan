-- =====================================================================
-- iAkauntan :: emailing a receipt
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/email_receipt.sql
--
-- `outbound_email.sql` already asserts the machinery this shares with
-- its sibling `email_document`: that a template is rendered, that an
-- organization's own wording wins over the built-in, that queued and
-- immediate are different things, and that nothing leaves until email
-- is switched on. Repeating all of that here would add files rather
-- than coverage.
--
-- What is `email_receipt`'s own, and asserted here:
--
--   * its own copy of the attachment guard, over `receipts/` rather
--     than `sales_documents/`. It is a second copy of a security check,
--     which is exactly the kind that gets edited on one side only;
--   * the receipt variables — the figures a customer reads and might
--     dispute, including the money on account the header of 0110 calls
--     out by name;
--   * the address it decides to send to, which is three fallbacks deep
--     and the difference between reaching the person who pays and
--     reaching nobody;
--   * that the message files itself against the receipt and not
--     against a document, since the per-document log is read to answer
--     "what did we send them".
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.mail_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.email_settings (org_id, is_enabled, from_name, reminder_days)
  values (v_org, true, p_name, '{}');
  return v_org;
end;
$$;

create or replace function pg_temp.invoice(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, date '2026-03-01', date '2026-03-31',
          p_contact, 'MYR', 1, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount, p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

-- Cash in, part of it against an invoice and the rest on account, so
-- `unapplied_amount` is a number somebody could argue with rather than
-- a zero that renders the same whether it is read or not.
create or replace function pg_temp.receipt(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_unapplied numeric default 0, p_invoice uuid default null,
  p_alloc numeric default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, payment_mode_code, reference)
  values (p_org, p_no, date '2026-03-05', p_contact, p_amount, p_unapplied,
          'MYR', 1, '03', 'FT26030512')
  returning id into v_id;
  if p_invoice is not null then
    insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
    values (p_org, v_id, p_invoice, coalesce(p_alloc, p_amount));
  end if;
  perform public.post_receipt(v_id);
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- What the customer reads
--
-- The whole body is compared rather than a fragment of it. A receipt is
-- the message a customer files and produces years later, and the two
-- ways it goes wrong — a figure that is not the one on the receipt, and
-- a placeholder that never got substituted — are both invisible to a
-- `like '%1,500%'`.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Receipts Sdn Bhd');
  v_contact uuid; v_inv uuid; v_rcp uuid; v_msg uuid; r record;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;

  v_inv := pg_temp.invoice(v_org, v_contact, 'INV-1', 1000);
  v_rcp := pg_temp.receipt(v_org, v_contact, 'RCT-1', 1500, 500, v_inv, 1000);

  v_msg := public.email_receipt(v_rcp);
  select * into r from public.email_outbox where id = v_msg;

  perform pg_temp.check_eq('the subject names the receipt and the company',
    r.subject, 'Receipt RCT-1 from Receipts Sdn Bhd');

  perform pg_temp.check_eq('and the body is what was actually paid',
    r.body,
    E'Dear Buyer Bhd,\n\nThank you. We have received MYR 1,500.00 on '
    || E'05 Mar 2026, and your receipt RCT-1 is attached.\n\nThis has been '
    || E'set against INV-1.\n\nRegards,\nReceipts Sdn Bhd');

  -- Belt and braces on the sentence above: if the wording is ever
  -- changed the comparison has to be changed with it, and the temptation
  -- then is to relax it rather than update it.
  perform pg_temp.check_true('with nothing left unsubstituted',
    r.subject not like '%{{%' and r.body not like '%{{%');

  perform pg_temp.check_true('it is queued, not sent',
    r.status = 'queued' and r.dispatch = 'queued');
  perform pg_temp.check_eq('addressed to the customer',
    r.to_email, 'ap@buyer.example');
  perform pg_temp.check_eq('sent as the company', r.from_name, 'Receipts Sdn Bhd');

  -- The message is filed against the receipt. `document_activity` reads
  -- `document_id` to answer "what did we send them about this invoice",
  -- and a receipt that files itself there puts the wrong message under
  -- the wrong document.
  perform pg_temp.check_eq('filed against the receipt', r.receipt_id, v_rcp);
  perform pg_temp.check_true('and against no document', r.document_id is null);

  -- No share token is issued. 0110 says so, and the reason is that
  -- issuing one revokes the invoice's live link as a side effect — which
  -- the customer discovers, not us.
  perform pg_temp.check_eq('emailing a receipt revokes nobody''s link',
    (select count(*) from public.document_activity(v_inv)
      where kind = 'share link'), 0);

  v_msg := public.email_receipt(v_rcp, null, 'receipt_issued', 'immediate');
  perform pg_temp.check_true('and it can be sent now instead',
    (select ob.dispatch = 'immediate' from public.email_outbox ob
      where ob.id = v_msg));
end $$;

-- ---------------------------------------------------------------------
-- The figures that are not in the default wording
--
-- `unapplied_amount`, the payment mode and the bank reference are all
-- carried by `receipt_email_vars` and none of them appear in the
-- built-in template, so a company that asks for them in its own wording
-- is the only thing that reads them.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Detail Sdn Bhd');
  v_contact uuid; v_rcp uuid; v_msg uuid; v_body text;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;

  v_rcp := pg_temp.receipt(v_org, v_contact, 'RCT-9', 1500, 500);

  insert into public.email_templates (org_id, code, subject, body)
  values (v_org, 'receipt_detail', 'Receipt {{receipt_no}}',
          '{{currency}} {{amount}} by {{payment_mode}} ref {{reference}}; '
          || '{{currency}} {{unapplied_amount}} remains on account; '
          || 'set against [{{applied_to}}]');

  v_msg := public.email_receipt(v_rcp, null, 'receipt_detail');
  select ob.body into v_body from public.email_outbox ob where ob.id = v_msg;

  perform pg_temp.check_eq('every receipt variable is rendered', v_body,
    'MYR 1,500.00 by 03 ref FT26030512; MYR 500.00 remains on account; '
    || 'set against []');

  -- The empty brackets above are the point of this one: a receipt that
  -- is entirely on account has been set against nothing, and the
  -- variable has to be an empty string rather than null — null renders
  -- as the literal placeholder, or swallows the line, depending on the
  -- renderer.
  perform pg_temp.check_true('and nothing is left as a placeholder',
    v_body not like '%{{%');

  begin
    perform public.email_receipt(v_rcp, null, 'no_such_template');
    raise exception 'FAIL: rendered a template that does not exist';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a template nobody wrote is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Who it goes to
--
-- Three deep, and the order matters. The address typed into the send
-- dialog beats the person on file, and the named accounts-payable
-- contact beats the company's switchboard address — which is usually
-- info@, where a receipt goes to die.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Address Sdn Bhd');
  v_contact uuid; v_bare uuid; v_rcp uuid; v_bare_rcp uuid; v_msg uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'info@buyer.example')
  returning id into v_contact;
  v_rcp := pg_temp.receipt(v_org, v_contact, 'RCT-1', 100);

  v_msg := public.email_receipt(v_rcp);
  perform pg_temp.check_eq('with nobody named, the company address is used',
    (select ob.to_email from public.email_outbox ob where ob.id = v_msg),
    'info@buyer.example');

  -- Somebody on file, but not the primary one. A sales rep is not who
  -- you send a receipt to.
  insert into public.contact_persons (org_id, contact_id, name, email, is_primary)
  values (v_org, v_contact, 'Sales Rep', 'rep@buyer.example', false);
  v_msg := public.email_receipt(v_rcp);
  perform pg_temp.check_eq('a contact who is not the primary one is not used',
    (select ob.to_email from public.email_outbox ob where ob.id = v_msg),
    'info@buyer.example');

  insert into public.contact_persons (org_id, contact_id, name, email, is_primary)
  values (v_org, v_contact, 'Anita', 'anita@buyer.example', true);
  v_msg := public.email_receipt(v_rcp);
  perform pg_temp.check_eq('the primary contact beats the company address',
    (select ob.to_email from public.email_outbox ob where ob.id = v_msg),
    'anita@buyer.example');

  v_msg := public.email_receipt(v_rcp, 'finance@buyer.example');
  perform pg_temp.check_eq('and a typed address beats both',
    (select ob.to_email from public.email_outbox ob where ob.id = v_msg),
    'finance@buyer.example');

  -- Nowhere to send it. Queueing a row with no address would be
  -- discovered by the edge function at three in the morning, in a log
  -- nobody reads.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-002', 'Walk-in Bhd', 'customer')
  returning id into v_bare;
  v_bare_rcp := pg_temp.receipt(v_org, v_bare, 'RCT-2', 60);
  begin
    perform public.email_receipt(v_bare_rcp);
    raise exception 'FAIL: queued a receipt to nobody';
  exception when sqlstate '23514' then
    raise notice 'ok   a customer with no address is refused';
  end;

  begin
    perform public.email_receipt(v_rcp, 'not an address');
    raise exception 'FAIL: queued a receipt to something with no @';
  exception when sqlstate '23514' then
    raise notice 'ok   nor an address with no @';
  end;
  begin
    perform public.email_receipt(v_rcp, 'a@b');
    raise exception 'FAIL: queued a receipt to a domain with no dot';
  exception when sqlstate '23514' then
    raise notice 'ok   nor a domain with no dot';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The attachment
--
-- This is `email_receipt`'s own copy of the check `email_document`
-- carries, over a different folder, and the two are edited apart easily
-- because they look identical. The path is a claim made by the client
-- about a file it does not have to own: the storage policy governs who
-- may write there, so without this check a member could reference their
-- own upload — or a file sitting under another company's prefix — and
-- have the system email it out as this company's receipt.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Attach Sdn Bhd');
  v_contact uuid; v_rcp uuid; v_other uuid; v_msg uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;
  v_rcp   := pg_temp.receipt(v_org, v_contact, 'RCT-1', 100);
  v_other := pg_temp.receipt(v_org, v_contact, 'RCT-2', 200);

  -- Queued first, then read. Calling `email_receipt` inside the WHERE
  -- clause evaluates it once per candidate row rather than once, so the
  -- id being compared moves as the scan proceeds and nothing matches.
  v_msg := public.email_receipt(v_rcp);
  perform pg_temp.check_true('a receipt with no PDF still goes out',
    (select ob.attachment_path is null and ob.attachment_name is null
       from public.email_outbox ob where ob.id = v_msg));

  v_msg := public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
    v_org || '/receipts/' || v_rcp || '/rct-1.pdf');
  perform pg_temp.check_true('one under this receipt is kept, and named',
    (select ob.attachment_path = v_org || '/receipts/' || v_rcp || '/rct-1.pdf'
        and ob.attachment_name = 'rct-1.pdf'
       from public.email_outbox ob where ob.id = v_msg));

  v_msg := public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
    v_org || '/receipts/' || v_rcp || '/rct-1.pdf', 'Receipt RCT-1.pdf');
  perform pg_temp.check_eq('a nicer name than the object key can be given',
    (select ob.attachment_name from public.email_outbox ob where ob.id = v_msg),
    'Receipt RCT-1.pdf');

  begin
    perform public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
      v_org || '/receipts/' || v_other || '/rct-2.pdf');
    raise exception 'FAIL: attached another receipt''s file';
  exception when sqlstate '42501' then
    raise notice 'ok   another receipt''s file is refused';
  end;

  begin
    perform public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
      gen_random_uuid() || '/receipts/' || v_rcp || '/theirs.pdf');
    raise exception 'FAIL: attached a file from another organization';
  exception when sqlstate '42501' then
    raise notice 'ok   nor one under another organization';
  end;

  -- The folder is part of the check, not decoration. A path that is
  -- perfectly valid for `email_document` is not valid here, and this is
  -- the assertion that fails if the two copies are ever edited apart.
  begin
    perform public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
      v_org || '/sales_documents/' || v_rcp || '/inv-1.pdf');
    raise exception 'FAIL: attached from the documents folder';
  exception when sqlstate '42501' then
    raise notice 'ok   nor one from the documents folder';
  end;

  begin
    perform public.email_receipt(v_rcp, null, 'receipt_issued', 'queued',
      v_org || '/receipts/' || v_rcp || '/');
    raise exception 'FAIL: accepted a path with no file on the end';
  exception when sqlstate '42501' then
    raise notice 'ok   nor a directory with no file';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Who may send one, and what cannot be sent
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Guard Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_viewer uuid := pg_temp.another_user('viewer@iakauntan.test');
  v_contact uuid; v_rcp uuid; v_gone uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;
  v_rcp  := pg_temp.receipt(v_org, v_contact, 'RCT-1', 100);
  v_gone := pg_temp.receipt(v_org, v_contact, 'RCT-2', 200);

  -- `email_outbox.dispatch` carries its own CHECK, and a check violation
  -- is 23514 too — so asserting that 'later' is refused would pass with
  -- the function's own guard deleted, which is a test that reports on
  -- the table rather than on the function.
  --
  -- What is the function's alone is the *order*: the choice is checked
  -- before the receipt is looked up, so a bad dispatch against a receipt
  -- that does not exist still comes back as a bad dispatch. Delete the
  -- guard and this same call answers P0002 instead, from a line that has
  -- nothing to do with what was wrong.
  begin
    perform public.email_receipt(gen_random_uuid(), null, 'receipt_issued',
      'later');
    raise exception 'FAIL: accepted a dispatch nobody drains';
  exception when sqlstate '23514' then
    raise notice 'ok   a dispatch nobody drains is refused first';
  end;
  begin
    perform public.email_receipt(v_rcp, null, 'receipt_issued', 'later');
    raise exception 'FAIL: queued a receipt nothing would send';
  exception when sqlstate '23514' then
    raise notice 'ok   and refused on a receipt that does exist';
  end;

  begin
    perform public.email_receipt(gen_random_uuid());
    raise exception 'FAIL: emailed a receipt that does not exist';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a receipt that does not exist is refused';
  end;

  -- A deleted receipt is not evidence of anything, and sending one is
  -- how a customer ends up holding a document the company has voided.
  update public.receipts set deleted_at = now() where id = v_gone;
  begin
    perform public.email_receipt(v_gone);
    raise exception 'FAIL: emailed a deleted receipt';
  exception when sqlstate 'P0002' then
    raise notice 'ok   nor a deleted one';
  end;

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_viewer, 'viewer') on conflict do nothing;
  perform pg_temp.sign_in_as(v_viewer);
  begin
    perform public.email_receipt(v_rcp);
    raise exception 'FAIL: a read-only member sent a receipt';
  exception when sqlstate '42501' then
    raise notice 'ok   a read-only member cannot send one';
  end;

  -- Nobody at all. The function is SECURITY DEFINER, so without this
  -- the definer's own authority is what would be tested.
  perform pg_temp.sign_out();
  begin
    perform public.email_receipt(v_rcp);
    raise exception 'FAIL: a signed-out caller sent a receipt';
  exception when sqlstate '42501' then
    raise notice 'ok   nor a caller who is nobody';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- Switched off is switched off, whatever else is right.
  update public.email_settings set is_enabled = false where org_id = v_org;
  begin
    perform public.email_receipt(v_rcp);
    raise exception 'FAIL: queued a receipt with email switched off';
  exception when sqlstate '22023' then
    raise notice 'ok   nothing is sent until email is switched on';
  end;
end $$;

rollback;
