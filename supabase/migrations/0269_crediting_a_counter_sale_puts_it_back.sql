-- =====================================================================
-- Crediting an invoice, and the ingredients that come back with it
--
-- 0264 takes a dish's ingredients out of the store when the bill is
-- settled, and its own header says the way back is a credit note,
-- because `void_pos_sale` refuses a settled bill. It then says, plainly,
-- that a credit note does not put the ingredients back: it returns the
-- stock of whatever the invoice moved, which for a dish is nothing.
--
-- So a warung that rings up two plates and credits one has 180 grams of
-- rice missing from its store and RM 4.70 of food cost charged against
-- a sale it did not make. Over a year of returns that is a real hole in
-- both the stock figure and the margin, and it is the kind of hole
-- nobody finds until they count the store by hand.
--
-- ---------------------------------------------------------------------
-- Except a credit note is not attached to anything
--
-- Building the return turned up the larger problem underneath it.
-- `sales_documents.original_invoice_id` has existed since 0005 and
-- **nothing has ever written it** -- checked across every migration, the
-- Dart and the edge functions. `transfer_document` cannot produce a
-- credit note either: 0081's allow-map has no arm from `invoice`. A
-- credit note is a document somebody types by hand in the generic
-- editor, and nothing records which invoice it credits.
--
-- That is worse than a missing feature. A credit note that names no
-- invoice cannot be capped at what was invoiced, cannot be reported
-- against the sale it reverses, and cannot tell a recipe which plates
-- came back. So this migration builds the link first and the return on
-- top of it, rather than adding a trigger that would never fire.
--
-- `credit_sales_invoice` copies the lines being credited, caps each at
-- what is left uncredited on that invoice, sets `original_invoice_id`,
-- and posts. Crediting more than was sold is refused rather than
-- rounded away: a credit note is a document about money, and it is not
-- authorisation to invent a return.
--
-- ---------------------------------------------------------------------
-- What comes back is what the credit note says, not a share of the money
--
-- A credit note carries its own lines: one nasi lemak, not "half the
-- value of the bill". Exploding those through the same recipe returns
-- exactly one plate's ingredients, which is both more accurate than a
-- value ratio and easier to explain to whoever is holding the stock
-- sheet. A credit for a discount rather than for food -- a line with no
-- item, or an item with no recipe -- returns nothing, which is correct:
-- no food came back.
--
-- ---------------------------------------------------------------------
-- At the price it left at
--
-- The rice went out at the weighted average of the moment it was
-- cooked. Putting it back at today's average would book a gain or a
-- loss on a plate nobody ate, and would do it every time the price of
-- rice moved. The unit cost is read off the original consumption
-- movement, exactly as 0265's transfer receipt reads its cost off its
-- own dispatch and for the same reason.
--
-- ---------------------------------------------------------------------
-- And never more than went out
--
-- Two credit notes against one bill must not put back rice the kitchen
-- never used. Every return is capped at what that sale consumed less
-- what has already come back, and a return with nothing left to give
-- does nothing.
--
-- ---------------------------------------------------------------------
-- To the batches it came from
--
-- 0267 sends a tracked ingredient out earliest-expiry-first and has no
-- arm for one coming back, so a batch-tracked ingredient would fail the
-- lot invariant here exactly as it failed everywhere else before 0267.
-- The return goes to the same batches the consumption took, most
-- recently taken first: the last thing out of the pot is the first
-- thing back into it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What this sale has already given back
-- ---------------------------------------------------------------------
create or replace function app.pos_recipe_returned(
  p_sale uuid, p_item uuid)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(sum(sm.quantity), 0)
    from public.stock_movements sm
   where sm.source_table = 'pos_sales'
     and sm.source_id = p_sale
     and sm.item_id = p_item
     and sm.quantity > 0;
$$;

revoke all on function app.pos_recipe_returned(uuid, uuid)
  from public, anon, authenticated;

-- And what it took in the first place.
create or replace function app.pos_recipe_consumed(
  p_sale uuid, p_item uuid)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(-sum(sm.quantity), 0)
    from public.stock_movements sm
   where sm.source_table = 'pos_sales'
     and sm.source_id = p_sale
     and sm.item_id = p_item
     and sm.quantity < 0;
$$;

