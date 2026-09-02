-- =====================================================================
-- iAkauntan :: a document cannot be paid more than it is for
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/over_allocation.sql
--
-- Measured before 0464 was written: a RM1,000 invoice took a RM5,000
-- allocation and came back with `balance_amount` -4,000 and status
-- 'completed'. Nothing refused it. The receipt had credited the
-- receivable by the full RM5,000, so the control account carried
-- RM4,000 that belonged to no document, and the trial balance still
-- balanced — which is why it would never have been noticed.
--
-- What is asserted here is the refusal, on both sides, in both shapes
-- (too much against one document, and more out of a receipt than the
-- receipt holds), and the two things that must still work: a part
-- payment, and taking an allocation back off.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.oa_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C', 'Pembeli Sdn Bhd', 'customer'),
         (v_org, 'S', 'Penjual Sdn Bhd', 'supplier');
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100);
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current', 'Maybank', '512345678901', 'MYR', 0, 0, true);
  return v_org;
end $$;

create or replace function pg_temp.oa_invoice(p_org uuid, p_no text, p_amt numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (p_org, 'invoice', p_no, current_date, current_date,
          (select id from public.contacts where org_id = p_org and code = 'C'),
          'draft', 'MYR', 1)
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work', 1, p_amt);
  perform public.post_sales_document(v_id);
  return v_id;
end $$;

create or replace function pg_temp.oa_receipt(p_org uuid, p_no text, p_amt numeric)
returns uuid language sql as $$
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (p_org, p_no, current_date,
          (select id from public.contacts where org_id = p_org and code = 'C'),
          (select id from public.bank_accounts where org_id = p_org limit 1),
          'MYR', 1, p_amt, p_amt)
  returning id;
$$;

-- ---------------------------------------------------------------------
-- The invoice
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_inv  uuid;
  v_rcp  uuid;
  v_msg  text;
  v_took boolean;
  v_alloc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.oa_org('Lebih Bayar Sdn Bhd');
  v_inv := pg_temp.oa_invoice(v_org, 'INV-1', 1000);
  v_rcp := pg_temp.oa_receipt(v_org, 'RCP-1', 5000);

  -- The measured defect, in one line.
  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 5000, null,
                                          current_date);
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'an invoice cannot be paid more than it is for', not v_took);
  perform pg_temp.check_true('and the refusal names it and both figures',
    v_msg like '%INV-1%' and v_msg like '%1,000.00%'
    and v_msg like '%5,000.00%');

  perform pg_temp.check_eq('so the invoice still owes what it owed',
    (select balance_amount from public.sales_documents where id = v_inv),
    1000::numeric);
  perform pg_temp.check_eq('and is not marked paid',
    (select status::text from public.sales_documents where id = v_inv),
    'posted');

  -- A part payment is untouched by this. It is the ordinary case and
  -- the one a guard written carelessly would break.
  v_alloc := public.allocate_with_discount(v_rcp, v_inv, 400, null,
                                           current_date);
  perform pg_temp.check_eq('a part payment goes through',
    (select balance_amount from public.sales_documents where id = v_inv),
    600::numeric);
  perform pg_temp.check_eq('and the invoice is partly paid',
    (select status::text from public.sales_documents where id = v_inv),
    'partial');

  -- Exactly the balance, to the sen, is settlement and not overpayment.
  perform public.allocate_with_discount(v_rcp, v_inv, 600, null,
                                        current_date);
  perform pg_temp.check_eq('and the rest of it settles the invoice',
    (select balance_amount from public.sales_documents where id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('which is what completed means',
    (select status::text from public.sales_documents where id = v_inv),
    'completed');

  -- One sen more than nothing.
  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 0.01, null,
                                          current_date);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a sen more than the invoice is a sen too much', not v_took);

  -- And taking one back off has to work, or a set of books that is
  -- already over-allocated could never be put right.
  delete from public.payment_allocations where id = v_alloc;
  perform pg_temp.check_eq('an allocation can be taken back off',
    (select balance_amount from public.sales_documents where id = v_inv),
    400::numeric);
end $$;

-- ---------------------------------------------------------------------
-- The receipt itself
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_a    uuid;
  v_b    uuid;
  v_rcp  uuid;
  v_msg  text;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.oa_org('Sebar Luas Sdn Bhd');
  v_a   := pg_temp.oa_invoice(v_org, 'INV-A', 800);
  v_b   := pg_temp.oa_invoice(v_org, 'INV-B', 800);

  -- A receipt for RM1,000 spread across RM1,600 of invoices. Each
  -- allocation is within its own document; what is wrong is that the
  -- money was only ever RM1,000.
  v_rcp := pg_temp.oa_receipt(v_org, 'RCP-2', 1000);
  perform public.allocate_with_discount(v_rcp, v_a, 800, null, current_date);

  begin
    perform public.allocate_with_discount(v_rcp, v_b, 800, null,
                                          current_date);
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a receipt cannot be spread further than the money that arrived',
    not v_took);
  perform pg_temp.check_true('and the refusal says by how much',
    v_msg like '%RCP-2%' and v_msg like '%600.00%');

  perform pg_temp.check_eq('the second invoice is untouched',
    (select balance_amount from public.sales_documents where id = v_b),
    800::numeric);
  perform pg_temp.check_eq('and the receipt still has its remainder',
    (select unapplied_amount from public.receipts where id = v_rcp),
    200::numeric);

  -- Which is the answer to an overpayment: it sits there, on the
  -- receipt, until somebody decides what it is.
  perform public.allocate_with_discount(v_rcp, v_b, 200, null, current_date);
  perform pg_temp.check_eq('what is left of it can still be applied',
    (select unapplied_amount from public.receipts where id = v_rcp),
    0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- Books that were already over-allocated
-- ---------------------------------------------------------------------
--
-- Every build before 0464 could reach this state, so the guard has to
-- leave a way out of it. Constructed the only way it can be now — with
-- the trigger switched off — and then unpicked with it back on.
do $$
declare
  v_org  uuid;
  v_inv  uuid;
  v_rcp  uuid;
  v_one  uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.oa_org('Sudah Terlanjur Sdn Bhd');
  v_inv := pg_temp.oa_invoice(v_org, 'INV-OLD', 1000);
  v_rcp := pg_temp.oa_receipt(v_org, 'RCP-OLD', 3000);

  alter table public.payment_allocations disable trigger apply_allocation;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 800) returning id into v_one;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 800), (v_org, v_rcp, v_inv, 800);
  alter table public.payment_allocations enable trigger apply_allocation;

  -- 2,400 against a 1,000 invoice. Taking one row off leaves 1,600,
  -- which is still too much — and has to be allowed anyway, or the
  -- second and third rows can never come off either.
  begin
    delete from public.payment_allocations where id = v_one;
    v_took := true;
  exception when others then v_took := false;
  end;
  perform pg_temp.check_true(
    'an over-allocated invoice can be unpicked one row at a time', v_took);
  perform pg_temp.check_eq('even while it is still over-allocated',
    (select balance_amount from public.sales_documents where id = v_inv),
    -600::numeric);

  delete from public.payment_allocations
   where invoice_id = v_inv and amount = 800;
  perform pg_temp.check_eq('and all the way back to what it owes',
    (select balance_amount from public.sales_documents where id = v_inv),
    1000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- The purchase side, which had the same hole
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_bill uuid;
  v_pay  uuid;
  v_item uuid;
  v_msg  text;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.oa_org('Bayar Lebih Sdn Bhd');
  select id into v_item from public.items where org_id = v_org and code = 'SVC';

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, status, currency,
     exchange_rate)
  values (v_org, 'bill', 'BILL-1', current_date,
          (select id from public.contacts where org_id = v_org and code = 'S'),
          'draft', 'MYR', 1)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Bought', 1, 400);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (v_org, 'PAY-1', current_date,
          (select id from public.contacts where org_id = v_org and code = 'S'),
          (select id from public.bank_accounts where org_id = v_org limit 1),
          'MYR', 1, 900, 900)
  returning id into v_pay;

  begin
    perform public.allocate_payment_with_discount(v_pay, v_bill, 900, null,
                                                  current_date);
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a bill cannot be paid more than it is for', not v_took);
  perform pg_temp.check_true('and it says so about the bill',
    v_msg like '%BILL-1%' and v_msg like '%400.00%');

  perform pg_temp.check_eq('the bill still owes what it owed',
    (select balance_amount from public.purchase_documents where id = v_bill),
    400::numeric);

  perform public.allocate_payment_with_discount(v_pay, v_bill, 400, null,
                                                current_date);
  perform pg_temp.check_eq('paying it exactly settles it',
    (select balance_amount from public.purchase_documents where id = v_bill),
    0::numeric);
  perform pg_temp.check_eq('and the rest of the payment is unapplied',
    (select unapplied_amount from public.purchase_payments where id = v_pay),
    500::numeric);
end $$;

rollback;
