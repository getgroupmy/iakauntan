-- =====================================================================
-- iAkauntan :: posting is the posting functions' (0837)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posting_is_the_posting_functions.sql
--
-- "Is this in the books?" is asked of `gl_entry_id`, everywhere. Before
-- `0837` a client could set it on a draft: a draft receipt given another
-- document's journal was taken as posted by `0832`'s door and settled an
-- invoice while the receivable stood still, and could then never be
-- posted; a draft invoice given one showed on the customer's open items
-- with nothing in the ledger. Asked as the owner with the role
-- `authenticated`, as every screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pp (org uuid, u uuid, cust uuid, supp uuid, bank uuid,
  wh uuid, item uuid, journal uuid, inv uuid, draft_inv uuid, draft_bill uuid,
  draft_rcp uuid, draft_pay uuid, mo uuid);
grant select on t_pp to authenticated;

-- What the receivable control account says.
create or replace function pg_temp.pp_ar()
returns numeric language sql as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where a.org_id = (select org from t_pp) and a.code = '1210';
$$;
grant execute on function pg_temp.pp_ar() to authenticated;

do $$
declare r t_pp;
begin
  r.u := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.u);
  r.org := pg_temp.test_org('Catat Sendiri Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['inventory', 'manufacturing']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  r.bank := pg_temp.test_bank_account(r.org, 'Maybank current');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'S-1', 'Pembekal', 'supplier') returning id into r.supp;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'KILANG', 'Factory', true) returning id into r.wh;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code)
  values (r.org, 'ROTI', 'Bread', 'stock', true, 'C62') returning id into r.item;

  -- A posted invoice, whose journal is the one borrowed below.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (r.org, 'invoice', 'INV-1', pg_temp.today(), pg_temp.today(), r.cust, 'draft', 'MYR', 1)
  returning id into r.inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (r.org, r.inv, 1, 'item', 'Work', 1, 1000);
  perform public.post_sales_document(r.inv);
  select gl_entry_id into r.journal from public.sales_documents where id = r.inv;
  insert into t_pp select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_pp;
  r record;
  v_ar numeric;
begin
  select * into d from t_pp;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- Drafts of each, as the screens make them.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (d.org, 'invoice', 'INV-D', pg_temp.today(), pg_temp.today(), d.cust, 'draft', 'MYR', 1)
  returning id into d.draft_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price)
  values (d.org, d.draft_inv, 1, 'item', 'More work', 1, 400);
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status, currency, exchange_rate)
  values (d.org, 'bill', 'BILL-D', pg_temp.today(), pg_temp.today(), d.supp, 'draft', 'MYR', 1)
  returning id into d.draft_bill;
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (d.org, 'RCP-D', pg_temp.today(), d.cust, 1000, 1000, 'MYR', 1, d.bank)
  returning id into d.draft_rcp;
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (d.org, 'PAY-D', pg_temp.today(), d.supp, 700, 700, 'MYR', 1, d.bank)
  returning id into d.draft_pay;
  insert into public.manufacturing_orders
    (org_id, order_no, item_id, warehouse_id, quantity)
  values (d.org, 'MO-D', d.item, d.wh, 10)
  returning id into d.mo;

  -- What was measured: a draft receipt given INV-1's journal.
  perform pg_temp.check_refused('a draft receipt is not given another''s journal',
    format('update public.receipts set gl_entry_id = %L, status = ''posted'' where id = %L',
           d.journal, d.draft_rcp),
    'The gl_entry_id of RCP-D is the posting''s: it is set when it is posted, voided or reversed, not by hand.',
    '42501');
  perform pg_temp.check_refused('so 0832''s door still sees it as a draft',
    format('select public.allocate_with_discount(%L, %L, 1000)', d.draft_rcp, d.inv),
    'Receipt RCP-D is not posted yet.%', '23514');

  -- Each posting column on each, alone.
  for r in select * from (values
      ('sales_documents', 'INV-D', d.draft_inv),
      ('purchase_documents', 'BILL-D', d.draft_bill),
      ('receipts', 'RCP-D', d.draft_rcp),
      ('purchase_payments', 'PAY-D', d.draft_pay),
      ('manufacturing_orders', 'MO-D', d.mo)) as t(tbl, no, id)
  loop
    perform pg_temp.check_refused(format('%s: no journal by hand', r.no),
      format('update public.%I set gl_entry_id = %L where id = %L', r.tbl, d.journal, r.id),
      format('The gl_entry_id of %s is the posting''s%%', r.no), '42501');
    perform pg_temp.check_refused(format('%s: no posting date by hand', r.no),
      format('update public.%I set posted_at = now() where id = %L', r.tbl, r.id),
      format('The posted_at of %s is the posting''s%%', r.no), '42501');
    if r.tbl <> 'manufacturing_orders' then
      perform pg_temp.check_refused(format('%s: no poster by hand', r.no),
        format('update public.%I set posted_by = %L where id = %L', r.tbl, d.u, r.id),
        format('The posted_by of %s is the posting''s%%', r.no), '42501');
    end if;
    if r.tbl in ('receipts', 'purchase_payments') then
      perform pg_temp.check_refused(format('%s: no status by hand', r.no),
        format('update public.%I set status = ''posted'' where id = %L', r.tbl, r.id),
        format('The status of %s is the posting''s%%', r.no), '42501');
    end if;
  end loop;

  -- Nor is one recorded already posted.
  perform pg_temp.check_refused('an invoice is not recorded with a journal',
    format($q$insert into public.sales_documents
              (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
               currency, exchange_rate, gl_entry_id)
              values (%L, 'invoice', 'INV-BORN', %L, %L, %L, 'draft', 'MYR', 1, %L)$q$,
           d.org, pg_temp.today(), pg_temp.today(), d.cust, d.journal),
    'INV-BORN starts as a draft. Its gl_entry_id is set when it is posted%', '42501');
  perform pg_temp.check_refused('nor a receipt with a posting date',
    format($q$insert into public.receipts
              (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
               currency, exchange_rate, bank_account_id, posted_at)
              values (%L, 'RCP-BORN', %L, %L, 100, 100, 'MYR', 1, %L, now())$q$,
           d.org, pg_temp.today(), d.cust, d.bank),
    'RCP-BORN starts as a draft. Its posted_at is set when it is posted%', '42501');
  perform pg_temp.check_refused('nor a payment already posted',
    format($q$insert into public.purchase_payments
              (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
               currency, exchange_rate, bank_account_id, status)
              values (%L, 'PAY-BORN', %L, %L, 100, 100, 'MYR', 1, %L, 'posted')$q$,
           d.org, pg_temp.today(), d.supp, d.bank),
    'PAY-BORN starts as a draft. Its status is set when it is posted%', '42501');
  perform pg_temp.check_refused('nor an order',
    format($q$insert into public.manufacturing_orders
              (org_id, order_no, item_id, warehouse_id, quantity, gl_entry_id)
              values (%L, 'MO-BORN', %L, %L, 1, %L)$q$, d.org, d.item, d.wh, d.journal),
    'MO-BORN starts as a draft. Its gl_entry_id is set when it is posted%', '42501');

  -- What the screens write is as before, and the functions post.
  update public.sales_documents set notes = 'Second visit' where id = d.draft_inv;
  update public.manufacturing_orders set status = 'cancelled' where id = d.mo;
  perform pg_temp.check_eq('a draft is still edited, and an order cancelled',
    (select notes from public.sales_documents where id = d.draft_inv)
      || ' / ' || (select status::text from public.manufacturing_orders where id = d.mo),
    'Second visit / cancelled');
  v_ar := pg_temp.pp_ar();
  perform public.post_sales_document(d.draft_inv);
  perform pg_temp.check_true('the invoice is posted by posting it',
    (select gl_entry_id is not null and posted_at is not null and gl_entry_id <> d.journal
       from public.sales_documents where id = d.draft_inv));
  perform pg_temp.check_eq('and the receivable moves with it', pg_temp.pp_ar() - v_ar, 400);
  perform public.record_settlement(d.org, true, d.cust, 1000, pg_temp.today(),
    jsonb_build_array(jsonb_build_object('document_id', d.inv, 'amount', 1000)),
    d.bank, null, null, null, 0, 'MYR', 1, null);
  perform pg_temp.check_eq('and money is recorded, applied and posted by its function',
    (select balance_amount || '/' || status from public.sales_documents where id = d.inv),
    '0.00/completed');
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: every function that posts, voids or reverses is a
-- definer, which runs as the owner at any depth.
do $$
declare d t_pp;
begin
  select * into d from t_pp;
  update public.receipts set posted_at = now()
   where org_id = d.org and receipt_no = 'RCP-D';
  perform pg_temp.check_true('the owner, at the top, is not refused',
    (select posted_at is not null from public.receipts
      where org_id = d.org and receipt_no = 'RCP-D'));
end $$;

rollback;
