-- =====================================================================
-- Sell in cartons, stock in pieces
--
-- 0264 built the conversion machinery: `ref_uom_factors` for what a
-- kilogram is, `item_uom_packs` for what *this* shop's carton holds,
-- and `app.uom_qty` to turn one into the other. 0265 through 0267 use
-- it for recipes, transfers and conversions.
--
-- Every caller is in the point-of-sale and stock code. **No sales or
-- purchase document converts anything.** `post_sales_document` moves
-- `l.quantity` and has never read `l.uom_code`.
--
-- That is not wrong today, and the reason it is not wrong is the reason
-- this has to be one migration: `line_draft.dart` copies the item's own
-- unit onto every line and there is no unit picker, so the two always
-- agree. Add the picker on its own and every carton sold takes one
-- piece off the shelf. Add the conversion on its own and nothing
-- changes. They go together or not at all.
--
-- ---------------------------------------------------------------------
-- The money is per line, the stock is per piece
--
-- This is the whole design and it keeps the change small. A line that
-- says "2 cartons at RM 240" is RM 480, and that arithmetic is already
-- right — `calc_document_line` multiplies the line's own quantity by
-- the line's own price and neither has anything to do with pieces.
--
-- Only the *stock* side converts. Two cartons of twenty-four is
-- forty-eight pieces off the shelf, and on a purchase RM 480 for
-- forty-eight pieces is RM 10 each — not RM 240, which is what
-- dividing by the carton count would have made it. That last one is the
-- assertion this migration is built around, because a weighted average
-- that is out by the pack size poisons the cost of every subsequent
-- sale of that item.
--
-- ---------------------------------------------------------------------
-- Resolved when the line is saved, and stored
--
-- `base_quantity` is written by `calc_document_line`, the trigger that
-- already fires on both line tables and already owns the line's derived
-- numbers. Stored rather than computed on demand, for the reason 0265
-- stores a transfer's sent quantity: a pack size corrected next month
-- must not change what was invoiced last Tuesday.
--
-- A line with no item -- a description, a subtotal, a discount -- takes
-- its own quantity, because there is nothing to convert and nothing on
-- a shelf.
--
-- ---------------------------------------------------------------------
-- And `app.uom_qty` has to stop depending on who is asking
--
-- It reads `item_uom_packs`, which has a read policy gated on the
-- `inventory` module. Every caller so far has been SECURITY DEFINER, so
-- the policy has never applied. `calc_document_line` is an ordinary
-- trigger that runs as whoever saved the line, and a company that did
-- not buy the inventory module would have found its cartons silently
-- converting by the reference table or not at all — the worst kind of
-- wrong, because the number looks plausible.
--
-- So it becomes SECURITY DEFINER. It converts a quantity for an item
-- the caller has already named and returns a number; it exposes
-- nothing that reading the item would not.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What the line comes to in the item's own unit
-- ---------------------------------------------------------------------
alter table public.sales_document_lines
  add column if not exists base_quantity numeric(18, 6);
alter table public.purchase_document_lines
  add column if not exists base_quantity numeric(18, 6);

comment on column public.sales_document_lines.base_quantity is
  'The line quantity in the item''s own stock unit, resolved when the line was saved. Stored rather than recomputed: a pack size corrected next month must not change what was invoiced last Tuesday.';
comment on column public.purchase_document_lines.base_quantity is
  'The line quantity in the item''s own stock unit, resolved when the line was saved. What goes onto the shelf, and what the unit cost is divided by.';

-- ---------------------------------------------------------------------
-- The conversion stops caring who is asking
-- ---------------------------------------------------------------------
--
-- Re-created from 0264 with `security definer` added and nothing else
-- changed. See the header.
create or replace function app.uom_qty(
  p_item uuid, p_qty numeric, p_uom text)
returns numeric
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_base text;
  v_name text;
  v_pack numeric;
  v_from numeric; v_from_dim text;
  v_to   numeric; v_to_dim   text;
