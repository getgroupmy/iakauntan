-- =====================================================================
-- iAkauntan :: the shapes one transfer arrives in
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/group_payment_shapes.sql
--
-- `group_payment.sql` is a good file: 69 assertions, a section of its
-- own for what the operation refuses, and a mutation sweep of 63
-- one-line mutants killed 35 of them outright -- both permission
-- checks, all three grouping keys, the overpayment guard from both
-- sides, the duplicate-document check.
--
-- What lived was not the design. It was the arithmetic AT THE EDGES of
-- it, and the reason is one fixture decision: `gp_org` gives every
-- company exactly ONE customer, ONE supplier and ONE bank account, and
-- every figure in the file is a whole number of ringgit.
--
--   * one customer, so `sum` and `max` are the same number and the
--     allocation loop's contact filter has nothing to cross
--   * one bank account, so three of the four conditions on the
--     fallback are unasserted
--   * whole ringgit, so both `round(..., 2)` calls are invisible
--   * and every payment is made today, so `p_paid_on` and
--     `current_date` are the same day
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- Same shape as `group_payment.sql`'s own, with a second customer and a
-- second bank account, which is where most of this file lives.
create or replace function pg_temp.gs_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  perform public.create_fiscal_year(
    v_org, (date_trunc('year', current_date) - interval '1 year')::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true
    from unnest(array['sales', 'purchases', 'accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Kumpulan Awan', 'customer'),
         (v_org, 'CUST2', 'Syarikat Kedua', 'customer'),
         (v_org, 'SUP', 'Pembekal Bersama', 'supplier'),
         (v_org, 'SUP2', 'Pembekal Kedua', 'supplier');
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Consulting', 'service', false, 100);
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current account', 'Maybank', '512345678901', 'MYR', 0, 0, true);
  return v_org;
end $$;

create or replace function pg_temp.gs_contact(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.contacts where org_id = p_org and code = p_code;
$$;

-- Named, not picked: a `limit 1` with no `order by` is a coin toss, and
-- this file deliberately creates a second account in one company.
create or replace function pg_temp.gs_bank(p_org uuid, p_name text)
returns uuid language sql as $$
  select id from public.bank_accounts
   where org_id = p_org and name = p_name order by created_at limit 1;
$$;

create or replace function pg_temp.gs_invoice(
  p_org uuid, p_no text, p_amount numeric,
  p_contact text default 'CUST', p_post boolean default true,
  p_currency char(3) default 'MYR', p_rate numeric default 1,
  p_date date default current_date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', p_no, p_date, p_date,
          pg_temp.gs_contact(p_org, p_contact), p_currency, p_rate, 'draft')
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work done', 1, p_amount);
  if p_post then perform public.post_sales_document(v_id); end if;
  return v_id;
end $$;

create or replace function pg_temp.gs_bill(
  p_org uuid, p_no text, p_amount numeric,
  p_contact text default 'SUP')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', p_no, current_date,
          pg_temp.gs_contact(p_org, p_contact), 'MYR', 1, 'draft')
  returning id into v_id;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work bought', 1, p_amount);
  perform public.post_purchase_document(v_id);
  return v_id;
end $$;

-- One line of a payment, as the client sends it.
create or replace function pg_temp.gs_line(
  p_invoice uuid, p_amount numeric, p_discount numeric default null,
  p_bank uuid default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'invoice_id', p_invoice, 'amount', p_amount,
    'discount', p_discount, 'bank_account_id', p_bank));
$$;

create or replace function pg_temp.gs_bline(
  p_bill uuid, p_amount numeric, p_discount numeric default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'bill_id', p_bill, 'amount', p_amount, 'discount', p_discount));
$$;

-- ---------------------------------------------------------------------
-- 1. A third of a ringgit, and a payload that is not a list
-- ---------------------------------------------------------------------
-- `app.group_payment_lines` is four lines and does three things the
-- rest of the function trusts: it rounds the amount, rounds the
-- discount, and turns a missing payload into an empty list rather than
-- into null. Every figure in the existing file is whole ringgit, so
-- both `round`s were invisible.
--
-- The amounts here are what a three-way split of RM1,000 actually
-- produces. Unrounded, the sum of the parts is a number with more
-- places than money has, and it is compared against a balance that has
-- two -- which is the comparison the overpayment guard makes.
do $$
declare
  v_org uuid := pg_temp.gs_org('Sen Sdn Bhd');
  v_inv uuid; v_batch uuid; v_rec public.receipts;
