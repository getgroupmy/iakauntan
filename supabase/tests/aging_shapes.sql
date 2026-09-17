-- =====================================================================
-- iAkauntan :: the documents an aged listing has to leave off
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/aging_shapes.sql
--
-- `aged_balances.sql` does the hard part: it foots the listing against
-- the control account, and it pins all four bucket boundaries from both
-- sides. A mutation sweep of the two reports still killed only 20 of
-- 42, and everything that lived was about WHAT IS ON THE LISTING rather
-- than which column it lands in.
--
-- A quotation, an unallocated receipt, a voided receipt, a receipt
-- banked by another company, a credit note half used, a settlement
-- discount: every one is an ordinary row, and each of the two reports
-- has a `where` clause that exists to keep it off or a piece of
-- arithmetic that exists to net it down.
--
-- The nine assertions the two reports share are written once and run
-- against both, because the tail of the two functions is word for word
-- the same and a fixture that only exercises the receivable half is how
-- the payable half came to be movable in the first place.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ag_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end $$;

create or replace function pg_temp.ag_party(
  p_org uuid, p_code text, p_name text, p_type app.contact_type)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, p_name, p_type) returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.ag_sales(
  p_org uuid, p_contact uuid, p_type app.sales_doc_type, p_no text,
  p_amount numeric, p_date date, p_due date default null,
  p_post boolean default true, p_currency char(3) default 'MYR',
  p_rate numeric default 1)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type, p_no, p_date, p_due, p_contact, p_currency, p_rate,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount, p_amount);
  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end $$;

create or replace function pg_temp.ag_bill(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date,
  p_due date default null, p_currency char(3) default 'MYR',
  p_rate numeric default 1)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'bill', p_no, p_date, p_due, p_contact, p_currency, p_rate,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Supplies', 1, p_amount);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end $$;

