-- =====================================================================
-- iAkauntan :: whose money it is
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/allocation_party.sql
--
-- Measured before 0465: a receipt from Pelanggan A allocated against
-- Pelanggan B's invoice was accepted and left B's invoice at nil.
-- `create_contra` has refused the same crossing since 0272; the
-- ordinary allocation path never did.
--
-- The interesting half is what must still be allowed: a group that
-- keeps one customer under two contact records, saying so with the same
-- TIN. That is the same rule consolidation already runs on, and a guard
-- that broke it would be worse than the hole.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ap_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
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

create or replace function pg_temp.ap_customer(
  p_org uuid, p_code text, p_name text, p_tin text default null)
returns uuid language sql as $$
  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (p_org, p_code, p_name, 'customer', p_tin) returning id;
$$;

create or replace function pg_temp.ap_invoice(
  p_org uuid, p_no text, p_contact uuid, p_amt numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (p_org, 'invoice', p_no, current_date, current_date, p_contact,
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

create or replace function pg_temp.ap_receipt(
  p_org uuid, p_no text, p_contact uuid, p_amt numeric)
returns uuid language sql as $$
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (p_org, p_no, current_date, p_contact,
          (select id from public.bank_accounts where org_id = p_org limit 1),
          'MYR', 1, p_amt, p_amt)
  returning id;
$$;

-- ---------------------------------------------------------------------
-- Two customers
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_a    uuid;
  v_b    uuid;
  v_inv  uuid;
  v_rcp  uuid;
  v_msg  text;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ap_org('Silap Orang Sdn Bhd');
  v_a   := pg_temp.ap_customer(v_org, 'A', 'Pelanggan A');
  v_b   := pg_temp.ap_customer(v_org, 'B', 'Pelanggan B');
  v_inv := pg_temp.ap_invoice(v_org, 'INV-B', v_b, 500);
  v_rcp := pg_temp.ap_receipt(v_org, 'RCP-A', v_a, 500);

  perform pg_temp.check_true('they really are two parties',
    not app.same_party(v_a, v_b));

  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 500, null,
                                          current_date);
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'one customer''s money cannot settle another''s invoice', not v_took);
  perform pg_temp.check_true('and the refusal names both of them',
    v_msg like '%Pelanggan A%' and v_msg like '%Pelanggan B%');
  perform pg_temp.check_true('and says what to do if they are one party',
    v_msg like '%same TIN%');

  perform pg_temp.check_eq('so B''s invoice is still owed',
    (select balance_amount from public.sales_documents where id = v_inv),
    500::numeric);
  perform pg_temp.check_eq('and A''s money is still A''s',
    (select unapplied_amount from public.receipts where id = v_rcp),
    500::numeric);

  -- A's own invoice, settled by A's receipt, is untouched by any of it.
  perform public.allocate_with_discount(
    v_rcp, pg_temp.ap_invoice(v_org, 'INV-A', v_a, 500), 500, null,
    current_date);
  perform pg_temp.check_eq('A''s receipt still settles A''s invoice',
    (select unapplied_amount from public.receipts where id = v_rcp),
    0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- One party under two names
-- ---------------------------------------------------------------------
--
-- A group with a head office record and a branch record is one debtor.
-- `app.same_party` decides it by TIN, which is the same rule the
-- consolidation work runs on, and a guard that refused this would break
-- every customer kept that way.
do $$
declare
  v_org uuid;
  v_hq  uuid;
  v_br  uuid;
  v_inv uuid;
  v_rcp uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ap_org('Satu Kumpulan Sdn Bhd');
  v_hq  := pg_temp.ap_customer(v_org, 'HQ', 'Kumpulan Awan (HQ)',
                               'C24680135790');
  v_br  := pg_temp.ap_customer(v_org, 'BR', 'Kumpulan Awan (Cawangan)',
                               'C24680135790');

  perform pg_temp.check_true('the same TIN makes them one party',
    app.same_party(v_hq, v_br));

  v_inv := pg_temp.ap_invoice(v_org, 'INV-BR', v_br, 700);
  v_rcp := pg_temp.ap_receipt(v_org, 'RCP-HQ', v_hq, 700);

  perform public.allocate_with_discount(v_rcp, v_inv, 700, null,
                                        current_date);
  perform pg_temp.check_eq(
    'so head office can settle the branch''s invoice',
    (select balance_amount from public.sales_documents where id = v_inv),
    0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- The purchase side, and a blank TIN on both
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_s1    uuid;
  v_s2    uuid;
  v_item  uuid;
  v_bill  uuid;
  v_pay   uuid;
  v_msg   text;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ap_org('Salah Pembekal Sdn Bhd');
  select id into v_item from public.items where org_id = v_org and code = 'SVC';

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'Pembekal Satu', 'supplier') returning id into v_s1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S2', 'Pembekal Dua', 'supplier') returning id into v_s2;

  -- Neither has a TIN. `same_party` deliberately does not treat two
  -- blanks as a match — 0272 wrote that rule down — so these are two
  -- suppliers, and the guard has to hold here too.
  perform pg_temp.check_true('two blanks are not one party',
    not app.same_party(v_s1, v_s2));

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, status, currency,
     exchange_rate)
  values (v_org, 'bill', 'BILL-S2', current_date, v_s2, 'draft', 'MYR', 1)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Bought', 1, 300);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (v_org, 'PAY-S1', current_date, v_s1,
          (select id from public.bank_accounts where org_id = v_org limit 1),
          'MYR', 1, 300, 300)
  returning id into v_pay;

  begin
    perform public.allocate_payment_with_discount(v_pay, v_bill, 300, null,
                                                  current_date);
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'money sent to one supplier cannot settle another''s bill', not v_took);
  perform pg_temp.check_true('and it names them',
    v_msg like '%Pembekal Satu%' and v_msg like '%Pembekal Dua%');
  perform pg_temp.check_eq('the bill is still owed',
    (select balance_amount from public.purchase_documents where id = v_bill),
    300::numeric);