begin
  v_inv := pg_temp.gs_invoice(v_org, 'INV-SEN', 1000);

  -- 333.333... is not payable. The parser rounds it to the sen before
  -- anything compares it to anything.
  v_batch := public.record_group_payment(
    current_date, 'REF-SEN',
    jsonb_build_array(pg_temp.gs_line(v_inv, 1000.0 / 3)));

  select * into v_rec from public.receipts where batch_id = v_batch;
  perform pg_temp.check_eq('a third of a thousand ringgit is banked in sen',
    v_rec.amount, 333.33);
  perform pg_temp.check_eq('and the invoice is reduced by exactly that',
    (select balance_amount from public.sales_documents where id = v_inv),
    666.67);
  -- The scale is the column's, and the column is what makes the
  -- rounding invisible if the function stops doing it. Asserted so the
  -- two cannot drift apart unnoticed.
  perform pg_temp.check_eq('because money is kept to the sen',
    (select numeric_scale::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'receipts'
        and column_name = 'amount'), 2);
end $$;

-- The payload itself. A client that sends nothing, or sends an object
-- where a list belongs, has to be told rather than have the run fall
-- through `jsonb_to_recordset` into a runtime error nobody can read.
do $$
declare
  v_org uuid := pg_temp.gs_org('Senarai Sdn Bhd');
  v_inv uuid;
begin
  v_inv := pg_temp.gs_invoice(v_org, 'INV-L', 100);

  perform pg_temp.check_refused('a payment of nothing at all is refused',
    format($q$ select public.record_group_payment(
                 current_date, 'R', null::jsonb) $q$),
    '%settles something%', '23514');
  perform pg_temp.check_refused('and so is an object where a list belongs',
    format($q$ select public.record_group_payment(
                 current_date, 'R', '{"invoice_id": null}'::jsonb) $q$),
    '%settles something%', '23514');
  perform pg_temp.check_refused('and a list with nothing in it',
    format($q$ select public.record_group_payment(
                 current_date, 'R', '[]'::jsonb) $q$),
    '%settles something%', '23514');
  -- A string and a number are both valid jsonb and neither is a list.
  perform pg_temp.check_refused('and a bare number',
    format($q$ select public.record_group_payment(
                 current_date, 'R', '7'::jsonb) $q$),
    '%settles something%', '23514');
end $$;

-- ---------------------------------------------------------------------
-- 2. The other side of every guard
-- ---------------------------------------------------------------------
-- Several guards are two-sided and only one side was reached. A line
-- naming NEITHER document was refused; naming BOTH was not. A NEGATIVE
-- allocation was refused; one of exactly nought was not.
do $$
declare
  v_org uuid := pg_temp.gs_org('Dua Belah Sdn Bhd');
  v_inv uuid; v_bill uuid; v_gone uuid; v_part uuid; v_batch uuid;
begin
  v_inv  := pg_temp.gs_invoice(v_org, 'INV-D', 500);
  v_bill := pg_temp.gs_bill(v_org, 'BILL-D', 300);

  -- One line, one document. Naming both is not "settle both" -- the
  -- rest of the function reads `coalesce(invoice_id, bill_id)` and
  -- would silently drop the bill.
  perform pg_temp.check_refused(
    'a line naming an invoice AND a bill is refused',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'invoice_id', %L::uuid, 'bill_id', %L::uuid,
                   'amount', 100))) $q$, v_inv, v_bill),
    '%one invoice or one bill%', '23514');

  -- Nought is not a payment. It would cut a receipt for nothing, number
  -- it, and post it.
  perform pg_temp.check_refused('an allocation of nought is refused',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'invoice_id', %L::uuid, 'amount', 0))) $q$, v_inv),
    '%allocation is of something%', '23514');
  -- And a line with no amount at all, which is what a form field left
  -- blank serialises to.
  perform pg_temp.check_refused('and so is a line with no amount on it',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'invoice_id', %L::uuid))) $q$, v_inv),
    '%allocation is of something%', '23514');

  -- A deleted document is not payable, on either side. It is still in
  -- the table, so only the `deleted_at is null` on the join keeps it
  -- out -- and the count check downstream is what turns its absence
  -- into a refusal rather than a silent short payment.
  v_gone := pg_temp.gs_invoice(v_org, 'INV-GONE', 400);
  update public.sales_documents set deleted_at = now() where id = v_gone;
  perform pg_temp.check_refused('a deleted invoice cannot be paid',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'invoice_id', %L::uuid, 'amount', 100))) $q$, v_gone),
    '%does not exist%', 'P0002');

  v_gone := pg_temp.gs_bill(v_org, 'BILL-GONE', 400);
  update public.purchase_documents set deleted_at = now() where id = v_gone;
  perform pg_temp.check_refused('and neither can a deleted bill',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'bill_id', %L::uuid, 'amount', 100))) $q$, v_gone),
    '%does not exist%', 'P0002');

  -- A made-up bank account is caught by the `a.id is null` half of the
  -- bank check, which the cross-company case never reaches.
  perform pg_temp.check_refused(
    'a bank account that does not exist is refused',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'invoice_id', %L::uuid, 'amount', 100,
                   'bank_account_id', %L::uuid))) $q$,
           v_inv, gen_random_uuid()),
    '%belongs to another company%', '23514');

  -- AND THE ACCEPTING SIDE. A partly paid invoice is exactly what a
  -- group payment is usually for -- somebody paid part of it last
  -- month -- so 'partial' has to be on the allowed list, not merely
  -- 'posted'.
  v_part := pg_temp.gs_invoice(v_org, 'INV-PART', 1000);
  perform public.record_group_payment(
    current_date, 'FIRST', jsonb_build_array(pg_temp.gs_line(v_part, 400)));
  perform pg_temp.check_eq('a part payment leaves the invoice partial',
    (select status::text from public.sales_documents where id = v_part),
    'partial');
  v_batch := public.record_group_payment(
    current_date, 'SECOND', jsonb_build_array(pg_temp.gs_line(v_part, 600)));
  perform pg_temp.check_true('and the rest of it may still be paid',
    v_batch is not null);
  perform pg_temp.check_eq('which settles it',
    (select balance_amount from public.sales_documents where id = v_part), 0);