create or replace function pg_temp.ag_receipt(
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
end $$;

-- =====================================================================
-- 1. What both listings share
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_supp  uuid;
  v_paid  uuid;
  v_early uuid;
  v_fx    uuid;
  v_odd   uuid;
  v_zed   uuid;
  v_alfa  uuid;
  r       record;
begin
  v_org  := pg_temp.ag_org('Penuaan Sdn Bhd');
  v_cust := pg_temp.ag_party(v_org, 'C-1', 'Zulu Trading', 'customer');
  v_supp := pg_temp.ag_party(v_org, 'S-1', 'Zulu Supplies', 'supplier');

  -- MUTANT: `where round(d.outstanding, 2) <> 0` -> true. An invoice
  -- paid in full is not a receivable, and a listing that keeps every
  -- settled document a company has ever raised is a listing nobody can
  -- read -- and one whose total is right only because the zeros add up
  -- to nothing.
  v_paid := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-PAID', 1000,
                             date '2026-01-10', date '2026-02-10');
  perform pg_temp.ag_receipt(v_org, v_cust, 'RC-1', 1000, date '2026-01-20',
                             v_paid);
  perform pg_temp.check_eq('a settled invoice is off the listing',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31') a
      where a.document_id = v_paid), 0);

  -- MUTANT: `greatest(0, ...)` dropped from days_overdue. A document not
  -- yet due is nought days overdue, not minus forty. The column is read
  -- straight onto a screen and into a chasing letter.
  v_early := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-EARLY', 500,
                              date '2026-03-01', date '2026-05-10');
  select * into r from public.report_ar_aging(v_org, date '2026-03-31') a
   where a.document_id = v_early;
  perform pg_temp.check_eq('a document not yet due is nought days overdue',
    r.days_overdue::numeric, 0);
  perform pg_temp.check_eq('and sits in the current column',
    r.aging_bucket, 'current');

  -- MUTANT: `round(d.outstanding * d.rate, 2)` replaced by the foreign
  -- amount. USD1,000 at 4.50 is RM4,500 of receivable, and the two
  -- columns exist because one of them is what the balance sheet says.
  v_fx := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-USD', 1000,
                           date '2026-03-01', date '2026-03-10', true,
                           'USD', 4.50);
  select * into r from public.report_ar_aging(v_org, date '2026-03-31') a
   where a.document_id = v_fx;
  perform pg_temp.check_eq('the foreign column is in the foreign money',
    r.outstanding, 1000);
  perform pg_temp.check_eq('and the base column is in ringgit',
    r.base_outstanding, 4500);

  -- MUTANT: `round(d.outstanding, 2)` dropped. A third of a ringgit is
  -- an ordinary part payment, and a listing is a column of figures
  -- somebody adds up by hand.
  v_odd := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-ODD', 1000,
                            date '2026-03-01', date '2026-03-10');
  perform pg_temp.ag_receipt(v_org, v_cust, 'RC-ODD', 333.34,
                             date '2026-03-05', v_odd, 333.34);
  perform pg_temp.check_eq('the listing is in sen',
    (select a.outstanding::text from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_odd), '666.66');

  -- MUTANT: `order by c.name, d.doc_date, d.doc_no` -> by doc_no alone.
  -- The listing is read customer by customer; ordering it by document
  -- number scatters each customer's documents through the page.
  v_alfa := pg_temp.ag_party(v_org, 'C-2', 'Alfa Trading', 'customer');
  perform pg_temp.ag_sales(v_org, v_alfa, 'invoice', 'ZZ-1', 700,
                           date '2026-03-01', date '2026-03-10');
  perform pg_temp.check_eq('the listing is ordered by customer first',
    (select a.contact_name from public.report_ar_aging(
       v_org, date '2026-03-31') a limit 1), 'Alfa Trading');

  -- And the same on the payables side, whose tail is word for word the
  -- same function and whose fixtures had none of these.
  perform pg_temp.ag_bill(v_org, v_supp, 'BILL-EARLY', 500,
                          date '2026-03-01', date '2026-05-10');
  select * into r from public.report_ap_aging(v_org, date '2026-03-31') a
   where a.doc_no = 'BILL-EARLY';
  perform pg_temp.check_eq('a bill not yet due is nought days overdue',
    r.days_overdue::numeric, 0);

  perform pg_temp.ag_bill(v_org, v_supp, 'BILL-USD', 1000,
                          date '2026-03-01', date '2026-03-10', 'USD', 4.50);
  select * into r from public.report_ap_aging(v_org, date '2026-03-31') a
   where a.doc_no = 'BILL-USD';
  perform pg_temp.check_eq('a foreign bill is listed in both moneys',
    r.outstanding::text || '/' || r.base_outstanding::text, '1000.00/4500.00');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-2', 'Alfa Supplies', 'supplier');
  perform pg_temp.ag_bill(v_org,
    (select id from public.contacts where org_id = v_org and code = 'S-2'),
    'ZZ-BILL', 700, date '2026-03-01', date '2026-03-10');
  perform pg_temp.check_eq('and the payables listing is ordered by supplier',
    (select a.contact_name from public.report_ap_aging(
       v_org, date '2026-03-31') a limit 1), 'Alfa Supplies');

  -- MUTANT: `where round(d.outstanding, 2) <> 0` -> true, on the
  -- PAYABLES side, whose fixtures never settle a bill in full.
  perform pg_temp.ag_bill(v_org, v_supp, 'BILL-PAID', 900,
                          date '2026-01-10', date '2026-02-10');
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, currency,
     exchange_rate)
  values (v_org, 'PY-PAID', date '2026-01-20', v_supp, 900, 'MYR', 1);
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  select v_org,
         (select id from public.purchase_payments
           where org_id = v_org and payment_no = 'PY-PAID'),
         (select id from public.purchase_documents
           where org_id = v_org and doc_no = 'BILL-PAID'),
         900;
  perform public.post_purchase_payment(
    (select id from public.purchase_payments
      where org_id = v_org and payment_no = 'PY-PAID'));
  perform pg_temp.check_eq('a settled bill is off the payables listing',
    (select count(*) from public.report_ap_aging(v_org, date '2026-03-31') a
      where a.doc_no = 'BILL-PAID'), 0);

  -- MUTANT: `round(d.outstanding, 2)` deleted, on both listings.
  --
  -- IT SURVIVES, because every figure that reaches the subtraction is
  -- already in sen: `total_amount` and `payment_allocations.amount` are
  -- both numeric(18,2), so their difference cannot have a third decimal
  -- to round away. The COLUMN SCALES are what make the round redundant,
  -- and widening one would make it load-bearing again -- so the scales
  -- are what is asserted.
  perform pg_temp.check_eq('every figure the listing subtracts is in sen',
    (select count(*) from information_schema.columns
      where table_schema = 'public'
        and ((table_name = 'sales_documents' and column_name = 'total_amount')
          or (table_name = 'purchase_documents' and column_name = 'total_amount')
          or (table_name = 'payment_allocations'
              and column_name in ('amount', 'discount_amount'))
          or (table_name = 'receipts' and column_name = 'amount')
          or (table_name = 'purchase_payments' and column_name = 'amount'))
        and numeric_scale = 2), 6);

  raise notice 'ok   what both listings share';
