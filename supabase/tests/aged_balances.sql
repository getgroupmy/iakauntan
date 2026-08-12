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
     currency, exchange_rate)
  values (p_org, p_no, p_date, p_contact, p_amount, p_amount, 'MYR', 1)
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
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate)
  values (p_org, p_no, p_date, p_contact, p_amount, p_amount, 'MYR', 1)
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
  perform pg_temp.check_true('ninety-one days over is the last column',
    (select aging_bucket = 'over_90'
       from public.report_ar_aging(v_org, date '2026-05-31')));

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
