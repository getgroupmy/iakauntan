-- =====================================================================
-- iAkauntan :: LHDN's record is written by its functions (0804)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_records.sql
--
-- `einvoice_documents`, its lines, its submissions and the monthly
-- consolidations with their items are what this company filed with
-- LHDN and what LHDN said. Before `0804` a client could insert, update
-- and delete all of them: an accepted e-Invoice marked 'cancelled' by
-- hand let `void_sales_document` void an invoice LHDN still held as
-- valid. Asked as the owner, with the role `authenticated`, which is
-- who the app is; the functions and the database's own writes are asked to go
-- on writing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.er_invoice(p_org uuid, p_contact uuid, p_no text)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, pg_temp.today(), pg_temp.today() + 30,
          p_contact, 'MYR', 1, 100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Khidmat', 1, 100, 100);
  perform public.post_sales_document(v_doc);
  return v_doc;
end $$;

create temporary table t_er (
  org uuid,
  inv_valid uuid, ei_valid uuid,       -- LHDN accepted it
  inv_void uuid, ei_void uuid,         -- voided, its e-Invoice withdrawn
  inv_new uuid,                        -- posted, for the client to prepare
  inv_cons uuid,                       -- posted, in the month's consolidation
  submission uuid, consolidation uuid);
grant select on t_er to authenticated;

do $$
declare
  r   t_er;
  v_c uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Rekod LHDN Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  update public.organizations
     set einvoice_enabled = true, tin = 'C12345678901'
   where id = r.org;
  insert into public.contacts (org_id, code, name, contact_type, country_code, tin)
  values (r.org, 'C-1', 'Pembeli Sdn Bhd', 'customer', 'MYS', 'C88888888888')
  returning id into v_c;

  r.inv_valid := pg_temp.er_invoice(r.org, v_c, 'INV-R1');
  r.ei_valid := public.prepare_einvoice(r.inv_valid);
  r.inv_void := pg_temp.er_invoice(r.org, v_c, 'INV-R2');
  r.ei_void := public.prepare_einvoice(r.inv_void);
  perform public.void_sales_document(r.inv_void, 'salah pelanggan');
  r.inv_new := pg_temp.er_invoice(r.org, v_c, 'INV-R3');
  r.inv_cons := pg_temp.er_invoice(r.org, v_c, 'INV-R4');

  -- A submission and a consolidation with one receipt in it, as the
  -- MyInvois function and the month-end job leave them. Not INV-R3,
  -- which the client prepares below: `0805` refuses an e-Invoice of its
  -- own for a sale the month's return carries.
  insert into public.einvoice_submissions (org_id, document_count)
  values (r.org, 1) returning id into r.submission;
  update public.einvoice_documents set submission_id = r.submission
   where id = r.ei_valid;
  insert into public.einvoice_consolidations
    (org_id, period_start, period_end, document_count, total_amount)
  values (r.org, date_trunc('month', pg_temp.today())::date,
          (date_trunc('month', pg_temp.today()) + interval '1 month - 1 day')::date,
          1, 100)
  returning id into r.consolidation;
  insert into public.einvoice_consolidation_items
    (org_id, consolidation_id, sales_document_id, amount)
  values (r.org, r.consolidation, r.inv_cons, 100);

  insert into t_er select r.*;
end $$;

-- LHDN's answer, written where the MyInvois function writes it. The
-- function runs as `service_role`; written here as the session, which
-- owns the tables, because the CLI stack CI runs on does not grant
-- `service_role` these tables (run 38100240247) though the hosted
-- project does. What is asked is that a write which is not a client's
-- still goes through.
update public.einvoice_documents
   set status = 'valid', myinvois_uuid = 'LHDN-UUID-R1', validated_at = now()
 where id = (select ei_valid from t_er);
update public.einvoice_submissions set status = 'valid', accepted_count = 1
 where id = (select submission from t_er);

do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_true('LHDN''s answer is written, and the invoice copies it',
    (select e.status = 'valid' and s.einvoice_status = 'valid'
       from public.einvoice_documents e
       join public.sales_documents s on s.id = e.source_id
      where e.id = d.ei_valid));
  perform pg_temp.check_eq('the voided invoice''s e-Invoice was withdrawn',
    (select status::text from public.einvoice_documents where id = d.ei_void), 'cancelled');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- A member reads all five
