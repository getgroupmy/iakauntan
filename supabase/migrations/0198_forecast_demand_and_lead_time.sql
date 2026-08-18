-- The two things a forecast is made of, read from what already
-- happened rather than typed in: what was wanted, and how long it took
-- to arrive.
--
-- ## Demand is a series with holes in it, and the holes are the point
--
-- The obvious query — group the deliveries by week and average them —
-- is wrong in a way that is easy to miss and expensive to be wrong
-- about. A week with no sales produces no row, so grouping alone gives
-- you the average of the weeks that had demand, not the average week.
-- For an item that sells 10 units in one week out of four, that is a
-- mean of 10 instead of 2.5, and it flows straight into the reorder
-- point.
--
-- The variance is worse. Dropping the zeroes removes exactly the
-- observations that make demand look erratic, so the standard
-- deviation collapses and the safety stock with it — the buffer gets
-- smallest precisely for the intermittent items that most need one.
--
-- So the series is generated over every bucket in the window and the
-- movements are joined onto it. Absence is recorded as zero, because
-- that is what it means.
--
-- ## Signs
--
-- Outbound movements are stored negative. Demand is therefore the
-- negation of the sum, and a `sales_return` — stored positive — nets
-- itself off without any special handling. A bucket can come out
-- negative if more came back than went out that week; that is real and
-- it is left alone rather than clamped, because clamping it would hide
-- a returns problem behind a flat line.
--
-- ## Lead time is a median, measured from the movement
--
-- Not a mean. One shipment stuck in customs for six weeks should not
-- double the reorder point for the next year, and with the handful of
-- receipts a small business has per item it very nearly would. The
-- median moves when the supplier's behaviour actually changes.
--
-- What it measures from matters more than it looks. The obvious
-- reading is "goods received date minus purchase order date", and on
-- this database that returns nothing at all: stock here arrives on
-- `bill` documents, not on `goods_received` ones. Both are legitimate.
-- A business with a warehouse receipts goods and bills later; a
-- business without one enters the supplier invoice and the stock lands
-- with it. Keying off the document type picks one of those and is
-- silently blind to the other.
--
-- So it keys off the movement. `purchase_receipt` in `stock_movements`
-- is the moment stock actually arrived whichever document caused it,
-- and `movement_date` is a better arrival date than any document date
-- anyway. From there `source_line_id` walks back through the document
-- cycle to the purchase order that ordered it.
--
-- Null when there is no purchase order upstream, which is the honest
-- answer for a business that does not raise them.

-- ---------------------------------------------------------------------
-- What was wanted, per bucket, including the buckets where nothing was
-- ---------------------------------------------------------------------
create or replace function app.demand_series(
  p_org             uuid,
  p_item            uuid,
  p_warehouse       uuid,
  p_bucket          app.forecast_bucket,
  p_from            date,
  p_to              date,
  p_count_transfers boolean default false,
  p_count_shrinkage boolean default false)
returns table (period_start date, qty numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_types app.stock_movement_type[] :=
    array['sales_delivery', 'sales_return']::app.stock_movement_type[];
  v_step interval := ('1 ' || p_bucket::text)::interval;
begin
  if not app.can_read_module(p_org, 'forecasting') then
    raise exception 'not permitted to read forecasting for this organization'
      using errcode = '42501';
  end if;

  -- Stock consumed by adjustment or written off. Off by default: an
  -- item that keeps being written off does not need more of itself
  -- ordered, it needs somebody to find out where it is going.
  if p_count_shrinkage then
    v_types := v_types
      || array['adjustment_out', 'write_off']::app.stock_movement_type[];
  end if;

  -- Only meaningful when forecasting a single warehouse. At company
  -- level a transfer out is matched by a transfer in and nets to
  -- nothing, which is the correct answer rather than a coincidence.
  if p_count_transfers then
    v_types := v_types
      || array['transfer_out']::app.stock_movement_type[];
  end if;

  return query
  with buckets as (
    select generate_series(
             date_trunc(p_bucket::text, p_from::timestamp),
             date_trunc(p_bucket::text, p_to::timestamp),
             v_step)::date as period_start
  ),
  moved as (
    select date_trunc(p_bucket::text, m.movement_date::timestamp)::date as period_start,
           -sum(m.quantity) as qty
      from public.stock_movements m
     where m.org_id = p_org
       and m.item_id = p_item
       and m.movement_type = any (v_types)
       and m.movement_date between p_from and p_to
       and (p_warehouse is null or m.warehouse_id = p_warehouse)
     group by 1
  )
  select b.period_start,
         coalesce(mv.qty, 0)::numeric
    from buckets b
    left join moved mv on mv.period_start = b.period_start
   order by b.period_start;
end;
$$;

grant execute on function app.demand_series(
  uuid, uuid, uuid, app.forecast_bucket, date, date, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- How long this supplier actually takes
-- ---------------------------------------------------------------------
--
-- Null when there is nothing to measure, which the caller has to handle
-- rather than paper over: a lead time of zero for an item never
-- purchased would set the reorder point to the safety stock alone and
-- quietly stop reordering it.
create or replace function app.measured_lead_time(
  p_org      uuid,
  p_item     uuid,
  p_supplier uuid default null,
  p_since    date default null)
returns numeric
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_days numeric;
  v_n    integer;
begin
  if not app.can_read_module(p_org, 'forecasting') then
    raise exception 'not permitted to read forecasting for this organization'
      using errcode = '42501';
  end if;

  select count(*),
         percentile_cont(0.5) within group (
           order by (m.movement_date - po.doc_date)::double precision)
    into v_n, v_days
    from public.stock_movements       m
    -- The line on whatever document brought the stock in: a bill in a
    -- business without a warehouse, a goods-received note in one with.
    join public.purchase_document_lines rl on rl.id = m.source_line_id
    -- And the line that document was raised from, which is the order.
    join public.purchase_document_lines pl on pl.id = rl.source_line_id
    join public.purchase_documents      po on po.id = pl.document_id
   where m.org_id = p_org
     and m.item_id = p_item
     and m.movement_type = 'purchase_receipt'
     and po.doc_type = 'purchase_order'
     and po.status  <> 'void'
     -- Stock arriving before it was ordered is a data entry error, not
     -- a negative lead time. Excluded rather than clamped so it cannot
     -- drag the median toward zero.
     and m.movement_date >= po.doc_date
     and (p_supplier is null or po.contact_id = p_supplier)
     and (p_since is null or po.doc_date >= p_since);

  -- One delivery is an anecdote. Two is the least that can have a
  -- median worth the name.
  if coalesce(v_n, 0) < 2 then
    return null;
  end if;

  return round(v_days::numeric, 2);
end;
$$;

grant execute on function app.measured_lead_time(uuid, uuid, uuid, date) to authenticated;

comment on function app.demand_series(
  uuid, uuid, uuid, app.forecast_bucket, date, date, boolean, boolean) is
  'Demand per bucket over a window, with empty buckets returned as zero '
  'rather than omitted. Omitting them averages only the weeks that sold '
  'something and collapses the variance, which shrinks safety stock '
  'exactly for the intermittent items that need it most.';

comment on function app.measured_lead_time(uuid, uuid, uuid, date) is
  'Median days from purchase order to the stock actually arriving, or '
  'null when fewer than two receipts trace back to an order. Measured '
  'from the stock movement rather than a document, because stock '
  'arrives on a bill in one business and a goods-received note in '
  'another, and keying off either is blind to the other.';
