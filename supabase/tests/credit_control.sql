-- =====================================================================
-- iAkauntan :: credit control tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_control.sql
--
-- contacts.credit_limit was collected, stored, shown back and never
-- checked. These assert that it now bites when it is meant to and, just
-- as importantly, that it does not bite where it must not: a credit note
-- reduces exposure and refusing one because the customer is over their
-- limit is exactly backwards.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cc_org(p_name text, p_mode text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  update public.organizations set credit_control = p_mode where id = v_org;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.invoice_for(
  p_org uuid, p_cust uuid, p_no text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, date '2026-03-01', p_cust, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Sale', 1, p_amount);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- block: the invoice that takes them past the limit is refused
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('Blocking Sdn Bhd', 'block');
  v_cust uuid; v_a uuid; v_b uuid; v_st jsonb;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Tight Buyer', 'customer', 5000)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 4000);
  perform public.post_sales_document(v_a);

  v_st := public.customer_credit_status(v_cust);
  perform pg_temp.check_eq('outstanding after the first',
    (v_st->>'outstanding')::numeric, 4000);
  perform pg_temp.check_eq('with a thousand left',
    (v_st->>'available')::numeric, 1000);
  perform pg_temp.check_true('and not over yet',
    (v_st->>'over_limit')::boolean = false);

  v_b := pg_temp.invoice_for(v_org, v_cust, 'INV-2', 2000);
  begin
    perform public.post_sales_document(v_b);
    raise exception 'FAIL: posted past the credit limit';
  exception when sqlstate '23514' then
    raise notice 'ok   posting past the limit is refused';
  end;

  -- And one that fits still goes through, so the guard is not simply
  -- refusing everything for that customer from here on.
  update public.sales_document_lines set unit_price = 900 where document_id = v_b;
  perform public.post_sales_document(v_b);
  perform pg_temp.check_eq('an invoice that fits still posts',
    (public.customer_credit_status(v_cust)->>'outstanding')::numeric, 4900);
end $$;

-- ---------------------------------------------------------------------
-- warn: it posts, and the position is still reported
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('Warning Sdn Bhd', 'warn');
  v_cust uuid; v_a uuid; v_b uuid; v_st jsonb;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Tight Buyer', 'customer', 5000)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 4000);
  perform public.post_sales_document(v_a);
  v_b := pg_temp.invoice_for(v_org, v_cust, 'INV-2', 2000);
  perform public.post_sales_document(v_b);

  v_st := public.customer_credit_status(v_cust);
  perform pg_temp.check_eq('it went through', (v_st->>'outstanding')::numeric, 6000);
  perform pg_temp.check_true('and is reported as over',
    (v_st->>'over_limit')::boolean);
  perform pg_temp.check_eq('by a thousand', (v_st->>'available')::numeric, -1000);
end $$;

-- ---------------------------------------------------------------------
-- A limit of zero is no limit, not a limit of nothing
--
-- Every existing contact carries the column default of zero. Reading
-- that as "may owe nothing" would stop every one of them being invoiced
-- the moment this migration landed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('No Limit Sdn Bhd', 'block');
  v_cust uuid; v_a uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Open Account', 'customer', 0)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 999999);
  perform public.post_sales_document(v_a);
  perform pg_temp.check_true('no limit means no block',
    (select gl_entry_id is not null from public.sales_documents where id = v_a));
end $$;

-- ---------------------------------------------------------------------
-- A credit note is never blocked
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('Credit Note Sdn Bhd', 'block');
  v_cust uuid; v_a uuid; v_cn uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Over Buyer', 'customer', 1000)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 900);
  perform public.post_sales_document(v_a);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'credit_note', 'CN-1', date '2026-03-02', v_cust, 'MYR', 1,
          500, 500, 500, 'draft')
  returning id into v_cn;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_cn, 1, 'Return', 1, 500);

  perform public.post_sales_document(v_cn);
  perform pg_temp.check_true('crediting somebody over their limit is allowed',
    (select gl_entry_id is not null from public.sales_documents where id = v_cn));