end $$;

-- ---------------------------------------------------------------------
-- A contra is not held to this rule, because it names two parties
-- ---------------------------------------------------------------------
--
-- `create_contra` checks the parties itself, with a message about them,
-- and a contra note carries a customer contact and a supplier contact
-- by design. Holding it to a rule about one party would mean picking a
-- side of a row that has two. This asserts the skip is real rather than
-- assumed.
do $$
declare
  v_org  uuid;
  v_both uuid;
  v_item uuid;
  v_inv  uuid;
  v_bill uuid;
  v_id   uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ap_org('Tolak Selari Sdn Bhd');
  select id into v_item from public.items where org_id = v_org and code = 'SVC';

  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (v_org, 'BOTH', 'Rakan Niaga Sdn Bhd', 'both', 'C13579246810')
  returning id into v_both;

  v_inv := pg_temp.ap_invoice(v_org, 'INV-X', v_both, 400);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, status, currency,
     exchange_rate)
  values (v_org, 'bill', 'BILL-X', current_date, v_both, 'draft', 'MYR', 1)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Bought', 1, 400);
  perform public.post_purchase_document(v_bill);

  v_id := public.create_contra(
    v_org, current_date,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 400)),
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 400)),
    null);

  perform pg_temp.check_true('a contra still goes through', v_id is not null);
  perform pg_temp.check_eq('and clears both sides',
    (select balance_amount from public.sales_documents where id = v_inv)
    + (select balance_amount from public.purchase_documents where id = v_bill),
    0::numeric);

  -- And *why* it goes through, which is the part worth asserting. The
  -- guard reads the money's party out of six columns; a contra
  -- allocation names none of them, so there is nothing to compare and
  -- the check declines on its own. 0465 carried an explicit
  -- `contra_id is null` until a mutant showed it never decided
  -- anything; this is the shape that was standing behind it.
  perform pg_temp.check_eq(
    'a contra allocation names no money source, so nothing is compared',
    (select count(*)::integer from public.payment_allocations a
      where a.contra_id = v_id
        and (a.receipt_id is not null or a.payment_id is not null
             or a.credit_note_id is not null or a.deposit_id is not null
             or a.pdc_id is not null or a.withholding_id is not null)), 0);
  perform pg_temp.check_true('and there are allocations to say that about',
    (select count(*) from public.payment_allocations where contra_id = v_id) = 2);
