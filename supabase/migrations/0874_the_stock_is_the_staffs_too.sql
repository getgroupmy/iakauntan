-- =====================================================================
-- iAkauntan :: 0874 the stock is the staff's too
--
-- `0873` gave the definers that answer with the company's sales,
-- purchases, tax and contacts `app.is_staff_member` in place of
-- `is_org_member`, so a member who is only a self-service employee is
-- refused them. This is the second domain: what is on hand, at what
-- cost, in which lot and expiring when, and what a manufacturing order
-- is short of.
--
-- Measured on 13 October 2026, locally, after `0873`, as an `employee`
-- member with no access type, with the role `authenticated`:
-- `stock_on_hand` answered her the 40 on hand at 2.50 that it answers
-- the owner.
--
-- Production held no `employee` member on 13 October.
--
-- As in `0873`, each body below is the live one as `pg_get_functiondef`
-- gave it, with `app.is_staff_member(` in place of `app.is_org_member(`
-- and nothing else changed. `employee_definers.sql` takes these nine
-- off its list of what is not yet done.
-- =====================================================================

-- stock_on_hand: 1 membership check
CREATE OR REPLACE FUNCTION public.stock_on_hand(p_org_id uuid, p_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(item_id uuid, code text, name text, uom_code text, quantity numeric, average_cost numeric, value numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select i.id, i.code, i.name, i.uom_code,
         coalesce(sum(l.quantity), 0),
         coalesce(i.average_cost, 0),
         coalesce(sum(l.value), 0)
    from public.items i
    left join public.stock_levels l on l.item_id = i.id
      and (p_warehouse_id is null or l.warehouse_id = p_warehouse_id)
   where i.org_id = p_org_id and i.track_inventory and i.deleted_at is null
     and i.is_active
   group by i.id, i.code, i.name, i.uom_code, i.average_cost
   order by i.code;
end;
$function$;

-- report_stock_card: 1 membership check
CREATE OR REPLACE FUNCTION public.report_stock_card(p_org_id uuid, p_item_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today(), p_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(movement_date date, movement_no text, movement_type app.stock_movement_type, warehouse text, reference text, quantity numeric, unit_cost numeric, total_cost numeric, balance_quantity numeric, balance_value numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_open_qty   numeric := 0;
  v_open_value numeric := 0;
begin
  -- Stock is not the ledger, and a storekeeper who may not read the
  -- general ledger still has to be able to answer for a shelf. Membership
  -- is the same bar `stock_movements` itself sets for select.
  if not app.is_staff_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  if p_from is not null then
    select coalesce(sum(m.quantity), 0), coalesce(sum(m.total_cost), 0)
      into v_open_qty, v_open_value
      from public.stock_movements m
     where m.org_id = p_org_id and m.item_id = p_item_id
       and m.movement_date < p_from
       and (p_warehouse_id is null or m.warehouse_id = p_warehouse_id);
  end if;

  return query
  with moved as (
    select m.movement_date, m.movement_no, m.movement_type,
           w.name as warehouse,
           -- What the movement came from, so the card answers "why"
           -- rather than only "when". The source tables are the ones
           -- that write movements; anything else falls back to the note.
           coalesce(
             (select d.doc_no from public.sales_documents d
               where m.source_table = 'sales_documents' and d.id = m.source_id),
             (select d.doc_no from public.purchase_documents d
               where m.source_table = 'purchase_documents' and d.id = m.source_id),
             (select a.adjustment_no from public.stock_adjustments a
               where m.source_table = 'stock_adjustments' and a.id = m.source_id),
             m.notes) as reference,
           m.quantity, m.unit_cost, m.total_cost, m.id
      from public.stock_movements m
      join public.warehouses w on w.id = m.warehouse_id
     where m.org_id = p_org_id and m.item_id = p_item_id
       and m.movement_date <= p_to
       and (p_from is null or m.movement_date >= p_from)
       and (p_warehouse_id is null or m.warehouse_id = p_warehouse_id))
  select x.movement_date, x.movement_no, x.movement_type, x.warehouse,
         x.reference, x.quantity, x.unit_cost, x.total_cost,
         x.balance_quantity, x.balance_value
    from (
    -- The line the range starts from. Omitted when there is no range and
    -- when nothing came before it, because a brought-forward of nil at
    -- the top of a card that begins at the beginning is noise.
    select p_from, null::text, null::app.stock_movement_type, null::text,
           'Brought forward'::text,
           null::numeric, null::numeric, null::numeric,
           round(v_open_qty, 4), round(v_open_value, 2),
           null::uuid, 0
     where p_from is not null and (v_open_qty <> 0 or v_open_value <> 0)
    union all
    select d.movement_date, d.movement_no, d.movement_type, d.warehouse,
           d.reference, d.quantity, d.unit_cost, d.total_cost,
           round(v_open_qty + sum(d.quantity) over w, 4),
           round(v_open_value + sum(d.total_cost) over w, 2),
           d.id, 1
      from moved d
    window w as (order by d.movement_date, d.movement_no, d.id
                 rows between unbounded preceding and current row)
  ) x (movement_date, movement_no, movement_type, warehouse, reference,
       quantity, unit_cost, total_cost, balance_quantity, balance_value,
       id, ord)
   order by x.ord, x.movement_date, x.movement_no, x.id;
end $function$;

-- report_lot_balances: 1 membership check
CREATE OR REPLACE FUNCTION public.report_lot_balances(p_org_id uuid, p_item_id uuid DEFAULT NULL::uuid, p_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(lot_id uuid, item_code text, item_name text, lot_ref text, kind text, expiry_date date, days_to_expiry integer, warehouse text, quantity numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select b.lot_id, i.code, i.name, b.lot_ref, b.kind, b.expiry_date,
         case when b.expiry_date is null then null
              else (b.expiry_date - app.today())::integer end,
         w.name, b.quantity
    from public.v_lot_balances b
    join public.items i on i.id = b.item_id
    left join public.warehouses w on w.id = b.warehouse_id
   where b.org_id = p_org_id
     and (p_item_id is null or b.item_id = p_item_id)
     and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id)
   order by i.code, b.expiry_date asc nulls last, b.lot_ref;
end;
$function$;

-- report_expiring_stock: 1 membership check
CREATE OR REPLACE FUNCTION public.report_expiring_stock(p_org_id uuid, p_within_days integer DEFAULT 90)
 RETURNS TABLE(item_code text, item_name text, lot_ref text, expiry_date date, days_to_expiry integer, warehouse text, quantity numeric, value_at_average numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select i.code, i.name, b.lot_ref, b.expiry_date,
         (b.expiry_date - app.today())::integer,
         w.name, b.quantity,
         -- At the item's weighted average, because that is what this
         -- stock is carried at. It is what would be written off, not a
         -- cost specific to the batch — see the header.
         round(b.quantity * coalesce(i.average_cost, 0), 2)
    from public.v_lot_balances b
    join public.items i on i.id = b.item_id
    left join public.warehouses w on w.id = b.warehouse_id
   where b.org_id = p_org_id
     and b.expiry_date is not null
     and b.expiry_date <= app.today() + p_within_days
     and b.quantity > 0
   order by b.expiry_date, i.code;
end;
$function$;

-- trace_lot: 1 membership check
CREATE OR REPLACE FUNCTION public.trace_lot(p_org_id uuid, p_lot_id uuid)
 RETURNS TABLE(direction text, movement_date date, movement_type text, quantity numeric, warehouse text, contact_name text, document_no text, source_table text, source_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select case when sml.quantity > 0 then 'in' else 'out' end,
         m.movement_date,
         m.movement_type::text,
         sml.quantity,
         w.name,
         coalesce(sd.who, pd.who),
         coalesce(sd.doc_no, pd.doc_no),
         m.source_table,
         m.source_id
    from public.stock_movement_lots sml
    join public.stock_movements m on m.id = sml.movement_id
    left join public.warehouses w on w.id = m.warehouse_id
    left join lateral (
      select d.doc_no, c.name as who
        from public.sales_documents d
        left join public.contacts c on c.id = d.contact_id
       where m.source_table = 'sales_documents' and d.id = m.source_id) sd on true
    left join lateral (
      select d.doc_no, c.name as who
        from public.purchase_documents d
        left join public.contacts c on c.id = d.contact_id
       where m.source_table = 'purchase_documents' and d.id = m.source_id) pd on true
   where sml.lot_id = p_lot_id
     and m.org_id = p_org_id
   order by m.movement_date, m.created_at;
end;
$function$;

-- line_lots: 1 membership check
CREATE OR REPLACE FUNCTION public.line_lots(p_line_table text, p_line_id uuid)
 RETURNS TABLE(lot_ref text, quantity numeric, expiry_date date, manufactured_on date, supplier_lot_ref text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  select d.org_id into v_org from public.document_line_lots d
   where (p_line_table = 'sales_document_lines'    and d.sales_line_id = p_line_id)
      or (p_line_table = 'purchase_document_lines' and d.purchase_line_id = p_line_id)
      or (p_line_table = 'stock_adjustment_lines'  and d.adjustment_line_id = p_line_id)
   limit 1;

  if v_org is null then return; end if;
  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of that organization' using errcode = '42501';
  end if;

  return query
  select d.lot_ref, d.quantity, d.expiry_date, d.manufactured_on,
         d.supplier_lot_ref
    from public.document_line_lots d
   where (p_line_table = 'sales_document_lines'    and d.sales_line_id = p_line_id)
      or (p_line_table = 'purchase_document_lines' and d.purchase_line_id = p_line_id)
      or (p_line_table = 'stock_adjustment_lines'  and d.adjustment_line_id = p_line_id)
   order by d.lot_ref;
end;
$function$;

-- suggest_lots: 1 membership check
CREATE OR REPLACE FUNCTION public.suggest_lots(p_item_id uuid, p_warehouse_id uuid, p_quantity numeric)
 RETURNS TABLE(lot_ref text, expiry_date date, available numeric, take numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org  uuid;
  v_left numeric(18, 4) := abs(coalesce(p_quantity, 0));
  r      record;
begin
  select org_id into v_org from public.items where id = p_item_id;
  if v_org is null or not app.is_staff_member(v_org) then
    raise exception 'Not a member of that organization' using errcode = '42501';
  end if;

  for r in
    select b.lot_ref, b.expiry_date, b.quantity
      from public.v_lot_balances b
     where b.item_id = p_item_id
       and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id)
       and b.quantity > 0
     order by b.expiry_date asc nulls last, b.lot_ref
  loop
    exit when v_left <= 0;
    lot_ref := r.lot_ref;
    expiry_date := r.expiry_date;
    available := r.quantity;
    take := least(r.quantity, v_left);
    v_left := v_left - take;
    return next;
  end loop;
end;
$function$;

-- document_lot_problems: 1 membership check
CREATE OR REPLACE FUNCTION public.document_lot_problems(p_document_id uuid, p_kind text)
 RETURNS TABLE(line_no integer, item_code text, needed numeric, allocated numeric, problem text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  if p_kind not in ('sales', 'purchase') then
    raise exception 'Unknown document kind %', p_kind using errcode = '23514';
  end if;

  select case when p_kind = 'sales'
              then (select org_id from public.sales_documents where id = p_document_id)
              else (select org_id from public.purchase_documents where id = p_document_id)
         end into v_org;
  if v_org is null then
    raise exception 'No such document' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of that organization' using errcode = '42501';
  end if;

  return query
  with lines as (
    select l.id, l.line_no, l.item_id, l.quantity
      from public.sales_document_lines l
     where p_kind = 'sales' and l.document_id = p_document_id
       and l.line_type = 'item' and l.quantity > 0
    union all
    select l.id, l.line_no, l.item_id, l.quantity
      from public.purchase_document_lines l
     where p_kind = 'purchase' and l.document_id = p_document_id
       and l.line_type = 'item' and l.quantity > 0)
  select ln.line_no, i.code, ln.quantity,
         coalesce(a.total, 0),
         case when coalesce(a.total, 0) = 0
              then format('%s is tracked by %s and nothing has been named',
                          i.code, i.tracking)
              else format('%s of %s has been named, the line is for %s',
                          a.total, i.code, ln.quantity)
         end
    from lines ln
    join public.items i on i.id = ln.item_id
    left join lateral (
      select sum(d.quantity) as total
        from public.document_line_lots d
       where (p_kind = 'sales' and d.sales_line_id = ln.id)
          or (p_kind = 'purchase' and d.purchase_line_id = ln.id)) a on true
   where i.tracking <> 'none'
     and coalesce(a.total, 0) <> ln.quantity
   order by ln.line_no;
end;
$function$;

-- mo_shortages: 1 membership check
CREATE OR REPLACE FUNCTION public.mo_shortages(p_mo_id uuid)
 RETURNS TABLE(item_id uuid, item_code text, item_name text, quantity_required numeric, quantity_on_hand numeric, quantity_short numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select c.item_id, i.code, i.name,
         c.quantity_required,
         coalesce(sl.quantity, 0),
         greatest(c.quantity_required - coalesce(sl.quantity, 0), 0)
    from public.mo_components c
    join public.manufacturing_orders m on m.id = c.mo_id
    join public.items i on i.id = c.item_id
    left join public.stock_levels sl
      on sl.item_id = c.item_id and sl.warehouse_id = m.warehouse_id
   where c.mo_id = p_mo_id
     and app.is_staff_member(m.org_id)
   order by i.code;
$function$;