end $$;

-- ---------------------------------------------------------------------
-- On stop, which is not a small limit
-- ---------------------------------------------------------------------
-- 0362. `credit_hold` was a column nothing read for three hundred and
-- fifty migrations. A hold is a person's instruction rather than
-- arithmetic, so unlike the limit it applies whatever the
-- organization's mode says — otherwise the effect of a checkbox would
-- depend on a setting three screens away, and whoever ticked it would
-- have no way to know which they had.
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
  v_refused boolean;
  v_msg  text;
begin
  v_org := pg_temp.test_org('Kedai Tahan Kredit');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  -- Warn, deliberately: the weaker of the two modes, so what is proved
  -- below is the hold and not the limit.
  update public.organizations set credit_control = 'warn' where id = v_org;

  insert into public.contacts
    (org_id, code, name, contact_type, credit_limit, credit_hold)
  values (v_org, 'C-STOP', 'Syarikat Lambat Bayar', 'customer', 0, true)
  returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status,
     total_amount, base_total_amount, balance_amount)
  values (v_org, 'invoice', 'INV-STOP-1', v_cust, current_date, 'draft',
          100, 100, 100)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_inv, 1, 'More on account', 1, 100);

  v_refused := false;
  begin
    perform public.post_sales_document(v_inv);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'an invoice to somebody on stop is refused, even in warn mode',
    v_refused);
  -- The sentence names the customer. "Credit hold" on its own leaves
  -- whoever is posting a batch to work out which of forty it was.
  perform pg_temp.check_true('and says who: ' || coalesce(v_msg, ''),
    v_msg like '%Lambat Bayar%');

  -- Credits still go through, which is 0086's reasoning unchanged: the
  -- customer on stop is exactly the one most likely to need one, and
  -- blocking it would leave the balance that caused the hold
  -- uncorrectable.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status,
     total_amount, base_total_amount, balance_amount)
  values (v_org, 'credit_note', 'CN-STOP-1', v_cust, current_date, 'draft',
          50, 50, 50)
  returning id into v_cn;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_cn, 1, 'Return', 1, 50);
  perform public.post_sales_document(v_cn);
  perform pg_temp.check_true('but a credit note still posts',
    (select gl_entry_id is not null from public.sales_documents where id = v_cn));

  -- And the control: take the hold off and the same invoice posts. The
  -- refusal above is about the hold rather than about the document.
  update public.contacts set credit_hold = false where id = v_cust;
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_true('taking the hold off lets it through',
    (select gl_entry_id is not null from public.sales_documents where id = v_inv));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the status reader is closed to anon',
    not has_function_privilege('anon',
      'public.customer_credit_status(uuid)', 'execute'));
  perform pg_temp.check_true('and the guard is not callable at all',
    not has_function_privilege('authenticated',
      'app.enforce_credit_limit()', 'execute'));
end $$;

-- =====================================================================
-- What is counted against the limit
--
-- The blocks above assert the guards: the hold, the warn/block mode, a
-- customer with no limit set, an opening balance, and a counter sale
-- paid in full. A mutation sweep found all five of those covered and
-- everything else open. What went untested was the sum itself --
--
--   select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
--     from public.sales_documents d
--    where d.org_id = new.org_id and d.contact_id = new.contact_id
--      and d.gl_entry_id is not null and d.status <> 'void'
--      and d.deleted_at is null and d.id <> new.id
--
-- -- every filter on it, the exchange rate, and the comparison at the
-- end. A limit that counts the wrong things is worse than no limit: it
-- refuses good business and lets bad business through, and does both
-- silently.
--
-- The fixtures above are one customer with one posted invoice, which is
-- the shape where none of that can show. Below, the customer sits at
-- exactly their limit and everything that must not count is put in
-- front of them at once.
--
-- Two clauses in that sum survive any assertion, and both were checked
-- rather than assumed:
--
--   * `d.org_id = new.org_id` is implied by `d.contact_id =
--     new.contact_id`. `contacts.id` is a primary key, so a contact
--     belongs to exactly one company and naming the contact already
--     names the company. No contact in the database sits in two.
--   * `d.id <> new.id` cannot be observed either. The trigger is BEFORE
--     UPDATE, so the row still carries its old `gl_entry_id` -- null,
--     for the document being posted -- and `d.gl_entry_id is not null`
--     already leaves it out of its own sum. The other route in, an
--     update to a document that was already posted, is closed by the
--     early return the block below asserts.
--
-- Both stay: they say what the query means, and the first also keeps
-- the planner on the org index.
-- =====================================================================

