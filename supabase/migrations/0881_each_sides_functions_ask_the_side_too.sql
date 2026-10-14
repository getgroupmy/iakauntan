-- =====================================================================
-- iAkauntan :: 0881 each side's functions ask the side too
--
-- `0878` made each side write its own: a trigger on the six tables
-- refuses a salesperson's purchase documents and a purchaser's sales
-- ones. It refuses a client's own statement and nothing else, and said
-- so -- a definer's statements are the owner's, not the client's -- and
-- its handoff entry named the functions that raise one side's paper and
-- ask only `can_write` as the next place to look.
--
-- Measured on 14 October 2026, locally, with the role `authenticated`:
-- a `sales` member imported a supplier bill through
-- `import_purchase_transactions`, and a `purchaser` raised a quotation
-- through `quote_opportunity`. `create_po_from_suggestions` asks
-- `can_write_module(org, 'purchases')`, which every role with no access
-- type passes.
--
-- Production held no `sales` and no `purchaser` member on 14 October.
--
-- Answered "each asks the side too". `app.require_side(org, side)`
-- raises `0878`'s own sentences where `app.writes_side` says no, and
-- seven functions ask it straight after the guard they already had:
--
--   'sales'      quote_opportunity, import_sales_transactions
--   'purchases'  import_purchase_transactions,
--                draft_bill_from_received_einvoice,
--                create_po_from_suggestions, accept_intercompany_bill
--   its source's transfer_document, which carries a document forward
--                on the side it is already on
--
-- Each body is `pg_get_functiondef` of what was applied, with the one
-- `perform` added. The till keeps its own: `complete_pos_sale` sells and
-- `settle_pos_stalls` bills the stall owners when a cashier closes it.
-- An access type decides instead, where the company has given one.
-- =====================================================================

create or replace function app.require_side(p_org_id uuid, p_side text)
returns void
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
begin
  if app.writes_side(p_org_id, p_side) then
    return;
  end if;
  if p_side = 'purchases' then
    raise exception
      'A salesperson does not write purchase documents or supplier '
      'payments. An access type can give them the purchases side.'
      using errcode = '42501';
  end if;
  raise exception
    'A purchaser does not write sales documents or receipts. An '
    'access type can give them the sales side.'
    using errcode = '42501';
end $$;

revoke all on function app.require_side(uuid, text) from public, anon;

comment on function app.require_side(uuid, text) is
  'Refuses the caller, in 0878''s words, where app.writes_side says they may not write this side (''sales'' or ''purchases''). Asked by the definers that raise one side''s documents (0881).';

-- quote_opportunity
CREATE OR REPLACE FUNCTION public.quote_opportunity(p_opportunity uuid, p_valid_until date DEFAULT NULL::date, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_o     public.opportunities;
  v_doc   uuid;
  v_no    text;
  v_tax   uuid;
  v_rate  numeric := 0;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select * into v_o from public.opportunities
   where id = p_opportunity and deleted_at is null;
  if v_o.id is null then
    raise exception 'No such opportunity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_o.org_id) then
    raise exception 'not permitted to raise a quotation'
      using errcode = '42501';
  end if;
  perform app.require_side(v_o.org_id, 'sales');
  if v_o.contact_id is null then
    raise exception
      'A quotation goes to somebody. Name the customer on the deal '
      'first.' using errcode = '23502';
  end if;
  if v_o.quotation_id is not null then
    raise exception
      'This deal already has a quotation. Revise that one, or the '
      'pipeline ends up with two figures for one job.'
      using errcode = '23505';
  end if;
  if v_o.status <> 'open' then
    raise exception
      'This deal is already %. Quoting a closed deal is quoting for '
      'work nobody is waiting on.', v_o.status using errcode = '23514';
  end if;
  if coalesce(v_o.amount, 0) <= 0 then
    raise exception
      'The deal is worth nothing, so there is nothing to quote. Put the '
      'figure on the deal first.' using errcode = '23514';
  end if;
  if p_valid_until is not null and p_valid_until < v_today then
    raise exception 'A quotation cannot be valid until a day that has '
      'already passed.' using errcode = '23514';
  end if;

  v_no := public.next_document_number(v_o.org_id, 'quotation');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, valid_until, notes, created_by)
  values (v_o.org_id, 'quotation', v_no, v_today, v_o.contact_id,
          coalesce(v_o.currency, app.base_currency(v_o.org_id)), 1,
          'draft',
          -- A quotation with no end is an offer that never runs out,
          -- which `0374` is the note on. Thirty days where nobody said.
          coalesce(p_valid_until, v_today + 30),
          v_o.name, auth.uid())
  returning id into v_doc;

  -- One line, at the deal's own figure. It is a starting point that
  -- somebody prices properly; what matters is that the deal and the
  -- document begin from the same number instead of two.
  --
  -- 0438. With the tax the company is registered for, as of the day the
  -- quotation is dated. `tax_rate` as well as `tax_code_id`: totals are
  -- recalculated from the rate on the line, so naming ST8 without its 8
  -- produces a quotation showing a tax code and charging nothing. The
  -- deal's figure is read as tax-exclusive -- a salesperson records the
  -- contract value and the tax goes on top when it is invoiced.
  v_tax := app.default_sales_tax(v_o.org_id, v_today);
  select coalesce(rate, 0) into v_rate from public.tax_codes
   where id = v_tax;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (v_o.org_id, v_doc, 1,
          coalesce(nullif(btrim(coalesce(p_description, '')), ''), v_o.name),
          1, v_o.amount, v_tax, coalesce(v_rate, 0));

  update public.opportunities
     set quotation_id = v_doc, updated_at = now()
   where id = p_opportunity;

  return v_doc;
