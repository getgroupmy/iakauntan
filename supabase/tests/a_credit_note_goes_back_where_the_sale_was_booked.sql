-- =====================================================================
-- iAkauntan :: a credit note goes back where the sale was booked (0924)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_credit_note_goes_back_where_the_sale_was_booked.sql
--
-- Before `0924` `credit_sales_invoice` wrote its credit lines with no
-- account: an invoice of RM100 on a line naming 4150, credited in
-- full, left 4150 at -100 and 4100 at +100. And since `0923` a credit
-- for a document whose line's account had closed was refused outright,
-- with advice the credit door gives nobody the chance to take. As the
-- owner with the role `authenticated`, as the invoice screen credits.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cr (
  org uuid, cust uuid, sup uuid,
  service uuid, gone_rev uuid, special uuid, gone_exp uuid,
  sales uuid, rental uuid, dormant uuid, dormant_inv uuid);
grant select on t_cr to authenticated;

do $$
declare r t_cr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Nota Kredit Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['accounting', 'sales', 'purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '4150', 'Jualan Khidmat', 'revenue', 'sales', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '4100' returning id into r.service;
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '4151', 'Jualan Lama', 'revenue', 'sales', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '4100' returning id into r.gone_rev;
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '6291', 'Belanja Khas', 'expense', 'operating_expense', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '6200' returning id into r.special;
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '6288', 'Belanja Lama', 'expense', 'operating_expense', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '6200' returning id into r.gone_exp;
  select id into r.sales  from public.accounts where org_id = r.org and code = '4100';
  select id into r.rental from public.accounts where org_id = r.org and code = '6200';

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  -- A sale booked to an account that was afterwards only switched off,
  -- which is how one was put out of use before there was a way to
  -- close it. No client can do that now (`0829`), so it is made here.
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '4152', 'Jualan Tidur', 'revenue', 'sales', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '4100' returning id into r.dormant;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'invoice', 'INV-KR-4', pg_temp.today(), pg_temp.today(), r.cust, 'MYR', 1, 'draft')
  returning id into r.dormant_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (r.org, r.dormant_inv, 1, 'item', 'Khidmat tidur', 1, 20, 0, r.dormant);
  perform public.post_sales_document(r.dormant_inv);
  update public.accounts set is_active = false where id = r.dormant;

  insert into t_cr select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- What the posted ledger holds in the accounts asked about.
create or replace function pg_temp.cr_gl(p_org uuid, p_codes text[]) returns text language sql as $$
  select coalesce(string_agg(a.code || ' ' || x.amt::text, ', ' order by a.code), 'nothing')
    from (select l.account_id, sum(l.debit - l.credit) amt
            from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
           where e.org_id = p_org and e.status = 'posted'
           group by l.account_id having sum(l.debit - l.credit) <> 0) x
    join public.accounts a on a.id = x.account_id
   where a.code = any (p_codes);
$$;

-- The accounts a document's lines name, in line order.
create or replace function pg_temp.cr_lines(p_table text, p_doc uuid) returns text language plpgsql as $$
declare v text;
begin
  execute format(
    'select string_agg(coalesce(a.code, ''none''), '', '' order by l.line_no) '
    '  from public.%I l left join public.accounts a on a.id = l.account_id '
    ' where l.document_id = $1', p_table) into v using p_doc;
  return v;
end $$;

do $$
declare
  d t_cr; v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_note uuid; v_line uuid;
  v_bill uuid; v_bill2 uuid;