revoke all on function app.pos_recipe_consumed(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Putting it back
-- ---------------------------------------------------------------------
create or replace function app.pos_return_recipes(
  p_sale   uuid,
  p_credit uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_doc    public.sales_documents;
  v_wh     uuid;
  v_row    record;
  v_qty    numeric;
  v_left   numeric;
  v_unit   numeric;
  v_cost   numeric := 0;
  v_moved  numeric;
  v_lines  jsonb;
  v_cogs   uuid;
  v_inv    uuid;
  v_entry  uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  select * into v_doc  from public.sales_documents where id = p_credit;
  if v_sale.id is null or v_doc.id is null then
    return null;
  end if;

  select coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = v_sale.org_id and w.is_default limit 1))
    into v_wh
    from public.pos_outlets o where o.id = v_sale.outlet_id;
  if v_wh is null then
    return null;
  end if;

  -- Already done. A credit note posted twice -- reversed and re-posted,
  -- say -- must not return the food twice.
  if exists (select 1 from public.stock_movements sm
              where sm.source_table = 'pos_sales'
                and sm.source_id = p_sale
                and sm.source_line_id = p_credit) then
    return null;
  end if;

  for v_row in
    select c.item_id, sum(c.quantity) as quantity, i.name
      from public.sales_document_lines l
      cross join lateral app.pos_recipe_components(l.item_id, l.quantity) c
      join public.items i on i.id = c.item_id
     where l.document_id = p_credit
       and l.line_type = 'item'
       and l.item_id is not null
       and l.quantity > 0
       and i.track_inventory
     group by c.item_id, i.name
  loop
    -- Never more than went out. See the header.
    v_left := app.pos_recipe_consumed(p_sale, v_row.item_id)
              - app.pos_recipe_returned(p_sale, v_row.item_id);
    v_qty  := least(round(v_row.quantity, 4), round(v_left, 4));
    if v_qty <= 0 then
      continue;
    end if;

    -- The price it left at, read off the movement that took it.
    select sm.unit_cost into v_unit
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.item_id = v_row.item_id and sm.quantity < 0
     order by sm.created_at limit 1;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id,
      source_line_id, notes, created_by)
    values (
      v_sale.org_id,
      app.next_document_number_internal(v_sale.org_id, 'stock_movement'),
      v_doc.doc_date, 'assembly_in', v_row.item_id, v_wh, v_qty,
      coalesce(v_unit, 0),
      'pos_sales', p_sale, p_credit,
      'Credited ' || v_doc.doc_no, auth.uid());

    select sm.total_cost into v_moved
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.source_line_id = p_credit and sm.item_id = v_row.item_id
     order by sm.created_at desc limit 1;

    v_cost := v_cost + coalesce(v_moved, 0);
  end loop;

  if round(v_cost, 2) = 0 then
    return null;
  end if;

  select a.id into v_cogs from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '5200';
  select a.id into v_inv from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '1310';
  if v_cogs is null or v_inv is null then
    return null;
  end if;

  -- The mirror of 0264's entry: stock back in, cost of sales released.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_inv,
      'description', 'Ingredients returned ' || v_doc.doc_no,
      'debit', round(v_cost, 2), 'credit', 0),
    jsonb_build_object('account_id', v_cogs,
      'description', 'Food cost credited ' || v_doc.doc_no,
      'debit', 0, 'credit', round(v_cost, 2)));

  v_entry := app.create_gl_entry_internal(
    v_sale.org_id, v_doc.doc_date, 'stock_movement', v_lines,
    'Recipe returned ' || v_doc.doc_no, 'pos_sales', p_sale);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'pos_sales' and sm.source_id = p_sale
     and sm.source_line_id = p_credit and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

revoke all on function app.pos_return_recipes(uuid, uuid)
  from public, anon, authenticated;

comment on function app.pos_return_recipes(uuid, uuid) is
  'Puts a credited counter sale''s ingredients back at the cost they left at, capped at what that sale consumed. Called by trigger when the credit note posts.';

-- ---------------------------------------------------------------------
-- Which fires when a credit note against a counter sale is posted
-- ---------------------------------------------------------------------
--
-- A trigger rather than a line inside `post_sales_document`, for 0264's
-- reason: this is a consequence of a credit note being posted, not a
-- step in working out its journal, and `post_sales_document` is a long
-- function that two migrations have already re-created.
--
-- Only `credit_note`. A `refund_note` is money going back over a credit
-- that already happened, and returning the food a second time on the
-- refund would double it.
create or replace function app.sales_credit_recipe_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_sale uuid;
begin
  if new.doc_type <> 'credit_note' then
    return new;
  end if;
  if new.status <> 'posted' or old.status is not distinct from 'posted' then
    return new;
  end if;
  if new.original_invoice_id is null then
    return new;
  end if;

  select s.id into v_sale from public.pos_sales s
   where s.invoice_id = new.original_invoice_id;
  if v_sale is null then
    return new;
  end if;

  perform app.pos_return_recipes(v_sale, new.id);
  return new;
