-- =====================================================================
-- iAkauntan :: the two dates on a sales document
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_dates.sql
--
-- `sales_documents.valid_until` and `delivery_date` have been columns
-- since `0005`. `valid_until` carries the comment `-- quotations`, which
-- was the whole of what anybody ever did about it.
--
-- The first claim is the expensive one. A quotation is an offer, and
-- `transfer_document` would turn a year-old one into an invoice without
-- a word — every figure carried forward, every downstream total
-- agreeing, nothing in the books looking wrong, and the work done at
-- last year's price. It is asserted as a refusal and as a way through,
-- because a refusal with no way through is how somebody ends up voiding
-- the quote and retyping it.
--
-- The second is about a promise. The delivery date given on a quotation
-- was dropped at every transfer, so by the time an order existed nobody
-- could say what had been promised — and `report_late_orders` is the
-- question the column is for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.dd_quote(
  p_org uuid, p_no text, p_valid date, p_delivery date default null)
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid;
begin
  select id into v_cust from public.contacts
   where org_id = p_org and code = 'C-1';
  if v_cust is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'C-1', 'Widget Buyer', 'customer') returning id into v_cust;
  end if;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status, valid_until, delivery_date)
  values (p_org, 'quotation', p_no, current_date - 400, v_cust, 'MYR', 1,
          'draft', p_valid, p_delivery)
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Widget', 10, 100);
  return v_doc;
end $$;

-- ---------------------------------------------------------------------
-- A price that ran out
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Sebut Harga Lama Sdn Bhd');
  v_old   uuid;
  v_live  uuid;
  v_none  uuid;
  v_order uuid;
  v_said  text;
begin
  v_old  := pg_temp.dd_quote(v_org, 'QT-OLD',  current_date - 30);
  v_live := pg_temp.dd_quote(v_org, 'QT-LIVE', current_date + 30);
  -- Every quotation raised before `0374` has none, and refusing them all
  -- would break every open quote in every company on the day it applied.
  v_none := pg_temp.dd_quote(v_org, 'QT-NONE', null);

  begin
    perform public.transfer_document(v_old, 'sales_order');
    raise exception 'FAIL: an expired quotation was transferred';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an expired quotation will not transfer',
    v_said like '%only valid until%');
  perform pg_temp.check_true('and the message names the document',
    v_said like '%QT-OLD%');
  perform pg_temp.check_true('and offers both ways forward',
    v_said like '%Extend it%' and v_said like '%new one%');

  perform pg_temp.check_true('one still in date transfers',
    public.transfer_document(v_live, 'sales_order') is not null);
  perform pg_temp.check_true('and one with no date is not expired',
    public.transfer_document(v_none, 'sales_order') is not null);

  -- The way through, which is the half that keeps the refusal honest.
  begin
    perform public.extend_document_validity(v_old, current_date - 1);
    raise exception 'FAIL: a quotation was extended into the past';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an extension to a day already gone is refused',
    v_said like '%already passed%');

  begin
    perform public.extend_document_validity(v_old, current_date - 500);
    raise exception 'FAIL: a quotation expired before it was raised';
  exception when sqlstate '23514' then
    null;  -- caught above by the same guard; the ordering is the point
  end;

  perform public.extend_document_validity(v_old, current_date + 14);
  perform pg_temp.check_eq('extended, it carries the new date',
    (select valid_until from public.sales_documents where id = v_old)::text,
    (current_date + 14)::text);
  v_order := public.transfer_document(v_old, 'sales_order');
  perform pg_temp.check_true('and then it transfers', v_order is not null);

  -- Only the two document types that are offers have a validity at all.
  begin
    perform public.extend_document_validity(v_order, current_date + 30);
    raise exception 'FAIL: a sales order was given a validity';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an order has no validity to extend',
    v_said like '%quotation or a proforma%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A promise that survives the transfer, and the report that reads it
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Janji Hantar Sdn Bhd');
  v_quote uuid;
  v_order uuid;
  v_do    uuid;
  v_inv   uuid;
  r       record;
begin
  v_quote := pg_temp.dd_quote(v_org, 'QT-1', current_date + 30,
                              current_date - 10);

  v_order := public.transfer_document(v_quote, 'sales_order');
  perform pg_temp.check_eq('the promised date reaches the order',
    (select delivery_date from public.sales_documents where id = v_order)::text,
    (current_date - 10)::text);

  v_do := public.transfer_document(v_order, 'delivery_order');
  perform pg_temp.check_eq('and the delivery order raised from it',
    (select delivery_date from public.sales_documents where id = v_do)::text,
    (current_date - 10)::text);

  -- An invoice's delivery date is a fact about a delivery that happened.
  -- Copying a promise into it would restate history.
  --
  -- Called into a variable first, deliberately. Written as
  -- `where id = public.transfer_document(...)` the planner is free to
  -- evaluate a volatile function once per row it scans, and the second
  -- call raises "nothing left to transfer" — a failing test with nothing
  -- wrong in the code under it.
  v_inv := public.transfer_document(v_order, 'invoice');
  perform pg_temp.check_true('but not an invoice, which records a fact',
    (select delivery_date is null from public.sales_documents
      where id = v_inv));

  -- The delivery order above took the whole quantity, which is what
  -- makes an order not late. Put it back to nothing shipped, because
  -- that is the state the rest of this block is about.
  update public.sales_document_lines set quantity_fulfilled = 0
   where document_id = v_order;

  -- A draft order is not yet a promise anybody made.
  perform pg_temp.check_eq('a draft order is not late',
    (select count(*) from public.report_late_orders(v_org)), 0);

  update public.sales_documents set status = 'approved' where id = v_order;
  select * into r from public.report_late_orders(v_org);
  perform pg_temp.check_eq('once it is approved, it is late', r.doc_no,
    (select doc_no from public.sales_documents where id = v_order));
  perform pg_temp.check_eq('by the days since the date given',
    r.days_late, 10);
  perform pg_temp.check_eq('with the whole order outstanding',
    r.outstanding, 10);
  perform pg_temp.check_eq('and the customer named', r.contact_name,
    'Widget Buyer');

  -- Measured on the lines, not on the status: nine tenths shipped is
  -- late on the tenth that is not.
  update public.sales_document_lines set quantity_fulfilled = 9
   where document_id = v_order;
  select * into r from public.report_late_orders(v_org);
  perform pg_temp.check_eq('a part-shipped order is late on the remainder',
    r.outstanding, 1);

  update public.sales_document_lines set quantity_fulfilled = 10
   where document_id = v_order;
  perform pg_temp.check_eq('and a shipped one is not late at all',
    (select count(*) from public.report_late_orders(v_org)), 0);

  -- As at a date before the promise, nothing is late yet.
  update public.sales_document_lines set quantity_fulfilled = 0
   where document_id = v_order;
  perform pg_temp.check_eq('nor is anything late before the day promised',
    (select count(*) from public.report_late_orders(
       v_org, current_date - 20)), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('extending a quotation is closed to anon',
    not has_function_privilege('anon',
      'public.extend_document_validity(uuid, date)', 'execute'));
  perform pg_temp.check_true('and the late orders report',
    not has_function_privilege('anon',
      'public.report_late_orders(uuid, date)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may read it',
    has_function_privilege('authenticated',
      'public.report_late_orders(uuid, date)', 'execute'));
end $$;

rollback;