end $$;

-- =====================================================================
-- 2. Documents and receipts that must not reach the listing
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_cust   uuid;
  v_quote  uuid;
  v_inv    uuid;
  v_rec    uuid;
  v_void   uuid;
  v_late   uuid;
  v_unapp  uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ag_org('Bukan Penghutang Sdn Bhd');
  v_cust := pg_temp.ag_party(v_org, 'C-1', 'Pelanggan', 'customer');

  -- MUTANT: `d.doc_type in ('invoice','debit_note','credit_note',
  -- 'refund_note')` dropped.
  --
  -- IT SURVIVES, and the reason is worth writing down: the list is word
  -- for word the list in `post_sales_document_internal`, and the next
  -- condition is `d.gl_entry_id is not null`. Nothing that is not one
  -- of those four can ever have a ledger entry, so the type filter is a
  -- second lock on the same door.
  --
  -- The two lists AGREEING is the rule, and it is a rule nothing
  -- re-checks: widen the posting list to let a proforma into the ledger
  -- and this report silently stops counting it. So what is asserted is
  -- the pairing -- every sales document type that is not one of the four
  -- is refused at the ledger door, by name.
  v_quote := pg_temp.ag_sales(v_org, v_cust, 'quotation', 'QT-1', 9000,
                              date '2026-01-10', date '2026-02-10', false);
  perform pg_temp.check_refused('a quotation cannot reach the ledger',
    format($q$ select public.post_sales_document(%L) $q$, v_quote),
    '%does not post to the ledger%');
  perform pg_temp.check_eq('and so is not a receivable',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31') a
      where a.document_id = v_quote), 0);

  perform pg_temp.check_refused('nor can a sales order',
    format($q$ select public.post_sales_document(%L) $q$,
           pg_temp.ag_sales(v_org, v_cust, 'sales_order', 'SO-1', 100,
                            date '2026-01-10', null, false)),
    '%does not post to the ledger%');
  perform pg_temp.check_refused('nor a delivery order',
    format($q$ select public.post_sales_document(%L) $q$,
           pg_temp.ag_sales(v_org, v_cust, 'delivery_order', 'DO-1', 100,
                            date '2026-01-10', null, false)),
    '%does not post to the ledger%');
  perform pg_temp.check_refused('nor a proforma',
    format($q$ select public.post_sales_document(%L) $q$,
           pg_temp.ag_sales(v_org, v_cust, 'proforma', 'PF-1', 100,
                            date '2026-01-10', null, false)),
    '%does not post to the ledger%');

  -- Which is every type the enum has beyond the four the listing names.
  perform pg_temp.check_eq('and that is every other type there is',
    (select count(*) from unnest(enum_range(null::app.sales_doc_type)) t
      where t::text not in ('invoice', 'credit_note', 'debit_note',
                            'refund_note')), 4);

  -- MUTANT: `r.status <> 'void'` dropped from the receipt arm. A voided
  -- receipt is money that did not arrive; on the listing it reads as a
  -- credit the customer does not have.
  v_inv  := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-1', 5000,
                             date '2026-01-10', date '2026-02-10');
  v_void := pg_temp.ag_receipt(v_org, v_cust, 'RC-VOID', 2000,
                               date '2026-01-20');
  update public.receipts set status = 'void' where id = v_void;
  perform pg_temp.check_eq('a voided receipt is not on the listing',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31') a
      where a.document_id = v_void), 0);

  -- MUTANT: `and r.status <> 'void'` dropped from the ALLOCATIONS join.
  -- This is the other half of the same fact and it is the expensive
  -- half: an allocation from a voided receipt would settle the invoice
  -- as well, so the invoice would come off the listing and the money
  -- would be owed by nobody.
  v_late := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-2', 3000,
                             date '2026-01-10', date '2026-02-10');
  v_rec  := pg_temp.ag_receipt(v_org, v_cust, 'RC-2', 3000,
                               date '2026-01-25', v_late);
  perform pg_temp.check_eq('a live receipt settles its invoice',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31') a
      where a.document_id = v_late), 0);
  update public.receipts set status = 'void' where id = v_rec;
  perform pg_temp.check_eq('and a voided one gives the invoice back',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_late), 3000);

  -- MUTANT: `where a.org_id = p_org_id` dropped from the allocations.
  -- The composite keys make a cross-company allocation impossible to
  -- store, so what is asserted is the key rather than the filter -- and
  -- this listing is the balance sheet's own reconciliation, so an
  -- allocation from another company settling an invoice here would take
  -- a real debt off a real listing.
  perform pg_temp.check_eq('an allocation cannot name two companies',
    (select count(*) from pg_constraint
      where conrelid = 'public.payment_allocations'::regclass
        and conname = 'payment_allocations_invoice_same_org'), 1);
  perform pg_temp.check_eq('nor a receipt from one and an invoice from another',
    (select count(*) from pg_constraint
      where conrelid = 'public.payment_allocations'::regclass
        and conname = 'payment_allocations_receipt_same_org'), 1);

  -- MUTANT: the unallocated-receipt arm of the union deleted, and its
  -- sign flipped. Cash received and not yet matched credited the
  -- receivable on the day it was banked; leaving it off makes the
  -- listing exceed the control account by exactly the unapplied cash,
  -- which is the reconciliation difference that costs an evening.
  v_unapp := pg_temp.ag_receipt(v_org, v_cust, 'RC-3', 1200,
                                date '2026-02-05');
  perform pg_temp.check_eq('unapplied cash is on the listing',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_unapp), -1200);
  perform pg_temp.check_eq('and it is a credit, so the listing nets down',
    (select sum(a.outstanding) from public.report_ar_aging(
       v_org, date '2026-03-31') a), 5000 + 3000 - 1200);

  raise notice 'ok   documents and receipts that must not reach the listing';
