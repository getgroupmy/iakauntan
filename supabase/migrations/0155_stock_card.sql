-- =====================================================================
-- iAkauntan :: 0155 the stock card
--
-- `docs/unreachable.md` has carried this line for some time:
--
--   **Stock card.** `stock_movements` cannot be inspected per item, so
--   "why is this figure what it is" has no answer in the app.
--
-- Every stock investigation starts there. The screen says 47 on hand and
-- the shelf has 44, and the only way to find out where the three went is
-- to read the movements in order. Until now they could be written and
-- never read, which for an inventory system is most of the point.
--
-- 0152 made it sharper by adding opening balances: a company's stock now
-- starts with a movement nobody could look at.
--
-- ---------------------------------------------------------------------
-- The running balance is computed, not read
--
-- `stock_movements` already stores `balance_quantity`, `balance_value`
-- and `average_cost_after`, written by the trigger as each movement
-- lands. It would be quicker to select those columns and quicker still
-- to be wrong: they are per *warehouse*, so a card covering all of them
-- would show a running balance that jumps between locations and belongs
-- to none.
--
-- So the running figures here come from a window over whatever scope was
-- asked for, which is right for one warehouse and for all of them. What
-- makes that safe rather than merely different is the assertion in
-- `supabase/tests/stock_card.sql`: for a single warehouse the computed
-- balance must equal the stored one at every movement. Two independent
-- routes to the same number, checked against each other — and if they
-- ever disagree, the stock card is exactly the screen somebody would be
-- staring at while trying to work out why.
--
-- For the two to agree the window has to run in the order the trigger
-- ran, and that order is `movement_no`, not `created_at`: a bill that
-- receives stock and a delivery that ships it inside one transaction
-- carry the same timestamp to the microsecond, and production already
-- has such a pair. `movement_no` is allocated in sequence as each
-- movement lands, so it is the only faithful record of the order the
-- balances were computed in.
--
-- Date comes first all the same, because a card is read down the page by
-- date. The two orderings part company for a back-dated movement — one
-- entered today against last month — which the card places by its date
-- while the stored balance still carries it last. The card is right for
-- a reader; the stored column is right about the sequence it was
-- computed in; neither is wrong, and the test asserts the agreement on
-- movements that arrive in order, which is the case the stored column
-- can speak to.
--
-- ---------------------------------------------------------------------
-- Brought forward
--
-- A card for a date range that opens without the balance it started from
-- is unreadable — the first movement appears to come from nowhere. So a
-- range with a start date gets a synthetic first line carrying
-- everything before it, with no movement type, because it is not one.
-- =====================================================================

create or replace function public.report_stock_card(
  p_org_id uuid,
  p_item_id uuid,
  p_from date default null,
  p_to date default current_date,
  p_warehouse_id uuid default null)
returns table (
  movement_date    date,
  movement_no      text,
  movement_type    app.stock_movement_type,
  warehouse        text,
  reference        text,
  quantity         numeric,
  unit_cost        numeric,
  total_cost       numeric,
  balance_quantity numeric,
  balance_value    numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_open_qty   numeric := 0;
  v_open_value numeric := 0;
begin
  -- Stock is not the ledger, and a storekeeper who may not read the
  -- general ledger still has to be able to answer for a shelf. Membership
  -- is the same bar `stock_movements` itself sets for select.
  if not app.is_org_member(p_org_id) then
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
end $$;

revoke all on function
  public.report_stock_card(uuid, uuid, date, date, uuid) from public, anon;
grant execute on function
  public.report_stock_card(uuid, uuid, date, date, uuid) to authenticated;

comment on function public.report_stock_card(uuid, uuid, date, date, uuid) is
  'Every movement of one item in order, with a running quantity and '
  'value over whatever scope was asked for. The running figures are '
  'computed rather than read from the per-warehouse columns the trigger '
  'maintains, and the two are asserted equal for a single warehouse.';
