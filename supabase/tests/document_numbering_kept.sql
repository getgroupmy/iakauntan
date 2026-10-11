-- =====================================================================
-- iAkauntan :: a series is set through its setting (0819)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_numbering_kept.sql
--
-- `set_document_numbering` will not set a series' next number below the
-- last one issued: the draw would hit a number already on a document.
-- Before `0819` an admin could write the row directly: invoices wound
-- back to 1 after three were issued, and the next invoice -- and every
-- one after it -- failed on the unique index. Asked as the owner, with
-- the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_dn (org uuid, cust uuid, prefix text);
grant select on t_dn to authenticated;

create or replace function pg_temp.dn_invoice(p_org uuid, p_cust uuid)
returns text language plpgsql as $$
declare v_inv uuid;
begin
  insert into public.sales_documents
    (org_id, doc_no, doc_type, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, public.next_document_number(p_org, 'invoice'), 'invoice',
          date '2026-03-01', date '2026-03-31', p_cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_inv, 1, 'Sale', 1, 100);
  perform public.post_sales_document(v_inv);
  return (select doc_no from public.sales_documents where id = v_inv);
end $$;
grant execute on function pg_temp.dn_invoice(uuid, uuid) to authenticated;

do $$
declare
  r t_dn;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Nombor Siri Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Buyer', 'customer') returning id into r.cust;
  perform pg_temp.dn_invoice(r.org, r.cust);
  perform pg_temp.dn_invoice(r.org, r.cust);
  perform pg_temp.dn_invoice(r.org, r.cust);
  r.prefix := (select prefix from public.number_sequences
                where org_id = r.org and doc_type = 'invoice');
  insert into t_dn select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d      t_dn;
  v_four text;
begin
  select * into d from t_dn;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('three invoices issued, the fourth next',
    (select count(*)::integer || '/' || max(n.next_value)
       from public.sales_documents s, public.number_sequences n
      where s.org_id = d.org and s.doc_type = 'invoice' and s.status = 'posted'
        and n.org_id = d.org and n.doc_type = 'invoice'), '3/4');

  -- The setting's rule, as it was.
  perform pg_temp.check_refused('the setting will not wind the series back',
    format('select public.set_document_numbering(%L, %L, %L, %L, 5, %L, 1)',
           d.org, 'invoice', d.prefix, '', 'yearly'),
    'The last of invoices issued was %00003; the next cannot be lower than 4%', '23514');

  -- What was measured: the row wound back by hand instead.
  perform pg_temp.check_refused('nor is the row wound back by hand',
    format($q$update public.number_sequences set next_value = 1
               where org_id = %L and doc_type = 'invoice'$q$, d.org),
    'permission denied for table number_sequences', '42501');
  perform pg_temp.check_refused('nor deleted, to start again from 1',
    format($q$delete from public.number_sequences
               where org_id = %L and doc_type = 'invoice'$q$, d.org),
    'permission denied for table number_sequences', '42501');
  perform pg_temp.check_refused('nor a series typed in',
    format($q$insert into public.number_sequences (org_id, doc_type, prefix, next_value)
              values (%L, 'quotation', 'Q-', 1)$q$, d.org),
    'permission denied for table number_sequences', '42501');

  -- So the next invoice is issued, and numbered after the third.
  v_four := pg_temp.dn_invoice(d.org, d.cust);
  perform pg_temp.check_true('so the fourth invoice is issued, after the third: ' || v_four,
    v_four like '%00004');

  -- The road: a new shape is a new series, and may start again.
  perform public.set_document_numbering(d.org, 'invoice', 'INV/', '', 4, 'never', 1);
  perform pg_temp.check_eq('a series is set through its setting',
    (select prefix || '/' || padding || '/' || reset_policy || '/' || next_value
       from public.number_sequences where org_id = d.org and doc_type = 'invoice'),
    'INV//4/never/1');
  perform pg_temp.check_eq('and the next invoice is numbered by it',
    pg_temp.dn_invoice(d.org, d.cust), 'INV/0001');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the series',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'number_sequences'
        and cmd <> 'SELECT'), 0);
end $$;

rollback;
