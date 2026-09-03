-- =====================================================================
-- The customer who is also the supplier
--
-- One assertion matters more than the rest, and it is that the
-- subsidiary ledgers move. A manual journal between the two control
-- accounts is what a contra has had to be until now, and it leaves the
-- invoice and the bill showing their old balances — so the aged
-- receivable stops agreeing with the account it is meant to reconcile
-- to, silently, and stays wrong.
--
-- The rest: the ledger entry itself, the two sides having to come to
-- the same figure, a party being the same party, a foreign document
-- being refused rather than guessed at, and voiding one putting both
-- balances back.
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
  v_both   uuid;   -- one contact, buys and sells
  v_cust   uuid;   -- and the same party kept as two records
  v_sup    uuid;
  v_other  uuid;   -- somebody else entirely
  v_item   uuid;

  v_inv    uuid;
  v_inv2   uuid;
  v_bill   uuid;
  v_bill2  uuid;
  v_ctr    uuid;
  v_entry  uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Kedai Besi Sinar Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (v_org, 'BINA', 'Bina Jaya Enterprise', 'both', 'C1234567890')
  returning id into v_both;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'LAIN', 'Somebody else', 'both') returning id into v_other;

  -- A service, so this file is about the money and nothing else: an
  -- item that held stock would drag warehouses into a test about two
  -- control accounts.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SIMEN', 'Cement', 'service', false, 100)
  returning id into v_item;

  -- He owes us eight thousand.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_both,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Cement', 80, 100);
  perform public.post_sales_document(v_inv);

  -- We owe him five.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_both, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Scaffolding hire', 50, 100);
  perform public.post_purchase_document(v_bill);

  perform pg_temp.check_eq('he owes eight thousand',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    8000::numeric);
  perform pg_temp.check_eq('and we owe him five',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    5000::numeric);

  -- ------------------------------------------------------------------
  -- 1. Both sides have to come to the same figure
  -- ------------------------------------------------------------------
  begin
    perform public.create_contra(
      v_org, current_date,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 8000)),
      jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 5000)),
      null);
    perform pg_temp.check_true('a contra can invent three thousand', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a contra cancels what is owed both ways and creates nothing',
      v_msg like '%come to 8000.00 and 5000.00%');
  end;

  -- ------------------------------------------------------------------
  -- 2. The assertion this migration is built around
  -- ------------------------------------------------------------------
  --
  -- The smaller figure cancels, and both subsidiary ledgers say so.
  v_ctr := public.create_contra(
    v_org, current_date,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 5000)),
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 5000)),
    'Agreed at the yard');

  perform pg_temp.check_eq('the invoice is down to three thousand',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    3000::numeric);
  perform pg_temp.check_eq('and says it is part paid',
    (select d.status::text from public.sales_documents d where d.id = v_inv),
    'partial');
  perform pg_temp.check_eq('the bill is settled in full',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    0::numeric);
  perform pg_temp.check_eq('and says so',
    (select d.status::text from public.purchase_documents d where d.id = v_bill),
    'completed');

  select n.gl_entry_id into v_entry from public.contra_notes n where n.id = v_ctr;
  perform pg_temp.check_eq('the payable is debited',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2110'), 5000::numeric);
  perform pg_temp.check_eq('and the receivable credited by the same',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 5000::numeric);
  perform pg_temp.check_eq('no cash moved, and none was pretended to',
    (select count(*) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.account_subtype = 'bank'), 0::numeric);

  -- The aged receivable and the control account are the whole point:
  -- after a contra they still agree, which is what a manual journal
  -- could never manage.
  perform pg_temp.check_eq(
    'what the customer ledger says he owes',
    (select coalesce(sum(d.balance_amount), 0) from public.sales_documents d
      where d.org_id = v_org and d.doc_type = 'invoice'
        and d.status in ('posted', 'partial')), 3000::numeric);
  perform pg_temp.check_eq(
    'is what the control account says he owes',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where a.org_id = v_org and a.code = '1210'), 3000::numeric);

  -- ------------------------------------------------------------------
  -- 3. Voiding it puts both back
  -- ------------------------------------------------------------------
  perform public.void_contra(v_ctr, 'He changed his mind');
  perform pg_temp.check_eq('the invoice owes eight thousand again',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    8000::numeric);
  perform pg_temp.check_eq('and the bill five',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    5000::numeric);
  perform pg_temp.check_eq(
    'the ledger entry is reversed rather than deleted',
    (select count(*) from public.gl_entries e where e.id = v_entry), 1::numeric);
  perform pg_temp.check_true('and the reversal is recorded on the note',
    (select n.void_entry_id is not null and n.void_reason = 'He changed his mind'
       from public.contra_notes n where n.id = v_ctr));

  begin
    perform public.void_contra(v_ctr, 'again');
    perform pg_temp.check_true('a contra voided twice reverses twice', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a contra cannot be voided twice',
      v_msg like '%already void%');
  end;

  -- Created outside the block below on purpose: an exception inside a
  -- plpgsql block rolls the insert back but leaves the variable holding
  -- its id, and the next line would then void a contra that no longer
  -- exists.
  v_ctr := public.create_contra(
    v_org, current_date,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 100)),
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 100)),
    null);
  begin
    perform public.void_contra(v_ctr, '   ');
    perform pg_temp.check_true('a reversal with no reason is allowed', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and not without saying why',
      v_msg like '%Say why%');
  end;
  perform public.void_contra(v_ctr, 'tidying the test up');

  -- ------------------------------------------------------------------
  -- 4. The same party, kept as two records
  -- ------------------------------------------------------------------
  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (v_org, 'BINA-C', 'Bina Jaya (sales)', 'customer', 'C9999999999')
  returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (v_org, 'BINA-S', 'Bina Jaya (purchases)', 'supplier', 'C9999999999')
  returning id into v_sup;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv2, 1, 'item', v_item, 'Cement', 10, 100);
  perform public.post_sales_document(v_inv2);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-2', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill2;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill2, 1, 'item', v_item, 'Hire', 10, 100);
  perform public.post_purchase_document(v_bill2);

  v_ctr := public.create_contra(
    v_org, current_date,
    jsonb_build_array(jsonb_build_object('document', v_inv2, 'amount', 1000)),
    jsonb_build_array(jsonb_build_object('document', v_bill2, 'amount', 1000)),
    null);
  perform pg_temp.check_eq(
    'two contact records with one TIN are one party',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv2),
    0::numeric);
  perform public.void_contra(v_ctr, 'tidying the test up');

  -- And the same list finds both sides of the party from either record.
  perform pg_temp.check_eq('the candidates list finds both sides',
    (select count(*) from public.contra_candidates(v_cust)), 2::numeric);
  perform pg_temp.check_eq('and does not reach the other company',
    (select count(*) from public.contra_candidates(v_cust) c
      where c.contact_id = v_both), 0::numeric);

  -- ------------------------------------------------------------------
  -- 5. What it refuses
  -- ------------------------------------------------------------------
  --
  -- Two contacts with no TIN between them are two parties, not one.
  -- Treating blank as equal is how one customer's invoice would come to
  -- settle a different supplier's bill.
  begin
    perform public.create_contra(
      v_org, current_date,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 100)),
      jsonb_build_array(jsonb_build_object('document', v_bill2, 'amount', 100)),
      null);
    perform pg_temp.check_true('two different parties can be offset', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a contra between two different parties is refused',
      v_msg like '%two different parties%');
  end;

  -- More than is outstanding.
  begin
    perform public.create_contra(
      v_org, current_date,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 99000)),
      jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 99000)),
      null);
    perform pg_temp.check_true('a contra can overpay an invoice', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and cannot settle more than is outstanding',
      v_msg like '%outstanding and the contra is for%');
  end;

  -- One-sided.
  begin
    perform public.create_contra(
      v_org, current_date,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 100)),
      '[]'::jsonb, null);
    perform pg_temp.check_true('a one-sided contra is a contra', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a contra needs something on both sides',
      v_msg like '%both sides%');
  end;

  -- Foreign currency, refused rather than guessed at.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-3', current_date, current_date, v_both,
          'USD', 4.7, 'draft')
  returning id into v_inv2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv2, 1, 'item', v_item, 'Cement', 10, 100);
  perform public.post_sales_document(v_inv2);
  begin
    perform public.create_contra(
      v_org, current_date,
      jsonb_build_array(jsonb_build_object('document', v_inv2, 'amount', 100)),
      jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 100)),
      null);
    perform pg_temp.check_true('a rate nobody agreed was struck anyway', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a foreign document is refused rather than struck at a guessed rate',
      v_msg like '%only the two parties can agree%');
  end;

  -- And a draft has nothing outstanding to offset.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-3', current_date, v_both, 'MYR', 1, 'draft')
  returning id into v_bill2;
  begin
    perform public.create_contra(
      v_org, current_date,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 100)),
      jsonb_build_array(jsonb_build_object('document', v_bill2, 'amount', 100)),
      null);
    perform pg_temp.check_true('a draft bill can be contra''d', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('only an outstanding posted bill can be offset',
      v_msg like '%only an outstanding posted bill%');
  end;

  -- ------------------------------------------------------------------
  -- 6. Several against several
  -- ------------------------------------------------------------------
  --
  -- A quarter's trading between two businesses is not one invoice and
  -- one bill.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-4', current_date, v_both, 'MYR', 1, 'draft')
  returning id into v_bill2;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill2, 1, 'item', v_item, 'Hire', 20, 100);
  perform public.post_purchase_document(v_bill2);

  v_ctr := public.create_contra(
    v_org, current_date,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 3000)),
    jsonb_build_array(
      jsonb_build_object('document', v_bill, 'amount', 1000),
      jsonb_build_object('document', v_bill2, 'amount', 2000)),
    null);
  perform pg_temp.check_eq('one invoice settles two bills',
    (select count(*) from public.contra_lines(v_ctr)), 3::numeric);
  -- Eight thousand less the three thousand this contra took: the
  -- earlier ones in this file were all voided again, so the invoice is
  -- back to its full amount before this one strikes.
  perform pg_temp.check_eq('and the invoice is down by all three thousand',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    5000::numeric);
  perform pg_temp.check_eq('and the note is for what it settled',
    (select n.amount from public.contra_notes n where n.id = v_ctr),
    3000::numeric);
  perform pg_temp.check_eq('the list counts both sides',
    (select l.invoices + l.bills from public.contra_notes_list(v_org) l
      where l.id = v_ctr), 3::numeric);

  raise notice 'ok   contra';
