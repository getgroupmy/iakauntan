-- =====================================================================
-- The cheque dated next month
--
-- One assertion matters more than the rest: the bank balance does not
-- move. A post-dated cheque recorded as a receipt puts six weeks of
-- money into the bank on the day it is handed over, and every cash flow
-- decision taken on that balance is wrong by the whole post-dated book.
--
-- The rest: the receivable going when the cheque is handed over, the
-- money arriving only when it clears, a bounce putting the invoice back
-- into the aged listing, a cheque that could be banked today being
-- refused, and the maturity list finding the one somebody forgot.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_cust   uuid;
  v_sup    uuid;
  v_item   uuid;
  v_bank   uuid;
  v_bank_a uuid;

  v_inv    uuid;
  v_bill   uuid;
  v_pdc    uuid;
  v_out    uuid;
  v_entry  uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Perniagaan Cek Lambat Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A contractor', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'A merchant', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'KERJA', 'Work done', 'service', false, 1)
  returning id into v_item;

  select id into v_bank_a from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org, v_bank_a, 'Current account', 'Maybank', '512345678901',
          'MYR', 0, 0, true)
  returning id into v_bank;

  -- Forty thousand of work, invoiced.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 40000, 1);
  perform public.post_sales_document(v_inv);

  -- ------------------------------------------------------------------
  -- 1. The assertion this migration is built around
  -- ------------------------------------------------------------------
  v_pdc := public.record_pdc(
    v_org, 'incoming', v_cust, '123456', current_date + 45, 40000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 40000)),
    v_bank, 'CIMB', current_date, 'Dated the fifteenth of next month');

  perform pg_temp.check_eq(
    'the bank balance has not moved, because no money has arrived',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    0::numeric);
  select c.gl_entry_id into v_entry
    from public.post_dated_cheques c where c.id = v_pdc;
  perform pg_temp.check_eq('and nothing was posted to the bank account',
    (select count(*) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1120'), 0::numeric);

  -- But he has discharged the debt with a negotiable instrument, so the
  -- receivable goes and the aged listing stops chasing him.
  perform pg_temp.check_eq('the invoice is settled',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('and says so',
    (select d.status::text from public.sales_documents d where d.id = v_inv),
    'completed');
  perform pg_temp.check_eq('the receivable is credited',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 40000::numeric);
  perform pg_temp.check_eq('and it is sitting in cheques on hand',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1140'), 40000::numeric);
  perform pg_temp.check_eq('1140 is an asset, and a current one',
    (select a.account_subtype::text from public.accounts a
      where a.org_id = v_org and a.code = '1140'), 'current_asset');

  -- ------------------------------------------------------------------
  -- 2. Banking it is not clearing it
  -- ------------------------------------------------------------------
  perform public.deposit_pdc(v_pdc, current_date + 44);
  perform pg_temp.check_eq('paid in',
    (select c.status::text from public.post_dated_cheques c where c.id = v_pdc),
    'deposited');
  perform pg_temp.check_eq(
    'and still not in the bank, because it has not cleared',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    0::numeric);

  -- ------------------------------------------------------------------
  -- 3. Now it is money
  -- ------------------------------------------------------------------
  v_entry := public.clear_pdc(v_pdc, current_date + 46);
  perform pg_temp.check_eq('the bank has it at last',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    40000::numeric);
  perform pg_temp.check_eq('debited to the bank',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1120'), 40000::numeric);
  perform pg_temp.check_eq('out of cheques on hand',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1140'), 40000::numeric);
  perform pg_temp.check_eq('and 1140 is empty again',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where a.org_id = v_org and a.code = '1140'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 4. One that bounces puts the invoice back
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'More work', 5000, 1);
  perform public.post_sales_document(v_inv);

  v_pdc := public.record_pdc(
    v_org, 'incoming', v_cust, '123457', current_date + 30, 5000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 5000)),
    v_bank, 'CIMB');
  perform pg_temp.check_eq('settled again, for now',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    0::numeric);

  v_entry := public.bounce_pdc(v_pdc, 'Refer to drawer', current_date + 31);

  perform pg_temp.check_eq('he owes it again',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    5000::numeric);
  -- This is the one that would have failed silently before 0272: a
  -- fully unallocated document used to keep saying `completed`, which
  -- would have dropped a bounced cheque out of the chasing for ever.
  perform pg_temp.check_eq('and is back in the aged listing, not marked paid',
    (select d.status::text from public.sales_documents d where d.id = v_inv),
    'posted');
  perform pg_temp.check_eq('the receivable is debited back',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 5000::numeric);
  perform pg_temp.check_eq('and the cheques account emptied',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1140'), 5000::numeric);
  perform pg_temp.check_eq('the reason is kept, because it decides what next',
    (select c.bounce_reason from public.post_dated_cheques c where c.id = v_pdc),
    'Refer to drawer');
  perform pg_temp.check_eq('and the bank never saw any of it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    40000::numeric);

  -- ------------------------------------------------------------------
  -- 5. The other direction: one we write
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Materials', 8000, 1);
  perform public.post_purchase_document(v_bill);

  v_out := public.record_pdc(
    v_org, 'outgoing', v_sup, '990001', current_date + 60, 8000,
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 8000)),
    v_bank, 'Maybank');
  select c.gl_entry_id into v_entry
    from public.post_dated_cheques c where c.id = v_out;

  perform pg_temp.check_eq('the bill is settled by the cheque we wrote',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    0::numeric);
  perform pg_temp.check_eq('the payable is debited',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2110'), 8000::numeric);
  perform pg_temp.check_eq('and what we owe is now a cheque outstanding',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2115'), 8000::numeric);
  perform pg_temp.check_eq('2115 is a liability',
    (select a.account_type::text from public.accounts a
      where a.org_id = v_org and a.code = '2115'), 'liability');
  perform pg_temp.check_eq('and the bank still has what it had',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    40000::numeric);

  perform public.clear_pdc(v_out, current_date + 61);
  perform pg_temp.check_eq('until he presents it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    32000::numeric);

  -- ------------------------------------------------------------------
  -- 6. The morning list
  -- ------------------------------------------------------------------
  --
  -- One dated a week out and one whose date went by while nobody was
  -- looking. The second is the whole reason to read this list.
  perform public.record_pdc(
    v_org, 'incoming', v_cust, '123458', current_date + 7, 100,
    '[]'::jsonb, v_bank, 'CIMB');
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date,
     amount, received_on, bank_account_id)
  values (v_org, 'PDC-FORGOTTEN', 'incoming', v_cust, '123459',
          current_date - 5, 250, current_date - 40, v_bank);

  perform pg_temp.check_eq('the week ahead has one in it',
    (select count(*) from public.pdc_maturing(v_org, current_date, current_date + 7)
      where not overdue), 1::numeric);
  perform pg_temp.check_eq('and the one nobody banked is on it too',
    (select count(*) from public.pdc_maturing(v_org, current_date, current_date + 7)
      where overdue), 1::numeric);
  perform pg_temp.check_eq('a cleared cheque is not on the list at all',
    (select count(*) from public.pdc_maturing(v_org, current_date - 90, current_date + 90)
      where status = 'cleared'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 7. What it refuses
  -- ------------------------------------------------------------------
  begin
    perform public.record_pdc(
      v_org, 'incoming', v_cust, '123460', current_date, 100,
      '[]'::jsonb, v_bank);
    perform pg_temp.check_true('a cheque dated today is post-dated', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a cheque that can be banked today is a receipt, not this',
      v_msg like '%is a receipt, not a post-dated cheque%');
  end;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-3', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 3000, 1);
  perform public.post_sales_document(v_inv);

  begin
    perform public.record_pdc(
      v_org, 'incoming', v_cust, '123461', current_date + 10, 3000,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 1000)),
      v_bank);
    perform pg_temp.check_true('a cheque can half-settle and half-float', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a cheque settling less than its face value is two facts as one',
      v_msg like '%two facts pretending to be one%');
  end;

  begin
    perform public.record_pdc(
      v_org, 'incoming', v_cust, '123462', current_date + 10, 3000,
      jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 3000)),
      v_bank);
    perform pg_temp.check_true('an incoming cheque can settle our own bill', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an incoming cheque settles an invoice',
      v_msg like '%No such invoice%');
  end;

  v_pdc := public.record_pdc(
    v_org, 'incoming', v_cust, '123463', current_date + 10, 3000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 3000)),
    v_bank);
  begin
    perform public.bounce_pdc(v_pdc, '   ');
    perform pg_temp.check_true('a bounce with no reason is allowed', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a bounce says why, because it decides what next',
      v_msg like '%Say why%');
  end;

  -- Handed back before anything happened to it: the entry is reversed
  -- and the invoice is outstanding again.
  perform public.cancel_pdc(v_pdc, 'He asked for it back and paid cash');
  perform pg_temp.check_eq('a cancelled cheque leaves the invoice owing',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    3000::numeric);
  perform pg_temp.check_eq('and nothing is left in cheques on hand for it',
    (select count(*) from public.payment_allocations a where a.pdc_id = v_pdc),
    0::numeric);

  begin
    perform public.clear_pdc(v_pdc);
    perform pg_temp.check_true('a cancelled cheque can still clear', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a cancelled cheque cannot clear',
      v_msg like '%is cancelled%');
  end;

  raise notice 'ok   post_dated_cheques';
end $$;

-- ---------------------------------------------------------------------
-- The register itself
--
-- `pdc_maturing` above is the Monday-morning list. `pdc_list` is the
-- register behind it — every cheque either way, filtered by direction
-- and by status — and it was called by nothing.
--
-- Its own work is not the listing. It is that a cheque's direction is
-- gated on a different module from the other's: incoming cheques belong
-- to sales, outgoing to purchases, and each row is tested separately
-- against what the company actually bought. A company that has sales and
-- not purchases must see what its customers handed over and nothing of
-- what it wrote to its suppliers — the amounts, the bank, the payee. The
-- guard at the top of the function is not that rule; it only asks
-- whether the caller holds *either* module, and a company holding one of
-- them passes it while still having no business seeing the other half.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user();
  v_cust uuid; v_sup uuid; v_bank_a uuid; v_bank uuid;
  v_in uuid; v_out uuid; r record; v_ok boolean;
  v_type uuid; v_type2 uuid; v_inv uuid;
  v_buyer uuid := pg_temp.another_user('buyer@cek.test');
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Daftar Cek Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Pembeli Bhd', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'Pembekal Bhd', 'supplier') returning id into v_sup;
  select id into v_bank_a from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org, v_bank_a, 'Maybank', 'Maybank', '514011', 'MYR', 0, 0, true)
  returning id into v_bank;

  -- Dated relative to today on purpose: `days_to_go` is measured against
  -- today, so a fixed date would make the assertion drift by a day every
  -- day and fail on some future morning for no reason.
  --
  -- And today in Kuala Lumpur, not in whatever zone the session happens
  -- to be in. `0419` pinned `pdc_list` to Malaysia; this fixture said
  -- `current_date`, and between midnight and eight in the morning there
  -- the two are a day apart, which is how this line came to be written.
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date,
     amount, received_on, bank_account_id, bank_name)
  values (v_org, 'PDC-IN', 'incoming', v_cust, '900001', v_today + 10,
          1500, v_today, v_bank, 'CIMB')
  returning id into v_in;
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date,
     amount, bank_account_id, bank_name)
  values (v_org, 'PDC-OUT', 'outgoing', v_sup, '900002', v_today + 20,
          900, v_bank, 'Maybank')
  returning id into v_out;

  perform pg_temp.check_eq('the register holds both directions',
    (select count(*) from public.pdc_list(v_org)), 2);

  select * into r from public.pdc_list(v_org) where id = v_in;
  perform pg_temp.check_eq('a cheque names who handed it over', r.party, 'Pembeli Bhd');
  perform pg_temp.check_eq('and which bank it is drawn on', r.bank_name, 'CIMB');
  perform pg_temp.check_eq('and what it is for', r.amount, 1500);
  -- Ten days out, counted from today rather than from anything stored.
  perform pg_temp.check_eq('and how long until it can be banked',
    r.days_to_go, 10);
  perform pg_temp.check_eq('with nothing settled against it yet', r.settles, 0);

  -- And the count is the cheque's own. A register that showed every
  -- allocation in the company against every cheque would tell a
  -- bookkeeper that a cheque covering one invoice covers eleven.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-PDC', current_date, current_date + 30,
          v_cust, 'MYR', 1, 1500, 1500, 1500, 'draft')
  returning id into v_inv;
  insert into public.payment_allocations (org_id, invoice_id, amount, pdc_id)
  values (v_org, v_inv, 1500, v_in);

  perform pg_temp.check_eq('once it settles something, it says so',
    (select settles from public.pdc_list(v_org) where id = v_in), 1);
  perform pg_temp.check_eq('and the other cheque still settles nothing',
    (select settles from public.pdc_list(v_org) where id = v_out), 0);

  -- Both filters, and that they filter rather than merely being accepted.
  perform pg_temp.check_eq('it can be asked for one direction',
    (select count(*) from public.pdc_list(v_org, 'outgoing')), 1);
  perform pg_temp.check_eq('and the one it returns is that direction',
    (select direction from public.pdc_list(v_org, 'outgoing')), 'outgoing');
  perform pg_temp.check_eq('and for one status',
    (select count(*) from public.pdc_list(v_org, null, 'held')), 2);
  perform pg_temp.check_eq('a status nothing is in comes back empty',
    (select count(*) from public.pdc_list(v_org, null, 'bounced')), 0);

  -- ------------------------------------------------------------------
  -- One module, one half of the book
  -- ------------------------------------------------------------------
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'purchases';

  perform pg_temp.check_eq('without purchases the register is sales only',
    (select count(*) from public.pdc_list(v_org)), 1);
  perform pg_temp.check_eq('and it is the incoming one',
    (select pdc_no from public.pdc_list(v_org)), 'PDC-IN');
  -- Asked for the half they may not see, they get nothing rather than an
  -- error: the filter is per row, so the answer is an empty register.
  perform pg_temp.check_eq('asking for the other half returns none of it',
    (select count(*) from public.pdc_list(v_org, 'outgoing')), 0);

  -- The mirror, so the assertion above is about the direction rather
  -- than about `purchases` being the module that happens to matter.
  --
  -- It cannot be done by switching `sales` off. `sales` is a core module
  -- — `platform_modules.is_core` — and `app.module_access` answers for a
  -- core module before it ever looks at `org_modules`, so the row stays
  -- readable however that table is edited. That is right: a company
  -- cannot un-buy the thing it invoices with. It also means the guard at
  -- the top of `pdc_list`, which asks whether the caller holds either
  -- module, can never fire for a member of a company at all.
  --
  -- The half that can be withheld is withheld by an access type, which
  -- is what access types are for, and that is the real mechanism behind
  -- both halves of this rule.
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'purchases';

  insert into public.access_types (org_id, name)
  values (v_org, 'Purchasing only') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'purchases', 'read');
  insert into public.org_members (org_id, user_id, role, access_type_id)
  values (v_org, v_buyer, 'purchaser', v_type);

  perform pg_temp.sign_in_as(v_buyer);
  perform pg_temp.check_eq('somebody let into purchasing only sees that half',
    (select count(*) from public.pdc_list(v_org)), 1);
  perform pg_temp.check_eq('and it is the outgoing one',
    (select pdc_no from public.pdc_list(v_org)), 'PDC-OUT');

  -- Neither, and now it is a refusal rather than an empty list, because
  -- there is no register to show at all. This is the only route by which
  -- that guard is reachable.
  insert into public.access_types (org_id, name)
  values (v_org, 'Contacts only') returning id into v_type2;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type2, 'contacts', 'read');
  update public.org_members set access_type_id = v_type2
   where org_id = v_org and user_id = v_buyer;

  v_ok := true;
  begin
    perform * from public.pdc_list(v_org);
  exception when sqlstate '42501' then v_ok := false;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and somebody let into neither is refused', not v_ok);
