-- =====================================================================
-- iAkauntan :: money is applied once it is in the books (0832)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/settlement_in_one_go.sql
--
-- The receipt and payment screens recorded a settlement as three
-- requests -- insert a draft, apply it, post it -- and the knock-off
-- functions asked nothing of whether either side was posted. A draft
-- receipt settled a posted invoice the ledger still said was owed; a
-- posted receipt settled a draft invoice into `completed`, past
-- posting. Now `record_settlement` records, applies and posts in one
-- go, and the knock-off refuses anything not in the books. Asked as
-- the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_so (org uuid, cust uuid, supp uuid, bank uuid,
  inv1 uuid, inv2 uuid, inv3 uuid, draft_inv uuid, void_inv uuid,
  bill1 uuid, draft_bill uuid, void_bill uuid, usd_inv uuid, banked uuid,
  inv4 uuid, bill2 uuid, viewer uuid);
grant select on t_so to authenticated;

-- A posted invoice of one line, in ringgit or not.
create or replace function pg_temp.so_inv(p_no text, p_amt numeric,
  p_post boolean default true, p_cur text default 'MYR', p_rate numeric default 1)
returns uuid language plpgsql as $$
declare d t_so; v uuid;
begin
  select * into d from t_so;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.cust, 'draft', p_cur, p_rate)
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (d.org, v, 1, 'item', 'Work', 1, p_amt);
  if p_post then perform public.post_sales_document(v); end if;
  return v;
end $$;

create or replace function pg_temp.so_bill(p_no text, p_amt numeric, p_post boolean default true)
returns uuid language plpgsql as $$
declare d t_so; v uuid;
begin
  select * into d from t_so;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (d.org, 'bill', p_no, pg_temp.today(), pg_temp.today(), d.supp, 'draft', 'MYR', 1)
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, account_id)
  values (d.org, v, 1, 'item', 'Stuff', 1, p_amt,
          (select id from public.accounts where org_id = d.org and code = '6100'));
  if p_post then perform public.post_purchase_document(v); end if;
  return v;
end $$;

-- What the receivable control account says.
create or replace function pg_temp.so_ar()
returns numeric language sql as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where a.org_id = (select org from t_so) and a.code = '1210';
$$;
grant execute on function pg_temp.so_ar() to authenticated;