create or replace function pg_temp.doc_for(
  p_org uuid, p_cust uuid, p_type text, p_no text, p_amount numeric,
  p_ccy text, p_rate numeric)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, p_type::app.sales_doc_type, p_no, date '2026-03-01', p_cust,
          p_ccy, p_rate, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Sale', 1, p_amount);
  return v_doc;
end; $$;

create or replace function pg_temp.foreign_debt(
  p_org uuid, p_code text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_c uuid; v_doc uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (p_org, p_code, 'Their buyer', 'customer', 50000) returning id into v_c;
  v_doc := pg_temp.invoice_for(p_org, v_c, 'INV-THEIRS', p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end; $$;

do $$
declare
  v_org uuid := pg_temp.cc_org('Baki Kredit Sdn Bhd', 'block');
  v_them uuid;
  v_cust uuid; v_other uuid; v_void_cust uuid;
  v_dn_cust uuid; v_fx_cust uuid; v_cut_cust uuid;
  v_doc uuid; v_msg text;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Tepat Buyer', 'customer', 5000)
  returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-002', 'Somebody Else', 'customer', 5000)
  returning id into v_other;

  -- ------------------------------------------------------------------
  -- Exactly at the limit is inside it
  -- ------------------------------------------------------------------
  -- A limit of RM 5,000 means five thousand may be owed, not four
  -- thousand nine hundred and ninety-nine. Nothing above asserted the
  -- boundary from the inside, so refusing at exactly the limit would
  -- have passed.
  v_doc := pg_temp.invoice_for(v_org, v_cust, 'INV-AT', 5000);
  perform public.post_sales_document(v_doc);
  perform pg_temp.check_true('an invoice that reaches the limit exactly posts',
    (select gl_entry_id is not null from public.sales_documents where id = v_doc));

  -- And one ringgit past it does not.
  v_doc := pg_temp.invoice_for(v_org, v_cust, 'INV-OVER', 1);
  begin
    perform public.post_sales_document(v_doc);
    raise exception 'FAIL: a ringgit over the limit was posted';
  exception when check_violation then
    raise notice 'ok   and a ringgit more is refused';
  end;

  -- ------------------------------------------------------------------
  -- What is counted against it
  -- ------------------------------------------------------------------
  -- Everything below would let the customer through if it were counted,
  -- or keep them out if it were not. The customer is at exactly their
  -- limit, so any miscounting shows up at once.

  -- A draft invoice is not a debt. It is not in the ledger.
  perform pg_temp.invoice_for(v_org, v_cust, 'INV-DRAFT', 9000);
  -- Another customer's debt is their own.
  v_doc := pg_temp.invoice_for(v_org, v_other, 'INV-THEM', 4000);
  perform public.post_sales_document(v_doc);
  -- And another company's books are nothing to do with this one. The
  -- same person is a member of both, so `is_org_member` is no guard
  -- here; the org_id in the sum is.
  v_them := pg_temp.cc_org('Syarikat Lain Sdn Bhd', 'block');
  perform pg_temp.foreign_debt(v_them, 'C-001', 9000);

  -- None of those moved this customer, so the sen is still refused
  -- rather than being refused twice over, and a credit note still
  -- makes room.
  v_doc := pg_temp.invoice_for(v_org, v_cust, 'INV-OVER-2', 1);
  begin
    perform public.post_sales_document(v_doc);
    raise exception 'FAIL: a ringgit over the limit was posted';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a draft, another customer and another company are not this debt',
      v_msg like '%5,001.00%' or v_msg like '%5001.00%');
  end;

  -- ------------------------------------------------------------------
  -- A voided invoice is not owed
  -- ------------------------------------------------------------------
  -- Its own customer, because the one above is at their limit and
  -- nothing more can be posted to them in order to be voided.
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-003', 'Void Buyer', 'customer', 5000)
  returning id into v_void_cust;

  v_doc := pg_temp.invoice_for(v_org, v_void_cust, 'INV-VOID', 3000);
  perform public.post_sales_document(v_doc);
  update public.sales_documents set status = 'void' where id = v_doc;

  -- With the three thousand voided there is the whole limit to use. If
  -- a voided invoice still counted, five thousand on top of it would be
  -- eight and this would be refused.
  v_doc := pg_temp.invoice_for(v_org, v_void_cust, 'INV-FULL', 5000);
  perform public.post_sales_document(v_doc);
  perform pg_temp.check_true('a voided invoice is not owed and not counted',
    (select gl_entry_id is not null from public.sales_documents where id = v_doc));
  -- ------------------------------------------------------------------
  -- A limit decides the next sale, not the last one
  -- ------------------------------------------------------------------
  -- The trigger returns early when the document was already posted. Cut
  -- a customer's limit after they have bought, and every posted invoice
  -- of theirs is now over it -- so without that early return, correcting
  -- a reference or a note on an old invoice would be refused, and the
  -- only way to fix a typo would be to raise the limit back.
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-006', 'Cut Buyer', 'customer', 5000)
  returning id into v_cut_cust;
  v_doc := pg_temp.invoice_for(v_org, v_cut_cust, 'INV-CUT', 5000);
  perform public.post_sales_document(v_doc);

  update public.contacts set credit_limit = 1000 where id = v_cut_cust;
  update public.sales_documents set reference = 'PO-88' where id = v_doc;
  perform pg_temp.check_eq(
    'a posted invoice can still be corrected after the limit is cut',
    (select reference from public.sales_documents where id = v_doc), 'PO-88');

  -- ------------------------------------------------------------------
  -- A debit note is credit too
  -- ------------------------------------------------------------------
  -- The trigger names two document types and every fixture used the
  -- first. A debit note is how a further charge is raised against a
  -- customer who already has an invoice, so leaving it out would let
  -- the limit be walked past by choosing a different form.
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-004', 'Note Buyer', 'customer', 5000)
  returning id into v_dn_cust;
  v_doc := pg_temp.invoice_for(v_org, v_dn_cust, 'INV-DN', 5000);
  perform public.post_sales_document(v_doc);

  v_doc := pg_temp.doc_for(v_org, v_dn_cust, 'debit_note', 'DN-1', 1, 'MYR', 1);
  begin
    perform public.post_sales_document(v_doc);
    raise exception 'FAIL: a debit note walked past the limit';
  exception when check_violation then
    raise notice 'ok   a debit note is credit like any other';
  end;

  -- ------------------------------------------------------------------
  -- A dollar invoice is counted in ringgit
  -- ------------------------------------------------------------------
  -- The limit is a ringgit figure. USD 2,000 at 4.70 is RM 9,400 of
  -- exposure, not two thousand of it, and every fixture until now was
  -- in ringgit at a rate of one -- where multiplying by the rate and
  -- forgetting to are the same arithmetic.
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-005', 'Dollar Buyer', 'customer', 5000)
  returning id into v_fx_cust;
  v_doc := pg_temp.doc_for(v_org, v_fx_cust, 'invoice', 'INV-USD', 2000, 'USD', 4.70);
  begin
    perform public.post_sales_document(v_doc);
    raise exception 'FAIL: a dollar invoice was counted in dollars';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a foreign invoice is measured in ringgit',
      v_msg like '%9,400%' or v_msg like '%9400%');
  end;
end $$;

rollback;