end $$;

-- ---------------------------------------------------------------------
-- 3. Two customers in one company, and two invoices for one of them
-- ---------------------------------------------------------------------
-- `gp_org` gives each company one customer, and that one decision hides
-- three separate things at once:
--
--   * with one document per group, `sum(amount)` and `max(amount)` are
--     the same number, so the figure banked was never really asserted
--   * with one contact per company, the allocation loop's
--     `contact_id = g.contact_id` has nothing to cross
--   * and the currency check's `c.contact_id = b.contact_id` likewise
--
-- A practice paying its own suppliers' invoices at one company for two
-- different clients on one transfer is the ordinary case: two receipts,
-- because a receipt is FROM somebody, and the money must not cross.
do $$
declare
  v_org uuid := pg_temp.gs_org('Dua Pelanggan Sdn Bhd');
  v_a1 uuid; v_a2 uuid; v_b1 uuid; v_batch uuid;
  v_cust uuid; v_cust2 uuid;
begin
  v_cust  := pg_temp.gs_contact(v_org, 'CUST');
  v_cust2 := pg_temp.gs_contact(v_org, 'CUST2');

  -- Two invoices for the first customer, one for the second.
  v_a1 := pg_temp.gs_invoice(v_org, 'INV-A1', 300, 'CUST');
  v_a2 := pg_temp.gs_invoice(v_org, 'INV-A2', 700, 'CUST');
  v_b1 := pg_temp.gs_invoice(v_org, 'INV-B1', 450, 'CUST2');

  v_batch := public.record_group_payment(
    current_date, 'REF-2C',
    jsonb_build_array(
      pg_temp.gs_line(v_a1, 300),
      pg_temp.gs_line(v_a2, 700),
      pg_temp.gs_line(v_b1, 450)));

  -- Two receipts, not one and not three. One per payer.
  perform pg_temp.check_eq('one transfer, two payers, two receipts',
    (select count(*)::integer from public.receipts where batch_id = v_batch), 2);

  -- THE SUM. The first customer's receipt is RM1,000 -- both invoices
  -- added -- not RM700, which is the larger of the two.
  perform pg_temp.check_eq('the first payer''s receipt is both invoices added',
    (select amount from public.receipts
      where batch_id = v_batch and contact_id = v_cust), 1000);
  perform pg_temp.check_eq('and the second payer''s is their own',
    (select amount from public.receipts
      where batch_id = v_batch and contact_id = v_cust2), 450);

  -- And the allocations stayed where they belong. A loop that dropped
  -- the contact filter would try the first payer's receipt against the
  -- second's invoice.
  perform pg_temp.check_eq('every invoice is settled in full',
    (select sum(balance_amount) from public.sales_documents
      where org_id = v_org), 0);
  perform pg_temp.check_true(
    'and no receipt was applied to another payer''s invoice',
    not exists (
      select 1 from public.payment_allocations a
        join public.receipts r on r.id = a.receipt_id
        join public.sales_documents d on d.id = a.invoice_id
       where r.batch_id = v_batch and d.contact_id <> r.contact_id));
  perform pg_temp.check_eq('nothing is left sitting unapplied',
    (select sum(unapplied_amount) from public.receipts
      where batch_id = v_batch), 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. Which bank account the money lands in
-- ---------------------------------------------------------------------
-- The fallback is four conditions and one company with one account
-- reaches one of them. The comment above it says why it exists: left
-- null the posting falls through to cash and no bank balance moves,
-- which is the wrong answer for every company that banks. So which
-- account it picks matters, and three of the four ways it could pick
-- the wrong one were unasserted.
do $$
declare
  v_org uuid := pg_temp.gs_org('Dua Akaun Sdn Bhd');
  v_main uuid; v_second uuid; v_shut uuid; v_acct uuid;
  v_inv uuid; v_batch uuid;
begin
  v_main := pg_temp.gs_bank(v_org, 'Current account');
  select account_id into v_acct from public.bank_accounts where id = v_main;

  -- A second account that is NOT the default, and a third that is
  -- closed. Both are ordinary: a company keeps a savings account, and
  -- keeps the old current account on file after switching banks.
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default, is_active)
  values (v_org, v_acct, 'Savings account', 'CIMB', '700111222333',
          'MYR', 0, 0, false, true)
  returning id into v_second;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default, is_active)
  values (v_org, v_acct, 'Old account', 'RHB', '800111222333',
          'MYR', 0, 0, false, false)
  returning id into v_shut;

  -- Nothing named: the DEFAULT, and not merely the oldest active one.
  -- The savings account is made the default while the current account
  -- -- created first, so first in any unordered walk -- is not. A
  -- fallback that ignored `is_default` would bank the money in the
  -- current account, which is the plausible wrong answer rather than an
  -- obviously wrong one.
  update public.bank_accounts set is_default = false where id = v_main;
  update public.bank_accounts set is_default = true  where id = v_second;
  v_inv := pg_temp.gs_invoice(v_org, 'INV-BK0', 50);
  v_batch := public.record_group_payment(
    current_date, 'R0', jsonb_build_array(pg_temp.gs_line(v_inv, 50)));
  perform pg_temp.check_true(
    'the default account is chosen, not the oldest one',
    (select bank_account_id = v_second from public.receipts
      where batch_id = v_batch));
  update public.bank_accounts set is_default = false where id = v_second;
  update public.bank_accounts set is_default = true  where id = v_main;

  v_inv := pg_temp.gs_invoice(v_org, 'INV-BK1', 100);
  v_batch := public.record_group_payment(
    current_date, 'R1', jsonb_build_array(pg_temp.gs_line(v_inv, 100)));
  perform pg_temp.check_true(
    'with no account named the money lands in the default one',
    (select bank_account_id = v_main from public.receipts
      where batch_id = v_batch));

  -- Named: the caller's choice wins over the default. A practice that
  -- banks a client's money in the client account must not have it
  -- silently moved to the office account.
  v_inv := pg_temp.gs_invoice(v_org, 'INV-BK2', 200);
  v_batch := public.record_group_payment(
    current_date, 'R2',
    jsonb_build_array(pg_temp.gs_line(v_inv, 200, null, v_second)));
  perform pg_temp.check_true(
    'and an account that is named is the one used, default or not',
    (select bank_account_id = v_second from public.receipts
      where batch_id = v_batch));

  -- The default made inactive. A closed account must not take the
  -- money: nothing would reconcile against it again.
  update public.bank_accounts set is_default = false where id = v_main;
  update public.bank_accounts set is_default = true, is_active = false
   where id = v_shut;
  v_inv := pg_temp.gs_invoice(v_org, 'INV-BK3', 300);
  v_batch := public.record_group_payment(
    current_date, 'R3', jsonb_build_array(pg_temp.gs_line(v_inv, 300)));
  perform pg_temp.check_true(
    'a closed account is not chosen even when it is the default',
    (select bank_account_id is distinct from v_shut from public.receipts
      where batch_id = v_batch));

  raise notice 'the bank fallback: default, named, and closed';