end $$;

-- ---------------------------------------------------------------------
-- The other four money sources
--
-- A mutation sweep of `app.apply_allocation` read the party guard as
-- six separate lookups, and this file asserted two of them. Delete the
-- credit note, the deposit, the cheque or the withholding certificate
-- from the coalesce and the whole suite stayed green -- so each of the
-- four could still settle a different party's invoice, which is
-- precisely the hole 0465 was written to close.
--
-- Asserted here by inserting the allocation directly. The trigger is
-- what is under test, and reaching it through each source's own RPC
-- would assert that RPC's guards instead of this one's.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_a uuid; v_b uuid; v_inv uuid;
  v_cn uuid; v_dep uuid; v_pdc uuid; v_wht uuid;
  v_msg text; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ap_org('Enam Sumber Sdn Bhd');
  v_a   := pg_temp.ap_customer(v_org, 'A', 'Pelanggan A');
  v_b   := pg_temp.ap_customer(v_org, 'B', 'Pelanggan B');
  v_inv := pg_temp.ap_invoice(v_org, 'INV-B', v_b, 500);

  -- A's credit note.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_org, 'credit_note', 'CN-A', current_date, current_date, v_a,
          'posted', 'MYR', 1, 500, 500, 500)
  returning id into v_cn;

  -- A's deposit.
  insert into public.deposit_notes
    (org_id, deposit_no, kind, contact_id, amount)
  values (v_org, 'DEP-A', 'customer', v_a, 500) returning id into v_dep;

  -- A's cheque.
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date, amount)
  values (v_org, 'PDC-A', 'incoming', v_a, '000123',
          current_date + 30, 500) returning id into v_pdc;

  -- Tax withheld from A.
  insert into public.withholding_certificates
    (org_id, certificate_no, contact_id, wht_code, section, gross_amount,
     rate, tax_amount, due_date)
  values (v_org, 'WHT-A', v_a, 'S109_INTEREST', '109', 5000, 10, 500,
          current_date + 30) returning id into v_wht;

  -- Each in turn, against B's invoice.
  v_took := false;
  begin
    insert into public.payment_allocations
      (org_id, credit_note_id, invoice_id, amount)
    values (v_org, v_cn, v_inv, 500);
    v_took := true;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('A''s credit note cannot settle B''s invoice',
    not v_took and v_msg like 'This money is Pelanggan A''s and the '
                           || 'document belongs to Pelanggan B.%');

  v_took := false;
  begin
    insert into public.payment_allocations
      (org_id, deposit_id, invoice_id, amount)
    values (v_org, v_dep, v_inv, 500);
    v_took := true;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('nor A''s deposit',
    not v_took and v_msg like 'This money is Pelanggan A''s%');

  v_took := false;
  begin
    insert into public.payment_allocations
      (org_id, pdc_id, invoice_id, amount)
    values (v_org, v_pdc, v_inv, 500);
    v_took := true;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('nor A''s cheque',
    not v_took and v_msg like 'This money is Pelanggan A''s%');

  v_took := false;
  begin
    insert into public.payment_allocations
      (org_id, withholding_id, invoice_id, amount)
    values (v_org, v_wht, v_inv, 500);
    v_took := true;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('nor tax withheld from A',
    not v_took and v_msg like 'This money is Pelanggan A''s%');

  perform pg_temp.check_eq('and B''s invoice is untouched by any of them',
    (select balance_amount from public.sales_documents where id = v_inv),
    500::numeric);

  -- The control. Four refusals are satisfied by a guard that refuses
  -- everything, so each source settles its OWN party's invoice.
  declare
    v_inv_a uuid;
  begin
    v_inv_a := pg_temp.ap_invoice(v_org, 'INV-A', v_a, 2000);
    insert into public.payment_allocations
      (org_id, credit_note_id, invoice_id, amount) values (v_org, v_cn, v_inv_a, 500);
    insert into public.payment_allocations
      (org_id, deposit_id, invoice_id, amount) values (v_org, v_dep, v_inv_a, 500);
    insert into public.payment_allocations
      (org_id, pdc_id, invoice_id, amount) values (v_org, v_pdc, v_inv_a, 500);
    insert into public.payment_allocations
      (org_id, withholding_id, invoice_id, amount) values (v_org, v_wht, v_inv_a, 500);
    perform pg_temp.check_eq(
      'while all four settle their own party''s invoice',
      (select paid_amount from public.sales_documents where id = v_inv_a),
      2000::numeric);
    perform pg_temp.check_eq('leaving it completed',
      (select status::text from public.sales_documents where id = v_inv_a),
      'completed');
  end;