-- =====================================================================
do $$
declare d t_er;
begin
  select * into d from t_er;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('the e-Invoices are read',
    (select count(*)::integer from public.einvoice_documents where org_id = d.org), 2);
  perform pg_temp.check_true('and their lines',
    exists (select 1 from public.einvoice_lines where einvoice_id = d.ei_valid));
  perform pg_temp.check_eq('and the submission, with LHDN''s answer',
    (select status from public.einvoice_submissions where id = d.submission), 'valid');
  perform pg_temp.check_eq('and the consolidation and its receipt',
    (select count(*)::integer from public.einvoice_consolidations c
       join public.einvoice_consolidation_items i on i.consolidation_id = c.id
      where c.id = d.consolidation), 1);
end $$;

-- =====================================================================
-- None of them is written by hand
-- =====================================================================
do $$
declare
  d   t_er;
  v_t text;
begin
  select * into d from t_er;
  foreach v_t in array array['einvoice_documents', 'einvoice_lines',
    'einvoice_submissions', 'einvoice_consolidations',
    'einvoice_consolidation_items']
  loop
    perform pg_temp.check_refused(format('%s takes no insert', v_t),
      format('insert into public.%I (org_id) values (%L)', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
    perform pg_temp.check_refused(format('%s takes no update', v_t),
      format('update public.%I set org_id = org_id where org_id = %L', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
    perform pg_temp.check_refused(format('%s takes no delete', v_t),
      format('delete from public.%I where org_id = %L', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
  end loop;

  -- What was measured, one by one.
  perform pg_temp.check_refused('an accepted e-Invoice is not marked cancelled by hand',
    format('update public.einvoice_documents set status = ''cancelled'' where id = %L',
           d.ei_valid),
    'permission denied for table einvoice_documents', '42501');
  perform pg_temp.check_refused('so its invoice is not voided under it',
    format('select public.void_sales_document(%L, ''salah'')', d.inv_valid),
    'Cannot void INV-R1: cancel the e-Invoice with LHDN first');
  perform pg_temp.check_refused('nor its figures rewritten',
    format('update public.einvoice_documents set payable_amount = 1 where id = %L',
           d.ei_valid),
    'permission denied for table einvoice_documents', '42501');
  perform pg_temp.check_refused('nor a withdrawn one put back in the queue',
    format('update public.einvoice_documents set status = ''queued'' where id = %L',
           d.ei_void),
    'permission denied for table einvoice_documents', '42501');
  perform pg_temp.check_refused('nor a receipt taken out of the month''s consolidation',
    format('delete from public.einvoice_consolidation_items where consolidation_id = %L',
           d.consolidation),
    'permission denied for table einvoice_consolidation_items', '42501');

  perform pg_temp.check_true('and LHDN''s record is as LHDN left it',
    (select status = 'valid' and myinvois_uuid = 'LHDN-UUID-R1' and payable_amount > 1
       from public.einvoice_documents where id = d.ei_valid)
    and (select status = 'cancelled' from public.einvoice_documents where id = d.ei_void)
    and exists (select 1 from public.einvoice_consolidation_items
                 where consolidation_id = d.consolidation));
end $$;

-- =====================================================================
-- The functions are the road, and still run
-- =====================================================================
do $$
declare
  d    t_er;
  v_ei uuid;
begin
  select * into d from t_er;
  v_ei := public.prepare_einvoice(d.inv_new);
  perform pg_temp.check_true('a client prepares an e-Invoice through its function, lines and all',
    exists (select 1 from public.einvoice_documents
             where id = v_ei and source_id = d.inv_new)
    and exists (select 1 from public.einvoice_lines where einvoice_id = v_ei));
  perform public.void_sales_document(d.inv_new, 'salah pelanggan');
  perform pg_temp.check_eq('and voiding the invoice withdraws it',
    (select status::text from public.einvoice_documents where id = v_ei), 'cancelled');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the five',
    (select count(*)::integer from pg_policies
      where schemaname = 'public'
        and tablename in ('einvoice_documents', 'einvoice_lines',
                          'einvoice_submissions', 'einvoice_consolidations',
                          'einvoice_consolidation_items')
        and cmd <> 'SELECT'), 0);
end $$;

rollback;