end $$;

-- ---------------------------------------------------------------------
-- 5. A transfer entered days after it cleared
-- ---------------------------------------------------------------------
-- Every payment in the existing file is made today, so `p_paid_on` and
-- `current_date` are the same date and three separate uses of the
-- former could be swapped for the latter unnoticed: the receipt's own
-- date, the date each allocation is recorded at, and -- the one that
-- moves money -- the date the exchange rate is read on.
--
-- Entering a transfer after the fact is the normal way this is used: a
-- bookkeeper reconciles the bank on Friday and enters what cleared on
-- Monday.
do $$
declare
  v_org uuid := pg_temp.gs_org('Kemudian Sdn Bhd');
  v_inv uuid; v_batch uuid; v_rec public.receipts;
  v_then date := current_date - 30;
begin
  -- The rate on the day it cleared, and a different one since.
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.10, v_then, 'manual'),
         (v_org, 'USD', 'MYR', 4.80, current_date, 'manual');

  v_inv := pg_temp.gs_invoice(v_org, 'INV-USD', 1000, 'CUST', true,
                              'USD', 4.10, v_then);

  v_batch := public.record_group_payment(
    v_then, 'REF-LATE', jsonb_build_array(pg_temp.gs_line(v_inv, 1000)));
  select * into v_rec from public.receipts where batch_id = v_batch;

  perform pg_temp.check_eq('the receipt is dated the day the money moved',
    v_rec.receipt_date::text, v_then::text);
  -- The rate is the one that stood when it cleared. Read today it would
  -- be 4.80, and RM700 of exchange difference would appear from nowhere.
  perform pg_temp.check_eq('at the rate that stood on that day',
    v_rec.exchange_rate, 4.10);
  perform pg_temp.check_eq('so it is RM4,100 in the books, not RM4,800',
    round(v_rec.amount * v_rec.exchange_rate, 2), 4100);