end $$;

-- ---------------------------------------------------------------------
-- The buying side of the same trigger, and what a removal puts back
--
-- ASYMMETRY. `app.apply_allocation` is symmetric twice over -- invoice
-- against bill, receipt against payment -- and the sweep found the
-- selling half asserted and the buying half not: a bill left unmarked
-- when it is part paid, and a payment spread further than the money
-- that left.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_sup uuid; v_bill uuid; v_pay uuid; v_alloc uuid;
  v_msg text; v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ap_org('Separuh Bayar Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S', 'Pembekal', 'supplier') returning id into v_sup;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_org, 'bill', 'BILL-1', current_date, current_date, v_sup,
          'posted', 'MYR', 1, 1000, 1000, 1000)
  returning id into v_bill;

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, unapplied_amount)
  values (v_org, 'PAY-1', current_date, v_sup,
          (select id from public.bank_accounts where org_id = v_org limit 1),
          'MYR', 1, 400, 400)
  returning id into v_pay;

  insert into public.payment_allocations
    (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay, v_bill, 400) returning id into v_alloc;

  perform pg_temp.check_eq('a part-paid bill is marked partial',
    (select status::text from public.purchase_documents where id = v_bill),
    'partial');
  perform pg_temp.check_eq('owing the rest',
    (select balance_amount from public.purchase_documents where id = v_bill),
    600::numeric);
  perform pg_temp.check_eq('and the payment has nothing left unapplied',
    (select unapplied_amount from public.purchase_payments where id = v_pay),
    0::numeric);

  -- Spread further than the money that left.
  v_took := false;
  begin
    insert into public.payment_allocations
      (org_id, payment_id, bill_id, amount)
    values (v_org, v_pay, v_bill, 100);
    v_took := true;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true(
    'a payment cannot be spread further than the money that left',
    not v_took and v_msg like 'Payment PAY-1 has been spread further than '
                           || 'the money that left: 100.00 more than it is '
                           || 'for.');

  -- And taking the allocation away puts the bill back. What does that
  -- is `coalesce(new.bill_id, old.bill_id)` at the top: on a DELETE
  -- there is no NEW, so without the OLD half the trigger would have no
  -- document to recompute and the bill would stay reading as part paid
  -- with nothing paying it.
  --
  -- The `return coalesce(new, old)` at the bottom is a different thing
  -- and is EQUIVALENT -- the tenth of this programme. The trigger is
  -- AFTER, and Postgres ignores what an AFTER trigger returns. It is
  -- kept because it is what the statement would have to be if the
  -- trigger were ever made BEFORE, and because returning NEW from a
  -- DELETE is a plainly wrong thing to leave written down.
  delete from public.payment_allocations where id = v_alloc;
  perform pg_temp.check_eq('removing the allocation puts the bill back',
    (select balance_amount from public.purchase_documents where id = v_bill),
    1000::numeric);
  perform pg_temp.check_eq('and returns it from partial to posted',
    (select status::text from public.purchase_documents where id = v_bill),
    'posted');
  perform pg_temp.check_eq('with the money unapplied again',
    (select unapplied_amount from public.purchase_payments where id = v_pay),
    400::numeric);
end $$;


rollback;