end $$;

-- ---------------------------------------------------------------------
-- Cek Jiran Sdn Bhd: a cheque clears into its own company's bank
--
-- `clear_pdc` takes an optional bank account to clear the cheque into.
-- It checked that account against the cheque's company in one place —
-- the lookup that resolves which ledger account to post to — while the
-- balance it updates and the account it writes back onto the cheque
-- both used the argument raw. Clearing into another company's account
-- moved THEIR balance. That is 0506, and it is the same shape 0505
-- closed in settle_deposit.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid; v_org2 uuid;
  v_owner uuid := pg_temp.test_user();
  v_cust  uuid; v_bank uuid; v_theirs uuid; v_pdc uuid;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Cek Kami Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Encik Zul', 'customer') returning id into v_cust;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Our account', 'Maybank', '544444444444', 'MYR', 0, 0, true)
  returning id into v_bank;

  v_org2 := pg_temp.test_org('Cek Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org2,
          (select id from public.accounts where org_id = v_org2 and code = '1120'),
          'Their account', 'RHB', '555555555555', 'MYR', 0, 6000, true)
  returning id into v_theirs;

  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date, amount,
     received_on, bank_account_id, status)
  values (v_org, 'PDC-JIRAN', 'incoming', v_cust, '600001', current_date,
          800, current_date, v_bank, 'held')
  returning id into v_pdc;

  begin
    perform public.clear_pdc(v_pdc, current_date, v_theirs);
    raise exception 'FAIL cleared a cheque into another company''s account';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a cheque cannot clear into another company',
      v_msg like '%belongs to another company%');
  end;
  perform pg_temp.check_eq('and their balance did not move',
    (select b.current_balance from public.bank_accounts b where b.id = v_theirs),
    6000::numeric);
  perform pg_temp.check_true('the cheque is still waiting, in its own bank',
    (select c.status::text = 'held' and c.bank_account_id = v_bank
       from public.post_dated_cheques c where c.id = v_pdc));

  -- Into its own, it clears.
  perform public.clear_pdc(v_pdc, current_date, v_bank);
  perform pg_temp.check_eq('cleared into its own account, the money arrives',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    800::numeric);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The twenty-eight a mutation sweep found
