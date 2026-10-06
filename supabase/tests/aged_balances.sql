-- =====================================================================
-- iAkauntan :: aged receivables and payables
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/aged_balances.sql
--
-- The assertion this file exists for is the footing: the aged listing
-- has to equal the control account in the nominal at the same date. A
-- listing that does not foot is reconciled by hand every month until
-- somebody stops believing both numbers.
--
-- The rest of the file is the cases where a listing built off today's
-- `balance_amount` gives a different answer from one built off the
-- ledger — an invoice settled after the as-at date, and cash received
-- before it against an invoice raised after it.
--
-- And the columns themselves. Both listings put every document into one
-- of five buckets, and each of the four boundaries is asserted from
-- both sides: the last day inside a column and the first day outside
-- it. A boundary asserted from one side only can be moved outwards and
-- nothing fails, which is how the sixty-day division on the receivables
-- side and every division on the payables side came to be movable.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.aged_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.party(
  p_org uuid, p_code text, p_name text, p_type app.contact_type)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, p_name, p_type)
  returning id into v_id;
  return v_id;
end;
$$;

-- A posted sales document of any type, one line, no tax.
create or replace function pg_temp.sales_doc(
  p_org uuid, p_contact uuid, p_type app.sales_doc_type, p_no text,
  p_amount numeric, p_date date, p_due date default null,
  p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type, p_no, p_date, p_due, p_contact, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount, p_amount);
  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end;
$$;

create or replace function pg_temp.bill(
  p_org uuid, p_contact uuid, p_type app.purchase_doc_type, p_no text,
  p_amount numeric, p_date date, p_due date default null)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type, p_no, p_date, p_due, p_contact, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Supplies', 1, p_amount);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