end;
$$;

create trigger sales_credit_recipes
  after update of status on public.sales_documents
  for each row execute function app.sales_credit_recipe_trigger();

-- ---------------------------------------------------------------------
-- And the batches, which have no arm for something coming back
-- ---------------------------------------------------------------------
--
-- Replaced from 0267 -- the migration that last defined it, checked
-- rather than assumed, which is the mistake 0267 itself made and
-- `opening_stock.sql` caught. 0152's opening-balance arm and all of
-- 0267's are carried unchanged; the credit-note arm is the only
-- addition.
create or replace function app.materialise_movement_lots()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_track text;
  v_code  text;
  v_sign  numeric := sign(new.quantity);
  v_found integer := 0;
  r       record;
  v_lot   uuid;
  v_ref   text;
  v_exp   date;
  v_n     integer;
begin
  select i.tracking, i.code into v_track, v_code
    from public.items i where i.id = new.item_id;

  if v_track is null or v_track = 'none' then
    return null;
  end if;

  -- 0152's arm, kept. An opening balance has no document line to read
  -- lots from, so `import_opening_stock` writes them itself and this
  -- stands aside. Carried across explicitly rather than inherited: this
  -- function is being replaced from source, and a replacement built
  -- from 0106's copy would silently revert it -- which is exactly what
  -- the first draft of this migration did, and what `opening_stock.sql`
  -- caught.
  if new.source_table = 'opening_stock' then
    return null;
  end if;

  for r in
    select d.lot_ref, d.quantity, d.expiry_date, d.manufactured_on,
           d.supplier_lot_ref
      from public.document_line_lots d
     where new.source_line_id is not null
       and ((new.source_table = 'sales_documents'    and d.sales_line_id = new.source_line_id)
         or (new.source_table = 'purchase_documents' and d.purchase_line_id = new.source_line_id)
         or (new.source_table = 'stock_adjustments'  and d.adjustment_line_id = new.source_line_id))
  loop
    insert into public.stock_lots
      (org_id, item_id, lot_ref, kind, expiry_date, manufactured_on,
       supplier_lot_ref)
    values (new.org_id, new.item_id, r.lot_ref, v_track,
            r.expiry_date, r.manufactured_on, r.supplier_lot_ref)
    on conflict (org_id, item_id, lot_ref) do update
      set expiry_date      = coalesce(excluded.expiry_date, stock_lots.expiry_date),
          manufactured_on  = coalesce(excluded.manufactured_on,
                                      stock_lots.manufactured_on),
          supplier_lot_ref = coalesce(excluded.supplier_lot_ref,
                                      stock_lots.supplier_lot_ref),
          updated_at       = now()
    returning id into v_lot;

    insert into public.stock_movement_lots
      (org_id, movement_id, lot_id, quantity)
    values (new.org_id, new.id, v_lot, r.quantity * v_sign);

    v_found := v_found + 1;
  end loop;

  if v_found > 0 then
    return null;
  end if;

  -- ------------------------------------------------------------------
  -- A transfer arriving: the same batches its own van carried
  -- ------------------------------------------------------------------
  --
  -- Read off the dispatch rather than picked again, so a batch keeps
  -- its identity across the journey. A short delivery takes from those
  -- batches earliest-expiry first and stops when the count is met; what
  -- is left behind is the shortfall the receipt already wrote off.
  if new.source_table = 'stock_transfers' and new.quantity > 0
     and new.source_line_id is not null then
    declare v_left numeric := new.quantity;
    begin
      for r in
        select sml.lot_id, -sml.quantity as quantity
          from public.stock_movement_lots sml
          join public.stock_movements m on m.id = sml.movement_id
          join public.stock_lots l on l.id = sml.lot_id
         where m.source_table = 'stock_transfers'
           and m.source_line_id = new.source_line_id
           and m.quantity < 0
         order by l.expiry_date asc nulls last, l.lot_ref
      loop
        exit when v_left <= 0;
        insert into public.stock_movement_lots
          (org_id, movement_id, lot_id, quantity)
        values (new.org_id, new.id, r.lot_id, least(r.quantity, v_left));
        v_left  := v_left - least(r.quantity, v_left);
        v_found := v_found + 1;
      end loop;
    end;
    if v_found > 0 then
      return null;
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- A conversion's output: the chicken it came off
  -- ------------------------------------------------------------------
  if new.source_table = 'item_conversions' and new.quantity > 0 then
    select count(distinct sml.lot_id),
           min(l.lot_ref), min(l.expiry_date)
      into v_n, v_ref, v_exp
      from public.stock_movement_lots sml
      join public.stock_lots l on l.id = sml.lot_id
      join public.stock_movements m on m.id = sml.movement_id
     where m.source_table = 'item_conversions'
       and m.source_line_id is not distinct from new.source_line_id
       and m.quantity < 0;

    -- Several batches in one pot: a lot of its own, carrying the
    -- earliest expiry of what went in. See the header -- the safe
    -- direction is the early one.
    if coalesce(v_n, 0) <> 1 then
      v_ref := 'CONV-' || to_char(new.movement_date, 'YYYYMMDD') || '-'
                       || left(replace(new.source_id::text, '-', ''), 6);
    end if;

    insert into public.stock_lots
      (org_id, item_id, lot_ref, kind, expiry_date)
    values (new.org_id, new.item_id, v_ref, v_track, v_exp)
    on conflict (org_id, item_id, lot_ref) do update
      set expiry_date = coalesce(excluded.expiry_date, stock_lots.expiry_date),
          updated_at  = now()
    returning id into v_lot;

    insert into public.stock_movement_lots
      (org_id, movement_id, lot_id, quantity)
    values (new.org_id, new.id, v_lot, new.quantity);
    return null;
  end if;

  -- ------------------------------------------------------------------
  -- An ingredient coming back off a credit note
  -- ------------------------------------------------------------------
  --
  -- To the batches this sale took, most recently taken first. The last
  -- thing out of the pot is the first thing back into it, and a batch
  -- that was emptied and closed should not be reopened ahead of one
  -- that is still open.
  if new.source_table = 'pos_sales' and new.quantity > 0 then
    declare v_back numeric := new.quantity;
    begin
      for r in
        select sml.lot_id, -sml.quantity as quantity
          from public.stock_movement_lots sml
          join public.stock_movements m on m.id = sml.movement_id
         where m.source_table = 'pos_sales'
           and m.source_id = new.source_id
           and m.item_id = new.item_id
           and m.quantity < 0
         order by m.created_at desc, sml.lot_id
      loop
        exit when v_back <= 0;
        insert into public.stock_movement_lots
          (org_id, movement_id, lot_id, quantity)
        values (new.org_id, new.id, r.lot_id, least(r.quantity, v_back))
        on conflict (movement_id, lot_id) do update
          set quantity = public.stock_movement_lots.quantity
                         + excluded.quantity;
        v_back  := v_back - least(r.quantity, v_back);
        v_found := v_found + 1;
      end loop;
    end;
    if v_found > 0 then
      return null;
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Anything going out with nobody to ask: earliest expiry first
  -- ------------------------------------------------------------------
  if new.quantity < 0
     and new.source_table in ('stock_transfers', 'item_conversions', 'pos_sales')
  then
    for r in
      select p.lot_id, p.take
        from app.pick_lots_fefo(new.item_id, new.warehouse_id, new.quantity) p
    loop
      insert into public.stock_movement_lots
        (org_id, movement_id, lot_id, quantity)
      values (new.org_id, new.id, r.lot_id, -r.take);
      v_found := v_found + 1;
    end loop;
    if v_found > 0 then
      return null;
    end if;
  end if;

  raise exception
    'Item % is tracked by %, so every unit has to be named before this '
    'can be posted. Nothing was recorded against this line.',
    v_code, v_track using errcode = '23514';
