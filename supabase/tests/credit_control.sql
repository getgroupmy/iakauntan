-- =====================================================================
-- iAkauntan :: credit control tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_control.sql
--
-- contacts.credit_limit was collected, stored, shown back and never
-- checked. These assert that it now bites when it is meant to and, just
-- as importantly, that it does not bite where it must not: a credit note
-- reduces exposure and refusing one because the customer is over their
-- limit is exactly backwards.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cc_org(p_name text, p_mode text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  update public.organizations set credit_control = p_mode where id = v_org;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.invoice_for(
  p_org uuid, p_cust uuid, p_no text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, date '2026-03-01', p_cust, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Sale', 1, p_amount);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- block: the invoice that takes them past the limit is refused
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('Blocking Sdn Bhd', 'block');
  v_cust uuid; v_a uuid; v_b uuid; v_st jsonb;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Tight Buyer', 'customer', 5000)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 4000);
  perform public.post_sales_document(v_a);

  v_st := public.customer_credit_status(v_cust);
  perform pg_temp.check_eq('outstanding after the first',
    (v_st->>'outstanding')::numeric, 4000);
  perform pg_temp.check_eq('with a thousand left',
    (v_st->>'available')::numeric, 1000);
  perform pg_temp.check_true('and not over yet',
    (v_st->>'over_limit')::boolean = false);

  v_b := pg_temp.invoice_for(v_org, v_cust, 'INV-2', 2000);
  begin
    perform public.post_sales_document(v_b);
    raise exception 'FAIL: posted past the credit limit';
  exception when sqlstate '23514' then
    raise notice 'ok   posting past the limit is refused';
  end;

  -- And one that fits still goes through, so the guard is not simply
  -- refusing everything for that customer from here on.
  update public.sales_document_lines set unit_price = 900 where document_id = v_b;
  perform public.post_sales_document(v_b);
  perform pg_temp.check_eq('an invoice that fits still posts',
    (public.customer_credit_status(v_cust)->>'outstanding')::numeric, 4900);
end $$;

-- ---------------------------------------------------------------------
-- warn: it posts, and the position is still reported
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('Warning Sdn Bhd', 'warn');
  v_cust uuid; v_a uuid; v_b uuid; v_st jsonb;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Tight Buyer', 'customer', 5000)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 4000);
  perform public.post_sales_document(v_a);
  v_b := pg_temp.invoice_for(v_org, v_cust, 'INV-2', 2000);
  perform public.post_sales_document(v_b);

  v_st := public.customer_credit_status(v_cust);
  perform pg_temp.check_eq('it went through', (v_st->>'outstanding')::numeric, 6000);
  perform pg_temp.check_true('and is reported as over',
    (v_st->>'over_limit')::boolean);
  perform pg_temp.check_eq('by a thousand', (v_st->>'available')::numeric, -1000);
end $$;

-- ---------------------------------------------------------------------
-- A limit of zero is no limit, not a limit of nothing
--
-- Every existing contact carries the column default of zero. Reading
-- that as "may owe nothing" would stop every one of them being invoiced
-- the moment this migration landed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('No Limit Sdn Bhd', 'block');
  v_cust uuid; v_a uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Open Account', 'customer', 0)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 999999);
  perform public.post_sales_document(v_a);
  perform pg_temp.check_true('no limit means no block',
    (select gl_entry_id is not null from public.sales_documents where id = v_a));
end $$;

-- ---------------------------------------------------------------------
-- A credit note is never blocked
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.cc_org('Credit Note Sdn Bhd', 'block');
  v_cust uuid; v_a uuid; v_cn uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, credit_limit)
  values (v_org, 'C-001', 'Over Buyer', 'customer', 1000)
  returning id into v_cust;

  v_a := pg_temp.invoice_for(v_org, v_cust, 'INV-1', 900);
  perform public.post_sales_document(v_a);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'credit_note', 'CN-1', date '2026-03-02', v_cust, 'MYR', 1,
          500, 500, 500, 'draft')
  returning id into v_cn;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_cn, 1, 'Return', 1, 500);

  perform public.post_sales_document(v_cn);
  perform pg_temp.check_true('crediting somebody over their limit is allowed',
    (select gl_entry_id is not null from public.sales_documents where id = v_cn));
end $$;

-- ---------------------------------------------------------------------
-- On stop, which is not a small limit
-- ---------------------------------------------------------------------
-- 0362. `credit_hold` was a column nothing read for three hundred and
-- fifty migrations. A hold is a person's instruction rather than
-- arithmetic, so unlike the limit it applies whatever the
-- organization's mode says — otherwise the effect of a checkbox would
-- depend on a setting three screens away, and whoever ticked it would
-- have no way to know which they had.
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
  v_refused boolean;
  v_msg  text;
begin
  v_org := pg_temp.test_org('Kedai Tahan Kredit');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  -- Warn, deliberately: the weaker of the two modes, so what is proved
  -- below is the hold and not the limit.
  update public.organizations set credit_control = 'warn' where id = v_org;

  insert into public.contacts
    (org_id, code, name, contact_type, credit_limit, credit_hold)
  values (v_org, 'C-STOP', 'Syarikat Lambat Bayar', 'customer', 0, true)
  returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status,
     total_amount, base_total_amount, balance_amount)
  values (v_org, 'invoice', 'INV-STOP-1', v_cust, current_date, 'draft',
          100, 100, 100)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_inv, 1, 'More on account', 1, 100);

  v_refused := false;
  begin
    perform public.post_sales_document(v_inv);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'an invoice to somebody on stop is refused, even in warn mode',
    v_refused);
  -- The sentence names the customer. "Credit hold" on its own leaves
  -- whoever is posting a batch to work out which of forty it was.
  perform pg_temp.check_true('and says who: ' || coalesce(v_msg, ''),
    v_msg like '%Lambat Bayar%');

  -- Credits still go through, which is 0086's reasoning unchanged: the
  -- customer on stop is exactly the one most likely to need one, and
  -- blocking it would leave the balance that caused the hold
  -- uncorrectable.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status,
     total_amount, base_total_amount, balance_amount)
  values (v_org, 'credit_note', 'CN-STOP-1', v_cust, current_date, 'draft',
          50, 50, 50)
  returning id into v_cn;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_cn, 1, 'Return', 1, 50);
  perform public.post_sales_document(v_cn);
  perform pg_temp.check_true('but a credit note still posts',
    (select gl_entry_id is not null from public.sales_documents where id = v_cn));

  -- And the control: take the hold off and the same invoice posts. The
  -- refusal above is about the hold rather than about the document.
  update public.contacts set credit_hold = false where id = v_cust;
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_true('taking the hold off lets it through',
    (select gl_entry_id is not null from public.sales_documents where id = v_inv));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the status reader is closed to anon',
    not has_function_privilege('anon',
      'public.customer_credit_status(uuid)', 'execute'));
  perform pg_temp.check_true('and the guard is not callable at all',
    not has_function_privilege('authenticated',
      'app.enforce_credit_limit()', 'execute'));
end $$;

rollback;