end $function$;

-- import_sales_transactions
CREATE OR REPLACE FUNCTION public.import_sales_transactions(p_org_id uuid, p_rows jsonb, p_commit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r         jsonb;
  v_results jsonb;
  v_bad     integer;
  v_total   integer;
  v_no      text;
  v_key     text;
  v_docs    jsonb := '{}'::jsonb;
  v_doc     uuid;
  v_line    integer;
  v_lines   jsonb := '{}'::jsonb;
  v_made    integer := 0;
begin
  if not app.can_write(p_org_id) then
    raise exception 'not permitted to import' using errcode = '42501';
  end if;
  perform app.require_side(p_org_id, 'sales');

  v_results := app.validate_sales_transactions(p_org_id, p_rows);
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

  -- All or nothing, as every other importer here. A file half imported
  -- is a file nobody can run again: the good half is now a duplicate.
  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file '
      'and run it again.', v_bad, v_total using errcode = '22023';
  end if;

  if p_commit then
    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_no  := app.import_text(r, 'doc_no');
      v_key := lower(v_no);

      if v_docs ? v_key then
        v_doc  := (v_docs ->> v_key)::uuid;
        v_line := (v_lines ->> v_key)::integer + 1;
      else
        insert into public.sales_documents (
          org_id, doc_type, doc_no, doc_date, due_date, contact_id,
          reference, currency, exchange_rate, status,
          import_source, import_ref, imported_at, created_by)
        values (
          p_org_id,
          lower(coalesce(app.import_text(r, 'doc_type'),
                         'invoice'))::app.sales_doc_type,
          v_no,
          app.import_date(app.import_text(r, 'doc_date')),
          app.import_date(app.import_text(r, 'due_date')),
          (select c.id from public.contacts c
            where c.org_id = p_org_id
              and lower(c.code) = lower(app.import_text(r, 'contact_code'))
              and c.deleted_at is null),
          app.import_text(r, 'reference'),
          upper(coalesce(app.import_text(r, 'currency'),
            (select base_currency from public.organizations
              where id = p_org_id))),
          coalesce(app.import_number(
            app.import_text(r, 'exchange_rate'), null), 1),
          -- Drafts. The header says why, and it is the line in this
          -- migration a reviewer should be slowest to change.
          'draft',
          'transactions', v_no, now(), auth.uid())
        returning id into v_doc;

        v_docs  := v_docs  || jsonb_build_object(v_key, v_doc::text);
        v_line  := 1;
        v_made  := v_made + 1;
      end if;

      -- Quantity, price and tax code only. `app.calc_document_line` and
      -- `app.recalc_sales_totals` do the arithmetic, so an imported
      -- invoice adds up exactly the way a typed one does.
      insert into public.sales_document_lines (
        org_id, document_id, line_no, description, item_id,
        quantity, unit_price, discount_percent, tax_code_id)
      values (
        p_org_id, v_doc, v_line,
        coalesce(app.import_text(r, 'description'), ''),
        (select it.id from public.items it
          where it.org_id = p_org_id
            and lower(it.code) = lower(app.import_text(r, 'item_code'))
            and it.deleted_at is null),
        app.import_number(app.import_text(r, 'quantity'), 1),
        app.import_number(app.import_text(r, 'unit_price'), 0),
        coalesce(app.import_number(
          app.import_text(r, 'discount_percent'), null), 0),
        (select t.id from public.tax_codes t
          where t.org_id = p_org_id
            and lower(t.code) = lower(app.import_text(r, 'tax_code'))));

      v_lines := v_lines || jsonb_build_object(v_key, v_line);
    end loop;
  end if;

  return jsonb_build_object(
    'rows', v_results,
    'total', v_total,
    'errors', v_bad,
    'documents', v_made,
    'committed', p_commit);
end $function$;

-- import_purchase_transactions
CREATE OR REPLACE FUNCTION public.import_purchase_transactions(p_org_id uuid, p_rows jsonb, p_commit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r         jsonb;
  v_results jsonb;
  v_bad     integer;
  v_total   integer;
  v_no      text;
  v_key     text;
  v_docs    jsonb := '{}'::jsonb;
  v_doc     uuid;
  v_line    integer;
  v_lines   jsonb := '{}'::jsonb;
  v_made    integer := 0;
begin
  if not app.can_write(p_org_id) then
    raise exception 'not permitted to import' using errcode = '42501';
  end if;
  perform app.require_side(p_org_id, 'purchases');

  v_results := app.validate_purchase_transactions(p_org_id, p_rows);
  select count(*) filter (where x ->> 'status' = 'error'), count(*)
    into v_bad, v_total
    from jsonb_array_elements(v_results) x;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file '
      'and run it again.', v_bad, v_total using errcode = '22023';
  end if;

  if p_commit then
    for r in select * from jsonb_array_elements(p_rows)
    loop
      v_no  := app.import_text(r, 'doc_no');
      v_key := lower(v_no);

      if v_docs ? v_key then
        v_doc  := (v_docs ->> v_key)::uuid;
        v_line := (v_lines ->> v_key)::integer + 1;
      else
        insert into public.purchase_documents (
          org_id, doc_type, doc_no, doc_date, due_date, contact_id,
          supplier_doc_no, reference, currency, exchange_rate, status,
          import_source, import_ref, imported_at, created_by)
        values (
          p_org_id,
          lower(coalesce(app.import_text(r, 'doc_type'),
                         'bill'))::app.purchase_doc_type,
          v_no,
          app.import_date(app.import_text(r, 'doc_date')),
          app.import_date(app.import_text(r, 'due_date')),
          (select c.id from public.contacts c
            where c.org_id = p_org_id
              and lower(c.code) = lower(app.import_text(r, 'contact_code'))
              and c.deleted_at is null),
          app.import_text(r, 'supplier_doc_no'),
          app.import_text(r, 'reference'),
          upper(coalesce(app.import_text(r, 'currency'),
            (select base_currency from public.organizations
              where id = p_org_id))),
          coalesce(app.import_number(
            app.import_text(r, 'exchange_rate'), null), 1),
          'draft',
          'transactions', v_no, now(), auth.uid())
        returning id into v_doc;

        v_docs  := v_docs  || jsonb_build_object(v_key, v_doc::text);
        v_line  := 1;
        v_made  := v_made + 1;
      end if;

      insert into public.purchase_document_lines (
        org_id, document_id, line_no, description, item_id,
        quantity, unit_price, discount_percent, tax_code_id)
      values (
        p_org_id, v_doc, v_line,
        coalesce(app.import_text(r, 'description'), ''),
        (select it.id from public.items it
          where it.org_id = p_org_id
            and lower(it.code) = lower(app.import_text(r, 'item_code'))
            and it.deleted_at is null),
        app.import_number(app.import_text(r, 'quantity'), 1),
        app.import_number(app.import_text(r, 'unit_price'), 0),
        coalesce(app.import_number(
          app.import_text(r, 'discount_percent'), null), 0),
        (select t.id from public.tax_codes t
          where t.org_id = p_org_id
            and lower(t.code) = lower(app.import_text(r, 'tax_code'))));

      v_lines := v_lines || jsonb_build_object(v_key, v_line);
    end loop;
  end if;

  return jsonb_build_object(
    'rows', v_results,
    'total', v_total,
    'errors', v_bad,
    'documents', v_made,
    'committed', p_commit);
end $function$;

-- draft_bill_from_received_einvoice
CREATE OR REPLACE FUNCTION public.draft_bill_from_received_einvoice(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row      public.received_einvoices;
  v_type     app.purchase_doc_type;
  v_bill     uuid;
  v_line     public.received_einvoice_lines;
  v_class    text;
  v_uom      text;
  v_total    numeric(18, 2);
  v_diff     numeric(18, 2);
  v_note     text;
begin
  select * into v_row from public.received_einvoices where id = p_id;
  if not found then
    raise exception 'No such received e-Invoice' using errcode = 'P0002';
  end if;
  if not app.can_write(v_row.org_id) then
    raise exception 'Not allowed to create bills in this organization'
      using errcode = '42501';
  end if;
  perform app.require_side(v_row.org_id, 'purchases');
  if v_row.bill_id is not null then
    raise exception 'This document is already on a bill' using errcode = '22023';
  end if;
  if v_row.contact_id is null then
    raise exception
      'Link a supplier to this document before drafting a bill'
      using errcode = '22023';
  end if;

  -- MyInvois document types, from the supplier's side of the trade.
  -- 04 is a refund note and 11 to 14 are self-billed, which we ISSUE
  -- rather than receive; neither has a purchase document to become, and
  -- guessing one would post the wrong sign.
  v_type := case v_row.type_code
    when '01' then 'bill'
    when '02' then 'purchase_credit_note'
    when '03' then 'purchase_debit_note'
    else null
  end::app.purchase_doc_type;
  if v_type is null then
    raise exception
      'e-Invoice type % has no purchase document to become', coalesce(v_row.type_code, '(none)')
      using errcode = '22023';
  end if;

  if v_row.currency is null
     or not exists (select 1 from public.ref_currencies where code = v_row.currency)
  then
    raise exception 'Currency % is not one this company knows',
      coalesce(v_row.currency, '(none)') using errcode = '22023';
  end if;

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, contact_id,
    supplier_doc_no, supplier_doc_date,
    currency, exchange_rate,
    -- The line discounts are already on the lines. A document-level
    -- discount here would take them off twice.
    discount_amount,
    -- A charge stated only at document level has nowhere else to land,
    -- and the parser does not read line-level charges at all, so this
    -- is where that money is restored.
    shipping_amount,
    status, einvoice_status, notes, created_by)
  values (
    v_row.org_id, v_type,
    app.next_document_number_internal(v_row.org_id, v_type::text),
    -- `app.today()` and not `current_date`: the caller's session zone
    -- decides what `current_date` is, and a bill dated by whoever
    -- happened to press the button is a bill in the wrong period.
    coalesce(v_row.issue_date, app.today()),
    v_row.contact_id,
    v_row.doc_no, v_row.issue_date,
    v_row.currency, v_row.exchange_rate,
    0,
    v_row.total_charges,
    'draft', 'not_applicable',
    case when v_row.myinvois_uuid is not null
      then 'From e-Invoice ' || v_row.myinvois_uuid end,
    auth.uid())
  returning id into v_bill;

  for v_line in
    select * from public.received_einvoice_lines
     where received_id = p_id order by line_no
  loop
    select code into v_class from public.ref_classification_codes
     where code = v_line.classification_code;
    select code into v_uom from public.ref_uom_codes
     where code = v_line.uom_code;

    insert into public.purchase_document_lines (
      org_id, document_id, line_no, line_type,
      description, classification_code,
      quantity, uom_code, unit_price,
      discount_amount, tax_rate, is_tax_inclusive)
    values (
      v_row.org_id, v_bill, v_line.line_no, 'item',
      v_line.description, v_class,
      v_line.quantity, v_uom, v_line.unit_price,
      v_line.discount_amount, v_line.tax_rate, false);
  end loop;

  -- The triggers have recomputed the bill by our rules. Whether that
  -- agrees with what the supplier asked for is a separate question, and
  -- it is the one somebody paying this needs answered.
  select total_amount into v_total from public.purchase_documents where id = v_bill;
  v_diff := round(v_total - v_row.payable_amount, 2);
  if abs(v_diff) > 0.005 then
    v_note := format(
      'This bill totals %s but the e-Invoice states %s payable, a difference of %s. '
      'The bill is calculated from the lines; check the line the supplier rounded.',
      to_char(v_total, 'FM999999999990.00'),
      to_char(v_row.payable_amount, 'FM999999999990.00'),
      to_char(v_diff, 'FM999999999990.00'));
    update public.purchase_documents set internal_notes = v_note where id = v_bill;
  end if;

  update public.received_einvoices
     set bill_id = v_bill, status = 'billed'
   where id = p_id;

  return v_bill;
end;
$function$;

-- create_po_from_suggestions
CREATE OR REPLACE FUNCTION public.create_po_from_suggestions(p_org uuid, p_lines jsonb DEFAULT NULL::jsonb, p_expected_date date DEFAULT NULL::date, p_warehouse uuid DEFAULT NULL::uuid)
 RETURNS TABLE(document_id uuid, doc_no text, supplier_id uuid, supplier_name text, line_count integer, total_quantity numeric, note text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_run       uuid;
  v_sup       record;
  v_row       record;
  v_doc       uuid;
  v_no        text;
  v_line_no   integer;
  v_price     numeric;
  v_tax_code  uuid;
  v_tax_rate  numeric;
  v_currency  char(3);
  v_rate      numeric;
  v_qty       numeric;
  v_expected  date;
  v_orphans   text[];
  v_orphan_q  numeric;
begin
  if not app.can_read_module(p_org, 'forecasting') then
    raise exception 'not permitted to read forecasting for this organization'
      using errcode = '42501';
  end if;

  -- Raising a purchase order is a purchasing act, whoever asked for it.
  -- A forecasting licence is not a licence to commit the company to
  -- buying something.
  if not app.can_write_module(p_org, 'purchases') then
    raise exception 'not permitted to raise purchase orders for this organization'
      using errcode = '42501';
  end if;
  perform app.require_side(p_org, 'purchases');

  select r.id into v_run
    from public.forecast_runs r
   where r.org_id = p_org
     and r.warehouse_id is not distinct from p_warehouse
   order by r.run_at desc
   limit 1;

  if v_run is null then
    raise exception
      'No forecast has been run for this organization and location yet.'
      using errcode = 'P0002';
  end if;

  for v_sup in
    select w.supplier_id as sup, c.name as sup_name,
           coalesce(c.currency, 'MYR')::char(3) as sup_currency,
           c.payment_term_id as sup_term, max(w.lead_time_days) as max_lead
      from app.forecast_wanted(p_org, v_run, p_lines) w
      join public.contacts c on c.id = w.supplier_id
     group by w.supplier_id, c.name, c.currency, c.payment_term_id
     order by c.name
  loop
    v_currency := v_sup.sup_currency;

    -- A foreign supplier with no rate on file is that supplier's
    -- problem, not the whole replenishment's. Their order is left out
    -- with a reason rather than aborting the orders that can be raised.
    begin
      v_rate := app.exchange_rate_for(p_org, v_currency, app.today());
    exception
      when sqlstate 'P0002' or sqlstate '23514' then
        v_rate := null;
    end;

    if v_rate is null then
      select count(*), coalesce(sum(w.want), 0)
        into line_count, total_quantity
        from app.forecast_wanted(p_org, v_run, p_lines) w
       where w.supplier_id = v_sup.sup;
      document_id := null;
      doc_no := null;
      supplier_id := v_sup.sup;
      supplier_name := v_sup.sup_name;
      note := format('No exchange rate for %s on or before today, so no '
                     'order was raised. Enter one and try again.', v_currency);
      return next;
      continue;
    end if;

    -- Far enough out to be there when it is needed: the longest lead
    -- time on the order, because the document carries one date and the
    -- slowest line sets it.
    v_expected := coalesce(p_expected_date,
                           app.today() + ceil(v_sup.max_lead)::integer);

    v_no := app.next_document_number_internal(p_org, 'purchase_order');

    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, expected_date, contact_id,
      payment_term_id, currency, exchange_rate, status, created_by,
      internal_notes)
    values (
      p_org, 'purchase_order', v_no, app.today(), v_expected, v_sup.sup,
      v_sup.sup_term, v_currency, v_rate, 'draft', auth.uid(),
      'Raised from the inventory forecast of ' || app.today()::text)
    returning id into v_doc;

    v_line_no := 0;
    v_qty     := 0;

    for v_row in
      select w.*
        from app.forecast_wanted(p_org, v_run, p_lines) w
       where w.supplier_id = v_sup.sup
       order by w.item_code
    loop
      -- What this was last bought for: from this supplier by preference,
      -- and in this order's currency, because a price in another
      -- currency is not a price. Falls back to the item's cost.
      select l.unit_price into v_price
        from public.purchase_document_lines l
        join public.purchase_documents d on d.id = l.document_id
       where l.org_id = p_org
         and l.item_id = v_row.item_id
         and d.doc_type in ('bill', 'purchase_order')
         and d.status <> 'void'
         and d.deleted_at is null
         and d.currency = v_currency
       order by (d.contact_id = v_sup.sup) desc,
                d.doc_date desc, d.created_at desc
       limit 1;

      v_price := coalesce(v_price, v_row.cost_price, 0);

      v_tax_code := v_row.purchase_tax_code_id;
      v_tax_rate := 0;
      if v_tax_code is not null then
        select t.rate into v_tax_rate
          from public.tax_codes t
         where t.id = v_tax_code and t.is_active;
        if v_tax_rate is null then
          -- Deactivated since the item was set up. Ordering with no tax
          -- is better than ordering at a rate nobody can charge.
          v_tax_code := null;
          v_tax_rate := 0;
        end if;
      end if;

      v_line_no := v_line_no + 1;
      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price,
        tax_code_id, tax_rate, warehouse_id, forecast_line_id)
      values (
        p_org, v_doc, v_line_no, 'item', v_row.item_id, v_row.item_name,
        v_row.classification_code, v_row.want, v_row.uom_code, v_price,
        v_tax_code, v_tax_rate, v_row.warehouse_id, v_row.line_id);

      v_qty := v_qty + v_row.want;
    end loop;

    document_id := v_doc;
    doc_no := v_no;
    supplier_id := v_sup.sup;
    supplier_name := v_sup.sup_name;
    line_count := v_line_no;
    total_quantity := v_qty;
    note := null;
    return next;
  end loop;

  -- And the ones nobody can be asked to supply.
  select array_agg(w.item_code order by w.item_code), coalesce(sum(w.want), 0)
    into v_orphans, v_orphan_q
    from app.forecast_wanted(p_org, v_run, p_lines) w
   where w.supplier_id is null;

  if coalesce(array_length(v_orphans, 1), 0) > 0 then
    document_id := null;
    doc_no := null;
    supplier_id := null;
    supplier_name := null;
    line_count := array_length(v_orphans, 1);
    total_quantity := v_orphan_q;
    note := format(
      '%s item(s) have no supplier and were not ordered: %s. Set a '
      'preferred supplier on the item, or a supplier in its forecast '
      'parameters.',
      array_length(v_orphans, 1), array_to_string(v_orphans, ', '));
    return next;
  end if;

  return;
end;
$function$;

-- accept_intercompany_bill
CREATE OR REPLACE FUNCTION public.accept_intercompany_bill(p_sales_document_id uuid, p_org_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row record;
  v_bill uuid;
  v_supplier uuid;
begin
  if not app.can_write(p_org_id) then
    raise exception 'You cannot raise bills in this company'
      using errcode = '42501';
  end if;
  perform app.require_side(p_org_id, 'purchases');

  -- Read it back through the inbox rather than from the table, so the
  -- addressing rule is written once and cannot drift between what a
  -- person may see and what they may act on.
  select * into v_row from public.intercompany_inbox(p_org_id) i
   where i.sales_document_id = p_sales_document_id;

  -- FOUND rather than `v_row is null`: a record is null only when every
  -- column is, which is true here but by accident rather than by rule.
  if not found then
    raise exception
      'That invoice is not addressed to this company, or has not been '
      'posted yet' using errcode = '42501';
  end if;

  if v_row.already_billed then
    raise exception 'That invoice has already been billed here';
  end if;

  if v_row.supplier_contact_id is null then
    raise exception
      'Add a supplier in this company linked to %, then try again. A bill '
      'has to be owed to somebody on this company''s own books.',
      v_row.from_org;
  end if;
  v_supplier := v_row.supplier_contact_id;

  insert into public.purchase_documents (
    org_id, doc_type, doc_no, doc_date, due_date, payment_term_id,
    contact_id,
    supplier_doc_no, supplier_doc_date,
    currency, exchange_rate,
    subtotal, discount_amount, tax_amount, total_amount, base_total_amount,
    balance_amount, status, source_sales_document_id,
    -- 0759. Carried like every other figure on the invoice.
    shipping_amount)
  select p_org_id, 'bill',
         app.next_document_number_internal(p_org_id, 'bill'),
         d.doc_date,
         -- 0439. Copied, like every other figure on this line. Without
         -- it the bill lands with no due date and `report_ap_aging`
         -- ages it from `doc_date`, so the group shows itself in
         -- arrears for the whole of the credit period it agreed.
         d.due_date, d.payment_term_id, v_supplier,
         -- Their number on our bill, which is what an SST audit and a
         -- self-billed e-Invoice both ask for.
         d.doc_no, d.doc_date,
         d.currency, d.exchange_rate,
         d.subtotal, d.discount_amount, d.tax_amount, d.total_amount,
         d.base_total_amount, d.total_amount, 'draft', d.id,
         -- 0759. Without it the line inserts below recompute the total
         -- without the delivery charge, and the bill owes less than the
         -- invoice says it does.
         d.shipping_amount
    from public.sales_documents d
   where d.id = p_sales_document_id
  returning id into v_bill;

  insert into public.purchase_document_lines (
    org_id, document_id, line_no, line_type, description,
    quantity, uom_code, unit_price,
    discount_percent, discount_amount,
    tax_code_id, tax_rate, tax_amount, is_tax_inclusive,
    line_subtotal, line_total)
  select p_org_id, v_bill, l.line_no, l.line_type, l.description,
         l.quantity, l.uom_code, l.unit_price,
         l.discount_percent, l.discount_amount,
         -- Matched by code, not by id: the two companies have their own
         -- tax_codes rows, and an id from theirs would point at nothing
         -- here — or, worse, at one of ours by coincidence.
         (select t.id from public.tax_codes t
           where t.org_id = p_org_id
             and t.code = (select s.code from public.tax_codes s
                            where s.id = l.tax_code_id)),
         l.tax_rate, l.tax_amount, l.is_tax_inclusive,
         l.line_subtotal, l.line_total
    from public.sales_document_lines l
   where l.document_id = p_sales_document_id
   order by l.line_no;

  -- Deliberately not copied: `item_id` and `account_id`. Both are ids in
  -- the issuer's own masters. Which of our items this is, and which
  -- expense account it belongs in, are decisions for this company —
  -- which is why the bill arrives as a draft rather than posted.
  return v_bill;
end; $function$;

-- transfer_document
CREATE OR REPLACE FUNCTION public.transfer_document(p_source_id uuid, p_target_type text, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sales      public.sales_documents;
  v_purchase   public.purchase_documents;
  v_is_sales   boolean;
  v_org        uuid;
  v_source_type text;
  v_counter    text;
  v_new_id     uuid;
  v_doc_no     text;
  v_due        date;
  v_term_id    uuid;
  v_term_days  integer;
  v_no         integer := 0;
  v_want       numeric(18, 4);
  v_left       numeric(18, 4);
  v_share      numeric(18, 8);
  v_src_net    numeric(18, 2);
  v_new_net    numeric(18, 2);
  -- 0646. What an approval rule would be about, if one covered this.
  v_kind       app.approval_entity;
  v_amount     numeric(18, 2);
  -- 0478. Who the new document is made out to, and their rows.
  v_holder     public.contacts;
  v_contact    uuid;
  v_person     uuid;
  v_address    uuid;
  r            record;
begin
  select * into v_sales from public.sales_documents where id = p_source_id;
  v_is_sales := found;

  if v_is_sales then
    v_org := v_sales.org_id;
    v_source_type := v_sales.doc_type::text;
    if v_sales.deleted_at is not null or v_sales.status = 'void' then
      raise exception 'Document % has been voided', v_sales.doc_no
        using errcode = '23514';
    end if;
  else
    select * into v_purchase from public.purchase_documents where id = p_source_id;
    if not found then
      raise exception 'Document % not found', p_source_id using errcode = 'P0002';
    end if;
    v_org := v_purchase.org_id;
    v_source_type := v_purchase.doc_type::text;
    if v_purchase.deleted_at is not null or v_purchase.status = 'void' then
      raise exception 'Document % has been voided', v_purchase.doc_no
        using errcode = '23514';
    end if;
  end if;

  if not app.can_write(v_org) then
    raise exception 'Insufficient privileges to transfer' using errcode = '42501';
  end if;
  perform app.require_side(v_org, case when v_is_sales then 'sales' else 'purchases' end);

  -- 0646. An approval rule that nothing consulted.
  --
  -- `app.refuse_unapproved_posting` is the only place an approval
  -- decision was ever read, and it fires on the transition into
  -- `posted`. SEVEN of the fifteen document types never post --
  -- quotation, proforma, sales order, delivery order, purchase
  -- requisition, purchase order, purchase return -- and the rule
  -- editor offers every one of them. So a company could set "purchase
  -- orders over ten thousand need the owner", save it, watch it appear
  -- in the list, submit an order for approval, have somebody approve
  -- it -- and the answer was written to a table nothing asked.
  --
  -- The transfer is where a document that does not post becomes an
  -- act: a requisition becomes an order, an order becomes goods
  -- received, a quotation becomes a sale. So the decision is read here
  -- too, with the same two functions the posting trigger uses, and a
  -- rule means the same thing whichever kind of document carries it.
  --
  -- On the SOURCE, not the target. The thing being authorised is
  -- acting on this document; a requisition is approved and then
  -- becomes an order, which is the order procurement is done in
  -- everywhere. The target gets its own gate at posting if it posts.
  --
  -- It inherits `app.approval_required`'s fail-open on the module, for
  -- the reason `approvals.sql` sets out at length: a company whose
  -- add-on lapsed must not be left holding documents it cannot move
  -- and no screen to release them.
  v_kind := case when v_is_sales then 'sales_document'
                 else 'purchase_document' end;
  v_amount := case when v_is_sales then v_sales.total_amount
                   else v_purchase.total_amount end;
  if app.approval_required(v_org, v_kind, v_source_type, v_amount)
     and not app.is_approved(v_org, v_kind, p_source_id) then
    raise exception
      '% needs approving before it can be turned into a %. Send it for '
      'approval first.',
      case when v_is_sales then v_sales.doc_no else v_purchase.doc_no end,
      replace(p_target_type, '_', ' ')
      using errcode = '42501';
  end if;

  -- 0374. A price that ran out. A quotation and a proforma are both
  -- offers with a date on them, and turning one into an order or an
  -- invoice after that date charges last quarter's price for this
  -- quarter's work — quietly, because every downstream figure agrees
  -- with it. Refused rather than warned: honouring an expired quote is
  -- a decision somebody makes, and `extend_document_validity` is where
  -- they make it and where it is recorded.
  if v_is_sales
     and v_sales.doc_type in ('quotation', 'proforma')
     and v_sales.valid_until is not null
     and v_sales.valid_until < app.today() then
    raise exception
      '% was only valid until %. Extend it, or raise a new one at '
      'today''s prices.', v_sales.doc_no, to_char(v_sales.valid_until, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  -- Raises on a transition that is not part of either cycle.
  v_counter := app.transfer_counter(v_source_type, p_target_type);

  -- 0478. The offer was made to a prospect; the sale is the customer
  -- record's. Resolved before anything is written.
  if v_is_sales then
    v_contact := v_sales.contact_id;
    v_person  := v_sales.contact_person_id;
    v_address := v_sales.shipping_address_id;

    select * into v_holder from public.contacts where id = v_sales.contact_id;
    if v_holder.contact_type = 'prospect' then
      v_contact := app.customer_record_of(v_sales.contact_id);
      if v_contact is null then
        raise exception
          '% is a prospect. Create a Customer record for them first; '
          'the % is then made out to it.',
          v_holder.name,
          replace(p_target_type, '_', ' ')
          using errcode = '23514',
                hint = 'Open the prospect, then Records, then '
                       '"Create a Customer record".';
      end if;

      -- The same person and the same door, on the customer record's
      -- own rows; empty where there is no such row, never the
      -- prospect's.
      select p2.id into v_person
        from public.contact_persons p1
        join public.contact_persons p2
          on p2.contact_id = v_contact
         and p2.name = p1.name
         and coalesce(p2.email, '') = coalesce(p1.email, '')
       where p1.id = v_sales.contact_person_id
       order by p2.is_primary desc, p2.created_at
       limit 1;
      if not found then v_person := null; end if;

      select a2.id into v_address
        from public.contact_addresses a1
        join public.contact_addresses a2
          on a2.contact_id = v_contact
         and a2.label = a1.label
         and coalesce(a2.address_line1, '') = coalesce(a1.address_line1, '')
         and coalesce(a2.postcode, '') = coalesce(a1.postcode, '')
       where a1.id = v_sales.shipping_address_id
       order by a2.is_default desc, a2.created_at
       limit 1;
      if not found then v_address := null; end if;
    end if;
  end if;

  v_doc_no := app.next_document_number_internal(v_org, p_target_type);

  -- A document that will be settled needs a due date; ageing is built on
  -- it and a null there quietly parks the debt in "not yet due" forever.
  if p_target_type in ('invoice', 'bill') then
    v_term_id := case when v_is_sales then v_sales.payment_term_id
                      else v_purchase.payment_term_id end;
    if v_term_id is not null then
      select days into v_term_days from public.payment_terms where id = v_term_id;
    end if;
    v_due := app.today() + coalesce(v_term_days, 30);
  end if;

  if v_is_sales then
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, shipping_address_id, reference, subject, parent_id,
      payment_term_id, currency, exchange_rate, salesperson_id,
      opportunity_id, matter_id, branch_id, notes, terms_conditions, status,
      created_by, delivery_date
    ) values (
      v_org, p_target_type::app.sales_doc_type, v_doc_no, app.today(), v_due,
      v_contact, v_person, v_address,
      v_sales.reference, v_sales.subject, v_sales.id,
      v_sales.payment_term_id, v_sales.currency, v_sales.exchange_rate,
      v_sales.salesperson_id, v_sales.opportunity_id, v_sales.matter_id,
      -- Which branch quoted it is which branch invoices it. An amount
      -- can be split across two invoices; a branch cannot, so this
      -- carries whole.
      v_sales.branch_id,
      v_sales.notes, v_sales.terms_conditions, 'draft', auth.uid(),
      -- 0374. The date promised on the quotation is the date promised on
      -- the order, and on the delivery order raised from it. Dropping it
      -- at each step is how a promise becomes nobody's.
      case when p_target_type in ('sales_order', 'delivery_order')
           then v_sales.delivery_date end
    ) returning id into v_new_id;

    for r in
      select l.*,
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id) as asked
        from public.sales_document_lines l
       where l.document_id = p_source_id
       order by l.line_no
    loop
      v_left := r.quantity - case v_counter
        when 'quantity_invoiced' then r.quantity_invoiced
        else r.quantity_fulfilled end;

      v_want := case when p_lines is null then greatest(v_left, 0)
                     else coalesce(r.asked, 0) end;
      if v_want <= 0 then continue; end if;

      if v_want > v_left then
        raise exception
          'Line % has % outstanding; % was asked for.',
          r.line_no, v_left, v_want using errcode = '23514';
      end if;

      v_no := v_no + 1;
      insert into public.sales_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price, discount_percent,
        discount_amount, tax_code_id, tax_rate, is_tax_inclusive, warehouse_id,
        account_id, project_code, department_code, source_line_id,
        service_start, service_end
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        -- A cash discount is proportional to what is being taken, not
        -- carried whole onto a partial transfer.
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id,
        -- The period is a property of what was sold, not of the piece of
        -- paper it was first written on. Dropping it here would let a
        -- quoted twelve-month contract arrive at the invoice as income
        -- earned on the day, and nobody would see it go.
        r.service_start, r.service_end
      );
    end loop;

    -- The header amounts, on the same rule the line above states:
    -- proportional to what is being taken, not carried whole onto a
    -- partial transfer and not dropped on a whole one.
    --
    -- Before this they were not carried at all, so a quotation for
    -- RM1000 of goods with RM50 delivery and RM100 off the job was
    -- invoiced at RM1080 against RM1030 quoted: the customer was billed
    -- fifty ringgit more than the price they had agreed, because the
    -- discount went and the delivery went with it.
    --
    -- The share is measured on line value rather than on quantity,
    -- because two lines at different prices are not two equal halves of
    -- a delivery charge. It is taken against the *source's* total and
    -- not against what is left, so two half-transfers add back to one
    -- whole -- exactly the property the line-level proration has.
    v_src_net := coalesce(v_sales.subtotal, 0);
    select coalesce(subtotal, 0) into v_new_net
      from public.sales_documents where id = v_new_id;

    v_share := case
      -- A document whose lines come to nothing but which carries a
      -- delivery charge. There is no value to apportion by, so the
      -- only defensible answers are all of it on a whole transfer and
      -- none of it on a partial one.
      when v_src_net = 0 then case when p_lines is null then 1 else 0 end
      else v_new_net / v_src_net
    end;

    update public.sales_documents d
       set shipping_amount = round(coalesce(v_sales.shipping_amount, 0) * v_share, 2),
           discount_amount = round(coalesce(v_sales.discount_amount, 0) * v_share, 2),
           service_charge_amount =
             round(coalesce(v_sales.service_charge_amount, 0) * v_share, 2)
     where d.id = v_new_id;

    -- And then let the arithmetic be done by the one function that owns
    -- it. `app.recalc_sales_totals` is a trigger on the *lines*, so a
    -- header amount written after the last line is in the row and not
    -- in the total -- which is how the figures above came to disagree
    -- with each other in the first place. Touching a line re-runs it
    -- over the header this function has just finished writing.
    --
    -- Rather than either of the alternatives: computing the share
    -- before the header insert would mean writing the `v_want`
    -- expression a second time, where the two copies can drift apart
    -- silently; and setting `total_amount` here by hand would put this
    -- function in the business of arithmetic that belongs somewhere
    -- else, on a draft somebody is still going to edit.
    update public.sales_document_lines
       set line_no = line_no where document_id = v_new_id;
  else
    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      contact_person_id, reference, parent_id, payment_term_id,
      currency, exchange_rate, branch_id, notes, status, created_by
    ) values (
      v_org, p_target_type::app.purchase_doc_type, v_doc_no, app.today(), v_due,
      v_purchase.contact_id, v_purchase.contact_person_id,
      v_purchase.reference, v_purchase.id, v_purchase.payment_term_id,
      v_purchase.currency, v_purchase.exchange_rate, v_purchase.branch_id,
      v_purchase.notes, 'draft', auth.uid()
    ) returning id into v_new_id;

    for r in
      select l.*,
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id) as asked
        from public.purchase_document_lines l
       where l.document_id = p_source_id
       order by l.line_no
    loop
      v_left := r.quantity - case v_counter
        when 'quantity_billed' then r.quantity_billed
        else r.quantity_received end;

      v_want := case when p_lines is null then greatest(v_left, 0)
                     else coalesce(r.asked, 0) end;
      if v_want <= 0 then continue; end if;

      if v_want > v_left then
        raise exception
          'Line % has % outstanding; % was asked for.',
          r.line_no, v_left, v_want using errcode = '23514';
      end if;

      v_no := v_no + 1;
      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price, discount_percent,
        discount_amount, tax_code_id, tax_rate, is_tax_inclusive, warehouse_id,
        account_id, project_code, department_code, source_line_id
      ) values (
        v_org, v_new_id, v_no, r.line_type, r.item_id, r.description,
        r.classification_code, v_want, r.uom_code, r.unit_price,
        r.discount_percent,
        case when r.quantity = 0 then 0
             else round(r.discount_amount * v_want / r.quantity, 2) end,
        r.tax_code_id, r.tax_rate, r.is_tax_inclusive, r.warehouse_id,
        r.account_id, r.project_code, r.department_code, r.id
      );
    end loop;

    -- The same on the buying side. A purchase order with carriage on it
    -- part-received and part-billed would otherwise be billed for the
    -- goods and never for the carriage. There is no service charge on a
    -- purchase document: a supplier's is a line on their bill.
    v_src_net := coalesce(v_purchase.subtotal, 0);
    select coalesce(subtotal, 0) into v_new_net
      from public.purchase_documents where id = v_new_id;

    v_share := case
      when v_src_net = 0 then case when p_lines is null then 1 else 0 end
      else v_new_net / v_src_net
    end;

    update public.purchase_documents d
       set shipping_amount = round(coalesce(v_purchase.shipping_amount, 0) * v_share, 2),
           discount_amount = round(coalesce(v_purchase.discount_amount, 0) * v_share, 2)
     where d.id = v_new_id;

    -- The same touch, for the same reason.
    update public.purchase_document_lines
       set line_no = line_no where document_id = v_new_id;
  end if;

  if v_no = 0 then
    -- Nothing was left to take. The empty document is rolled back rather
    -- than left behind, because a stray zero-line draft in the numbering
    -- sequence is a document somebody has to explain later.
    raise exception
      'Nothing left to transfer — every line has already been taken forward.'
      using errcode = '23514';
  end if;

  return v_new_id;
end;
$function$;