end $$;

-- The allocation's own date is the harder half, because `allocated_at`
-- is a timestamp of when the row was written -- it is `p_as_at` that
-- decides whether a SETTLEMENT DISCOUNT was still on offer. So the
-- assertion has to be one where the window is open on the day the money
-- moved and shut by the day it was typed in.
--
-- Five per cent in ten days, net thirty: an invoice raised thirty days
-- ago, paid within its ten days, entered today. Read on today's date
-- the discount is a fortnight out of time and the whole payment is
-- refused.
do $$
declare
  v_org  uuid := pg_temp.gs_org('Diskaun Lewat Sdn Bhd');
  v_term uuid; v_inv uuid; v_batch uuid;
  v_raised date := current_date - 28;
  v_paid   date := current_date - 20;
begin
  insert into public.payment_terms
    (org_id, code, name, days, term_type, discount_percent, discount_days)
  values (v_org, '5-10-N30', 'Five per cent in ten days, net thirty',
          30, 'net', 5, 10)
  returning id into v_term;

  v_inv := pg_temp.gs_invoice(v_org, 'INV-DISC', 1000, 'CUST', false,
                              'MYR', 1, v_raised);
  update public.sales_documents set payment_term_id = v_term where id = v_inv;
  perform public.post_sales_document(v_inv);

  -- Paid on day eight of ten. RM950 of cash and RM50 of discount settle
  -- the thousand.
  v_batch := public.record_group_payment(
    v_paid, 'REF-DISC',
    jsonb_build_array(pg_temp.gs_line(v_inv, 950, 50)));

  perform pg_temp.check_eq('a discount taken inside its window is allowed',
    (select amount from public.receipts where batch_id = v_batch), 950);
  perform pg_temp.check_eq('and the fifty settles the rest of the invoice',
    (select balance_amount from public.sales_documents where id = v_inv), 0);
  perform pg_temp.check_eq('with the discount recorded against the allocation',
    (select discount_amount from public.payment_allocations
      where invoice_id = v_inv), 50);
  -- The window really is shut by now, which is what makes the assertion
  -- above about the DAY and not about the discount.
  perform pg_temp.check_true('and the ten days are long past today',
    current_date > v_raised + 10);
end $$;

-- ---------------------------------------------------------------------
-- 6. What the shared row keeps
-- ---------------------------------------------------------------------
-- The batch is the only row several companies' staff can all see, so
-- what it stores is a decision. A reference typed with a stray space is
-- the same reference; a note left blank is no note at all, not an empty
-- string that reads as one in a list.
do $$
declare
  v_org uuid := pg_temp.gs_org('Rujukan Sdn Bhd');
  v_inv uuid; v_batch uuid; v_b public.payment_batches;