begin
  select i.uom_code, i.name into v_base, v_name
    from public.items i where i.id = p_item;
  if v_base is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if p_uom is null or p_uom = v_base then
    return p_qty;
  end if;

  select k.qty_in_stock_uom into v_pack
    from public.item_uom_packs k
   where k.item_id = p_item and k.uom_code = p_uom;
  if v_pack is not null then
    return p_qty * v_pack;
  end if;

  select f.factor, f.dimension into v_from, v_from_dim
    from public.ref_uom_factors f where f.code = p_uom;
  select f.factor, f.dimension into v_to, v_to_dim
    from public.ref_uom_factors f where f.code = v_base;

  if v_from is not null and v_to is not null and v_from_dim = v_to_dim then
    return p_qty * v_from / v_to;
  end if;

  raise exception
    'There is no way to turn % into % for %. Set what one % of it is.',
    p_uom, v_base, v_name, p_uom
    using errcode = '22023';
end;
$$;

revoke all on function app.uom_qty(uuid, numeric, text) from public, anon;
grant execute on function app.uom_qty(uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------
-- Which the line trigger now fills in
-- ---------------------------------------------------------------------
--
-- Re-created from 0009 -- the migration that last defined it, checked
-- rather than assumed -- with the base quantity added and the money
-- arithmetic untouched. It is set before the non-item early return, so
-- a description line carries its own quantity rather than a null that
-- every reader would have to coalesce.
create or replace function app.calc_document_line()
returns trigger
language plpgsql
-- 0023 swept a pinned search_path onto every function that existed then,
-- including this one. Re-creating it drops what the sweep applied, so the
-- pin is written back here; search_path.sql fails without it.
set search_path = public, pg_temp
as $$
declare
  v_gross     numeric(18, 4);
  v_discount  numeric(18, 2);
  v_net       numeric(18, 2);
  v_tax       numeric(18, 2);
begin
  -- The stock side. Raises when the unit cannot be converted, which is
  -- the right moment: the line is being typed and somebody can fix it.
  new.base_quantity := case
    when new.item_id is null then coalesce(new.quantity, 0)
    else app.uom_qty(new.item_id, coalesce(new.quantity, 0), new.uom_code)
  end;

  if new.line_type <> 'item' then
    new.line_subtotal := 0;
    new.tax_amount    := 0;
    new.line_total    := 0;
    return new;
  end if;

  -- The money side, unchanged: a line's price is per the line's own
  -- unit, so two cartons at RM 240 is RM 480 whatever a carton holds.
  v_gross := coalesce(new.quantity, 0) * coalesce(new.unit_price, 0);

  if coalesce(new.discount_percent, 0) > 0 then
    v_discount := round(v_gross * new.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(new.discount_amount, 0);
  end if;

  if new.is_tax_inclusive and coalesce(new.tax_rate, 0) > 0 then
    v_net := round((v_gross - v_discount) / (1 + new.tax_rate / 100.0), 2);
    v_tax := round(v_gross - v_discount - v_net, 2);
  else
    v_net := round(v_gross - v_discount, 2);
    v_tax := round(v_net * coalesce(new.tax_rate, 0) / 100.0, 2);
  end if;

  new.discount_amount := v_discount;
  new.line_subtotal   := v_net;
  new.tax_amount      := v_tax;
  new.line_total      := v_net + v_tax;

  return new;
end;
$$;

-- Everything already on the books was written in its item's own unit,
-- because nothing could write anything else. Filling it in makes the
-- coalesce in the posting functions a belt rather than the load-bearing
-- part.
update public.sales_document_lines
   set base_quantity = quantity where base_quantity is null;
update public.purchase_document_lines
   set base_quantity = quantity where base_quantity is null;

-- ---------------------------------------------------------------------
-- And the two posting functions, which move stock in pieces
-- ---------------------------------------------------------------------
--
-- Both re-created from 0097 -- the migration that last defined them,
-- checked rather than assumed. Three lines changed between them and
-- everything else is carried verbatim: the cost of sales, the quantity
-- that leaves on a sale, and the quantity and unit cost that arrive on
-- a purchase.
create or replace function app.post_sales_document_internal(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc         public.sales_documents;
  v_line        record;
  v_entries     jsonb := '[]'::jsonb;
  v_sign        integer;
  v_ar_account  uuid;
  v_tax_account uuid;
  v_round_acct  uuid;
  v_cogs_acct   uuid;
  v_inv_acct    uuid;
  v_rev_acct    uuid;
  v_entry_id    uuid;
  v_amount      numeric(18, 2);
  v_cogs_total  numeric(18, 2) := 0;
  v_from_do     boolean := false;
  v_rate        numeric(18, 8);
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then
    raise exception 'Sales document % not found', p_id;
  end if;
  if v_doc.doc_type not in ('invoice', 'credit_note', 'debit_note', 'refund_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  -- Credit and refund notes move the ledger the other way.
  v_sign := case when v_doc.doc_type in ('credit_note', 'refund_note') then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  select coalesce(c.receivable_account_id,
                  (select id from public.accounts
                    where org_id = v_doc.org_id and code = '1210'))
    into v_ar_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '2130';
  select id into v_round_acct from public.accounts
   where org_id = v_doc.org_id and code = '4990';

  -- Receivable: debit for an invoice, credit for a credit note.
  v_amount := round(v_sign * v_doc.total_amount * v_rate, 2);
  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_ar_account,
    'description', v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'debit',       greatest(v_amount, 0),
    'credit',      greatest(-v_amount, 0),
    'contact_id',  v_doc.contact_id
  );

  -- Revenue, one line per document line.
  for v_line in
    select l.*, i.sales_account_id, i.track_inventory, i.cogs_account_id,
           i.inventory_account_id, i.average_cost
      from public.sales_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_id and l.line_type = 'item'
     order by l.line_no
  loop
    v_rev_acct := app.resolve_account(
      v_doc.org_id, v_line.account_id, v_line.item_id, 'sales_account_id', '4100');

    v_amount := round(-v_sign * v_line.line_subtotal * v_rate, 2);
    if v_amount <> 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_rev_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'tax_code_id', v_line.tax_code_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code
      );
    end if;

    -- Cost of sales for stock items.
    if v_line.track_inventory and v_line.item_id is not null then
      -- `average_cost` is per the item's own unit, so the cost of a
      -- line sold in cartons is the pieces it came to, not the number
      -- of cartons. 0270.
      v_cogs_total := v_cogs_total
        + round(coalesce(v_line.base_quantity, v_line.quantity)
                * coalesce(v_line.average_cost, 0) * v_rate, 2);
    end if;
  end loop;

  -- Header discount, if it was not already pushed down to the lines.
  if coalesce(v_doc.discount_amount, 0) > 0 then
    v_amount := round(v_sign * v_doc.discount_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4300'),
      'description', 'Discount',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- SST output tax.
  if coalesce(v_doc.tax_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.tax_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_tax_account,
      'description', 'SST output tax',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0),
      'tax_amount',  abs(v_amount)
    );
  end if;

  -- Cash rounding difference.
  if coalesce(v_doc.rounding_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.rounding_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_round_acct,
      'description', 'Rounding adjustment',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- Shipping charged to the customer.
  if coalesce(v_doc.shipping_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.shipping_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4900'),
      'description', 'Shipping',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- Cost of sales pair.
  if v_cogs_total <> 0 then
    select id into v_cogs_acct from public.accounts where org_id = v_doc.org_id and code = '5200';
    select id into v_inv_acct  from public.accounts where org_id = v_doc.org_id and code = '1310';
    v_amount := round(v_sign * v_cogs_total, 2);
    v_entries := v_entries
      || jsonb_build_object('account_id', v_cogs_acct, 'description', 'Cost of goods sold',
                            'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0))
      || jsonb_build_object('account_id', v_inv_acct, 'description', 'Inventory movement',
                            'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0));
  end if;

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date,
    case v_doc.doc_type
      when 'credit_note' then 'credit_note'::app.journal_source
      when 'debit_note'  then 'debit_note'::app.journal_source
      else 'sales_invoice'::app.journal_source
    end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'sales_documents', v_doc.id, v_doc.reference,
    v_doc.currency, v_rate
  );

  -- Move stock, unless a delivery order already did.
  select exists (
    select 1 from public.sales_documents d
     where d.id = v_doc.parent_id and d.doc_type = 'delivery_order'
  ) into v_from_do;

  if not v_from_do then
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
    )
    select v_doc.org_id,
           app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'sales_delivery' else 'sales_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           -- In the item's own unit. Two cartons of twenty-four is
           -- forty-eight pieces off the shelf. 0270.
           -v_sign * coalesce(l.base_quantity, l.quantity),
           coalesce(i.average_cost, 0),
           'sales_documents', v_doc.id, l.id, v_entry_id, auth.uid()
      from public.sales_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_id
       and l.line_type = 'item'
       and i.track_inventory
       and l.quantity > 0;
  end if;

  update public.sales_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  return v_entry_id;
end;
$$;

create or replace function app.post_purchase_document_internal(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_doc         public.purchase_documents;
  v_line        record;
  v_entries     jsonb := '[]'::jsonb;
  v_sign        integer;
  v_ap_account  uuid;
  v_tax_account uuid;
  v_exp_acct    uuid;
  v_entry_id    uuid;
  v_amount      numeric(18, 2);
  v_rate        numeric(18, 8);
begin
  select * into v_doc from public.purchase_documents where id = p_id;
  if not found then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if v_doc.doc_type not in ('bill', 'purchase_credit_note', 'purchase_debit_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_doc.org_id and code = '2110'))
    into v_ap_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '1410';

  -- Payable: credit for a bill.
  v_amount := round(-v_sign * v_doc.total_amount * v_rate, 2);
  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_ap_account,
    'description', v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'debit',       greatest(v_amount, 0),
    'credit',      greatest(-v_amount, 0),
    'contact_id',  v_doc.contact_id
  );

  for v_line in
    select l.*, i.track_inventory, i.inventory_account_id, i.purchase_account_id
      from public.purchase_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_id and l.line_type = 'item'
     order by l.line_no
  loop
    -- Stock items capitalise into inventory; everything else expenses.
    if v_line.track_inventory then
      v_exp_acct := coalesce(v_line.inventory_account_id,
        (select id from public.accounts where org_id = v_doc.org_id and code = '1310'));
    else
      v_exp_acct := app.resolve_account(
        v_doc.org_id, v_line.account_id, v_line.item_id, 'purchase_account_id', '5100');
    end if;

    v_amount := round(v_sign * v_line.line_subtotal * v_rate, 2);
    if v_amount <> 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_exp_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'tax_code_id', v_line.tax_code_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code
      );
    end if;
  end loop;

  if coalesce(v_doc.tax_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.tax_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_tax_account,
      'description', 'SST input tax',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0),
      'tax_amount',  abs(v_amount)
    );
  end if;

  if coalesce(v_doc.shipping_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.shipping_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),
      'description', 'Freight and handling',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  if coalesce(v_doc.rounding_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.rounding_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4990'),
      'description', 'Rounding adjustment',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date,
    case when v_sign = -1 then 'purchase_credit_note'::app.journal_source
         else 'purchase_bill'::app.journal_source end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'purchase_documents', v_doc.id,
    coalesce(v_doc.supplier_doc_no, v_doc.reference),
    v_doc.currency, v_rate
  );

  -- Receive stock unless a goods-received note already did.
  if not exists (
    select 1 from public.purchase_documents d
     where d.id = v_doc.parent_id and d.doc_type = 'goods_received'
  ) then
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
    )
    select v_doc.org_id,
           app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'purchase_receipt' else 'purchase_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           -- Both in the item's own unit. Two cartons of twenty-four
           -- is forty-eight pieces onto the shelf, and RM 480 for them
           -- is RM 10 a piece -- not RM 240, which is what dividing by
           -- the carton count would have made it. 0270.
           v_sign * coalesce(l.base_quantity, l.quantity),
           case when coalesce(l.base_quantity, l.quantity) = 0 then 0
                else round(l.line_subtotal * v_rate
                           / coalesce(l.base_quantity, l.quantity), 6) end,
           'purchase_documents', v_doc.id, l.id, v_entry_id, auth.uid()
      from public.purchase_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_id
       and l.line_type = 'item'
       and i.track_inventory
       and l.quantity > 0;
  end if;

  update public.purchase_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  return v_entry_id;
end;
$$;

