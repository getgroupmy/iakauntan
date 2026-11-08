-- =====================================================================
-- iAkauntan :: stock is kept in 1310 (0915)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/stock_is_kept_in_1310.sql
--
-- Receiving and adjusting post to an item's own stock account; selling,
-- transferring, making and landing costs post to 1310 by number.
-- Before `0915` an item given 1320 took ten in on 1320 and, sold, out
-- of 1310: 1310 at -250 and 1320 at 250 with nothing on hand. As the
-- owner with the role `authenticated`, and once as the database's
-- owner: the rule is for every writer.
--
-- Every account named here is a different row from 1310, and the other
-- company's 1310 is a different row from this one's.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_sk (org uuid, other uuid, sup uuid, cust uuid, item uuid, legacy uuid,
                             wh uuid, inv uuid, transit uuid, other_inv uuid);
grant select on t_sk to authenticated;

do $$
declare r t_sk;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Stok Satu Sdn Bhd');
  r.other := pg_temp.test_org('Stok Lain Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['sales', 'purchases', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal Stok', 'supplier') returning id into r.sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan Stok', 'customer') returning id into r.cust;
  select id into r.inv       from public.accounts where org_id = r.org   and code = '1310';
  select id into r.transit   from public.accounts where org_id = r.org   and code = '1320';
  select id into r.other_inv from public.accounts where org_id = r.other and code = '1310';
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'BRG', 'Barang', 'stock', true, 'C62', 40) returning id into r.item;

  -- An item that named 1320 before the rule, as an import could have
  -- left one.
  alter table public.items disable trigger stock_is_kept_in_1310;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code,
                            unit_price, inventory_account_id)
  values (r.org, 'LAMA', 'Barang Lama', 'stock', true, 'C62', 40, r.transit)
  returning id into r.legacy;
  alter table public.items enable trigger stock_is_kept_in_1310;
  insert into t_sk select r.*;
end $$;

set local role authenticated;

create or replace function pg_temp.sk_gl(p_org uuid) returns text language sql as $$
  select string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code)
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id;
$$;

do $$
declare d t_sk; v uuid;
begin
  select * into d from t_sk;

  -- -------------------------------------------------------------------
  -- An item's stock is in 1310
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an item''s stock account is not moved to 1320',
    format('update public.items set inventory_account_id = %L where id = %L', d.transit, d.item),
    'Barang (BRG) keeps its stock in 1310, not in 1320 Goods in Transit: selling, transferring%',
    '23514');
  perform pg_temp.check_refused('nor does an item arrive naming it',
    format('insert into public.items (org_id, code, name, item_type, track_inventory, uom_code,
              unit_price, inventory_account_id) values (%L, %L, %L, %L, true, %L, 40, %L)',
           d.org, 'BARU', 'Barang Baru', 'stock', 'C62', d.transit),
    'Barang Baru (BARU) keeps its stock in 1310, not in 1320 Goods in Transit:%', '23514');
  -- The tenant foreign key refuses this as well, after the trigger: the
  -- mutant sweep's "another company's 1310 will do" is caught here only
  -- by which refusal speaks, so the company check is a second lock, not
  -- the only one.
  perform pg_temp.check_refused('nor is it another company''s 1310',
    format('update public.items set inventory_account_id = %L where id = %L', d.other_inv, d.item),
    'Barang (BRG) keeps its stock in 1310, not in an account of another company%', '23514');

  update public.items set inventory_account_id = d.inv where id = d.item;
  perform pg_temp.check_eq('naming 1310 itself stands',
    (select inventory_account_id from public.items where id = d.item), d.inv);
  update public.items set inventory_account_id = null where id = d.item;
  perform pg_temp.check_true('and so does naming none',
    (select inventory_account_id is null from public.items where id = d.item));

  -- An item that already names 1320 is still written, the account
  -- sent back unchanged with the rest of it, as an import re-sends it.
  update public.items set name = 'Barang Lama Bhd', inventory_account_id = d.transit
   where id = d.legacy;
  perform pg_temp.check_eq('an item already naming 1320 is still written',
    (select name from public.items where id = d.legacy), 'Barang Lama Bhd');

  -- -------------------------------------------------------------------
  -- So the goods go in and out of the same account
  -- -------------------------------------------------------------------
  update public.items set inventory_account_id = d.inv where id = d.item;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-SK', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', d.item, 'Barang', 10, 25, d.wh, 0);
  perform public.post_purchase_document(v);
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-SK', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price, warehouse_id, tax_rate)
  values (d.org, v, 1, 'item', d.item, 'Barang', 10, 40, d.wh, 0);
  perform public.post_sales_document(v);
  perform pg_temp.check_eq('bought and sold, the stock account is back at nothing',
    pg_temp.sk_gl(d.org), '1210 400.00, 2110 -250.00, 4100 -400.00, 5200 250.00');
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.items set inventory_account_id = %L where id = %L',
         (select transit from t_sk), (select item from t_sk)),
  'Barang (BRG) keeps its stock in 1310%', '23514');

rollback;