begin
  v_inv := pg_temp.gs_invoice(v_org, 'INV-R', 100);
  v_batch := public.record_group_payment(
    current_date, '  TT-99881  ',
    jsonb_build_array(pg_temp.gs_line(v_inv, 100)), '   ');

  select * into v_b from public.payment_batches where id = v_batch;
  perform pg_temp.check_eq('the reference keeps its characters and not its spaces',
    v_b.reference, 'TT-99881');
  perform pg_temp.check_true('and a note of spaces is no note',
    v_b.note is null);
  -- The receipt carries the same trimmed reference, because that is
  -- what somebody matches against the bank statement.
  perform pg_temp.check_eq('and the receipt quotes it the same way',
    (select reference from public.receipts where batch_id = v_batch),
    'TT-99881');

  -- A reference of nothing at all is stored as nothing, not as ''.
  v_inv := pg_temp.gs_invoice(v_org, 'INV-R2', 100);
  v_batch := public.record_group_payment(
    current_date, '', jsonb_build_array(pg_temp.gs_line(v_inv, 100)));
  perform pg_temp.check_true('and an empty reference is null, not blank',
    (select reference is null from public.payment_batches where id = v_batch));
end $$;

-- =====================================================================
-- 7. The survivors that are equivalent, and the rules they lean on
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.gs_org('Setara Bayaran Sdn Bhd');
  v_inv uuid; v_batch uuid;
begin
  v_inv := pg_temp.gs_invoice(v_org, 'INV-EQ', 100);

  -- (a) `case when g.currency = app.base_currency(g.org_id) then 1 else
  -- app.exchange_rate_for(...) end` tests base currency twice: the
  -- callee opens with `if p_currency is null or p_currency = v_base
  -- then return 1`. Remove the outer test and a ringgit receipt in a
  -- ringgit company still gets 1 -- WITHOUT a rate row existing, which
  -- is the part that could have failed.
  perform pg_temp.check_eq(
    'the rate lookup answers one for the base currency, with no rate on file',
    app.exchange_rate_for(v_org, 'MYR', current_date), 1);
  perform pg_temp.check_eq('and nothing in the table says so',
    (select count(*)::integer from public.exchange_rates
      where org_id = v_org and from_currency = 'MYR'), 0);

  -- (a2) `coalesce(p_lines, '[]'::jsonb)` in the parser is belt over
  -- two braces. `record_group_payment` refuses a null payload several
  -- lines before the parser is reached, and `jsonb_to_recordset` is
  -- strict anyway -- given null it returns no rows rather than raising.
  -- So the coalesce cannot change an answer. What it documents is the
  -- contract, and the contract is what is asserted.
  perform pg_temp.check_eq('the line parser reads nothing as no lines',
    (select count(*)::integer from app.group_payment_lines(null)), 0);
  perform pg_temp.check_eq('and an empty list the same way',
    (select count(*)::integer from app.group_payment_lines('[]'::jsonb)), 0);

  -- (a3) THE DISCOUNT'S ROUNDING AND THE OVERPAYMENT GUARD'S ARE A
  -- MUTUALLY-MASKING PAIR -- the fifth this campaign has met.
  --
  --     round(coalesce(x.discount, 0), 2)          -- in the parser
  --     round(amount + discount, 2) > round(balance, 2)  -- in the guard
  --
  -- The parser rounds the discount before the guard ever sees it, so
  -- the guard's own `round` has nothing left to do; and the guard
  -- rounds the sum, so the parser's rounding of the discount changes no
  -- comparison. Delete either and the other still answers. What is
  -- STORED is rounded by `payment_allocations.discount_amount`, which
  -- has a scale of its own -- so nothing observable moves either way.
  --
  -- The rule underneath all three is the same one: money is kept to the
  -- sen, in the columns as well as in the arithmetic.
  perform pg_temp.check_eq('a discount is stored to the sen',
    (select numeric_scale::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'payment_allocations'
        and column_name = 'discount_amount'), 2);
  perform pg_temp.check_eq('and so is the cash beside it',
    (select numeric_scale::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'payment_allocations'
        and column_name = 'amount'), 2);

  -- (b) `g.bank is distinct from g.bank_hi` versus a plain `<>`. The
  -- two differ only when exactly one side is null, and the group's two
  -- sides are `min(...)` and `max(...)` over the same column --
  -- aggregates that IGNORE nulls. So one side can be null only when
  -- both are, and the guard reads the same either way.
  --
  -- What that means in practice is worth writing down rather than
  -- leaving to be discovered: when one line of a company's share names
  -- an account and another leaves it blank, min and max both return the
  -- named one, no refusal is raised, and the named account takes the
  -- whole of that company's money.
  v_inv := pg_temp.gs_invoice(v_org, 'INV-MIX1', 100);
  declare
    v_inv2 uuid := pg_temp.gs_invoice(v_org, 'INV-MIX2', 200);
    v_bank uuid := pg_temp.gs_bank(v_org, 'Current account');
  begin
    v_batch := public.record_group_payment(
      current_date, 'MIX',
      jsonb_build_array(
        pg_temp.gs_line(v_inv, 100, null, v_bank),
        pg_temp.gs_line(v_inv2, 200)));
    perform pg_temp.check_eq(
      'a line naming an account and one leaving it blank is one receipt',
      (select count(*)::integer from public.receipts where batch_id = v_batch), 1);
    perform pg_temp.check_true('landing in the account that was named',
      (select bank_account_id = v_bank from public.receipts
        where batch_id = v_batch));
    perform pg_temp.check_eq('for the whole of that company''s share',
      (select amount from public.receipts where batch_id = v_batch), 300);
  end;