do $$
declare r t_so;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Bayar Sekali Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  r.bank := pg_temp.test_bank_account(r.org, 'Maybank current');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'S-1', 'Pembekal', 'supplier') returning id into r.supp;
  insert into public.exchange_rates (org_id, from_currency, to_currency, rate, rate_date, source)
  values (r.org, 'USD', 'MYR', 4.50, pg_temp.today(), 'manual');
  -- Somebody who may look at the books and not write them.
  r.viewer := pg_temp.another_user('lihat@bayarsekali.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (r.org, r.viewer, 'viewer', 'active', now());
  insert into t_so select r.*;
end $$;

-- The documents, posted and not, made as the invoice and bill screens
-- make them. A voided invoice through its function; a voided bill, which
-- no function makes today, by the session.
do $$
declare v uuid;
begin
  update t_so set inv1 = pg_temp.so_inv('INV-1', 1000),
                  inv2 = pg_temp.so_inv('INV-2', 500),
                  inv3 = pg_temp.so_inv('INV-3', 300),
                  draft_inv = pg_temp.so_inv('INV-DRAFT', 400, false),
                  void_inv = pg_temp.so_inv('INV-VOID', 200),
                  bill1 = pg_temp.so_bill('BILL-1', 700),
                  draft_bill = pg_temp.so_bill('BILL-DRAFT', 600, false),
                  void_bill = pg_temp.so_bill('BILL-VOID', 100),
                  usd_inv = pg_temp.so_inv('INV-USD', 1000, true, 'USD', 4.40),
                  inv4 = pg_temp.so_inv('INV-4', 400),
                  bill2 = pg_temp.so_bill('BILL-2', 250);
  perform public.void_sales_document((select void_inv from t_so), 'Raised in error');
  update public.purchase_documents set status = 'void' where id = (select void_bill from t_so);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d     t_so;
  v_rcp uuid;
  v_pay uuid;
  v_ar  numeric;
  v_n   integer;
begin
  select * into d from t_so;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- What was measured: a receipt recorded but never posted, applied.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (d.org, 'RCP-DRAFT', pg_temp.today(), d.cust, 1000, 1000, 'MYR', 1, d.bank)
  returning id into v_rcp;
  perform pg_temp.check_refused('a receipt not yet posted is not applied',
    format('select public.allocate_with_discount(%L, %L, 1000)', v_rcp, d.inv1),
    'Receipt RCP-DRAFT is not posted yet. Post it, then apply it%', '23514');
  perform pg_temp.check_eq('so INV-1 is still owed in full',
    (select balance_amount || '/' || status from public.sales_documents where id = d.inv1),
    '1000.00/posted');

  -- Posted, it applies -- to a posted invoice, not a draft or a void one.
  perform public.post_receipt(v_rcp);
  perform pg_temp.check_refused('nor is money applied to an invoice not yet posted',
    format('select public.allocate_with_discount(%L, %L, 400)', v_rcp, d.draft_inv),
    'INV-DRAFT is not posted yet. Post it, then apply money to it.', '23514');
  perform pg_temp.check_eq('which stays a draft',
    (select status::text from public.sales_documents where id = d.draft_inv), 'draft');
  perform pg_temp.check_refused('nor to one voided',
    format('select public.allocate_with_discount(%L, %L, 200)', v_rcp, d.void_inv),
    'INV-VOID has been voided, and is owed by nobody.', '23514');
  perform public.allocate_with_discount(v_rcp, d.inv1, 1000);
  perform pg_temp.check_eq('money in the books applies to an invoice in the books',
    (select balance_amount || '/' || status from public.sales_documents where id = d.inv1),
    '0.00/completed');

  -- The supplier side, the same three ways.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (d.org, 'PAY-DRAFT', pg_temp.today(), d.supp, 700, 700, 'MYR', 1, d.bank)
  returning id into v_pay;
  perform pg_temp.check_refused('a payment not yet posted is not applied',
    format('select public.allocate_payment_with_discount(%L, %L, 700)', v_pay, d.bill1),
    'Payment PAY-DRAFT is not posted yet. Post it, then apply it%', '23514');
  perform public.post_purchase_payment(v_pay);
  perform pg_temp.check_refused('nor money applied to a bill not yet posted',
    format('select public.allocate_payment_with_discount(%L, %L, 600)', v_pay, d.draft_bill),
    'BILL-DRAFT is not posted yet. Post it, then apply money to it.', '23514');
  perform pg_temp.check_refused('nor to one voided',
    format('select public.allocate_payment_with_discount(%L, %L, 100)', v_pay, d.void_bill),
    'BILL-VOID has been voided, and is owed to nobody.', '23514');
  perform public.allocate_payment_with_discount(v_pay, d.bill1, 700);
  perform pg_temp.check_eq('a posted payment applies to a posted bill',
    (select balance_amount || '/' || status from public.purchase_documents where id = d.bill1),
    '0.00/completed');

  -- The screens' one call: recorded, applied and posted together.
  v_ar := pg_temp.so_ar();
  v_rcp := public.record_settlement(d.org, true, d.cust, 800, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('document_id', d.inv2, 'amount', 500),
      jsonb_build_object('document_id', d.inv3, 'amount', 300)),
    d.bank, null, null, 'TT 0912', 0, 'MYR', 1, 'SETTLE-1');
  perform pg_temp.check_true('record_settlement posts the receipt',
    (select gl_entry_id is not null and unapplied_amount = 0
       from public.receipts where id = v_rcp));
  perform pg_temp.check_eq('and settles both invoices',
    (select string_agg(status::text, ',' order by doc_no)
       from public.sales_documents where id in (d.inv2, d.inv3)), 'completed,completed');
  perform pg_temp.check_eq('and the ledger says the same: RM800 less receivable',
    v_ar - pg_temp.so_ar(), 800::numeric);

  -- A retry is the same settlement.
  perform pg_temp.check_eq('a retry with the same key is the same receipt',
    public.record_settlement(d.org, true, d.cust, 800, pg_temp.today(),
      jsonb_build_array(
        jsonb_build_object('document_id', d.inv2, 'amount', 500),
        jsonb_build_object('document_id', d.inv3, 'amount', 300)),
      d.bank, null, null, 'TT 0912', 0, 'MYR', 1, 'SETTLE-1'), v_rcp);
  perform pg_temp.check_eq('and records nothing twice',
    (select count(*)::integer from public.receipts where org_id = d.org and reference = 'TT 0912'), 1);

  -- Refused at the posting, it leaves nothing applied: a date in no
  -- open period.
  select count(*) into v_n from public.receipts where org_id = d.org;
  perform pg_temp.check_refused('a settlement the ledger will not post is refused whole',
    format($q$select public.record_settlement(%L, true, %L, 400, date '2001-01-15',
                jsonb_build_array(jsonb_build_object('document_id', %L, 'amount', 400)),
                %L, null, null, null, 0, 'MYR', 1, null)$q$, d.org, d.cust, d.inv4, d.bank),
    'No fiscal period covers 2001-01-15.%', '23514');
  perform pg_temp.check_eq('so no receipt is left behind',
    (select count(*)::integer from public.receipts where org_id = d.org), v_n);
  perform pg_temp.check_eq('and INV-4 is still owed in full',
    (select balance_amount || '/' || status from public.sales_documents where id = d.inv4),
    '400.00/posted');

  -- Applied before it is posted, because posting reads what was applied
  -- to work out the exchange difference: USD 1,000 invoiced at 4.40 and
  -- received at 4.50 is a RM100 gain.
  v_rcp := public.record_settlement(d.org, true, d.cust, 1000, pg_temp.today(),
    jsonb_build_array(jsonb_build_object('document_id', d.usd_inv, 'amount', 1000)),
    d.bank, null, null, null, 0, 'USD', 4.50, null);
  perform pg_temp.check_eq('a foreign settlement books its exchange difference',
    (select fx_gain_loss from public.receipts where id = v_rcp), 100::numeric);

  -- The supplier side of the one call.
  v_pay := public.record_settlement(d.org, false, d.supp, 250, pg_temp.today(),
    jsonb_build_array(jsonb_build_object('document_id', d.bill2, 'amount', 250)),
    d.bank, null, null, null, 0, 'MYR', 1, null);
  perform pg_temp.check_eq('a supplier payment is recorded, applied and posted in one call',
    (select (p.gl_entry_id is not null) || '/' || b.status
       from public.purchase_payments p, public.purchase_documents b
      where p.id = v_pay and b.id = d.bill2), 'true/completed');

  -- And only by somebody who may write the books.
  perform set_config('request.jwt.claims',
    json_build_object('sub', d.viewer, 'role', 'authenticated')::text, true);
  perform pg_temp.check_refused('somebody who may only look does not record one',
    format($q$select public.record_settlement(%L, true, %L, 400, %L,
                jsonb_build_array(jsonb_build_object('document_id', %L, 'amount', 400)),
                %L, null, null, null, 0, 'MYR', 1, null)$q$,
           d.org, d.cust, pg_temp.today(), d.inv4, d.bank),
    'Not permitted to record a receipt here.', '42501');
end $$;

rollback;