--
-- Forty-four one-line mutants of `record_pdc` against seventeen test
-- files. Sixteen died, and they are the journal in both directions, the
-- held-cheque account chosen by direction, the cheque-date rule, and
-- the allocation. Twenty-eight survived, and they are the FRONT DOOR
-- and the SCOPING -- the same split this programme has now seen on
-- fourteen functions.
--
-- Two of the twenty-eight are cross-tenant. The lookup that finds the
-- document a cheque settles is scoped by `d.org_id = p_org`, and
-- deleting that from either the invoice branch or the bill branch
-- passed the whole suite: a cheque could settle ANOTHER COMPANY'S
-- document, clearing a receivable in books its holder cannot see. Two
-- more are the document TYPE -- without it a quotation is settled as
-- though it were an invoice, and a purchase order as though it were a
-- bill, so a cheque discharges a debt nobody has incurred yet.
--
-- Every refusal below compares the WHOLE message, so a probe cannot be
-- satisfied by whichever guard happens to fire first.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user();
  v_other uuid; v_cust uuid; v_sup uuid; v_item uuid;
  v_bank uuid; v_inv uuid; v_bill uuid; v_quote uuid;
  v_ar2 uuid; v_ap2 uuid; v_rel uuid; v_relsup uuid;
  v_relinv uuid; v_relbill uuid; v_pdc uuid;
  v_far_org uuid; v_far_cust uuid; v_far_inv uuid;
  v_msg text; v_took boolean;