end $$;

-- ---------------------------------------------------------------------
-- 8. Where the sen actually goes missing
-- ---------------------------------------------------------------------
-- One line of a third of a ringgit does NOT reach the rounding, because
-- `receipts.amount` is numeric(18,2) and the column rounds what the
-- function did not. Three lines do: rounded first they come to
-- RM999.99, and left alone they come to RM1,000.00 -- so the receipt
-- would be banked a sen larger than the allocations that make it up,
-- and the invoice would be settled by money nobody transferred.
--
-- Same blind spot the withholding sweep recorded: a column with a scale
-- hides a missing `round` until something adds the parts up.
do $$
declare
  v_org uuid := pg_temp.gs_org('Tiga Bahagi Sdn Bhd');
  v_a uuid; v_b uuid; v_c uuid; v_batch uuid; v_rec public.receipts;
begin
  v_a := pg_temp.gs_invoice(v_org, 'INV-T1', 400);
  v_b := pg_temp.gs_invoice(v_org, 'INV-T2', 400);
  v_c := pg_temp.gs_invoice(v_org, 'INV-T3', 400);

  v_batch := public.record_group_payment(
    current_date, 'THIRDS',
    jsonb_build_array(
      pg_temp.gs_line(v_a, 1000.0 / 3),
      pg_temp.gs_line(v_b, 1000.0 / 3),
      pg_temp.gs_line(v_c, 1000.0 / 3)));

  select * into v_rec from public.receipts where batch_id = v_batch;
  perform pg_temp.check_eq(
    'three thirds of a thousand ringgit come to 999.99, not 1000.00',
    v_rec.amount, 999.99);
  -- The assertion that makes it matter: the receipt equals the sum of
  -- what it settled. A sen either side and the bank does not agree with
  -- the ledger.
  perform pg_temp.check_eq('and the receipt is exactly what it settled',
    (select sum(amount) from public.payment_allocations
      where receipt_id = v_rec.id), v_rec.amount);
  perform pg_temp.check_eq('leaving three invoices owing 66.67 each',
    (select sum(balance_amount) from public.sales_documents
      where org_id = v_org), 200.01);
end $$;

-- The discount half, and the comparison the overpayment guard makes.
-- An invoice of RM100 offered RM99.995 of cash and RM0.005 of discount
-- is, unrounded, exactly RM100 -- and rounded to the sen it is RM100.01,
-- a sen more than is owed. The `round(...)` on BOTH sides of that
-- comparison is what decides which answer the customer gets.
do $$
declare
  v_org  uuid := pg_temp.gs_org('Bandingan Sdn Bhd');
  v_term uuid; v_inv uuid; v_other uuid; v_batch uuid;
begin
  -- A discount can only be taken where the terms offer one, so the
  -- rounding of the discount is only reachable through a term that
  -- does. Ten per cent in thirty days.
  insert into public.payment_terms
    (org_id, code, name, days, term_type, discount_percent, discount_days)
  values (v_org, '10-30-N60', 'Ten per cent in thirty days', 60, 'net', 10, 30)
  returning id into v_term;

  v_inv := pg_temp.gs_invoice(v_org, 'INV-CMP', 100, 'CUST', false);
  update public.sales_documents set payment_term_id = v_term where id = v_inv;
  perform public.post_sales_document(v_inv);

  -- 99.995 rounds to 100.00 and 0.005 rounds to 0.01, so the two
  -- together are a sen more than the hundred that is owed. Compared
  -- unrounded they are exactly a hundred and the overpayment goes
  -- through.
  perform pg_temp.check_refused(
    'a sen over the balance is over the balance, however it was typed',
    format($q$ select public.record_group_payment(current_date, 'R',
                 jsonb_build_array(jsonb_build_object(
                   'invoice_id', %L::uuid,
                   'amount', 99.995, 'discount', 0.005))) $q$, v_inv),
    '%More than is outstanding%', '23514');

  -- And a discount is rounded before it is stored, so no allocation
  -- carries a fraction of a sen into the ledger.
  v_other := pg_temp.gs_invoice(v_org, 'INV-CMP2', 100, 'CUST', false);
  update public.sales_documents set payment_term_id = v_term where id = v_other;
  perform public.post_sales_document(v_other);
  v_batch := public.record_group_payment(
    current_date, 'R2',
    jsonb_build_array(jsonb_build_object(
      'invoice_id', v_other, 'amount', 90.5, 'discount', 9.494)));
  perform pg_temp.check_eq('a discount is kept to the sen',
    (select discount_amount from public.payment_allocations
      where invoice_id = v_other), 9.49);
  perform pg_temp.check_eq('and the cash beside it too',
    (select amount from public.payment_allocations
      where invoice_id = v_other), 90.5);