-- Cash in, optionally matched against one invoice.
create or replace function pg_temp.receipt(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date,
  p_invoice uuid default null, p_alloc numeric default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (p_org, p_no, p_date, p_contact, p_amount, p_amount, 'MYR', 1,
          pg_temp.a_bank_account(p_org))
  returning id into v_id;
  if p_invoice is not null then
    insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
    values (p_org, v_id, p_invoice, coalesce(p_alloc, p_amount));
  end if;
  perform public.post_receipt(v_id);
  return v_id;
end;
$$;

create or replace function pg_temp.pay(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date,
  p_bill uuid default null, p_alloc numeric default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  -- `0728` refuses a payment that does not say which account it was
  -- paid from, so the helper names the company's account rather than
  -- falling through to the 1120 heading.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (p_org, p_no, p_date, p_contact, p_amount, p_amount, 'MYR', 1,
          pg_temp.a_bank_account(p_org))
  returning id into v_id;
  if p_bill is not null then
    insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
    values (p_org, v_id, p_bill, coalesce(p_alloc, p_amount));
  end if;
  perform public.post_purchase_payment(v_id);
  return v_id;
end;
$$;

create or replace function pg_temp.ar_total(p_org uuid, p_as_at date)
returns numeric language sql as $$
  select coalesce(sum(base_outstanding), 0)
    from public.report_ar_aging(p_org, p_as_at);
$$;

create or replace function pg_temp.ap_total(p_org uuid, p_as_at date)
returns numeric language sql as $$
  select coalesce(sum(base_outstanding), 0)
    from public.report_ap_aging(p_org, p_as_at);
$$;

-- The nominal side of the same question. A debit balance comes back
-- positive, so the payable control returns negative and the caller
-- negates it.
create or replace function pg_temp.control(
  p_org uuid, p_code text, p_as_at date)
returns numeric language sql as $$
  select coalesce(
    (select closing_balance from public.report_trial_balance(p_org, null, p_as_at)
      where code = p_code), 0);
$$;

-- ---------------------------------------------------------------------
-- As at a date, not as of now
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Aged AR Sdn Bhd');
  v_cust uuid; v_inv1 uuid;
begin
  v_cust := pg_temp.party(v_org, 'C-001', 'Steady Bhd', 'customer');

  v_inv1 := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-1', 1000,
                              date '2026-01-15', date '2026-02-14');
  perform pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-2', 500,
                            date '2026-03-01', date '2026-03-31');

  -- Settled in April. Today's `balance_amount` on INV-1 is zero, which
  -- is why a listing built from that column cannot answer for March.
  perform pg_temp.receipt(v_org, v_cust, 'RCP-1', 1000, date '2026-04-05', v_inv1);

  -- Keyed but never posted: it is not in the ledger, so it is not on
  -- the listing either.
  perform pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-3', 9999,
                            date '2026-02-01', date '2026-03-03', false);

  perform pg_temp.check_eq('both invoices are open at the quarter end',
    pg_temp.ar_total(v_org, date '2026-03-31'), 1500);
  perform pg_temp.check_eq('and the one settled in April is one of them',
    (select outstanding from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'INV-1'), 1000);

  -- The assertion the file exists for.
  perform pg_temp.check_eq('the listing foots to the control account',
    pg_temp.ar_total(v_org, date '2026-03-31'),
    pg_temp.control(v_org, '1210', date '2026-03-31'));

  perform pg_temp.check_eq('a month later only the unpaid one is left',
    pg_temp.ar_total(v_org, date '2026-04-30'), 500);
  perform pg_temp.check_eq('and it still foots',
    pg_temp.ar_total(v_org, date '2026-04-30'),
    pg_temp.control(v_org, '1210', date '2026-04-30'));

  perform pg_temp.check_eq('an unposted invoice is not on the listing',
    (select count(*) from public.report_ar_aging(v_org, date '2026-04-30')
      where doc_no = 'INV-3'), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Where the buckets divide
--
-- Thirty days over and thirty-one days over land in different columns,
-- and an off-by-one here moves money between them on every statement.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Bucket Sdn Bhd');
  v_cust uuid;
begin
  v_cust := pg_temp.party(v_org, 'C-001', 'Late Bhd', 'customer');
  perform pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-1', 100,
                            date '2026-02-01', date '2026-03-01');

  perform pg_temp.check_true('current on the day it falls due',
    (select aging_bucket = 'current' and days_overdue = 0
       from public.report_ar_aging(v_org, date '2026-03-01')));
  perform pg_temp.check_true('one day over is one to thirty',
    (select aging_bucket = '1_30'
       from public.report_ar_aging(v_org, date '2026-03-02')));
  perform pg_temp.check_true('thirty days over is still one to thirty',
    (select aging_bucket = '1_30' and days_overdue = 30
       from public.report_ar_aging(v_org, date '2026-03-31')));
  perform pg_temp.check_true('thirty-one days over is not',
    (select aging_bucket = '31_60' and days_overdue = 31
       from public.report_ar_aging(v_org, date '2026-04-01')));
  -- Sixty and sixty-one, which the block did not divide. The 30 and 90
  -- boundaries were each asserted from both sides and this one from
  -- neither, so it could be moved anywhere between them and nothing
  -- failed. Found by moving it.
  perform pg_temp.check_true('sixty days over is thirty-one to sixty',
    (select aging_bucket = '31_60' and days_overdue = 60
       from public.report_ar_aging(v_org, date '2026-04-30')));
  perform pg_temp.check_true('sixty-one is not',
    (select aging_bucket = '61_90' and days_overdue = 61
       from public.report_ar_aging(v_org, date '2026-05-01')));
  perform pg_temp.check_true('and ninety days over is still sixty-one to ninety',
    (select aging_bucket = '61_90' and days_overdue = 90
       from public.report_ar_aging(v_org, date '2026-05-30')));
  perform pg_temp.check_true('ninety-one days over is the last column',
    (select aging_bucket = 'over_90'
       from public.report_ar_aging(v_org, date '2026-05-31')));

  -- An invoice with no due date ages from the day it was raised, which
  -- is the only date there is. Nothing in the app requires a due date,
  -- and an unallocated receipt reaches this listing with none by
  -- construction, so the fallback is load-bearing rather than defensive.
  perform pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-2', 50,
                            date '2026-02-01', null);
  perform pg_temp.check_true('an invoice with no due date ages from its own date',
    (select aging_bucket = '31_60' and days_overdue = 58
       from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'INV-2'));
  -- And is current on the day it was raised. This is the assertion the
  -- one above cannot make: `days_overdue` and all four bands below
  -- `current` fall back to the document date independently, so only the
  -- `current` test itself is left unguarded, and it fails towards
  -- one-to-thirty -- an invoice raised this morning, already overdue.
  perform pg_temp.check_true('and is current on the day it was raised',
    (select aging_bucket = 'current' and days_overdue = 0
       from public.report_ar_aging(v_org, date '2026-02-01')
      where doc_no = 'INV-2'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- And the same divisions on the supplier side
--
-- The block below asserts one bill four weeks past due, which crosses
-- no boundary at all: every one of the four could be moved anywhere and
-- nothing failed. A payables ageing is what a company reads to decide
-- who to pay, so the columns have to mean what they say.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('AP Bucket Sdn Bhd');
  v_supp uuid;
begin
  v_supp := pg_temp.party(v_org, 'S-001', 'Parts Bhd', 'supplier');
  perform pg_temp.bill(v_org, v_supp, 'bill', 'BILL-1', 100,
                       date '2026-02-01', date '2026-03-01');

  perform pg_temp.check_true('current on the day it falls due',
    (select aging_bucket = 'current' and days_overdue = 0
       from public.report_ap_aging(v_org, date '2026-03-01')));
  perform pg_temp.check_true('one day over is one to thirty',
    (select aging_bucket = '1_30'
       from public.report_ap_aging(v_org, date '2026-03-02')));
  perform pg_temp.check_true('thirty days over is still one to thirty',
    (select aging_bucket = '1_30' and days_overdue = 30
       from public.report_ap_aging(v_org, date '2026-03-31')));
  perform pg_temp.check_true('thirty-one days over is not',
    (select aging_bucket = '31_60' and days_overdue = 31
       from public.report_ap_aging(v_org, date '2026-04-01')));
  perform pg_temp.check_true('sixty days over is thirty-one to sixty',
    (select aging_bucket = '31_60' and days_overdue = 60
       from public.report_ap_aging(v_org, date '2026-04-30')));
  perform pg_temp.check_true('sixty-one is sixty-one to ninety',
    (select aging_bucket = '61_90' and days_overdue = 61
       from public.report_ap_aging(v_org, date '2026-05-01')));
  perform pg_temp.check_true('ninety days over is still sixty-one to ninety',
    (select aging_bucket = '61_90' and days_overdue = 90
       from public.report_ap_aging(v_org, date '2026-05-30')));
  perform pg_temp.check_true('ninety-one days over is the last column',
    (select aging_bucket = 'over_90'
       from public.report_ap_aging(v_org, date '2026-05-31')));

  -- And the same fallback: a bill with no due date ages from its own.
  perform pg_temp.bill(v_org, v_supp, 'bill', 'BILL-2', 50,
                       date '2026-02-01', null);
  perform pg_temp.check_true('a bill with no due date ages from its own date',
    (select aging_bucket = '31_60' and days_overdue = 58
       from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'BILL-2'));
  perform pg_temp.check_true('and is current on the day it was raised',
    (select aging_bucket = 'current' and days_overdue = 0
       from public.report_ap_aging(v_org, date '2026-02-01')
      where doc_no = 'BILL-2'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The credits belong on it too
--
-- An unallocated credit note and cash sitting unapplied are both part
-- of what the customer ledger owes. Leaving them off makes a tidier
-- report that does not foot.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Credit Sdn Bhd');
  v_cust uuid;
begin
  v_cust := pg_temp.party(v_org, 'C-001', 'Returns Bhd', 'customer');

  perform pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-1', 1000,
                            date '2026-01-15', date '2026-02-14');
  perform pg_temp.sales_doc(v_org, v_cust, 'credit_note', 'CN-1', 300,
                            date '2026-03-05');
  perform pg_temp.receipt(v_org, v_cust, 'RCP-1', 400, date '2026-03-20');

  perform pg_temp.check_eq('an unused credit note is a negative line',
    (select outstanding from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'CN-1'), -300);
  perform pg_temp.check_eq('so is cash nobody has matched yet',
    (select outstanding from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'RCP-1'), -400);
  perform pg_temp.check_eq('and the three of them foot to the control account',
    pg_temp.ar_total(v_org, date '2026-03-31'),
    pg_temp.control(v_org, '1210', date '2026-03-31'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Cash in March against an invoice raised in April
--
-- The receipt credited the receivable on the day it was banked. At 31
-- March that is unapplied cash, whatever it was matched to afterwards.
-- Reading the allocation without checking the date of the invoice at
-- the other end of it makes the money disappear from the listing while
-- the control account still carries it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Advance Sdn Bhd');
  v_cust uuid; v_rcp uuid; v_inv uuid;
begin
  v_cust := pg_temp.party(v_org, 'C-001', 'Prepay Bhd', 'customer');

  v_rcp := pg_temp.receipt(v_org, v_cust, 'RCP-1', 300, date '2026-03-10');
  v_inv := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-1', 800,
                             date '2026-04-01', date '2026-05-01');
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 300);

  perform pg_temp.check_eq('at 31 March it is still money on account',
    pg_temp.ar_total(v_org, date '2026-03-31'), -300);
  perform pg_temp.check_eq('which is what the control account says',
    pg_temp.ar_total(v_org, date '2026-03-31'),
    pg_temp.control(v_org, '1210', date '2026-03-31'));
  perform pg_temp.check_eq('the invoice is not on a March listing at all',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'INV-1'), 0);

  perform pg_temp.check_eq('by 30 April it has been applied',
    pg_temp.ar_total(v_org, date '2026-04-30'), 500);
  perform pg_temp.check_eq('and that foots as well',
    pg_temp.ar_total(v_org, date '2026-04-30'),
    pg_temp.control(v_org, '1210', date '2026-04-30'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The same on the supplier side
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Aged AP Sdn Bhd');
  v_supp uuid; v_bill uuid;
begin
  v_supp := pg_temp.party(v_org, 'S-001', 'Parts Bhd', 'supplier');

  v_bill := pg_temp.bill(v_org, v_supp, 'bill', 'BILL-1', 2000,
                         date '2026-02-01', date '2026-03-03');
  perform pg_temp.pay(v_org, v_supp, 'PAY-1', 800, date '2026-04-10', v_bill);

  perform pg_temp.check_eq('the whole bill is owed at the quarter end',
    pg_temp.ap_total(v_org, date '2026-03-31'), 2000);
  -- A payable sits credit side, so the trial balance shows it negative.
  perform pg_temp.check_eq('which is the control account, the other way up',
    pg_temp.ap_total(v_org, date '2026-03-31'),
    -pg_temp.control(v_org, '2110', date '2026-03-31'));
  perform pg_temp.check_true('four weeks past due, and aged as such',
    (select aging_bucket = '1_30' and days_overdue = 28
       from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'BILL-1'));

  perform pg_temp.check_eq('the part payment shows in April',
    pg_temp.ap_total(v_org, date '2026-04-30'), 1200);
  perform pg_temp.check_eq('still footing',
    pg_temp.ap_total(v_org, date '2026-04-30'),
    -pg_temp.control(v_org, '2110', date '2026-04-30'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The receivables listing, rule by rule
--
-- A mutation sweep of `report_ar_aging` found these unasserted, with
-- nine test files reaching the function: a debit note, and what was
-- paid against one; a deleted invoice; and money that has not reached
-- the ledger -- a receipt keyed but never posted, one posted and then
-- deleted, and a credit note never posted -- each of which can carry an
-- allocation, because `app.apply_allocation` checks whose money it is
-- and how much, and not whether it was ever posted.
--
-- Not asserted, because no data can tell them apart: an allocation
-- filed under another company (`payment_allocations` has a composite
-- foreign key to the document's company and refuses it, 23503), and
-- `coalesce(exchange_rate, 1)` (the column is NOT NULL on all three
-- tables it is read from).
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Rules AR Sdn Bhd');
  v_cust uuid; v_inv uuid; v_gone uuid; v_dn uuid; v_cn uuid;
  v_draft uuid; v_rcp uuid;
begin
  v_cust := pg_temp.party(v_org, 'C-001', 'Rules Bhd', 'customer');
  v_inv := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-1', 1000,
                             date '2026-02-01', date '2026-03-03');

  -- A debit note adds to what is owed and is paid like an invoice.
  v_dn := pg_temp.sales_doc(v_org, v_cust, 'debit_note', 'DN-1', 300,
                            date '2026-02-10', date '2026-03-12');
  perform pg_temp.receipt(v_org, v_cust, 'RCP-DN', 100, date '2026-02-20',
                          v_dn);
  perform pg_temp.check_eq('a debit note is on the listing, less what paid it',
    (select outstanding from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'DN-1'), 200);

  -- A posted invoice deleted afterwards is not chased.
  v_gone := pg_temp.sales_doc(v_org, v_cust, 'invoice', 'INV-GONE', 700,
                              date '2026-02-01', date '2026-03-03');
  update public.sales_documents set deleted_at = now() where id = v_gone;
  perform pg_temp.check_eq('a deleted invoice is not on the listing',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'INV-GONE'), 0);

  -- A receipt keyed and matched but never posted: no money moved, so
  -- the invoice is still owed in full and the receipt is no line.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org, 'RCP-DRAFT', date '2026-02-15', v_cust, 250, 250, 'MYR', 1,
          pg_temp.a_bank_account(v_org))
  returning id into v_draft;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_draft, v_inv, 250);

  -- A credit note raised and matched but never posted: the same.
  v_cn := pg_temp.sales_doc(v_org, v_cust, 'credit_note', 'CN-DRAFT', 50,
                            date '2026-02-16', null, false);
  insert into public.payment_allocations (org_id, credit_note_id, invoice_id, amount)
  values (v_org, v_cn, v_inv, 50);

  -- And one posted and then deleted.
  v_rcp := pg_temp.receipt(v_org, v_cust, 'RCP-GONE', 150, date '2026-02-17',
                           v_inv);
  update public.receipts set deleted_at = now() where id = v_rcp;

  perform pg_temp.check_eq(
    'only money that reached the ledger settles an invoice',
    (select outstanding from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'INV-1'), 1000);
  perform pg_temp.check_eq('a receipt never posted is not a line',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'RCP-DRAFT'), 0);
  perform pg_temp.check_eq('nor is one posted and deleted',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31')
      where doc_no = 'RCP-GONE'), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The payables listing, rule by rule
--
-- The same sweep of `report_ap_aging` killed 3 of 37 on this file before
-- this block was added: the payables side had one bill, one payment and
-- the bucket edges. Each row below is one rule of the report's: a
-- purchase debit note and what paid it, a purchase credit note, a bill
-- not posted, void, deleted, or dated after the as-at date, cash paid
-- and not matched, and part matched, and money
-- that never reached the ledger -- a payment never posted, one posted
-- then deleted or voided, a withholding certificate never posted or
-- voided -- each carrying an allocation, which `app.apply_allocation`
-- allows because it checks whose money it is and how much, and not
-- whether it was ever posted.
--
-- Not asserted, because no data can tell them apart: an allocation
-- filed under another company (`payment_allocations` has a composite
-- foreign key to the document's company and refuses it, 23503), and
-- `coalesce(exchange_rate, 1)` (the column is NOT NULL), and the
-- bill's `discount_amount` (`allocation_discount_guard` refuses one
-- written onto an allocation, and `allocate_with_discount`, the only
-- door, settles invoices and never bills).
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Rules AP Sdn Bhd');
  v_supp uuid; v_bill uuid; v_pdn uuid; v_id uuid; v_pay uuid;
  v_cert uuid;
begin
  v_supp := pg_temp.party(v_org, 'S-001', 'Rules Supplies', 'supplier');
  v_bill := pg_temp.bill(v_org, v_supp, 'bill', 'BILL-1', 1000,
                         date '2026-02-01', date '2026-03-03');

  -- A purchase debit note adds to what is owed and is paid like a bill.
  v_pdn := pg_temp.bill(v_org, v_supp, 'purchase_debit_note', 'PDN-1', 300,
                        date '2026-02-10', date '2026-03-12');
  perform pg_temp.pay(v_org, v_supp, 'PAY-DN', 100, date '2026-02-20', v_pdn);
  perform pg_temp.check_eq('a purchase debit note is listed, less what paid it',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'PDN-1'), 200);

  -- A purchase credit note takes away, and stands until reversed.
  perform pg_temp.bill(v_org, v_supp, 'purchase_credit_note', 'PCN-1', 120,
                       date '2026-02-12');
  perform pg_temp.check_eq('a purchase credit note is a negative line',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'PCN-1'), -120);

  -- Bills that are not owed at 31 March, one way each.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-DRAFT', date '2026-02-01', date '2026-03-03',
          v_supp, 'MYR', 1, 999, 999, 999, 'draft');
  v_id := pg_temp.bill(v_org, v_supp, 'bill', 'BILL-VOID', 400,
                       date '2026-02-01', date '2026-03-03');
  update public.purchase_documents set status = 'void' where id = v_id;
  v_id := pg_temp.bill(v_org, v_supp, 'bill', 'BILL-GONE', 500,
                       date '2026-02-01', date '2026-03-03');
  update public.purchase_documents set deleted_at = now() where id = v_id;
  perform pg_temp.bill(v_org, v_supp, 'bill', 'BILL-APRIL', 600,
                       date '2026-04-05', date '2026-05-05');
  perform pg_temp.check_eq('no bill unposted, void, deleted or not yet raised',
    (select count(*) from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no in ('BILL-DRAFT', 'BILL-VOID', 'BILL-GONE', 'BILL-APRIL')), 0);

  -- Paid out and not matched: a debit on the supplier's account.
  perform pg_temp.pay(v_org, v_supp, 'PAY-UN', 400, date '2026-03-20');
  perform pg_temp.check_eq('a payment nobody has matched is a negative line',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'PAY-UN'), -400);

  -- Part matched: three hundred to BILL-1, two hundred still loose.
  perform pg_temp.pay(v_org, v_supp, 'PAY-PART', 500, date '2026-02-25',
                      v_bill, 300);
  perform pg_temp.check_eq('a part-matched payment shows what is left of it',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'PAY-PART'), -200);

  -- Money that never reached the ledger, each matched to BILL-1.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org, 'PAY-DRAFT', date '2026-02-27', v_supp, 70, 70, 'MYR', 1,
          pg_temp.a_bank_account(v_org))
  returning id into v_pay;
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay, v_bill, 70);
  v_pay := pg_temp.pay(v_org, v_supp, 'PAY-GONE', 60, date '2026-02-27',
                       v_bill);
  update public.purchase_payments set deleted_at = now() where id = v_pay;
  v_pay := pg_temp.pay(v_org, v_supp, 'PAY-VOID', 50, date '2026-02-27',
                       v_bill);
  update public.purchase_payments set status = 'void' where id = v_pay;

  -- One thousand, less the three hundred paid. Nothing else that
  -- names it reached the ledger.
  perform pg_temp.check_eq('only money that reached the ledger settles a bill',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'BILL-1'), 700);
  perform pg_temp.check_eq('and no payment that did not reach it is a line',
    (select count(*) from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no in ('PAY-DRAFT', 'PAY-GONE', 'PAY-VOID')), 0);

  -- And a withholding certificate, which settles a bill only once it
  -- is posted and only while it stands. One posted and then voided, one
  -- never posted but matched by hand: neither has moved 2110.
  v_bill := pg_temp.bill(v_org, v_supp, 'bill', 'BILL-W', 1000,
                         date '2026-02-01', date '2026-03-03');
  v_cert := public.create_withholding(v_bill, 'S109B_SPECIAL',
    p_gross_amount => 1000, p_cert_date => date '2026-02-15');
  perform public.post_withholding(v_cert);
  perform pg_temp.check_eq('a posted certificate settles its tax off the bill',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'BILL-W'), 900);
  update public.withholding_certificates set status = 'void' where id = v_cert;
  v_cert := public.create_withholding(v_bill, 'S109B_SPECIAL',
    p_gross_amount => 1000, p_cert_date => date '2026-02-16');
  insert into public.payment_allocations (org_id, withholding_id, bill_id, amount)
  values (v_org, v_cert, v_bill, 100);
  perform pg_temp.check_eq('a void or unposted one settles nothing',
    (select outstanding from public.report_ap_aging(v_org, date '2026-03-31')
      where doc_no = 'BILL-W'), 1000);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The three ways of being paid the listings never saw (0747)
