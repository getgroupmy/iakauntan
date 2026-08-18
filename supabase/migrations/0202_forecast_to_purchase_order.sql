-- The suggestion becomes an order, or it was a chart.
--
-- 0200 works out what to buy. Everything up to here is a number on a
-- screen, and a replenishment report whose output is retyped into a
-- purchase order is a report nobody keeps using past the second week.
-- This turns the run into drafts.
--
-- ## One order per supplier, which is what a purchase order is
--
-- A run suggests across the whole catalogue; an order goes to one
-- supplier. So the suggestions are grouped by supplier and each group
-- becomes its own document, numbered from the same sequence a
-- hand-typed order uses.
--
-- Items with no supplier cannot be ordered and are not silently
-- dropped: they come back as the last row of the result with a null
-- document, naming the codes. Refusing the whole batch for one
-- unassigned item would be worse — twenty-nine orderable items should
-- not wait on the thirtieth — but so would saying nothing, which is how
-- an item quietly stops being reordered.
--
-- ## Draft, and why that needs a second counter
--
-- What comes out is a draft. Nobody should discover that a forecast
-- emailed an order to a supplier.
--
-- But `app.quantity_on_order` deliberately excludes drafts — nobody has
-- committed to a draft, and counting one as stock on the way is how a
-- report stops asking for something that was never actually ordered.
-- Correct for the reorder point, and it leaves a hole here: raise the
-- drafts, re-run the forecast, and every item is suggested all over
-- again because nothing about the position changed.
--
-- So there are two counters over the same table and their statuses do
-- not overlap:
--
--   app.quantity_on_order        pending, approved, posted, partial
--                                -> `available`, the arithmetic
--   app.quantity_on_draft_order  draft
--                                -> netted off the suggestion
--
-- Every live purchase order line is counted by exactly one of them, so
-- nothing is missed and nothing is subtracted twice. Approving a draft
-- moves it from the second to the first in the same instant.
--
-- The draft counter does not care who typed the draft. A buyer who has
-- already drafted an order for the same item has done the thing the
-- suggestion is asking for, and the module should not ask again because
-- it was not the author.
--
-- ## Progress is derived here too
--
-- Nothing is written back to `forecast_lines` to record that an order
-- was raised. The quantity outstanding is computed from the purchase
-- orders that exist right now, so deleting a draft returns its
-- suggestion to the list with no correction step — the same reasoning
-- 0081 gives for deriving transfer progress rather than accumulating
-- it. A flag on the forecast line would still claim the stock was on
-- order after somebody deleted the order.
--
-- `forecast_line_id` on the purchase line is therefore provenance, not
-- bookkeeping: it answers "why did we order four hundred of these in
-- March" nine months later, which is the same question the whole module
-- is built around.

-- ---------------------------------------------------------------------
-- Where an ordered line came from
-- ---------------------------------------------------------------------
alter table public.purchase_document_lines
  add column if not exists forecast_line_id uuid
    references public.forecast_lines (id) on delete set null;

create index if not exists purchase_document_lines_forecast_idx
  on public.purchase_document_lines (forecast_line_id)
  where forecast_line_id is not null;

comment on column public.purchase_document_lines.forecast_line_id is
  'The forecast line this quantity was suggested by, or null if a human '
  'typed it. Provenance only — nothing reads it to decide what is still '
  'to be ordered, because a link cannot be trusted to disappear when the '
  'document does.';

-- ---------------------------------------------------------------------
-- What is drafted but not committed
-- ---------------------------------------------------------------------
create or replace function app.quantity_on_draft_order(
  p_org uuid, p_item uuid, p_warehouse uuid default null)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  -- Exactly the statuses app.quantity_on_order leaves out, so the two
  -- partition the live orders between them rather than overlapping.
  select coalesce(sum(greatest(l.quantity - coalesce(l.quantity_received, 0), 0)), 0)
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
   where l.org_id = p_org
     and l.item_id = p_item
     and d.doc_type = 'purchase_order'
     and d.status = 'draft'
     and d.deleted_at is null
     and (p_warehouse is null or l.warehouse_id = p_warehouse);
