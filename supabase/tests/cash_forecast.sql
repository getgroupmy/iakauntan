-- =====================================================================
-- The week the money runs out
--
-- One assertion matters more than the rest, and it is the measured lag.
-- An invoice due on the thirtieth from a customer who has taken
-- forty-five days every time is not cash on the thirtieth. A forecast
-- that puts it there is cheerfully wrong every month, and the whole
-- point of the exercise is the week the closing balance goes below
-- zero — which moves when the money does.
--
-- The rest: the running balance carrying across weeks, cheques counted
-- once and not twice, our own bills landing on their due date rather
-- than being quietly stretched, a recurring document repeating across
-- the horizon, and the manual items nothing in the ledger could know.
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
  v_slow   uuid;   -- pays forty-five days late, every time
  v_prompt uuid;   -- pays on the day
  v_sup    uuid;
  v_item   uuid;
  v_bank   uuid;

  v_inv    uuid;
  v_bill   uuid;
  v_pdc    uuid;
  v_msg    text;
  v_n      numeric;
  v_row    record;
  i        integer;
begin
  v_org := pg_temp.test_org('Syarikat Aliran Tunai Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['accounting','sales','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'LAMBAT', 'Always forty-five days', 'customer')
  returning id into v_slow;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CEPAT', 'Pays on the day', 'customer')
  returning id into v_prompt;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'A supplier', 'supplier') returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'KERJA', 'Work', 'service', false, 1)
  returning id into v_item;

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current account', 'Maybank', '512345678901', 'MYR', 0, 10000, true)
  returning id into v_bank;

  -- ------------------------------------------------------------------
  -- 1. The opening position is what the bank actually holds
  -- ------------------------------------------------------------------
  select * into v_row from public.report_cash_forecast(v_org, 4) where week_no = 1;
  perform pg_temp.check_eq('week one opens on the real balance',
    v_row.opening, 10000::numeric);
  perform pg_temp.check_eq('and starts today',
    v_row.week_start::text, current_date::text);

  -- ------------------------------------------------------------------
  -- 2. The assertion this migration is built around
  -- ------------------------------------------------------------------
  --
  -- Three invoices from the slow payer, each settled forty-five days
  -- after it was due. Then a fourth, still open, due in a week.
  for i in 1 .. 3 loop
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
       exchange_rate, status)
    values (v_org, 'invoice', 'OLD-' || i,
            current_date - (200 - i * 30), current_date - (200 - i * 30),
            v_slow, 'MYR', 1, 'draft')
    returning id into v_inv;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, item_id, description,
       quantity, unit_price)
    values (v_org, v_inv, 1, 'item', v_item, 'Work', 1000, 1);
    perform public.post_sales_document(v_inv);
    -- Settled forty-five days after it fell due.
    insert into public.payment_allocations
      (org_id, credit_note_id, invoice_id, amount, allocated_at)
    select v_org, null, v_inv, 1000,
           (current_date - (200 - i * 30) + 45)::timestamptz
     where false;
    -- The allocation needs a source, so a receipt carries it.
    insert into public.receipts
      (org_id, receipt_no, receipt_date, contact_id, currency, exchange_rate,
       amount, unapplied_amount, status, bank_account_id)
    values (v_org, 'R-' || i, current_date - (200 - i * 30) + 45, v_slow,
            'MYR', 1, 1000, 0, 'draft', v_bank)
    returning id into v_pdc;
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_at)
    values (v_org, v_pdc, v_inv, 1000,
            (current_date - (200 - i * 30) + 45)::timestamptz);
  end loop;

  perform pg_temp.check_eq(
    'the slow payer takes forty-five days, and the system knows it',
    (select l.lag_days from public.customer_payment_lags(v_org) l
      where l.contact_id = v_slow), 45::numeric);

  -- Now one still open, due in seven days.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-SLOW', current_date, current_date + 7,
          v_slow, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 5000, 1);
  perform public.post_sales_document(v_inv);

  -- Due in a week; expected in seven plus forty-five days, which is
  -- week eight, not week two.
  perform pg_temp.check_eq('the invoice is not expected when it falls due',
    (select count(*) from public.cash_forecast_detail(
       v_org, current_date, current_date + 13)
      where reference = 'INV-SLOW'), 0::numeric);
  perform pg_temp.check_eq('but forty-five days after that',
    (select d.expected_on from public.cash_forecast_detail(
       v_org, current_date, current_date + 90) d
      where d.reference = 'INV-SLOW')::text, (current_date + 52)::text);

  -- And with the history turned off it lands on the due date, which is
  -- the comparison that shows the shift is doing something.
  perform pg_temp.check_eq('without history it lands on the due date',
    (select d.expected_on from public.cash_forecast_detail(
       v_org, current_date, current_date + 90, false) d
      where d.reference = 'INV-SLOW')::text, (current_date + 7)::text);

  -- ------------------------------------------------------------------
  -- 3. A customer with no history gets his terms as written
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-FAST', current_date, current_date + 10,
          v_prompt, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 2000, 1);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('a new customer is taken at his word',
    (select d.expected_on from public.cash_forecast_detail(
       v_org, current_date, current_date + 90) d
      where d.reference = 'INV-FAST')::text, (current_date + 10)::text);

  -- ------------------------------------------------------------------
  -- 4. Our own bills are not quietly stretched
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, current_date + 3, v_sup,
          'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Materials', 4000, 1);
  perform public.post_purchase_document(v_bill);

  perform pg_temp.check_eq('a bill lands on the day it is due',
    (select d.expected_on from public.cash_forecast_detail(
       v_org, current_date, current_date + 90) d
      where d.reference = 'BILL-1')::text, (current_date + 3)::text);
  perform pg_temp.check_eq('and it is money going out',
    (select d.direction from public.cash_forecast_detail(
       v_org, current_date, current_date + 90) d
      where d.reference = 'BILL-1'), 'out');

  -- ------------------------------------------------------------------
  -- 5. A cheque is counted once
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-CHQ', current_date, current_date + 5,
          v_prompt, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 3000, 1);
  perform public.post_sales_document(v_inv);

  v_pdc := public.record_pdc(
    v_org, 'incoming', v_prompt, '778899', current_date + 20, 3000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 3000)),
    v_bank, 'CIMB');

  perform pg_temp.check_eq('the cheque is expected on its own date',
    (select d.expected_on from public.cash_forecast_detail(
       v_org, current_date, current_date + 90) d
      where d.source = 'cheque')::text, (current_date + 20)::text);
  -- 0275 took the invoice off the receivable ledger when the cheque was
  -- recorded, so the invoice arm cannot see it any more and the money
  -- appears exactly once.
  perform pg_temp.check_eq('and its invoice is not counted again beside it',
    (select count(*) from public.cash_forecast_detail(
       v_org, current_date, current_date + 90)
      where reference = 'INV-CHQ'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 6. What only a person knows
  -- ------------------------------------------------------------------
  perform public.upsert_cash_forecast_item(
    null, v_org, 'out', 'Income tax instalment', 2500, current_date + 14,
    'monthly', current_date + 100);
  perform pg_temp.check_eq('a monthly instalment repeats across the horizon',
    (select count(*) from public.cash_forecast_detail(
       v_org, current_date, current_date + 100)
      where reference = 'Income tax instalment'), 3::numeric);

  perform public.upsert_cash_forecast_item(
    null, v_org, 'out', 'A lorry', 90000, current_date + 21);
  perform pg_temp.check_eq('and a one-off happens once',
    (select count(*) from public.cash_forecast_detail(
       v_org, current_date, current_date + 365)
      where reference = 'A lorry'), 1::numeric);

  -- ------------------------------------------------------------------
  -- 7. The single number
  -- ------------------------------------------------------------------
  --
  -- Ten thousand in the bank, ninety going out on a lorry in three
  -- weeks, and the slow payer's five thousand not arriving until week
  -- eight. It runs dry, and the date is the whole point of the report.
  perform pg_temp.check_true('it runs out of money',
    public.cash_runs_out_on(v_org, 13) is not null);
  perform pg_temp.check_true('in the week the lorry is paid for',
    public.cash_runs_out_on(v_org, 13)
      between current_date + 14 and current_date + 21);

  -- The running balance is a running balance: each week opens where the
  -- last one closed.
  perform pg_temp.check_eq('every week opens where the last one closed',
    (select count(*) from (
       select r.opening, lag(r.closing) over (order by r.week_no) as prev
         from public.report_cash_forecast(v_org, 13) r) x
      where x.prev is not null and x.opening <> x.prev), 0::numeric);

  -- And with the lorry switched off it does not.
  perform public.retire_cash_forecast_item(
    (select l.id from public.cash_forecast_items_list(v_org) l
      where l.description = 'A lorry'));
  perform pg_temp.check_true('and stops running out once the lorry is off',
    public.cash_runs_out_on(v_org, 13) is null);
  perform pg_temp.check_eq('the item is switched off rather than deleted',
    (select count(*) from public.cash_forecast_items_list(v_org)
      where description = 'A lorry' and not is_active), 1::numeric);

  -- ------------------------------------------------------------------
  -- 8. What it refuses
  -- ------------------------------------------------------------------
  begin
    perform public.upsert_cash_forecast_item(
      null, v_org, 'out', '   ', 100, current_date);
    perform pg_temp.check_true('a nameless line is allowed', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a forecast line says what it is',
      v_msg like '%Say what it is%');
  end;

  begin
    perform public.upsert_cash_forecast_item(
      null, v_org, 'out', 'Backwards', 100, current_date + 30, 'monthly',
      current_date + 10);
    perform pg_temp.check_true('something can stop before it starts', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and cannot stop before it starts',
      v_msg like '%stops before it starts%');
  end;

  raise notice 'ok   cash_flow';
end $$;

rollback;
