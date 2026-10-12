-- =====================================================================
-- iAkauntan :: a payment is applied by applying it (0815)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payment_allocations.sql
--
-- What a receipt settled is written by the allocate functions, and the
-- discount with it is journalled there. Before `0815` a client could
-- delete an allocation directly: a receipt that settled an invoice with
-- a RM50 settlement discount came apart, the invoice owing RM1,000 again
-- and the receipt RM950 unapplied, while the ledger still said nothing
-- was owed. Asked as the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pa (org uuid, cust uuid, bank uuid, inv uuid, inv2 uuid, rcp uuid);
grant select on t_pa to authenticated;

create or replace function pg_temp.pa_invoice(p_org uuid, p_cust uuid, p_no text, p_term uuid)
returns uuid language plpgsql as $$
declare v_inv uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, payment_term_id)
  values (p_org, 'invoice', p_no, date '2026-03-01', date '2026-03-31', p_cust,
          'MYR', 1, 'draft', p_term)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_inv, 1, 'Sale', 1, 1000);
  perform public.post_sales_document(v_inv);
  return v_inv;
end $$;

do $$
declare
  r      t_pa;
  v_term uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Bayaran Sah Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  r.bank := pg_temp.test_bank_account(r.org, 'Maybank current', 'current', 'MYR', 0, 0, '1234');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Buyer', 'customer') returning id into r.cust;
  insert into public.payment_terms
    (org_id, code, name, days, term_type, discount_percent, discount_days)
  values (r.org, '5-10-N30', 'Five per cent in ten days, net thirty', 30, 'net', 5, 10)
  returning id into v_term;
  r.inv := pg_temp.pa_invoice(r.org, r.cust, 'INV-1', v_term);
  r.inv2 := pg_temp.pa_invoice(r.org, r.cust, 'INV-2', null);

  -- RM950 received inside the ten days: RM1,000 settled with RM50 off.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (r.org, 'RCP-1', date '2026-03-05', r.cust, 950, 950, 'MYR', 1, r.bank)
  returning id into r.rcp;
  perform public.post_receipt(r.rcp);
  perform public.allocate_with_discount(r.rcp, r.inv, 950, 50, date '2026-03-05');

  insert into t_pa select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d     t_pa;
  v_rc2 uuid;
begin
  select * into d from t_pa;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('RM950 and RM50 off settled INV-1',
    (select paid_amount || '/' || status from public.sales_documents where id = d.inv),
    '1000.00/completed');
  perform pg_temp.check_eq('and a member reads what settled it',
    (select amount || '+' || discount_amount from public.payment_allocations
      where receipt_id = d.rcp), '950.00+50.00');

  -- What was measured: the allocation taken away by hand.
  perform pg_temp.check_refused('a receipt''s allocation is not deleted by hand',
    format('delete from public.payment_allocations where receipt_id = %L', d.rcp),
    'permission denied for table payment_allocations', '42501');
  perform pg_temp.check_refused('nor its amount changed',
    format('update public.payment_allocations set amount = 1 where receipt_id = %L', d.rcp),
    'permission denied for table payment_allocations', '42501');
  perform pg_temp.check_refused('nor its discount',
    format('update public.payment_allocations set discount_amount = 0 where receipt_id = %L', d.rcp),
    'permission denied for table payment_allocations', '42501');
  perform pg_temp.check_refused('nor one typed in',
    format($q$insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
              values (%L, %L, %L, 1)$q$, d.org, d.rcp, d.inv2),
    'permission denied for table payment_allocations', '42501');
  perform pg_temp.check_eq('so INV-1 is still settled',
    (select balance_amount from public.sales_documents where id = d.inv), 0::numeric);

  -- The road: a second receipt recorded, applied and posted in one
  -- call, as the receipt screen does since `0832`, by the same client.
  v_rc2 := public.record_settlement(d.org, true, d.cust, 400, date '2026-03-06',
    jsonb_build_array(jsonb_build_object('document_id', d.inv2, 'amount', 400)),
    d.bank, null, null, null, 0, 'MYR', 1, null);
  perform pg_temp.check_eq('a payment is applied through its function',
    (select paid_amount || '/' || status from public.sales_documents where id = d.inv2),
    '400.00/partial');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the allocations',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'payment_allocations'
        and cmd <> 'SELECT'), 0);
end $$;

rollback;