end;
$$;

-- ---------------------------------------------------------------------
-- What is left uncredited on an invoice
-- ---------------------------------------------------------------------
--
-- Per line, because that is what a partial credit is about: two of the
-- five shirts came back, not "forty per cent of the money".
create or replace function public.invoice_credit_remaining(p_invoice uuid)
returns table (
  line_id     uuid,
  line_no     integer,
  item_id     uuid,
  description text,
  uom_code    text,
  unit_price  numeric,
  invoiced    numeric,
  credited    numeric,
  remaining   numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select d.org_id into v_org from public.sales_documents d
   where d.id = p_invoice and d.doc_type = 'invoice';
  if v_org is null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
  with credited as (
    select cl.item_id, cl.description, sum(cl.quantity) as qty
      from public.sales_documents c
      join public.sales_document_lines cl on cl.document_id = c.id
     where c.original_invoice_id = p_invoice
       and c.doc_type = 'credit_note'
       and c.status = 'posted'
       and cl.line_type = 'item'
     group by cl.item_id, cl.description
  )
  select l.id, l.line_no, l.item_id, l.description, l.uom_code, l.unit_price,
         l.quantity,
         coalesce(c.qty, 0),
         greatest(l.quantity - coalesce(c.qty, 0), 0)
    from public.sales_document_lines l
    left join credited c
      on c.item_id is not distinct from l.item_id
     and c.description = l.description
   where l.document_id = p_invoice
     and l.line_type = 'item'
   order by l.line_no;
end;
$$;

revoke all on function public.invoice_credit_remaining(uuid)
  from public, anon;
grant execute on function public.invoice_credit_remaining(uuid)
  to authenticated;

comment on function public.invoice_credit_remaining(uuid) is
  'What is left uncredited on each line of an invoice. Per line rather than as a share of the money, because two of the five shirts came back.';

-- ---------------------------------------------------------------------
-- Crediting it
-- ---------------------------------------------------------------------
--
-- `p_lines` is `[{"line": <invoice line id>, "quantity": n}]`. Null
-- credits the whole of whatever is left, which is what somebody means
-- when the customer brought the lot back.
create or replace function public.credit_sales_invoice(
  p_invoice uuid,
  p_lines   jsonb default null,
  p_reason  text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc   public.sales_documents;
  v_note  uuid;
  v_no    text;
  v_row   record;
  v_want  numeric;
  v_n     integer := 0;
begin
  select * into v_doc from public.sales_documents d
   where d.id = p_invoice and d.doc_type = 'invoice';
  if v_doc.id is null then
    raise exception 'No such invoice.' using errcode = 'P0002';
  end if;
  if not app.can_post(v_doc.org_id) then
    raise exception
      'Crediting an invoice posts a document, which needs permission this '
      'account has not been given.'
      using errcode = '42501';
  end if;
  -- Posted, part-paid or paid in full -- all three are invoices that
  -- have reached the ledger and can be credited. A counter sale's
  -- invoice is `completed` the moment the till takes the money, so
  -- testing for `posted` alone would refuse to credit exactly the sales
  -- this migration exists for.
  if v_doc.status not in ('posted', 'partial', 'completed') then
    raise exception
      'That invoice is %, so there is nothing to credit yet.', v_doc.status
      using errcode = '23514';
  end if;

  v_no := app.next_document_number_internal(v_doc.org_id, 'credit_note');

  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, original_invoice_id, parent_id, notes,
    created_by)
  values (
    v_doc.org_id, 'credit_note', v_no, current_date, current_date,
    v_doc.contact_id, v_doc.currency, v_doc.exchange_rate, 'draft',
    -- The link this whole migration exists to create.
    p_invoice, p_invoice,
    coalesce(nullif(btrim(coalesce(p_reason, '')), ''),
             'Credit against ' || v_doc.doc_no),
    auth.uid())
  returning id into v_note;

  for v_row in
    select r.*,
           (select (e ->> 'quantity')::numeric
              from jsonb_array_elements(p_lines) e
             where (e ->> 'line')::uuid = r.line_id) as asked
      from public.invoice_credit_remaining(p_invoice) r
  loop
    -- Null asks for everything left; a named line asks for what it says.
    v_want := case when p_lines is null then v_row.remaining
                   else coalesce(v_row.asked, 0) end;
    if v_want <= 0 then
      continue;
    end if;
    if v_want > v_row.remaining then
      raise exception
        'Only % of "%" is left uncredited on %, and this asks for %. A '
        'credit note is a document about money, not authorisation to '
        'invent a return.',
        v_row.remaining, v_row.description, v_doc.doc_no, v_want
        using errcode = '23514';
    end if;

    v_n := v_n + 1;
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, tax_code_id, tax_rate,
      is_tax_inclusive, warehouse_id)
    select v_doc.org_id, v_note, v_n, 'item', l.item_id, l.description,
           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,
           l.is_tax_inclusive, l.warehouse_id
      from public.sales_document_lines l where l.id = v_row.line_id;
  end loop;

  if v_n = 0 then
    -- Nothing to credit. The half-built note is removed rather than
    -- left as an empty document somebody has to explain.
    delete from public.sales_documents d where d.id = v_note;
    raise exception
      'There is nothing left to credit on %.', v_doc.doc_no
      using errcode = '23514';
  end if;

  perform app.post_sales_document_internal(v_note);
  return v_note;
end;
$$;

revoke all on function public.credit_sales_invoice(uuid, jsonb, text)
  from public, anon;
grant execute on function public.credit_sales_invoice(uuid, jsonb, text)
  to authenticated;

comment on function public.credit_sales_invoice(uuid, jsonb, text) is
  'Raises and posts a credit note against an invoice, capped at what is left uncredited on each line, and records which invoice it credits -- which nothing has ever done before.';