end $$;

-- ---------------------------------------------------------------------
-- 9. Two suppliers, and two currencies for one payer
-- ---------------------------------------------------------------------
-- The buying side has the same contact filter as the selling side and
-- one supplier per company to test it with. And the currency check
-- groups by BOTH company and contact: without the contact half, one
-- payer settling in ringgit and another in dollars at the same company
-- would be refused as if a single payer had used two currencies.
do $$
declare
  v_org uuid := pg_temp.gs_org('Dua Pembekal Sdn Bhd');
  v_b1 uuid; v_b2 uuid; v_batch uuid;
  v_s1 uuid; v_s2 uuid;
begin
  v_s1 := pg_temp.gs_contact(v_org, 'SUP');
  v_s2 := pg_temp.gs_contact(v_org, 'SUP2');
  v_b1 := pg_temp.gs_bill(v_org, 'BILL-S1', 600, 'SUP');
  v_b2 := pg_temp.gs_bill(v_org, 'BILL-S2', 250, 'SUP2');

  v_batch := public.record_group_payment(
    current_date, 'REF-2S',
    jsonb_build_array(
      pg_temp.gs_bline(v_b1, 600),
      pg_temp.gs_bline(v_b2, 250)));

  perform pg_temp.check_eq('one transfer, two suppliers, two payments',
    (select count(*)::integer from public.purchase_payments
      where batch_id = v_batch), 2);
  perform pg_temp.check_eq('each for what that supplier was owed',
    (select amount from public.purchase_payments
      where batch_id = v_batch and contact_id = v_s1), 600);
  perform pg_temp.check_true(
    'and no payment was applied to the other supplier''s bill',
    not exists (
      select 1 from public.payment_allocations a
        join public.purchase_payments p on p.id = a.payment_id
        join public.purchase_documents d on d.id = a.bill_id
       where p.batch_id = v_batch and d.contact_id <> p.contact_id));
  perform pg_temp.check_eq('and both bills are settled',
    (select sum(balance_amount) from public.purchase_documents
      where org_id = v_org), 0);
end $$;

-- Two payers at one company, one in ringgit and one in dollars. Each is
-- in ONE currency, which is all the rule asks; a check that looked only
-- at the company would see two and refuse a payment that is fine.
do $$
declare
  v_org uuid := pg_temp.gs_org('Dua Mata Wang Sdn Bhd');
  v_myr uuid; v_usd uuid; v_batch uuid;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.20, current_date - 7, 'manual');

  v_myr := pg_temp.gs_invoice(v_org, 'INV-MYR', 500, 'CUST');
  v_usd := pg_temp.gs_invoice(v_org, 'INV-USD2', 200, 'CUST2', true,
                              'USD', 4.20);

  v_batch := public.record_group_payment(
    current_date, 'REF-2CUR',
    jsonb_build_array(
      pg_temp.gs_line(v_myr, 500),
      pg_temp.gs_line(v_usd, 200)));

  perform pg_temp.check_eq(
    'two payers in two currencies at one company is two receipts',
    (select count(*)::integer from public.receipts where batch_id = v_batch), 2);
  perform pg_temp.check_eq('one in ringgit at a rate of one',
    (select exchange_rate from public.receipts
      where batch_id = v_batch and currency = 'MYR'), 1);
  perform pg_temp.check_eq('and one in dollars at the rate on file',
    (select exchange_rate from public.receipts
      where batch_id = v_batch and currency = 'USD'), 4.20);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a group payment is closed to anon',
    not has_function_privilege('anon',
      'public.record_group_payment(date, text, jsonb, text)', 'execute'));
  perform pg_temp.check_true('and so is the batch it writes',
    not has_table_privilege('anon', 'public.payment_batches', 'select'));
  perform pg_temp.check_true('and the line parser is not a client surface',
    not has_function_privilege('anon',
      'app.group_payment_lines(jsonb)', 'execute'));
end $$;

rollback;