$$;

grant execute on function app.quantity_on_draft_order(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What the latest run says to order, and what is left of it
-- ---------------------------------------------------------------------
--
-- Replaces the `setof forecast_lines` version from 0200. That shape
-- forced every caller to join items and contacts back on to render a
-- row, and had nowhere to say that an order had already been raised.
--
-- Fully-drafted suggestions stay in the list with `outstanding` at
-- zero rather than vanishing, for the reason 0146 keeps a billed
-- intercompany invoice in the inbox: somebody looking for the item
-- should find it and see that it was dealt with, not find nothing and
-- wonder.
drop function if exists public.forecast_suggestions(uuid);

create function public.forecast_suggestions(p_org uuid)
returns table (
  line_id           uuid,
  item_id           uuid,
  item_code         text,
  item_name         text,
  uom_code          text,
  warehouse_id      uuid,
  state             app.replenishment_state,
  on_hand           numeric,
  reserved          numeric,
  on_order          numeric,
  available         numeric,
  mean_daily_demand numeric,
  lead_time_days    numeric,
  lead_time_source  text,
  safety_stock      numeric,
  reorder_point     numeric,
  days_cover        numeric,
  stockout_on       date,
  suggested_qty     numeric,
  already_drafted   numeric,
  outstanding       numeric,
  supplier_id       uuid,
  supplier_name     text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, l.item_id, i.code, i.name, i.uom_code, l.warehouse_id, l.state,
         l.on_hand, l.reserved, l.on_order, l.available,
         l.mean_daily_demand, l.lead_time_days, l.lead_time_source,
         l.safety_stock, l.reorder_point, l.days_cover, l.stockout_on,
         l.suggested_qty,
         app.quantity_on_draft_order(l.org_id, l.item_id, l.warehouse_id),
         greatest(l.suggested_qty
                  - app.quantity_on_draft_order(l.org_id, l.item_id, l.warehouse_id), 0),
         l.supplier_id, c.name
    from public.forecast_lines l
    join public.items i on i.id = l.item_id
    left join public.contacts c on c.id = l.supplier_id
   where l.org_id = p_org
     and app.can_read_module(p_org, 'forecasting')
     and l.run_id = (select r.id from public.forecast_runs r
                      where r.org_id = p_org
                      order by r.run_at desc limit 1)
     and l.suggested_qty > 0
   order by array_position(
     array['stocked_out','below_safety','order_now','order_soon','ok','overstocked']
       ::text[], l.state::text),
     l.days_cover nulls last,
     i.code;
$$;

grant execute on function public.forecast_suggestions(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What is actually going to be ordered
-- ---------------------------------------------------------------------
--
-- Pulled out of the function below rather than written inline, because
-- three things need the same set — the suppliers to raise orders for,
-- the lines to put on each one, and the items that have no supplier at
-- all — and a predicate this load-bearing copied three times is a
-- predicate that will be corrected in two of them.
--
-- `p_lines` is `[{"line_id": uuid, "quantity": number}, ...]`; null
-- means every suggestion on the run.
--
-- A quantity given there is the total wanted on order against that
-- suggestion, not an amount to add to it. Submitting the same screen
-- twice therefore asks for nothing the second time, which is what a
-- double tap deserves, and a buyer who types 20 against a suggestion of
-- 12 gets 20 — the number they decided on, not 32.
create or replace function app.forecast_wanted(
  p_org   uuid,
  p_run   uuid,
  p_lines jsonb default null)
returns table (
  line_id             uuid,
  item_id             uuid,
  warehouse_id        uuid,
  supplier_id         uuid,
  item_code           text,
  item_name           text,
  uom_code            text,
  classification_code text,
  purchase_tax_code_id uuid,
  cost_price          numeric,
  lead_time_days      numeric,
  want                numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, l.item_id, l.warehouse_id, l.supplier_id,
         i.code, i.name, i.uom_code, i.classification_code,
         i.purchase_tax_code_id, i.cost_price, l.lead_time_days,
         greatest(
           coalesce(
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id),
             l.suggested_qty)
           - app.quantity_on_draft_order(l.org_id, l.item_id, l.warehouse_id),
           0)
    from public.forecast_lines l
    join public.items i on i.id = l.item_id
   where l.org_id = p_org
     and l.run_id = p_run
     and l.suggested_qty > 0
     and (p_lines is null
          or exists (select 1
                       from jsonb_array_elements(p_lines) e
                      where (e ->> 'line_id')::uuid = l.id))
     and greatest(
           coalesce(
             (select (e ->> 'quantity')::numeric
                from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
               where (e ->> 'line_id')::uuid = l.id),
             l.suggested_qty)
           - app.quantity_on_draft_order(l.org_id, l.item_id, l.warehouse_id),
           0) > 0;
$$;

revoke all on function app.forecast_wanted(uuid, uuid, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The orders
-- ---------------------------------------------------------------------
create or replace function public.create_po_from_suggestions(
  p_org           uuid,
  p_lines         jsonb default null,
  p_expected_date date default null)
returns table (
  document_id    uuid,
  doc_no         text,
  supplier_id    uuid,
  supplier_name  text,
  line_count     integer,
  total_quantity numeric,
  note           text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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

  select r.id into v_run
    from public.forecast_runs r
   where r.org_id = p_org
   order by r.run_at desc
   limit 1;

  if v_run is null then
    raise exception 'No forecast has been run for this organization yet.'
      using errcode = 'P0002';
  end if;

  for v_sup in
    select w.supplier_id as sup, c.name as sup_name,
           coalesce(c.currency, 'MYR')::char(3) as sup_currency,
           c.payment_term_id as sup_term,
           max(w.lead_time_days) as max_lead
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
      v_rate := app.exchange_rate_for(p_org, v_currency, current_date);
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
                           current_date + ceil(v_sup.max_lead)::integer);

    v_no := app.next_document_number_internal(p_org, 'purchase_order');

    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, expected_date, contact_id,
      payment_term_id, currency, exchange_rate, status, created_by,
      internal_notes)
    values (
      p_org, 'purchase_order', v_no, current_date, v_expected, v_sup.sup,
      v_sup.sup_term, v_currency, v_rate, 'draft', auth.uid(),
      'Raised from the inventory forecast of ' || current_date::text)
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
$$;

revoke all on function public.create_po_from_suggestions(uuid, jsonb, date)
  from public, anon;
grant execute on function public.create_po_from_suggestions(uuid, jsonb, date)
  to authenticated;

comment on function app.quantity_on_draft_order(uuid, uuid, uuid) is
  'Quantity on purchase orders still in draft — exactly the statuses '
  'app.quantity_on_order excludes, so between them every live order line '
  'is counted once. Netted off a suggestion so that raising the drafts '
  'and re-running the forecast does not order everything twice.';

comment on function app.forecast_wanted(uuid, uuid, jsonb) is
  'The suggestions still to be ordered, net of any draft order already '
  'raised. A quantity in p_lines is the total wanted against that '
  'suggestion, not an amount to add to it.';

comment on function public.create_po_from_suggestions(uuid, jsonb, date) is
  'Turns the latest run''s suggestions into one draft purchase order per '
  'supplier. Items with no supplier come back as a final row with a null '
  'document rather than being dropped, and a supplier whose currency has '
  'no rate on file comes back the same way rather than failing the batch.';

comment on function public.forecast_suggestions(uuid) is
  'What the latest run says to order, with the item and supplier named '
  'and any draft orders already raised netted off. Fully-drafted rows '
  'stay in the list at zero outstanding rather than vanishing, so an '
  'item that was dealt with can be found rather than merely absent.';
