-- =====================================================================
-- iAkauntan :: the settlement discount, and the terms it comes from
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/settlement_discount.sql
--
-- `payment_allocations.discount_amount` has been a column since `0005`
-- and nothing wrote it — which is just as well, because
-- `app.apply_allocation` clears the invoice by `amount +
-- discount_amount` and `app.post_receipt_internal` credits the
-- receivable by the cash alone. An allocation carrying a discount would
-- have marked the invoice settled and left the receivable control
-- account overstated by the discount, permanently, with no document
-- anywhere that mentions it.
--
-- The assertion that matters is the ledger one: after a discount is
-- taken, the receivable account and the invoice agree.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.sd_terms(
  p_org uuid, p_code text, p_days integer, p_type text,
  p_disc numeric default 0, p_disc_days integer default 0)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.payment_terms
    (org_id, code, name, days, term_type, discount_percent, discount_days)
  values (p_org, p_code, p_code, p_days, p_type, p_disc, p_disc_days)
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.sd_invoice(
  p_org uuid, p_no text, p_cust uuid, p_terms uuid, p_amount numeric,
  p_date date default null, p_due date default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, payment_term_id)
  values (p_org, 'invoice', p_no, coalesce(p_date, current_date), p_due,
          p_cust, 'MYR', 1, 'draft', p_terms)
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_id, 1, 'Goods', 1, p_amount);
  perform public.post_sales_document(v_id);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- The date the terms imply
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Syarat Bayaran Sdn Bhd');
  v_cust uuid;
  v_n30  uuid;
  v_eom  uuid;
  v_cod  uuid;
  v_inv  uuid;
  v_said text;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;

  v_n30 := pg_temp.sd_terms(v_org, 'N30', 30, 'net');
  v_eom := pg_temp.sd_terms(v_org, 'E30', 30, 'eom');
  v_cod := pg_temp.sd_terms(v_org, 'COD', 30, 'cod');

  v_inv := pg_temp.sd_invoice(v_org, 'INV-1', v_cust, v_n30, 1000,
    date '2026-03-05');
  perform pg_temp.check_eq('net terms count from the invoice date',
    (select due_date from public.sales_documents where id = v_inv)::text,
    '2026-04-04');

  v_inv := pg_temp.sd_invoice(v_org, 'INV-2', v_cust, v_eom, 1000,
    date '2026-03-05');
  -- The whole point of end-of-month terms: everything invoiced in a
  -- month falls due together, whatever day it went out.
  perform pg_temp.check_eq('end of month terms count from the month end',
    (select due_date from public.sales_documents where id = v_inv)::text,
    '2026-04-30');

  -- Cash on delivery is not credit, whatever the days column says.
  v_inv := pg_temp.sd_invoice(v_org, 'INV-3', v_cust, v_cod, 1000,
    date '2026-03-05');
  perform pg_temp.check_eq('cash on delivery falls due on the day',
    (select due_date from public.sales_documents where id = v_inv)::text,
    '2026-03-05');

  -- A date somebody typed is a date they negotiated.
  v_inv := pg_temp.sd_invoice(v_org, 'INV-4', v_cust, v_n30, 1000,
    date '2026-03-05', date '2026-06-30');
  perform pg_temp.check_eq('a negotiated date is not overwritten',
    (select due_date from public.sales_documents where id = v_inv)::text,
    '2026-06-30');

  begin
    perform pg_temp.sd_invoice(v_org, 'INV-5', v_cust, v_n30, 1000,
      date '2026-03-05', date '2026-03-01');
    raise exception 'FAIL: an invoice fell due before it was raised';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and cannot come before the document',
    v_said like '%before it was raised%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What is on offer
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Diskaun Awal Sdn Bhd');
  v_cust  uuid;
  v_terms uuid;
  v_plain uuid;
  v_half  uuid;
  v_inv   uuid;
  v_flat  uuid;
  r       record;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;

  -- 2/10 net 30, the term every textbook uses.
  v_terms := pg_temp.sd_terms(v_org, '2-10-N30', 30, 'net', 2, 10);
  v_plain := pg_temp.sd_terms(v_org, 'N30', 30, 'net');
  -- A percentage with no day, and a day with no percentage. Neither is
  -- a term anybody could act on.
  v_half  := pg_temp.sd_terms(v_org, 'HALF', 30, 'net', 2, 0);

  v_inv := pg_temp.sd_invoice(v_org, 'INV-1', v_cust, v_terms, 1000, v_today);
  select * into r from public.settlement_discount_available(v_inv);
  perform pg_temp.check_eq('the deadline is the discount days out',
    r.deadline::text, (v_today + 10)::text);
  perform pg_temp.check_eq('and the discount is the percentage of it',
    r.discount, 20);
  perform pg_temp.check_eq('so paying now costs', r.pay_now, 980);
  perform pg_temp.check_true('and it is still open', r.still_open);

  -- After the day, the full amount.
  select * into r from public.settlement_discount_available(v_inv,
    v_today + 11);
  perform pg_temp.check_true('after the day it is not', not r.still_open);
  perform pg_temp.check_eq('and the whole invoice is payable',
    r.pay_now, 1000);

  v_flat := pg_temp.sd_invoice(v_org, 'INV-2', v_cust, v_plain, 1000,
    v_today);
  select * into r from public.settlement_discount_available(v_flat);
  perform pg_temp.check_true('terms with no discount offer none',
    r.deadline is null);
  perform pg_temp.check_eq('and the full amount is due', r.pay_now, 1000);

  v_flat := pg_temp.sd_invoice(v_org, 'INV-3', v_cust, v_half, 1000, v_today);
  select * into r from public.settlement_discount_available(v_flat);
  perform pg_temp.check_true('a percentage with no day is not a term',
    r.deadline is null);

  -- On what is still outstanding, not on the invoice total. Half paid
  -- already, so the discount is on the half that is left — otherwise
  -- the customer is offered the same discount twice on the same money.
  update public.sales_documents
     set paid_amount = 500, balance_amount = 500, status = 'partial'
   where id = v_inv;
  select * into r from public.settlement_discount_available(v_inv);
  perform pg_temp.check_eq('a part-paid invoice discounts what is left',
    r.discount, 10);
  perform pg_temp.check_eq('and asks for the rest of it', r.pay_now, 490);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Taking it, and the ledger agreeing afterwards
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Ambil Diskaun Sdn Bhd');
  v_cust   uuid;
  v_bank   uuid;
  v_terms  uuid;
  v_inv    uuid;
  v_rcp    uuid;
  v_alloc  uuid;
  v_ar     numeric;
  v_disc   numeric;
  v_said   text;
  v_today  date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, currency)
  values (v_org, (select id from public.accounts
                   where org_id = v_org and code = '1110'),
          'Current account', 'Maybank', 'MYR')
  returning id into v_bank;

  v_terms := pg_temp.sd_terms(v_org, '2-10-N30', 30, 'net', 2, 10);
  v_inv := pg_temp.sd_invoice(v_org, 'INV-1', v_cust, v_terms, 1000, v_today);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     amount, unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-1', v_today, v_cust, v_bank, 980, 980, 'MYR', 1)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);

  -- The thing that used to be impossible to do correctly.
  v_alloc := public.allocate_with_discount(v_rcp, v_inv, 980, 20);

  perform pg_temp.check_eq('the invoice is settled',
    (select balance_amount from public.sales_documents where id = v_inv), 0);
  perform pg_temp.check_eq('and marked so',
    (select status::text from public.sales_documents where id = v_inv),
    'completed');

  -- The assertion this file exists for. Before `0385` the receivable
  -- would still hold twenty ringgit against an invoice showing nothing
  -- owed, and nothing anywhere would say why.
  select coalesce(sum(l.debit - l.credit), 0) into v_ar
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where a.org_id = v_org and a.code = '1210';
  perform pg_temp.check_eq('and the receivable is clear in the ledger too',
    round(v_ar, 2), 0);

  select coalesce(sum(l.debit - l.credit), 0) into v_disc
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where a.org_id = v_org and a.code = '4300';
  -- A reduction of revenue, which is what a discount for early
  -- settlement is — not an expense.
  perform pg_temp.check_eq('with the discount against revenue',
    round(v_disc, 2), 20);

  perform pg_temp.check_true('and the allocation names the journal',
    (select discount_entry_id is not null from public.payment_allocations
      where id = v_alloc));

  -- The tax is untouched. What was charged is what LHDN was told, and
  -- changing the taxable value takes a credit note.
  perform pg_temp.check_eq('the tax account is not touched',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
       join public.gl_entries e on e.id = l.entry_id
      where a.org_id = v_org and a.account_subtype = 'tax_payable'
        and e.description like 'Settlement discount%'), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What will not be discounted
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tak Layak Diskaun Sdn Bhd');
  v_cust  uuid;
  v_bank  uuid;
  v_terms uuid;
  v_plain uuid;
  v_inv   uuid;
  v_flat  uuid;
  v_old   uuid;
  v_rcp    uuid;
  v_legacy uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, currency)
  values (v_org, (select id from public.accounts
                   where org_id = v_org and code = '1110'),
          'Current account', 'Maybank', 'MYR')
  returning id into v_bank;

  v_terms := pg_temp.sd_terms(v_org, '2-10-N30', 30, 'net', 2, 10);
  v_plain := pg_temp.sd_terms(v_org, 'N30', 30, 'net');
  v_inv   := pg_temp.sd_invoice(v_org, 'INV-1', v_cust, v_terms, 1000,
    v_today);
  v_flat  := pg_temp.sd_invoice(v_org, 'INV-2', v_cust, v_plain, 1000,
    v_today);
  v_old   := pg_temp.sd_invoice(v_org, 'INV-3', v_cust, v_terms, 1000,
    v_today - 40);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     amount, unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-1', v_today, v_cust, v_bank, 3000, 3000, 'MYR', 1)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);

  begin
    perform public.allocate_with_discount(v_rcp, v_flat, 980, 20);
    raise exception 'FAIL: a discount was taken on terms that offer none';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('terms with no discount offer none',
    v_said like '%offer no settlement discount%');
  perform pg_temp.check_true('and the way through is a credit note',
    v_said like '%credit note%');

  begin
    perform public.allocate_with_discount(v_rcp, v_old, 980, 20);
    raise exception 'FAIL: an expired discount was taken';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a discount that ran out is not a discount',
    v_said like '%ran out on%');

  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 950, 50);
    raise exception 'FAIL: more was taken than the terms allow';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and no more than the terms allow',
    v_said like '%allow 20.00 as a settlement discount, not 50.00%');

  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 1000, 20);
    raise exception 'FAIL: cash and discount exceeded what was owed';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor more than is owed',
    v_said like '%come to more than%');

  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 0, 20);
    raise exception 'FAIL: an allocation of nothing was made';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  -- The message, not just the code. The table's own check on `amount`
  -- would refuse this too, and a test that took either would pass with
  -- this function's guard removed — after a discount journal had been
  -- posted for an allocation that never landed.
  perform pg_temp.check_true('and is refused before anything is posted',
    v_said like '%allocation is of something%');

  -- And the rule underneath all of it: an allocation cannot carry a
  -- discount that nothing posted, whatever route it comes in by.
  begin
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, discount_amount)
    values (v_org, v_rcp, v_inv, 980, 20);
    raise exception 'FAIL: a discount was written with no journal';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a discount without a journal is refused',
    v_said like '%overstated by this amount%');

  -- An ordinary allocation with no discount is untouched by any of it.
  perform pg_temp.check_true('an allocation with no discount is ordinary',
    public.allocate_with_discount(v_rcp, v_flat, 1000) is not null);

  -- A row exactly as they stood before this migration: a discount, and
  -- no journal. They are the damage the notice at the top reports, and
  -- somebody has to be able to correct them — so the guard judges the
  -- change and leaves an existing one editable.
  alter table public.payment_allocations
    disable trigger payment_allocations_discount_ck;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, discount_amount)
  values (v_org, v_rcp, v_old, 900, 20) returning id into v_legacy;
  alter table public.payment_allocations
    enable trigger payment_allocations_discount_ck;

  update public.payment_allocations set amount = 950 where id = v_legacy;
  perform pg_temp.check_eq('a row from before the rule stays editable',
    (select amount from public.payment_allocations where id = v_legacy), 950);

  -- Changing the discount itself, though, is claiming one now.
  begin
    update public.payment_allocations set discount_amount = 30
     where id = v_legacy;
    raise exception 'FAIL: an old discount was raised with no journal';
  exception when sqlstate '23514' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Siapa Boleh Diskaun Sdn Bhd');
  v_cust  uuid;
  v_bank  uuid;
  v_terms uuid;
  v_inv   uuid;
  v_rcp   uuid;
  v_out   uuid := pg_temp.another_user('outsider@sd.test');
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Sdn Bhd', 'customer') returning id into v_cust;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, currency)
  values (v_org, (select id from public.accounts
                   where org_id = v_org and code = '1110'),
          'Current account', 'Maybank', 'MYR')
  returning id into v_bank;
  v_terms := pg_temp.sd_terms(v_org, '2-10-N30', 30, 'net', 2, 10);
  v_inv := pg_temp.sd_invoice(v_org, 'INV-1', v_cust, v_terms, 1000, v_today);
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     amount, unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-1', v_today, v_cust, v_bank, 980, 980, 'MYR', 1)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);

  perform pg_temp.sign_in_as(v_out);
  begin
    perform public.settlement_discount_available(v_inv);
    raise exception 'FAIL: an outsider read a document';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.allocate_with_discount(v_rcp, v_inv, 980, 20);
    raise exception 'FAIL: an outsider allocated a receipt';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  -- The message: `create_gl_entry` refuses an outsider too, and a test
  -- taking either would pass with this function's own check removed.
  perform pg_temp.check_true('and is refused before anything is read',
    v_said like '%not permitted to allocate a receipt%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the discount on offer is closed to anon',
    not has_function_privilege('anon',
      'public.settlement_discount_available(uuid, date)', 'execute'));
  perform pg_temp.check_true('and taking one',
    not has_function_privilege('anon',
      'public.allocate_with_discount(uuid, uuid, numeric, numeric, date)',
      'execute'));
  perform pg_temp.check_true('while a signed-in user may take one',
    has_function_privilege('authenticated',
      'public.allocate_with_discount(uuid, uuid, numeric, numeric, date)',
      'execute'));
end $$;

rollback;
