-- =====================================================================
-- iAkauntan :: who a required custom field is asked of
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/custom_fields_required.sql
--
-- 0542 enforced `is_required` on every write to one of the eleven
-- carriers. FORTY-ONE FUNCTIONS in this schema create one of those
-- rows and not one of them passes a custom field, because not one of
-- them can — there is nobody there to ask. So a company that ticked
-- "it has to be filled in" on a sales document stopped being able to
-- invoice a quotation, ring a sale through the till, or raise a
-- standing order.
--
-- 0543's rule: a row carrying NO custom fields was not filled in by
-- anybody and passes; the moment any are supplied the whole set is
-- held to the definitions, required included.
--
-- This file is the measurement. Every assertion below fails on 0542's
-- rule and passes on 0543's, except the last two, which say the rule
-- did not simply stop being enforced.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org  uuid := pg_temp.test_org('Wajib Tetapi Sdn Bhd');
  v_cust uuid;
  v_item uuid;
  v_q    uuid;
  v_inv  uuid;
  v_pros uuid;
  v_new  uuid;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['ticketing', 'crm']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan Wajib', 'customer') returning id into v_cust;
  insert into public.items
    (org_id, code, name, item_type, uom_code, unit_price)
  values (v_org, 'I-1', 'Kerja', 'service', 'C62', 100)
  returning id into v_item;

  -- The company decides every invoice must carry a cost centre, and
  -- every contact a reference.
  perform public.upsert_custom_field(v_org, 'sales_document', 'Cost centre',
                                     null, 'text', true);
  perform public.upsert_custom_field(v_org, 'contact', 'Reference',
                                     null, 'text', true);
  perform public.upsert_custom_field(v_org, 'ticket', 'Reference',
                                     null, 'text', true);

  -- ------------------------------------------------------------------
  -- A person filling a form in is still asked
  -- ------------------------------------------------------------------
  -- The section always sends a key for every required field it drew,
  -- null where the box was left empty — so this is the shape a save
  -- from the app has, and the database is what refuses it.
  perform pg_temp.check_refused('a form that leaves a required box empty',
    format($q$insert into public.contacts
             (org_id, code, name, contact_type, custom_fields)
             values (%L, 'C-2', 'Pelanggan Dua', 'customer',
                     '{"reference": null}'::jsonb)$q$, v_org),
    'Reference has to be filled in.%', '23514');
  perform pg_temp.check_refused('and one that sends it blank',
    format($q$insert into public.contacts
             (org_id, code, name, contact_type, custom_fields)
             values (%L, 'C-2', 'Pelanggan Dua', 'customer',
                     '{"reference": "  "}'::jsonb)$q$, v_org),
    'Reference has to be filled in.%', '23514');

  -- And one that answers is written.
  insert into public.contacts
    (org_id, code, name, contact_type, custom_fields)
  values (v_org, 'C-2', 'Pelanggan Dua', 'customer',
          '{"reference":"REF-2"}'::jsonb);
  perform pg_temp.check_eq('a form that answers is written',
    (select custom_fields ->> 'reference' from public.contacts
      where org_id = v_org and code = 'C-2'), 'REF-2');

  -- ------------------------------------------------------------------
  -- A document the software raises is not somebody's form
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status, custom_fields)
  values (v_org, 'quotation', 'QT-W1', current_date, v_cust, 'MYR', 1,
          0, 0, 0, 'draft', '{"cost_centre":"KL-01"}'::jsonb)
  returning id into v_q;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_q, 1, 'item', v_item, 'Kerja', 1, 100);
  update public.sales_documents set status = 'posted' where id = v_q;

  -- THE ONE THAT BROKE. On 0542's rule this raised "Cost centre has to
  -- be filled in" and a company could no longer invoice its own
  -- quotations.
  v_inv := public.transfer_document(v_q, 'invoice');
  perform pg_temp.check_true('a quotation can still be invoiced', v_inv is not null);
  perform pg_temp.check_eq('and the invoice it raised carries no cost centre',
    (select custom_fields::text from public.sales_documents where id = v_inv),
    '{}');

  -- The same for a contact the software makes out of a prospect.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P-1', 'Bakal Pelanggan', 'prospect') returning id into v_pros;
  v_new := public.create_contact_as(v_pros, 'customer');
  perform pg_temp.check_true('a prospect can still be made a customer',
    v_new is not null);

  -- And for a ticket, which is raised by its own function.
  perform pg_temp.check_true('a ticket can still be opened',
    public.create_ticket(v_org, 'Something is broken', 'It is') is not null);

  -- ------------------------------------------------------------------
  -- The rule did not simply stop being enforced
  -- ------------------------------------------------------------------
  -- Touching the fields on a record asks for the whole set again, which
  -- is what stops "supply nothing" being a way round the rule for
  -- somebody who is actually editing.
  perform pg_temp.check_refused('editing the fields asks for the required one',
    format($q$update public.sales_documents
             set custom_fields = '{"cost_centre": null}'::jsonb
             where id = %L$q$, v_inv),
    'Cost centre has to be filled in.%', '23514');

  -- And a key nobody defined is still refused, whatever else changed.
  perform pg_temp.check_refused('and an undefined key is still refused',
    format($q$update public.sales_documents
             set custom_fields = '{"cost_centre":"KL-9","nonsense":"x"}'::jsonb
             where id = %L$q$, v_inv),
    'nonsense is not a field on a sales_document for this company.%', '23514');
end $$;

rollback;