begin
  select * into d from t_cr;

  -- -------------------------------------------------------------------
  -- A credit in full
  -- -------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-KR-1', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_inv, 1, 'item', 'Khidmat', 1, 100, 0, d.service),
         (d.org, v_inv, 2, 'item', 'Barang', 1, 50, 0, null);
  perform public.post_sales_document(v_inv);
  -- 1210 carries RM20 more than this block puts there: the fixture's
  -- invoice on the switched-off account, credited further down.
  perform pg_temp.check_eq('an invoice books one line to the account it names and one to Sales',
    pg_temp.cr_gl(d.org, array['1210', '4100', '4150']), '1210 170.00, 4100 -50.00, 4150 -100.00');

  v_note := public.credit_sales_invoice(v_inv);
  perform pg_temp.check_eq('its credit note names the same account on the same line, and none on the other',
    pg_temp.cr_lines('sales_document_lines', v_note), '4150, none');
  perform pg_temp.check_eq('and credited in full, every account is back where it started',
    pg_temp.cr_gl(d.org, array['1210', '4100', '4150']), '1210 20.00');

  -- -------------------------------------------------------------------
  -- A credit in part
  -- -------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-KR-2', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_inv2, 1, 'item', 'Khidmat', 4, 25, 0, d.service)
  returning id into v_line;
  perform public.post_sales_document(v_inv2);
  perform public.credit_sales_invoice(v_inv2,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 1)));
  perform pg_temp.check_eq('one of four credited takes a quarter back out of the account, and none out of Sales',
    pg_temp.cr_gl(d.org, array['1210', '4100', '4150']), '1210 95.00, 4150 -75.00');

  -- -------------------------------------------------------------------
  -- A credit for a sale whose account has closed since
  -- -------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-KR-3', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv3;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_inv3, 1, 'item', 'Khidmat lama', 1, 40, 0, d.gone_rev);
  perform public.post_sales_document(v_inv3);
  -- The account's revenue is journalled on to Sales, and it is closed.
  perform public.post_manual_journal(d.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', d.gone_rev, 'debit', 40, 'credit', 0),
      jsonb_build_object('account_id', d.sales, 'debit', 0, 'credit', 40)),
    'Pindah hasil', 'JV-KR-1');
  perform pg_temp.check_eq('an account emptied by journal is closed, though a posted invoice named it',
    public.retire_account(d.gone_rev), 'closed');

  v_note := public.credit_sales_invoice(v_inv3);
  perform pg_temp.check_eq('its credit note is still made, and names no account on that line',
    pg_temp.cr_lines('sales_document_lines', v_note), 'none');
  perform pg_temp.check_eq('so the credit lands in Sales, where the revenue had gone, and none in the closed account',
    pg_temp.cr_gl(d.org, array['1210', '4100', '4151']), '1210 95.00');

  -- And one whose account was only ever switched off: the RM20 stays
  -- where the sale put it, and the credit goes to Sales.
  v_note := public.credit_sales_invoice(d.dormant_inv);
  perform pg_temp.check_eq('a sale on an account since switched off is credited the same way',
    pg_temp.cr_lines('sales_document_lines', v_note) || ' / '
      || pg_temp.cr_gl(d.org, array['1210', '4100', '4152']),
    'none / 1210 75.00, 4100 20.00, 4152 -20.00');

  -- -------------------------------------------------------------------
  -- The purchase side, which carried the account already
  -- -------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-KR-1', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_bill, 1, 'item', 'Belanja', 1, 60, 0, d.special);
  perform public.post_purchase_document(v_bill);
  v_note := public.credit_purchase_bill(v_bill);
  perform pg_temp.check_eq('a bill''s credit note still names the bill line''s account',
    pg_temp.cr_lines('purchase_document_lines', v_note), '6291');
  perform pg_temp.check_eq('and credited in full, the expense and the payable are back where they started',
    pg_temp.cr_gl(d.org, array['2110', '5100', '6291']), 'nothing');

  -- And a bill whose account has closed since: refused outright between
  -- `0923` and `0924`.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-KR-2', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_bill2;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_bill2, 1, 'item', 'Belanja lama', 1, 30, 0, d.gone_exp);
  perform public.post_purchase_document(v_bill2);
  perform public.post_manual_journal(d.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', d.rental, 'debit', 30, 'credit', 0),
      jsonb_build_object('account_id', d.gone_exp, 'debit', 0, 'credit', 30)),
    'Pindah belanja', 'JV-KR-2');
  perform public.retire_account(d.gone_exp);

  v_note := public.credit_purchase_bill(v_bill2);
  perform pg_temp.check_eq('a bill whose account has closed is still credited, its line naming none',
    pg_temp.cr_lines('purchase_document_lines', v_note), 'none');
  perform pg_temp.check_eq('the credit landing in Purchases, as a line with no account does, and none in the closed account',
    pg_temp.cr_gl(d.org, array['2110', '5100', '6200', '6288']), '5100 -30.00, 6200 30.00');
end $$;

reset role;
rollback;