end $$;

-- =====================================================================
-- 3. A credit note half used, a refund note, and a discount
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_inv   uuid;
  v_cn    uuid;
  v_rn    uuid;
  v_disc  uuid;
  v_term  uuid;
  v_rec   uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ag_org('Nota Kredit Sdn Bhd');
  v_cust := pg_temp.ag_party(v_org, 'C-1', 'Pelanggan', 'customer');

  -- MUTANT: the credit note's used-up part replaced by nought, so it
  -- stands at its full value for ever.
  --
  -- A credit note keeps its own full total in `balance_amount` however
  -- much of it has been set against an invoice, so how much is LEFT can
  -- only be worked out from the allocations. RM2,000 raised, RM1,200
  -- applied: RM800 of credit is outstanding, and a listing that says
  -- RM2,000 understates the debtors by twelve hundred.
  v_inv := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-1', 5000,
                            date '2026-01-10', date '2026-02-10');
  v_cn  := pg_temp.ag_sales(v_org, v_cust, 'credit_note', 'CN-1', 2000,
                            date '2026-01-15', date '2026-01-15');
  insert into public.payment_allocations
    (org_id, credit_note_id, invoice_id, amount)
  values (v_org, v_cn, v_inv, 1200);

  perform pg_temp.check_eq('a credit note stands at what is left of it',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_cn), -800);
  perform pg_temp.check_eq('and the invoice is down by what was used',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_inv), 3800);

  -- MUTANT: `and cn.status <> 'void'` dropped from the allocations join.
  -- Voiding the credit note gives the invoice its RM1,200 back.
  update public.sales_documents set status = 'void' where id = v_cn;
  perform pg_temp.check_eq('voiding the credit note gives the invoice back',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_inv), 5000);
  perform pg_temp.check_eq('and the credit note itself is off the listing',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31') a
      where a.document_id = v_cn), 0);
  update public.sales_documents set status = 'posted' where id = v_cn;

  -- MUTANT: the refund note dropped from the negative side, so it ADDS
  -- to the receivable. A refund note is money going back to the
  -- customer; it reduces what they owe, and it cannot be allocated
  -- against anything, so it stands at its full value until reversed.
  v_rn := pg_temp.ag_sales(v_org, v_cust, 'refund_note', 'RF-1', 300,
                           date '2026-02-01', date '2026-02-01');
  perform pg_temp.check_eq('a refund note reduces the receivable',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_rn), -300);

  -- MUTANT: an allocation against a refund note taken as settling it.
  -- Nothing writes such a row today and the arithmetic must not depend
  -- on that staying true, so one is written here by hand.
  insert into public.payment_allocations
    (org_id, credit_note_id, invoice_id, amount)
  values (v_org, v_cn, v_rn, 100);
  perform pg_temp.check_eq('and stands at its full value regardless',
    (select a.outstanding from public.report_ar_aging(
       v_org, date '2026-03-31') a where a.document_id = v_rn), -300);
  delete from public.payment_allocations
   where org_id = v_org and invoice_id = v_rn;

  -- MUTANT: `sum(al.amount + al.discount_amount)` with the discount
  -- dropped. The settlement trigger treats a discount as settling the
  -- invoice, so a listing that ignores it shows the discounted part as
  -- still owing -- and stops footing to the control account, which is
  -- the one thing `aged_balances.sql` exists to protect.
  --
  -- `allocation_discount_guard` refuses a discount written straight
  -- into the allocation, because taking it off the document without
  -- taking it off the ledger leaves the control account overstated for
  -- ever. So the discount arrives the only way it can, through
  -- `allocate_with_discount`.
  insert into public.payment_terms
    (org_id, code, name, days, term_type, discount_percent, discount_days)
  values (v_org, '5-10-N30', 'Five per cent in ten days, net thirty',
          30, 'net', 5, 10)
  returning id into v_term;

  v_disc := pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-D', 1000,
                             date '2026-02-01', date '2026-03-01');
  update public.sales_documents set payment_term_id = v_term
   where id = v_disc;
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate)
  values (v_org, 'RC-D', date '2026-02-08', v_cust, 950, 950, 'MYR', 1)
  returning id into v_rec;
  perform public.post_receipt(v_rec);
  -- Inside the ten days the terms allow, which is the only window in
  -- which a settlement discount exists at all.
  perform public.allocate_with_discount(v_rec, v_disc, 950, 50,
                                        date '2026-02-08');

  perform pg_temp.check_eq('a settlement discount settles the invoice with the cash',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31') a
      where a.document_id = v_disc), 0);

  raise notice 'ok   a credit note half used, a refund note, and a discount';