--
-- A contra, a deposit applied and a post-dated cheque each credit the
-- control account and write an allocation, and until `0747` neither
-- listing read them: one invoice settled each way left the receivables
-- listing at 7,000.00 with 1210 at 2,200.00. Each is asserted on the
-- day before its journal and on the day of it, and the listing is
-- footed to the control account on both days, on both sides.
--
-- The deposit is applied with a date in February, on a day in October:
-- `allocated_at` is the moment the button was pressed, so a listing
-- that read it instead of `applied_on` would put February's settlement
-- in October.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.aged_org('Three Ways Sdn Bhd');
  v_party uuid; v_inv_c uuid; v_inv_d uuid; v_inv_p uuid;
  v_bill_c uuid; v_bill_d uuid; v_bill_p uuid;
  v_contra uuid; v_dep uuid; v_pdc uuid; v_owner uuid;
  v_bank uuid;
  v_other uuid;
begin
  v_owner := (select created_by from public.organizations where id = v_org);
  v_bank := pg_temp.a_bank_account(v_org);
  -- One party on both ledgers, which is what a contra needs.
  v_party := pg_temp.party(v_org, 'B-001', 'Dua Hala Bhd', 'both');

  v_inv_c := pg_temp.sales_doc(v_org, v_party, 'invoice', 'INV-C', 1000,
                               date '2026-01-10', date '2026-02-09');
  v_inv_d := pg_temp.sales_doc(v_org, v_party, 'invoice', 'INV-D', 2000,
                               date '2026-01-10', date '2026-02-09');
  v_inv_p := pg_temp.sales_doc(v_org, v_party, 'invoice', 'INV-P', 4000,
                               date '2026-01-10', date '2026-02-09');
  v_bill_c := pg_temp.bill(v_org, v_party, 'bill', 'BILL-C', 700,
                           date '2026-01-12', date '2026-02-11');
  v_bill_d := pg_temp.bill(v_org, v_party, 'bill', 'BILL-D', 900,
                           date '2026-01-12', date '2026-02-11');
  v_bill_p := pg_temp.bill(v_org, v_party, 'bill', 'BILL-P', 600,
                           date '2026-01-12', date '2026-02-11');

  -- 15 February: three hundred set off both ways.
  v_contra := public.create_contra(v_org, date '2026-02-15',
    jsonb_build_array(jsonb_build_object('document', v_inv_c, 'amount', 300)),
    jsonb_build_array(jsonb_build_object('document', v_bill_c, 'amount', 300)),
    'Agreed');

  -- 20 February: his deposit of 500 applied, and ours of 200 to him.
  v_dep := public.create_deposit(v_org, 'customer', v_party,
    date '2026-01-05', 500, v_bank, '02', 'CHQ 1', 'Up front');
  perform public.apply_deposit(v_dep, v_inv_d, 500, date '2026-02-20');
  perform public.apply_deposit(
    public.create_deposit(v_org, 'supplier', v_party, date '2026-01-06', 200,
                          v_bank, '02', 'CHQ 2', 'Up front'),
    v_bill_d, 200, date '2026-02-20');

  -- 25 February: his cheque for INV-P taken in, ours for BILL-P written.
  v_pdc := public.record_pdc(v_org, 'incoming', v_party, '100001',
    date '2026-03-25', 4000,
    jsonb_build_array(jsonb_build_object('document', v_inv_p, 'amount', 4000)),
    v_bank, 'CIMB', date '2026-02-25');
  perform public.record_pdc(v_org, 'outgoing', v_party, '200001',
    date '2026-03-25', 600,
    jsonb_build_array(jsonb_build_object('document', v_bill_p, 'amount', 600)),
    v_bank, 'MBB', date '2026-02-25');

  -- The day before each.
  perform pg_temp.check_eq('the day before the contra, the invoice is whole',
    (select outstanding from public.report_ar_aging(v_org, date '2026-02-14')
      where doc_no = 'INV-C'), 1000);
  perform pg_temp.check_eq('and so is the bill',
    (select outstanding from public.report_ap_aging(v_org, date '2026-02-14')
      where doc_no = 'BILL-C'), 700);
  perform pg_temp.check_eq('the day before the deposit was applied, whole',
    (select outstanding from public.report_ar_aging(v_org, date '2026-02-19')
      where doc_no = 'INV-D'), 2000);
  perform pg_temp.check_eq('the day before the cheque came, whole',
    (select outstanding from public.report_ar_aging(v_org, date '2026-02-24')
      where doc_no = 'INV-P'), 4000);

  -- And on the day.
  perform pg_temp.check_eq('a contra settles the invoice on its own date',
    (select outstanding from public.report_ar_aging(v_org, date '2026-02-15')
      where doc_no = 'INV-C'), 700);
  perform pg_temp.check_eq('and the bill',
    (select outstanding from public.report_ap_aging(v_org, date '2026-02-15')
      where doc_no = 'BILL-C'), 400);
  perform pg_temp.check_eq('a deposit settles from the day it was applied',
    (select outstanding from public.report_ar_aging(v_org, date '2026-02-20')
      where doc_no = 'INV-D'), 1500);
  perform pg_temp.check_eq('and a deposit paid away settles the bill',
    (select outstanding from public.report_ap_aging(v_org, date '2026-02-20')
      where doc_no = 'BILL-D'), 700);
  perform pg_temp.check_eq('a cheque taken in settles the invoice',
    (select count(*) from public.report_ar_aging(v_org, date '2026-02-25')
      where doc_no = 'INV-P'), 0);
  perform pg_temp.check_eq('and a cheque written out settles the bill',
    (select count(*) from public.report_ap_aging(v_org, date '2026-02-25')
      where doc_no = 'BILL-P'), 0);

  -- The assertion the file exists for, at both dates and on both sides.
  perform pg_temp.check_eq('the receivables listing foots, before',
    pg_temp.ar_total(v_org, date '2026-02-14'),
    pg_temp.control(v_org, '1210', date '2026-02-14'));
  perform pg_temp.check_eq('and after all three',
    pg_temp.ar_total(v_org, date '2026-02-28'),
    pg_temp.control(v_org, '1210', date '2026-02-28'));
  perform pg_temp.check_eq('which is 2,200.00 of 7,000.00',
    pg_temp.ar_total(v_org, date '2026-02-28'), 2200);
  perform pg_temp.check_eq('the payables listing foots, before',
    pg_temp.ap_total(v_org, date '2026-02-14'),
    -pg_temp.control(v_org, '2110', date '2026-02-14'));
  perform pg_temp.check_eq('and after',
    pg_temp.ap_total(v_org, date '2026-02-28'),
    -pg_temp.control(v_org, '2110', date '2026-02-28'));
  perform pg_temp.check_eq('which is 1,100.00 of 2,200.00',
    pg_temp.ap_total(v_org, date '2026-02-28'), 1100);

  -- Undone: the cheque bounces and the contra is voided. Both delete
  -- their allocations and both journals are reversed, so as at today
  -- the invoices are whole again and the listing still foots.
  perform public.bounce_pdc(v_pdc, 'Refer to drawer', date '2026-03-26');
  perform public.void_contra(v_contra, 'He changed his mind');
  perform pg_temp.check_eq('a bounced cheque puts the invoice back',
    (select outstanding from public.report_ar_aging(v_org)
      where doc_no = 'INV-P'), 4000);
  perform pg_temp.check_eq('a voided contra puts the invoice back',
    (select outstanding from public.report_ar_aging(v_org)
      where doc_no = 'INV-C'), 1000);
  perform pg_temp.check_eq('and the listing still foots today',
    pg_temp.ar_total(v_org, pg_temp.today()),
    pg_temp.control(v_org, '1210', pg_temp.today()));

  -- Another company's payment is not on this company's payables.
  v_other := pg_temp.aged_org('Three Ways Other Sdn Bhd');
  perform pg_temp.pay(v_other,
    pg_temp.party(v_other, 'S-001', 'Theirs', 'supplier'),
    'PAY-THEIRS', 333, date '2026-02-01');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('another company''s payment is not on the listing',
    (select count(*) from public.report_ap_aging(v_org, date '2026-02-28')
      where doc_no = 'PAY-THEIRS'), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who can read a customer ledger
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a stranger cannot age a customer ledger',
    not has_function_privilege('anon',
      'public.report_ar_aging(uuid, date)', 'execute')
    and not has_function_privilege('anon',
      'public.report_ap_aging(uuid, date)', 'execute'));

  perform pg_temp.check_true('a member can',
    has_function_privilege('authenticated',
      'public.report_ar_aging(uuid, date)', 'execute')
    and has_function_privilege('authenticated',
      'public.report_ap_aging(uuid, date)', 'execute'));

  -- The views these replaced computed the same five buckets a second
  -- time, against today rather than against a date.
  perform pg_temp.check_true('and the views that disagreed are gone',
    to_regclass('public.v_ar_aging') is null
    and to_regclass('public.v_ap_aging') is null);
end $$;

rollback;