begin
  v_org := pg_temp.test_org('Cek Sapu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C', 'Pelanggan', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S', 'Pembekal', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'KERJA', 'Kerja', 'service', false, 1) returning id into v_item;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org, (select id from public.accounts where org_id = v_org and code = '1120'),
          'Semasa', 'Maybank', '111', 'MYR', 0, 0, true) returning id into v_bank;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'invoice', 'INV-1', current_date, current_date + 30, v_cust,
          'draft', 'MYR', 1) returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Kerja', 1000, 1);
  perform public.post_sales_document(v_inv);

  -- A quotation, posted, for the same customer and the same money.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_org, 'quotation', 'QUO-1', current_date, current_date + 30,
          v_cust, 'posted', 'MYR', 1, 1000, 1000, 1000)
  returning id into v_quote;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_org, 'bill', 'BILL-1', current_date, current_date + 30, v_sup,
          'posted', 'MYR', 1, 1000, 1000, 1000) returning id into v_bill;

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.record_pdc(v_org, 'sideways', v_cust, '1',
      current_date + 30, 100);
    raise exception 'a cheque went sideways';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a cheque is either taken in or written out',
      v_msg, 'A cheque is either taken in or written out.');
  end;

  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '1',
      current_date + 30, 0);
    raise exception 'a cheque for nothing was recorded';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a cheque for nothing at all',
      v_msg, 'A cheque has to be for something.');
  end;

  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '   ',
      current_date + 30, 100);
    raise exception 'a cheque with no number was recorded';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a number of nothing but spaces is no number',
      v_msg, 'A cheque has a number on it.');
  end;

  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '1', null, 100);
    raise exception 'a cheque with no date was recorded';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a cheque has a date on it',
      v_msg, 'A cheque has a date on it.');
  end;

  begin
    perform public.record_pdc(v_org, 'incoming', gen_random_uuid(), '1',
      current_date + 30, 100);
    raise exception 'a cheque was taken from nobody';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a contact that does not exist',
      v_msg, 'No such contact.');
  end;

  -- And a contact of ANOTHER company, which is a different question:
  -- the row exists, it is simply not ours.
  v_far_org := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform public.create_fiscal_year(v_far_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_far_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_far_org, 'C', 'Orang Lain', 'customer') returning id into v_far_cust;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_far_org, 'invoice', 'INV-LAIN', current_date, current_date + 30,
          v_far_cust, 'posted', 'MYR', 1, 1000, 1000, 1000)
  returning id into v_far_inv;
  perform pg_temp.sign_in_as(v_owner);

  begin
    perform public.record_pdc(v_org, 'incoming', v_far_cust, '1',
      current_date + 30, 100);
    raise exception 'a cheque was taken from another company''s customer';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('nor a contact of another company',
      v_msg, 'No such contact.');
  end;

  -- ==================================================================
  -- 2. What a cheque may settle
  -- ==================================================================
  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '1',
      current_date + 30, 100,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 0)));
    raise exception 'a settlement for nothing was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a settlement for nothing',
      v_msg, 'A settlement has to be for something.');
  end;

  -- THE CROSS-TENANT ONE. Another company's invoice, settled by our
  -- cheque, would clear a receivable in books we cannot see.
  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '1',
      current_date + 30, 1000,
      jsonb_build_array(jsonb_build_object('document', v_far_inv,
                                           'amount', 1000)));
    raise exception 'a cheque settled another company''s invoice';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('another company''s invoice is not an invoice here',
      v_msg, 'No such invoice.');
  end;

  -- A quotation is not a debt. Settled as one, a cheque discharges
  -- money nobody has been billed for.
  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '1',
      current_date + 30, 1000,
      jsonb_build_array(jsonb_build_object('document', v_quote,
                                           'amount', 1000)));
    raise exception 'a cheque settled a quotation';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('nor is a quotation',
      v_msg, 'No such invoice.');
  end;

  -- A deleted invoice is not one either.
  declare v_gone uuid;
  begin
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount,
       deleted_at)
    values (v_org, 'invoice', 'INV-GONE', current_date, current_date + 30,
            v_cust, 'posted', 'MYR', 1, 1000, 1000, 1000, now())
    returning id into v_gone;
    begin
      perform public.record_pdc(v_org, 'incoming', v_cust, '1',
        current_date + 30, 1000,
        jsonb_build_array(jsonb_build_object('document', v_gone,
                                             'amount', 1000)));
      raise exception 'a cheque settled a deleted invoice';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('nor an invoice somebody deleted',
        v_msg, 'No such invoice.');
    end;
  end;

  -- The same on the buying side: another company's bill, and a purchase
  -- order that is not a bill.
  declare v_far_bill uuid; v_po uuid;
  begin
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_far_org, 'S', 'Pembekal Lain', 'supplier') returning id into v_far_cust;
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount)
    values (v_far_org, 'bill', 'BILL-LAIN', current_date, current_date + 30,
            v_far_cust, 'posted', 'MYR', 1, 1000, 1000, 1000)
    returning id into v_far_bill;
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount)
    values (v_org, 'purchase_order', 'PO-1', current_date, current_date + 30,
            v_sup, 'posted', 'MYR', 1, 1000, 1000, 1000)
    returning id into v_po;

    begin
      perform public.record_pdc(v_org, 'outgoing', v_sup, '2',
        current_date + 30, 1000,
        jsonb_build_array(jsonb_build_object('document', v_far_bill,
                                             'amount', 1000)));
      raise exception 'a cheque settled another company''s bill';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('another company''s bill is not a bill here',
        v_msg, 'No such bill.');
    end;

    begin
      perform public.record_pdc(v_org, 'outgoing', v_sup, '2',
        current_date + 30, 1000,
        jsonb_build_array(jsonb_build_object('document', v_po,
                                             'amount', 1000)));
      raise exception 'a cheque settled a purchase order';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('nor is a purchase order',
        v_msg, 'No such bill.');
    end;
  end;

  -- A draft is not outstanding.
  declare v_draft uuid;
  begin
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount)
    values (v_org, 'invoice', 'INV-DRAFT', current_date, current_date + 30,
            v_cust, 'draft', 'MYR', 1, 1000, 1000, 1000)
    returning id into v_draft;
    begin
      perform public.record_pdc(v_org, 'incoming', v_cust, '1',
        current_date + 30, 1000,
        jsonb_build_array(jsonb_build_object('document', v_draft,
                                             'amount', 1000)));
      raise exception 'a cheque settled a draft';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('a cheque settles an outstanding document',
        v_msg, 'INV-DRAFT is draft, and a cheque settles an outstanding '
            || 'document.');
    end;
  end;

  -- Somebody else's invoice, in our own books.
  declare v_other_cust uuid; v_other_inv uuid;
  begin
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, 'C2', 'Pelanggan Dua', 'customer') returning id into v_other_cust;
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount)
    values (v_org, 'invoice', 'INV-2', current_date, current_date + 30,
            v_other_cust, 'posted', 'MYR', 1, 1000, 1000, 1000)
    returning id into v_other_inv;
    begin
      perform public.record_pdc(v_org, 'incoming', v_cust, '1',
        current_date + 30, 1000,
        jsonb_build_array(jsonb_build_object('document', v_other_inv,
                                             'amount', 1000)));
      raise exception 'one customer''s cheque settled another''s invoice';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('a cheque settles its own party''s document',
        v_msg, 'That cheque is not INV-2''s.');
    end;
  end;

  -- A foreign invoice. A cheque held for weeks carries an exchange
  -- difference that only clearing settles.
  declare v_usd uuid;
  begin
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount)
    values (v_org, 'invoice', 'INV-USD', current_date, current_date + 30,
            v_cust, 'posted', 'USD', 4.7, 1000, 1000, 1000)
    returning id into v_usd;
    begin
      perform public.record_pdc(v_org, 'incoming', v_cust, '1',
        current_date + 30, 1000,
        jsonb_build_array(jsonb_build_object('document', v_usd,
                                             'amount', 1000)));
      raise exception 'a cheque settled a foreign invoice';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_true('a foreign document is banked, not held',
        v_msg like 'INV-USD is in USD, and a cheque held for weeks in '
                || 'another currency%');
    end;
  end;

  -- More than the document owes.
  begin
    perform public.record_pdc(v_org, 'incoming', v_cust, '1',
      current_date + 30, 1500,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 1500)));
    raise exception 'a cheque settled more than the invoice owed';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a cheque cannot settle more than is owed',
      v_msg, 'INV-1 has 1000.00 outstanding and the cheque would settle '
          || '1500.00.');
  end;

  -- ==================================================================
  -- 3. The control accounts the party names
  --
  -- THE COALESCE FALLBACK. Both sides read the contact's own control
  -- account and fall back to 1210 / 2110, and every cheque in this file
  -- was drawn by a contact that has none.
  -- ==================================================================
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '1215', 'Receivable — related', 'asset', 'accounts_receivable')
  returning id into v_ar2;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '2115', 'Payable — related', 'liability', 'accounts_payable')
  returning id into v_ap2;
  insert into public.contacts
    (org_id, code, name, contact_type, receivable_account_id)
  values (v_org, 'C-REL', 'Anak Syarikat', 'customer', v_ar2) returning id into v_rel;
  insert into public.contacts
    (org_id, code, name, contact_type, payable_account_id)
  values (v_org, 'S-REL', 'Induk', 'supplier', v_ap2) returning id into v_relsup;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_org, 'invoice', 'INV-REL', current_date, current_date + 30,
          v_rel, 'posted', 'MYR', 1, 600, 600, 600) returning id into v_relinv;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, subtotal, total_amount, balance_amount)
  values (v_org, 'bill', 'BILL-REL', current_date, current_date + 30,
          v_relsup, 'posted', 'MYR', 1, 700, 700, 700) returning id into v_relbill;

  v_pdc := public.record_pdc(v_org, 'incoming', v_rel, '900',
    current_date + 30, 600,
    jsonb_build_array(jsonb_build_object('document', v_relinv, 'amount', 600)),
    v_bank);
  perform pg_temp.check_eq(
    'the receivable relieved is the one the customer names',
    (select sum(gl.credit) from public.gl_lines gl
       join public.post_dated_cheques c on c.gl_entry_id = gl.entry_id
      where c.id = v_pdc and gl.account_id = v_ar2), 600::numeric);
  perform pg_temp.check_eq('and nothing of it in the ordinary one',
    (select coalesce(sum(gl.credit), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
       join public.post_dated_cheques c on c.gl_entry_id = gl.entry_id
      where c.id = v_pdc and a.code = '1210'), 0::numeric);
  perform pg_temp.check_eq('and both lines name the party',
    (select count(*) from public.gl_lines gl
       join public.post_dated_cheques c on c.gl_entry_id = gl.entry_id
      where c.id = v_pdc and gl.contact_id = v_rel), 2);
  -- `app.today()`, not `current_date`. `record_pdc` dates the entry
  -- with Malaysia's day (`v_on := coalesce(p_received, app.today())`),
  -- and this session's `current_date` is UTC. Between 16:00 and
  -- midnight UTC those are DIFFERENT DAYS, so written the other way
  -- this assertion fails for eight hours out of every twenty-four --
  -- which is exactly what it did, at 00:41 in Kuala Lumpur.
  --
  -- `malaysian_clock.sql` exists for this and says so: the day a
  -- Malaysian business is having is `app.today()`, and a test that
  -- reaches for the server's own date is asking a different question.
  perform pg_temp.check_true('the journal is dated the day it was taken in',
    (select e.entry_date = app.today() from public.gl_entries e
       join public.post_dated_cheques c on c.gl_entry_id = e.id
      where c.id = v_pdc));
  perform pg_temp.check_eq('and filed as a cheque',
    (select e.source::text from public.gl_entries e
       join public.post_dated_cheques c on c.gl_entry_id = e.id
      where c.id = v_pdc), 'cheque');
  perform pg_temp.check_eq('with the number trimmed of its spaces',
    (select cheque_no from public.post_dated_cheques where id = v_pdc), '900');

  v_pdc := public.record_pdc(v_org, 'outgoing', v_relsup, '  901  ',
    current_date + 30, 700,
    jsonb_build_array(jsonb_build_object('document', v_relbill, 'amount', 700)),
    v_bank);
  perform pg_temp.check_eq(
    'the payable relieved is the one the supplier names',
    (select sum(gl.debit) from public.gl_lines gl
       join public.post_dated_cheques c on c.gl_entry_id = gl.entry_id
      where c.id = v_pdc and gl.account_id = v_ap2), 700::numeric);
  perform pg_temp.check_eq('with nothing of it in the ordinary one',
    (select coalesce(sum(gl.debit), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
       join public.post_dated_cheques c on c.gl_entry_id = gl.entry_id
      where c.id = v_pdc and a.code = '2110'), 0::numeric);
  perform pg_temp.check_eq('and the number is stored trimmed',
    (select cheque_no from public.post_dated_cheques where id = v_pdc), '901');

  -- A document that is PART paid is still outstanding, and this is the
  -- ordinary case: a customer pays half today and post-dates a cheque
  -- for the rest. Refuse it and the second half can never be recorded
  -- as a cheque at all.
  declare v_half uuid; v_rcp uuid;
  begin
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subtotal, total_amount, balance_amount)
    values (v_org, 'invoice', 'INV-HALF', current_date, current_date + 30,
            v_cust, 'posted', 'MYR', 1, 1000, 1000, 1000)
    returning id into v_half;
    insert into public.receipts
      (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
       currency, exchange_rate, amount, unapplied_amount)
    values (v_org, 'RCP-HALF', current_date, v_cust, v_bank, 'MYR', 1,
            400, 400) returning id into v_rcp;
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount)
    values (v_org, v_rcp, v_half, 400);
    perform pg_temp.check_eq('the invoice is part paid',
      (select status::text from public.sales_documents where id = v_half),
      'partial');

    v_pdc := public.record_pdc(v_org, 'incoming', v_cust, '906',
      current_date + 30, 600,
      jsonb_build_array(jsonb_build_object('document', v_half, 'amount', 600)),
      v_bank);
    perform pg_temp.check_eq(
      'and a cheque may settle the rest of a part-paid document',
      (select balance_amount from public.sales_documents where id = v_half),
      0::numeric);
  end;

  -- ==================================================================
  -- 4. A cheque against nothing is in the register and nowhere else
  -- ==================================================================
  v_pdc := public.record_pdc(v_org, 'incoming', v_cust, '902',
    current_date + 30, 250, '[]'::jsonb, v_bank);
  perform pg_temp.check_true('a cheque against nothing posts no journal',
    (select gl_entry_id is null from public.post_dated_cheques where id = v_pdc));
  perform pg_temp.check_eq('and settles nothing',
    (select count(*) from public.payment_allocations where pdc_id = v_pdc), 0);

  -- ==================================================================
  -- 5. Who may write one
  -- ==================================================================
  -- Somebody outside the company. The guard is app.can_write_module,
  -- which is about MODULE ACCESS rather than about role: a member whose
  -- access type is unset is granted write, so an ordinary member is not
  -- the probe for it. The two things it actually refuses are a stranger
  -- and a module the company does not hold, and both are below.
  declare v_clerk uuid := pg_temp.another_user('stranger@cek.test');
  begin
    perform pg_temp.sign_in_as(v_clerk);
    begin
      perform public.record_pdc(v_org, 'incoming', v_cust, '903',
        current_date + 30, 100);
      v_msg := null;
    exception when others then get stacked diagnostics v_msg = message_text;
    end;
    perform pg_temp.sign_in_as(v_owner);
    perform pg_temp.check_eq('somebody who may not write may not take a cheque',
      v_msg, 'not permitted to write for this organization');
  end;

  -- And an outgoing cheque is the PURCHASES module, not sales. Read as
  -- sales, a company that bought the sales module and not purchases
  -- could write cheques it has no right to write.
  declare v_seller uuid := pg_temp.another_user('seller@cek.test');
  begin
    update public.org_modules set is_enabled = false
     where org_id = v_org and module_code = 'purchases';
    begin
      perform public.record_pdc(v_org, 'outgoing', v_sup, '904',
        current_date + 30, 100);
      v_msg := null;
    exception when others then get stacked diagnostics v_msg = message_text;
    end;
    perform pg_temp.check_eq(
      'an outgoing cheque is the purchases module, not sales',
      v_msg, 'not permitted to write for this organization');
    -- The control: with sales still on, an incoming one goes through.
    v_pdc := public.record_pdc(v_org, 'incoming', v_cust, '905',
      current_date + 30, 100, '[]'::jsonb, v_bank);
    perform pg_temp.check_true('while an incoming one still may be taken',
      v_pdc is not null);
    update public.org_modules set is_enabled = true
     where org_id = v_org and module_code = 'purchases';
  end;

  perform pg_temp.sign_out();
  raise notice 'ok   cheques: the twenty-eight a sweep found';
end $$;


rollback;
