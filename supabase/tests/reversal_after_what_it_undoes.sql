-- =====================================================================
-- iAkauntan :: a reversal never comes before what it undoes (0888)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reversal_after_what_it_undoes.sql
--
-- `reverse_gl_entry` took any open-period date, and the voids of a
-- sales document, a deposit and a contra reversed at today -- so a
-- journal could be undone before it was made, and a document dated
-- ahead was voided into the month before its own. Asked as an
-- accountant, with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_rv (org uuid, accountant uuid, both_c uuid, bank uuid,
  item uuid, inv_today uuid, inv_ahead uuid, inv_past uuid, deposit uuid,
  contra uuid, inv_usd uuid);
grant select on t_rv to authenticated;

-- The day a document's journal was reversed on, or 'none'.
create or replace function pg_temp.rv_reversed_on(p_entry uuid)
returns text language sql as $$
  select coalesce((select r.entry_date::text from public.gl_entries r
                    where r.reversed_entry_id = p_entry and r.status = 'posted'),
                  'none');
$$;

create or replace function pg_temp.rv_invoice(p_org uuid, p_no text, p_on date,
  p_contact uuid, p_item uuid, p_amount numeric, p_currency text default 'MYR',
  p_rate numeric default 1)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (p_org, 'invoice', p_no, p_on, p_on + 30, p_contact, p_currency, p_rate, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
  values (p_org, v, 1, 'item', p_item, 'Kerja', 1, p_amount);
  perform public.post_sales_document(v);
  return v;
end $$;

do $$
declare r t_rv; v_bill uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Songsang Bertarikh Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 90);
  r.accountant := pg_temp.another_user('akauntan@songsang.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'BOTH', 'Pelanggan Pembekal', 'both') returning id into r.both_c;
  insert into public.items (org_id, code, name, item_type, track_inventory, unit_price)
  values (r.org, 'KHID', 'Khidmat', 'service', false, 100) returning id into r.item;
  r.bank := pg_temp.test_bank_account(r.org, 'Semasa', 'current', 'MYR', 0, 0, '512345678906');

  r.inv_today := pg_temp.rv_invoice(r.org, 'INV-1', pg_temp.today(), r.both_c, r.item, 1000);
  r.inv_ahead := pg_temp.rv_invoice(r.org, 'INV-2', pg_temp.today() + 20, r.both_c, r.item, 700);
  r.inv_past  := pg_temp.rv_invoice(r.org, 'INV-3', pg_temp.today() - 5, r.both_c, r.item, 300);

  -- A deposit taken ten days on (0887 lets one be dated ahead).
  r.deposit := public.create_deposit(r.org, 'customer', r.both_c, pg_temp.today() + 10,
                 500, r.bank);

  -- A contra dated twenty days on, setting a bill off against INV-1.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BILL-1', pg_temp.today(), r.both_c, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
  values (r.org, v_bill, 1, 'item', r.item, 'Sewa', 1, 200);
  perform public.post_purchase_document(v_bill);
  r.contra := public.create_contra(r.org, pg_temp.today() + 20,
    jsonb_build_array(jsonb_build_object('document', r.inv_today, 'amount', 200)),
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 200)), null);

  -- A dollar invoice, so there is something to revalue.
  insert into public.exchange_rates (org_id, from_currency, to_currency, rate, rate_date, source)
  values (r.org, 'USD', 'MYR', 4.00, pg_temp.today() - 20, 'manual'),
         (r.org, 'USD', 'MYR', 4.40, pg_temp.today() - 5, 'manual'),
         (r.org, 'USD', 'MYR', 4.50, pg_temp.today(), 'manual');
  r.inv_usd := pg_temp.rv_invoice(r.org, 'INV-USD', pg_temp.today() - 15, r.both_c,
                 r.item, 100, 'USD', 4.00);
  insert into t_rv select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_rv));
set local role authenticated;

do $$
declare d t_rv; v_je uuid; v_rev uuid;
begin
  select * into d from t_rv;
  select gl_entry_id into v_je from public.sales_documents where id = d.inv_today;

  -- -------------------------------------------------------------------
  -- By hand: not before the journal
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a journal is not reversed before it was made',
    format('select public.reverse_gl_entry(%L, %L)', v_je, pg_temp.today() - 10),
    'Journal % is dated %, and a reversal cannot come before what it undoes.%', '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.reverse_gl_entry(%L, %L)', v_je, pg_temp.today() - 1),
    'Journal % is dated %, and a reversal cannot come before what it undoes.%', '23514');
  perform pg_temp.check_eq('so it stands',
    pg_temp.rv_reversed_on(v_je), 'none');
  v_rev := public.reverse_gl_entry(v_je, pg_temp.today());
  perform pg_temp.check_eq('it is reversed on its own day',
    pg_temp.rv_reversed_on(v_je), pg_temp.today()::text);

  -- -------------------------------------------------------------------
  -- Voided: on its own day if that is still to come, today if not
  -- -------------------------------------------------------------------
  perform public.void_sales_document(d.inv_ahead, 'Tersilap');
  perform pg_temp.check_eq('an invoice dated ahead is voided on its own day',
    pg_temp.rv_reversed_on((select gl_entry_id from public.sales_documents where id = d.inv_ahead)),
    (pg_temp.today() + 20)::text);
  perform public.void_sales_document(d.inv_past, 'Tersilap');
  perform pg_temp.check_eq('one already dated is voided today, as before',
    pg_temp.rv_reversed_on((select gl_entry_id from public.sales_documents where id = d.inv_past)),
    pg_temp.today()::text);
  perform public.void_deposit(d.deposit, 'Tersilap');
  perform pg_temp.check_eq('a deposit dated ahead is voided on its own day',
    pg_temp.rv_reversed_on((select gl_entry_id from public.deposit_notes where id = d.deposit)),
    (pg_temp.today() + 10)::text);
  perform public.void_contra(d.contra, 'Tersilap');
  perform pg_temp.check_eq('and so is a contra',
    pg_temp.rv_reversed_on((select gl_entry_id from public.contra_notes where id = d.contra)),
    (pg_temp.today() + 20)::text);

  -- -------------------------------------------------------------------
  -- A revaluation is re-measured, not undone
  -- -------------------------------------------------------------------
  v_je := public.revalue_foreign_balances(d.org, pg_temp.today());
  perform public.revalue_foreign_balances(d.org, pg_temp.today() - 5);
  perform pg_temp.check_eq('a revaluation rerun for an earlier day takes the standing one back on that day',
    pg_temp.rv_reversed_on(v_je), (pg_temp.today() - 5)::text);
end $$;

reset role;

rollback;