end $$;

-- ---------------------------------------------------------------------
-- Who may unpick a contra
-- ---------------------------------------------------------------------
-- A contra touches both subsidiary ledgers, so `void_contra` asks for
-- write on BOTH sales and purchases. Neither half of that was asserted:
-- with both modules on, one check does the same job as two, and the
-- fixture above never involves anybody who lacks either.
--
-- As with deposits, the person tried here is a stranger rather than a
-- viewer: a member with no access type assigned has module write
-- whatever their role (`0501`), so a viewer is not refused and pretending
-- otherwise would assert something untrue.
do $$
declare
  v_org   uuid;
  v_party uuid;
  v_inv   uuid;
  v_bill  uuid;
  v_ctr   uuid;
  v_item  uuid;
  v_owner uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Contra Kebenaran Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'DUA', 'Kedua Pihak Bhd', 'both') returning id into v_party;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'KHIDMAT', 'Service', 'service', false, 100)
  returning id into v_item;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-K1', current_date, current_date, v_party,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Service', 40, 100);
  perform public.post_sales_document(v_inv);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-K1', current_date, v_party, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Hire', 40, 100);
  perform public.post_purchase_document(v_bill);

  v_ctr := public.create_contra(
    v_org, current_date,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 4000)),
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 4000)),
    'Set off');

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-contra@example.test'));
  begin
    perform public.void_contra(v_ctr, 'not mine');
    raise exception 'FAIL a stranger unpicked a contra';
  exception when insufficient_privilege then
    raise notice 'ok   somebody outside the company cannot unpick its contra';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- One module is not enough. A contra puts money back on an invoice
  -- AND on a bill, so a company that has given up either side cannot
  -- undo one.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'purchases';
  begin
    perform public.void_contra(v_ctr, 'without the purchases side');
    raise exception 'FAIL unpicked a contra with only the sales module';
  exception when insufficient_privilege then
    raise notice 'ok   and unpicking one needs both sides of it';
  end;

  -- The sales half of that condition is NOT asserted, and cannot be.
  -- `sales` is a CORE module and `purchases` is an add-on, so
  -- `can_write_module(org, 'sales')` is true for every member of every
  -- company whatever they have bought — the clause can only be false
  -- for somebody who is not a member at all, and for them the purchases
  -- clause is false too. Tried both routes before writing this down:
  -- switching `sales` off in `org_modules` changes nothing, because a
  -- core module is not entitlement-gated. The clause stays because it
  -- says what the function means, and if `sales` ever stops being core
  -- it starts doing work.

  -- With both back, it comes apart as it should.
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'purchases';
  perform public.void_contra(v_ctr, 'agreed to settle in cash instead');
  perform pg_temp.check_eq('and the invoice is whole again',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    4000::numeric);
end $$;

rollback;