end $$;

-- =====================================================================
-- 4. Who may read a company's debtor book
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_cust uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ag_org('Buku Penghutang Sdn Bhd');
  v_cust := pg_temp.ag_party(v_org, 'C-1', 'Pelanggan', 'customer');
  perform pg_temp.ag_sales(v_org, v_cust, 'invoice', 'INV-1', 5000,
                           date '2026-01-10', date '2026-02-10');
  perform pg_temp.ag_bill(v_org,
    pg_temp.ag_party(v_org, 'S-1', 'Pembekal', 'supplier'),
    'BILL-1', 3000, date '2026-01-10', date '2026-02-10');

  perform pg_temp.check_true('a member sees the listing',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31')) = 1);

  -- MUTANT: `and app.is_org_member(p_org_id)` -> true. Both reports are
  -- SECURITY DEFINER and read every document in the organization named,
  -- so that one line in the `where` clause is the whole of the access
  -- control. Who owes a company money, and how late they are, is not a
  -- list to hand to a stranger.
  --
  -- It is a filter rather than a raise, so the refusal is an empty
  -- listing -- which is why this asserts the count and not an error.
  perform pg_temp.sign_in_as(pg_temp.another_user('agestranger@example.test'));
  perform pg_temp.check_eq('a stranger sees no receivables',
    (select count(*) from public.report_ar_aging(v_org, date '2026-03-31')), 0);
  perform pg_temp.check_eq('and no payables either',
    (select count(*) from public.report_ap_aging(v_org, date '2026-03-31')), 0);
  perform pg_temp.sign_out();

  raise notice 'ok   who may read a company''s debtor book';
end $$;

rollback;
