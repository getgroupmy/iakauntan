-- =====================================================================
-- iAkauntan :: a cheque comes back after it came in (0892)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/cheque_comes_back_after.sql
--
-- `bounce_pdc` took any date: a cheque could come back before it was
-- received, and a deposited one before it was paid in. Asked as an
-- accountant, with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ca (org uuid, accountant uuid, held uuid, paid_in uuid,
  issued uuid);
grant select on t_ca to authenticated;

-- What a cheque says about itself, days counted from today.
create or replace function pg_temp.ca_state(p_cheque uuid)
returns text language sql as $$
  select status::text || ' bounced ' || coalesce((bounced_on - pg_temp.today())::text, '-')
    from public.post_dated_cheques where id = p_cheque;
$$;

-- The days its two journals are dated, from today: taken, and returned.
create or replace function pg_temp.ca_journals(p_cheque uuid)
returns text language sql as $$
  select coalesce((select (e.entry_date - pg_temp.today())::text
                     from public.gl_entries e where e.id = c.gl_entry_id), 'none')
         || ' then ' ||
         coalesce((select (e.entry_date - pg_temp.today())::text
                     from public.gl_entries e where e.id = c.bounce_entry_id), 'none')
    from public.post_dated_cheques c where c.id = p_cheque;
$$;

do $$
declare r t_ca; v_both uuid; v_bank uuid; v_item uuid; v_inv uuid; v_bill uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Cek Kembali Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 60, pg_temp.today() + 90);
  r.accountant := pg_temp.another_user('akauntan@cekkembali.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'BOTH', 'Rakan Niaga', 'both') returning id into v_both;
  insert into public.items (org_id, code, name, item_type, track_inventory, unit_price)
  values (r.org, 'KHID', 'Khidmat', 'service', false, 100) returning id into v_item;
  v_bank := pg_temp.test_bank_account(r.org, 'Semasa', 'current', 'MYR', 0, 0, '512345678908');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'invoice', 'INV-1', pg_temp.today() - 30, pg_temp.today(), v_both, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
  values (r.org, v_inv, 1, 'item', v_item, 'Kerja', 1, 400);
  perform public.post_sales_document(v_inv);
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BILL-1', pg_temp.today() - 30, v_both, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
  values (r.org, v_bill, 1, 'item', v_item, 'Sewa', 1, 300);
  perform public.post_purchase_document(v_bill);

  -- Received five days ago, dated ten days on, settling INV-1.
  r.held := public.record_pdc(r.org, 'incoming', v_both, '700001',
    pg_temp.today() + 10, 400,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 400)),
    v_bank, 'CIMB', pg_temp.today() - 5);
  -- Received twenty days ago, dated yesterday, paid in today.
  r.paid_in := public.record_pdc(r.org, 'incoming', v_both, '700002',
    pg_temp.today() - 1, 200, '[]'::jsonb, v_bank, 'CIMB', pg_temp.today() - 20);
  perform public.deposit_pdc(r.paid_in, pg_temp.today());
  -- Ours, written five days ago for BILL-1, dated ten days on.
  r.issued := public.record_pdc(r.org, 'outgoing', v_both, '800001',
    pg_temp.today() + 10, 300,
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 300)),
    v_bank, 'MBB', pg_temp.today() - 5);
  insert into t_ca select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_ca));
set local role authenticated;

do $$
declare d t_ca;
begin
  select * into d from t_ca;

  -- -------------------------------------------------------------------
  -- Not before it was received
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a cheque does not come back before it was received',
    format('select public.bounce_pdc(%L, %L, %L)', d.held, 'Refer to drawer', pg_temp.today() - 20),
    format('Cheque 700001 was received on %s, and cannot have come back before it was.',
           to_char(pg_temp.today() - 5, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.bounce_pdc(%L, %L, %L)', d.held, 'Refer to drawer', pg_temp.today() - 6),
    format('Cheque 700001 was received on %s, and cannot have come back before it was.',
           to_char(pg_temp.today() - 5, 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_eq('so it is still held',
    pg_temp.ca_state(d.held), 'held bounced -');
  perform public.bounce_pdc(d.held, 'Stopped by the drawer', pg_temp.today() - 5);
  perform pg_temp.check_eq('it can come back the day it was received, before its own date',
    pg_temp.ca_state(d.held), 'bounced bounced -5');
  perform pg_temp.check_eq('and the returned journal is not before the one it undoes',
    pg_temp.ca_journals(d.held), '-5 then -5');

  -- -------------------------------------------------------------------
  -- Once paid in, not before that day
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a cheque paid in does not come back before it was',
    format('select public.bounce_pdc(%L, %L, %L)', d.paid_in, 'Refer to drawer', pg_temp.today() - 10),
    format('Cheque 700002 was paid in on %s, and cannot have come back before it was.',
           to_char(pg_temp.today(), 'DD Mon YYYY')),
    '23514');
  perform pg_temp.check_refused('not even the day before',
    format('select public.bounce_pdc(%L, %L, %L)', d.paid_in, 'Refer to drawer', pg_temp.today() - 1),
    format('Cheque 700002 was paid in on %s, and cannot have come back before it was.',
           to_char(pg_temp.today(), 'DD Mon YYYY')),
    '23514');
  perform public.bounce_pdc(d.paid_in, 'Refer to drawer', pg_temp.today());
  perform pg_temp.check_eq('it comes back the day it was paid in',
    pg_temp.ca_state(d.paid_in), 'bounced bounced 0');

  -- -------------------------------------------------------------------
  -- Ours: not before it was written
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a cheque the company wrote is not stopped before it was issued',
    format('select public.bounce_pdc(%L, %L, %L)', d.issued, 'Stopped', pg_temp.today() - 6),
    format('Cheque 800001 was issued on %s, and cannot have come back before it was.',
           to_char(pg_temp.today() - 5, 'DD Mon YYYY')),
    '23514');
  perform public.bounce_pdc(d.issued, 'Stopped', pg_temp.today() - 2);
  perform pg_temp.check_eq('it is stopped after',
    pg_temp.ca_state(d.issued) || ' / ' || pg_temp.ca_journals(d.issued),
    'bounced bounced -2 / -5 then -2');
end $$;

reset role;

rollback;
