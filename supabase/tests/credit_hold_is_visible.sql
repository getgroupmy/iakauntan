-- =====================================================================
-- iAkauntan :: say they are on hold before the invoice is typed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_hold_is_visible.sql
--
-- `app.enforce_credit_limit` refuses an invoice to a customer on credit
-- hold before it looks at the mode or the limit. `customer_credit_status`
-- -- the one thing the document editor asks before the lines are typed
-- -- did not report the hold at all, so the screen stayed silent in
-- exactly the arrangement a held customer is usually in: on hold, no
-- limit, nothing to draw a banner from.
--
-- What is asserted is both ends of that: the screen is told, and the
-- refusal it is being told about is real.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ch_post(p_org uuid, p_contact uuid,
                                           p_no text, p_amount numeric)
returns text language plpgsql as $$
declare v_doc uuid; v_msg text;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (p_org, 'invoice', p_no, current_date, current_date, p_contact,
          'draft', 'MYR', 1)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_doc, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work done', 1, p_amount);
  perform public.post_sales_document(v_doc);
  return 'posted';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

do $$
declare
  v_org  uuid;
  v_held uuid;
  v_ok   uuid;
  v_s    jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Tahan Kredit Sdn Bhd');
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100);

  -- The arrangement the defect was actually about: on hold, and no
  -- limit, because the hold *is* the decision. Every reason the banner
  -- had to stay quiet applies at once.
  insert into public.contacts (org_id, code, name, contact_type,
                               credit_limit, credit_hold)
  values (v_org, 'H', 'Pelanggan Tertahan', 'customer', 0, true)
  returning id into v_held;

  v_s := public.customer_credit_status(v_held);

  -- The key, not the value. A client writes `status['credit_hold'] ==
  -- true`, and a key that is missing and a key that is false look the
  -- same from there -- right up until somebody asks why the banner
  -- never appeared.
  perform pg_temp.check_true('the screen is told about the hold',
    v_s ? 'credit_hold');
  perform pg_temp.check_true('and told about it when there is no limit at all',
    (v_s ->> 'credit_hold')::boolean);
  perform pg_temp.check_eq('and there really is no limit to draw on',
    (v_s ->> 'credit_limit')::numeric, 0::numeric);
  perform pg_temp.check_true('so nothing else in the answer would show it',
    (v_s ->> 'over_limit')::boolean is not true
      and v_s ->> 'available' is null);
  perform pg_temp.check_eq('and it names who it is about',
    v_s ->> 'contact_name', 'Pelanggan Tertahan');

  -- The other end. If the post were allowed, the banner would be a
  -- warning about nothing.
  perform pg_temp.check_true('and the post really is refused',
    pg_temp.ch_post(v_org, v_held, 'INV-H1', 500) like '%on credit hold%');

  -- In every mode, which is why the banner may not be gated on one.
  update public.organizations set credit_control = 'off' where id = v_org;
  perform pg_temp.check_true('with credit control off as well',
    pg_temp.ch_post(v_org, v_held, 'INV-H2', 500) like '%on credit hold%');
  perform pg_temp.check_true('and the screen still says so',
    (public.customer_credit_status(v_held) ->> 'credit_hold')::boolean);

  -- And it is a hold, not a mood. Somebody not on hold is not reported
  -- as on hold, or the banner appears against every customer and means
  -- nothing against any of them.
  insert into public.contacts (org_id, code, name, contact_type,
                               credit_limit, credit_hold)
  values (v_org, 'K', 'Pelanggan Biasa', 'customer', 0, false)
  returning id into v_ok;
  perform pg_temp.check_true('somebody not on hold is not reported as one',
    (public.customer_credit_status(v_ok) ->> 'credit_hold')::boolean is false);
  perform pg_temp.check_eq('and can be invoiced',
    pg_temp.ch_post(v_org, v_ok, 'INV-K1', 500), 'posted');

  -- Taking the hold off is the answer the banner should be pointing at,
  -- so it has to be the answer that works.
  update public.contacts set credit_hold = false where id = v_held;
  perform pg_temp.check_true('and taking the hold off clears both',
    (public.customer_credit_status(v_held) ->> 'credit_hold')::boolean is false);
  perform pg_temp.check_eq('the report and the refusal together',
    pg_temp.ch_post(v_org, v_held, 'INV-H3', 500), 'posted');
end $$;

rollback;
