-- The scan field 0540 said a till needed.
--
-- `0540` taught the counter to sell dated stock: a batch-tracked item
-- is picked earliest-expiry-first at the moment the sale completes and
-- the answer is written onto the invoice line, so the paper says which
-- production run left the shop. It stopped deliberately short of
-- serials, and said why in as many words:
--
--   "A serial names ONE PHYSICAL UNIT. Picking one on the customer's
--    behalf would print a serial number on their invoice and their
--    warranty for a machine somebody else is holding, and the first
--    anyone would hear of it is a warranty claim being refused. That
--    wants a scan field at the till."
--
-- This is that field, and its other end.
--
-- A serialised item at a counter was, until now, a sale the till simply
-- refused -- correctly, but a phone shop selling handsets is not an
-- exotic tenant, and "invoice it from Sales" means leaving the customer
-- at the counter while somebody opens the back office.
--
-- WHAT IS HERE
--
-- `pos_sale_lines.serial_refs` -- the serials scanned onto one line.
-- On the LINE and not on the tender, because it is line state: it has
-- to survive parking a bill, splitting one, merging two, and a till
-- that reloads with a queue behind it.
--
-- `pos_scan_serial` and `pos_unscan_serial` -- one scan, checked while
-- the customer is still standing there. THAT IS THE POINT OF THEM. The
-- same checks run again at completion and would catch everything these
-- catch, but a refusal at payment is a refusal in front of a queue,
-- after the bag is packed, with no clue which of six scans was wrong.
-- Checked at the scanner, the answer names the label in the cashier's
-- hand.
--
-- Scanning also SETS THE QUANTITY. A till is used by scanning: three
-- handsets is three scans, and a quantity box the cashier also has to
-- keep in step is a second source of truth that will disagree. The
-- count of serials is the quantity, and the completion check is that
-- they still agree.
--
-- `complete_pos_sale` -- the refusal becomes a check. It does not pick,
-- it does not guess; it counts what the till scanned, confirms each
-- serial is on the shelf that this sale draws from, refuses the same
-- machine twice on one bill, and writes `document_line_lots` at one
-- unit each, which is where a typed invoice keeps the same fact.
--
-- WHY THE CHECKS RUN TWICE, WHICH IS NOT BELT AND BRACES
--
-- `0532` lets a till sell with no signal and land the basket later. A
-- queued sale never went through `pos_scan_serial` at all -- the app
-- wrote its lines from a local database -- and by the time it lands,
-- the serial it named may have been sold by the till next to it. The
-- second check is the only one that sale ever meets.
--
-- The refusals name the outlet, because a serial that is "not on the
-- shelf" is nearly always on a different shelf.
--
-- `supabase/tests/pos_serial_sale.sql` sells two handsets by serial,
-- and asks the invoice which two.

alter table public.pos_sale_lines
  add column if not exists serial_refs text[] not null default '{}'::text[];

comment on column public.pos_sale_lines.serial_refs is
  'Serial numbers scanned onto this line, one per unit. Empty on every '
  'line of every item that is not tracked by serial number.';

-- ---------------------------------------------------------------------
-- One scan
-- ---------------------------------------------------------------------
create or replace function public.pos_scan_serial(
  p_line   uuid,
  p_serial text)
returns text[]
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_org    uuid;
  v_sale   uuid;
  v_item   uuid;
  v_status app.pos_sale_status;
  v_track  text;
  v_kept   boolean;
  v_desc   text;
  v_wh     uuid;
  v_out    text;
  v_ref    text := nullif(btrim(p_serial), '');
  v_refs   text[];
begin
  if v_ref is null then
    raise exception 'Scan a serial number, or type one.'
      using errcode = '23514';
  end if;

  select l.org_id, l.sale_id, l.item_id, l.description,
         coalesce(l.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = l.org_id and w.is_default limit 1)),
         l.serial_refs
    into v_org, v_sale, v_item, v_desc, v_wh, v_refs
    from public.pos_sale_lines l where l.id = p_line;

  if v_org is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  -- A bill that has been paid for or thrown away is not a bill anybody
  -- should still be scanning onto.
  select s.status into v_status from public.pos_sales s where s.id = v_sale;
  if v_status <> 'parked' then
    raise exception 'That bill is % and can no longer be changed.', v_status
      using errcode = '22023';
  end if;

  select i.tracking, i.track_inventory into v_track, v_kept
    from public.items i where i.id = v_item;
  if not coalesce(v_kept, false) or coalesce(v_track, 'none') <> 'serial' then
    raise exception
      '% is not tracked by serial number, so there is nothing to scan.',
      coalesce(v_desc, 'That line') using errcode = '23514';
  end if;

  select o.name into v_out
    from public.pos_sales s
    join public.pos_outlets o on o.id = s.outlet_id
   where s.id = v_sale;

  -- ALREADY ON THIS LINE. Said before the shelf is consulted, because
  -- a double scan of the same label is the commonest thing that
  -- happens at a counter and "not on the shelf" would be a lie about
  -- it -- the unit IS on the shelf; it is on this bill already.
  if v_ref = any (v_refs) then
    raise exception 'Serial % is already on this line.', v_ref
      using errcode = '23514';
  end if;

  if not exists (
    select 1
      from public.v_lot_balances b
      join public.stock_lots s on s.id = b.lot_id
     where b.org_id = v_org
       and b.item_id = v_item
       and b.warehouse_id = v_wh
       and s.kind = 'serial'
       and s.lot_ref = v_ref
       and b.quantity > 0)
  then
    -- Two different problems, two different sentences. A serial this
    -- shop has never heard of is a mistyped label; one that is on file
    -- and not on this shelf has been sold, or is at another outlet, and
    -- the cashier can do something about each.
    if exists (select 1 from public.stock_lots s
                where s.org_id = v_org and s.item_id = v_item
                  and s.kind = 'serial' and s.lot_ref = v_ref) then
      raise exception
        'Serial % is not on the shelf at %. It may already have been '
        'sold, or it may be at another outlet.', v_ref, coalesce(v_out, 'this outlet')
        using errcode = '23514';
    else
      raise exception
        'No serial % on file for %. Check the label, or receive the '
        'stock in first.', v_ref, coalesce(v_desc, 'that item')
        using errcode = '23514';
    end if;
  end if;

  -- ON ANOTHER BILL THAT IS STILL OPEN. The balance cannot see it --
  -- nothing is posted until a bill is paid -- so a serial sitting in a
  -- parked basket at the next till would pass every check above and be
  -- sold twice.
  if exists (
    select 1 from public.pos_sale_lines l
      join public.pos_sales s on s.id = l.sale_id
     where l.org_id = v_org
       and l.id <> p_line
       and s.status = 'parked'
       and v_ref = any (l.serial_refs))
  then
    raise exception
      'Serial % is on another bill that is still open.', v_ref
      using errcode = '23514';
  end if;

  -- The count of serials IS the quantity. A till is used by scanning,
  -- and a quantity the cashier also has to keep in step is a second
  -- source of truth that will disagree with this one.
  update public.pos_sale_lines
     set serial_refs = array_append(serial_refs, v_ref),
         quantity = coalesce(array_length(array_append(serial_refs, v_ref), 1), 1)
   where id = p_line
  returning serial_refs into v_refs;

  -- AND THE MONEY FOLLOWS THE QUANTITY. Writing `quantity` on its own
  -- leaves `line_total` at what one machine cost -- the totals are
  -- computed, not stored by the column -- so the second scan would add
  -- a phone to the bag and nothing to the bill. Caught by the sale
  -- refusing to post: "Journal does not balance: debits 3930.00,
  -- credits 5130.00". `app.reprice_pos_line` is the same function
  -- every other line change goes through, and it recalculates the sale
  -- as well.
  perform app.reprice_pos_line(p_line);

  return v_refs;
end;
$$;

comment on function public.pos_scan_serial(uuid, text) is
  'Scan one serial onto a till line, checked while the customer is '
  'still at the counter. Sets the quantity to the number scanned.';

-- ---------------------------------------------------------------------
-- And taking one off again
-- ---------------------------------------------------------------------
create or replace function public.pos_unscan_serial(
  p_line   uuid,
  p_serial text)
returns text[]
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_org    uuid;
  v_sale   uuid;
  v_status app.pos_sale_status;
  v_ref    text := nullif(btrim(p_serial), '');
  v_refs   text[];
begin
  select l.org_id, l.sale_id, l.serial_refs
    into v_org, v_sale, v_refs
    from public.pos_sale_lines l where l.id = p_line;
  if v_org is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select s.status into v_status from public.pos_sales s where s.id = v_sale;
  if v_status <> 'parked' then
    raise exception 'That bill is % and can no longer be changed.', v_status
      using errcode = '22023';
  end if;

  if v_ref is null or not (v_ref = any (v_refs)) then
    raise exception 'Serial % is not on this line.',
      coalesce(v_ref, '(blank)') using errcode = '23514';
  end if;

  -- The line stays, at a quantity of one, when the last serial comes
  -- off. Deleting it would be a decision this function has no business
  -- making -- the cashier scanned the wrong label, they did not change
  -- their mind about selling a handset.
  update public.pos_sale_lines
     set serial_refs = array_remove(serial_refs, v_ref),
         quantity = greatest(
           coalesce(array_length(array_remove(serial_refs, v_ref), 1), 0), 1)
   where id = p_line
  returning serial_refs into v_refs;

  perform app.reprice_pos_line(p_line);

  return v_refs;
end;
$$;

comment on function public.pos_unscan_serial(uuid, text) is
  'Take a mis-scanned serial back off a till line.';

grant execute on function public.pos_scan_serial(uuid, text) to authenticated;
grant execute on function public.pos_unscan_serial(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- And the counter sale itself: the refusal becomes a check
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_pos_sale(p_sale uuid, p_tenders jsonb, p_contact uuid DEFAULT NULL::uuid)
 RETURNS TABLE(sale_id uuid, invoice_no text, total numeric, cash_due numeric, change_due numeric, rounding numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sale     public.pos_sales;
  v_outlet   public.pos_outlets;
  v_round    boolean;
  v_noncash  numeric := 0;
  v_cashin   numeric := 0;
  v_cashdue  numeric;
  v_adj      numeric;
  v_change   numeric;
  v_contact  uuid;
  v_inv      uuid;
  v_rcp      uuid;
  v_no       text;
  v_line     record;
  v_t        record;
  v_n        integer := 0;
  v_kind     app.pos_tender_kind;
  v_bank     uuid;
  v_mode     text;
  -- What of this basket is going on somebody's account rather than
  -- into the drawer. Counted separately from `v_noncash` because the
  -- two answer different questions: `v_noncash` is what the rounding
  -- rule works from -- an on-account amount is not cash and rounds the
  -- same way a card does -- and this is what no receipt may be written
  -- for.
  v_onacct   numeric := 0;
  v_recv     numeric;
  v_block    text;
  -- 0540. The invoice line just written, and what it needs said about
  -- it before it can be posted.
  v_dl       uuid;
  v_track    text;
  v_kept     boolean;
  v_need     numeric;
  v_got      numeric;
  v_wh       uuid;
  v_pick     record;
  -- 0546. The serials the till scanned onto this line, and the one
  -- being checked against the shelf.
  v_serials  text[];
  v_ref      text;
  v_lot      record;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status
      using errcode = '23514';
  end if;
  -- Aliased, because `sale_id` is also an OUT parameter of this
  -- function and plpgsql cannot tell which one an unqualified reference
  -- means. It refuses rather than guessing, which is the right choice
  -- and only says so at run time.
  if not exists (select 1 from public.pos_sale_lines l where l.sale_id = p_sale) then
    raise exception 'There is nothing on this sale to pay for.'
      using errcode = '23514';
  end if;

  -- The customer, before the basket is touched. `p_contact` is whoever
  -- the tender sheet had selected, and until 0523 nothing checked it
  -- belonged to this company: the sale ran all the way to the INSERT
  -- into `sales_documents`, where `sales_documents_contact_same_org`
  -- refused it -- correctly, and with
  -- `violates foreign key constraint "sales_documents_contact_same_org"`,
  -- which is the last thing a cashier with a queue needs to read. The
  -- key is still what holds the line. This is what says so.
  if p_contact is not null and not exists (
       select 1 from public.contacts c
        where c.id = p_contact and c.org_id = v_sale.org_id) then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;

  -- Worked out again here, not trusted from the screen. A bill parked
  -- at ten to eleven and settled at five past is settled outside the
  -- happy hour, and the customer is charged what the shop's own rule
  -- says at the moment the money changes hands. Re-read afterwards,
  -- because this is what moves the total.
  perform app.refresh_pos_promotions(p_sale);
  perform app.recalc_pos_sale(p_sale);
  select * into v_sale from public.pos_sales where id = p_sale;

  -- The zone minimum, checked at the one moment the basket is final.
  -- Refusing at the door would refuse the wrong thing: every shop with
  -- a minimum takes the address first and the order second.
  v_block := app.pos_delivery_blocked(p_sale);
  if v_block is not null then
    raise exception '%', v_block using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  select coalesce(ps.round_cash_to_5sen, true) into v_round
    from public.pos_settings ps where ps.org_id = v_sale.org_id;
  v_round := coalesce(v_round, true);

  -- --------------------------------------------------------------
  -- What is being paid with what
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid   as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference'     as reference
      from jsonb_array_elements(coalesce(p_tenders, '[]'::jsonb)) e
  loop
    if v_t.amount is null or v_t.amount <= 0 then
      raise exception 'A tender needs an amount.' using errcode = '23514';
    end if;
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id and tt.org_id = v_sale.org_id and tt.is_active;
    if v_kind is null then
      raise exception 'That is not a tender this company accepts.'
        using errcode = 'P0002';
    end if;
    if v_kind = 'cash' then
      v_cashin := v_cashin + v_t.amount;
    else
      v_noncash := v_noncash + v_t.amount;
      if v_kind = 'on_account' then
        v_onacct := v_onacct + v_t.amount;
      end if;
    end if;
    v_n := v_n + 1;
  end loop;

  -- A basket covered entirely by points has nothing left to tender,
  -- and that is a completed sale rather than an unpaid one. Without
  -- this, a customer with enough points to clear the till could put
  -- them all against the basket and then find the sale could not be
  -- rung up at all -- a dead end reachable from the screen that offers
  -- the redemption.
  if v_n = 0 and v_sale.total_amount > 0 then
    raise exception 'A sale has to be paid for.' using errcode = '23514';
  end if;

  -- 0208's rule: round what is left after everything that is not cash.
  v_cashdue := app.pos_cash_due(v_sale.total_amount, v_noncash, v_round);
  v_adj     := app.pos_rounding_adjustment(v_sale.total_amount, v_noncash, v_round);
  v_change  := round(v_cashin - v_cashdue, 2);

  if v_change < 0 then
    raise exception
      'Short by %. The customer still owes that much.', -v_change
      using errcode = '23514';
  end if;
  -- Non-cash cannot over-pay: a card charged more than the basket is a
  -- refund waiting to happen, not a sale.
  if v_noncash > v_sale.total_amount + 0.005 and v_cashin = 0 then
    raise exception
      'That is more than the basket comes to. Charge the card the right '
      'amount, or take the difference as a refund.'
      using errcode = '23514';
  end if;

  v_contact := coalesce(p_contact, v_sale.contact_id, v_outlet.walk_in_contact_id);
  if v_contact is null then
    raise exception
      'This outlet has no walk-in customer set, so an anonymous sale has '
      'nobody to bill. Set one on the outlet.'
      using errcode = '23502';
  end if;

  -- The walk-in contact is not an account. It is one row every
  -- anonymous sale in the outlet is billed to, so putting a basket on
  -- it would build a receivable balance belonging to nobody, that
  -- nobody would ever be chased for. An on-account sale has to name a
  -- customer, which is why this checks what was passed rather than
  -- `v_contact` -- the fallback above is exactly what must not count.
  if v_onacct > 0 and coalesce(p_contact, v_sale.contact_id) is null then
    raise exception
      'A sale on account has to name the customer whose account it goes '
      'on.'
      using errcode = '23502';
  end if;

  -- --------------------------------------------------------------
  -- The invoice
  -- --------------------------------------------------------------
  v_no := app.next_document_number_internal(v_sale.org_id, 'invoice');

  -- No salesperson. `sales_documents.salesperson_id` points at
  -- `public.salespeople` — a commission record — and not at the user
  -- who rang the sale up. A cashier is not automatically one of those,
  -- and 0105 has a trigger that says so. Who served the customer is on
  -- `pos_sales.sold_by`, which is the right place for it; a shop that
  -- pays counter commission can map the two later.
  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, notes, created_by)
  values (
    v_sale.org_id, 'invoice', v_no, app.today(), app.today(), v_contact,
    'MYR', 1, 'draft',
    'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_inv;

  for v_line in
    select * from public.pos_sale_lines l where l.sale_id = p_sale order by l.line_no
  loop
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, discount_amount, tax_code_id,
      tax_rate, is_tax_inclusive, warehouse_id)
    values (
      v_sale.org_id, v_inv, v_line.line_no, 'item', v_line.item_id,
      v_line.description, v_line.quantity, v_line.uom_code,
      v_line.unit_price, v_line.discount_amount, v_line.tax_code_id,
      v_line.tax_rate, v_line.is_tax_inclusive, v_line.warehouse_id)
    returning id into v_dl;

    -- 0540. WHICH BATCH LEFT THE SHELF, decided here because there is
    -- nobody to ask.
    --
    -- `app.materialise_movement_lots` refuses a movement of a tracked
    -- item that names no batch, and the delivery movement this invoice
    -- posts carries `source_table = 'sales_documents'` -- which is
    -- deliberately not in the function's earliest-expiry-first list,
    -- because an office typing an invoice CAN be asked which batch went
    -- and a silent pick there would let a recall miss the customer
    -- holding the affected box.
    --
    -- A till cannot be asked. Nobody stands at a counter reading batch
    -- numbers off a carton of milk, and there is no screen in the POS
    -- that could take the answer. So until this, a pharmacy, a
    -- mini-market or anybody else selling dated stock could not ring a
    -- sale through at all: the tender went in and the sale came back
    -- refused in the invariant's own words.
    --
    -- The shop's answer is earliest expiry first, which is what it does
    -- with its hands anyway, and writing it onto the invoice line as
    -- `document_line_lots` means the paper says which batch went
    -- exactly as a typed invoice would. The refusal above is untouched
    -- and still catches the invoice nobody named lots on.
    select i.tracking, i.track_inventory into v_track, v_kept
      from public.items i where i.id = v_line.item_id;

    -- BATCH IS PICKED, SERIAL IS SCANNED, and the difference is not a
    -- detail.
    --
    -- A batch names a production run. Which carton of the run the
    -- customer walked out with is not a fact anybody at the counter
    -- knows or needs to, and earliest-expiry-first is what the shop
    -- does with its hands, so the pick is a true statement.
    --
    -- A serial names ONE PHYSICAL UNIT. Picking one on the customer's
    -- behalf would print a serial number on their invoice and their
    -- warranty for a machine somebody else is holding, and the first
    -- anyone would hear of it is a warranty claim being refused. `0540`
    -- refused the sale outright and said why: "that wants a scan field
    -- at the till". This is that field's other end.
    --
    -- So the till says which units left, and this only checks. Nothing
    -- here guesses.
    if coalesce(v_kept, false) and coalesce(v_track, 'none') = 'serial' then
      select coalesce(l.base_quantity, l.quantity),
             coalesce(l.warehouse_id,
                      (select w.id from public.warehouses w
                        where w.org_id = v_sale.org_id and w.is_default
                        limit 1))
        into v_need, v_wh
        from public.sales_document_lines l where l.id = v_dl;

      v_serials := coalesce(v_line.serial_refs, '{}'::text[]);
      v_got := coalesce(array_length(v_serials, 1), 0);

      -- ONE SCAN PER UNIT, and counted rather than assumed. A cashier
      -- who typed the quantity up to three and scanned two is the
      -- ordinary way this goes wrong, and it goes wrong silently: the
      -- movement takes three off the shelf and the paper names two.
      if v_got <> v_need then
        raise exception
          '% leaves the shop by serial number: % on the bill and % '
          'scanned. Scan the rest, or put the quantity back to %.',
          v_line.description, trim_scale(v_need), trim_scale(v_got),
          trim_scale(v_got)
          using errcode = '23514';
      end if;

      foreach v_ref in array v_serials
      loop
        -- ON THE SHELF THIS SALE IS SELLING FROM. `pos_scan_serial`
        -- asked the same question when the cashier scanned, and this
        -- asks it again -- because an offline bill that landed hours
        -- later never went through that door, and because a serial
        -- somebody else sold in between is exactly what a queued
        -- basket cannot know.
        select s.lot_ref, s.expiry_date, s.manufactured_on,
               s.supplier_lot_ref
          into v_lot
          from public.v_lot_balances b
          join public.stock_lots s on s.id = b.lot_id
         where b.org_id = v_sale.org_id
           and b.item_id = v_line.item_id
           and b.warehouse_id = v_wh
           and s.kind = 'serial'
           and s.lot_ref = v_ref
           and b.quantity > 0
         limit 1;

        if not found then
          raise exception
            'Serial % is not on the shelf at %. It may already have '
            'been sold, or it belongs to another item.',
            v_ref, v_outlet.name using errcode = '23514';
        end if;

        -- THE SAME MACHINE TWICE ON ONE BILL. Nothing on this bill is
        -- posted yet, so the balance above still shows a unit this
        -- basket has already claimed on an earlier line -- the same
        -- hole the batch loop below deducts for, and on a serial it is
        -- worse: two customers would leave holding one warranty.
        if exists (
          select 1 from public.document_line_lots d
            join public.sales_document_lines dl on dl.id = d.sales_line_id
           where dl.document_id = v_inv
             and dl.item_id = v_line.item_id
             and d.lot_ref = v_ref) then
          raise exception
            'Serial % is on this bill twice. One serial is one machine.',
            v_ref using errcode = '23514';
        end if;

        -- A serial is one unit by definition, which is why the quantity
        -- is written and not read.
        insert into public.document_line_lots
          (org_id, sales_line_id, lot_ref, quantity, expiry_date,
           manufactured_on, supplier_lot_ref)
        values (v_sale.org_id, v_dl, v_lot.lot_ref, 1,
                v_lot.expiry_date, v_lot.manufactured_on,
                v_lot.supplier_lot_ref);
      end loop;
    end if;

    if coalesce(v_kept, false) and coalesce(v_track, 'none') = 'batch' then
      -- Read back rather than recomputed: `base_quantity` is what the
      -- movement will be in -- two cartons of twenty-four is forty-eight
      -- off the shelf -- and the warehouse falls back the same way the
      -- posting's does, so the pick is against the shelf the stock will
      -- actually come off.
      select coalesce(l.base_quantity, l.quantity),
             coalesce(l.warehouse_id,
                      (select w.id from public.warehouses w
                        where w.org_id = v_sale.org_id and w.is_default
                        limit 1))
        into v_need, v_wh
        from public.sales_document_lines l where l.id = v_dl;

      -- `app.pick_lots_fefo`'s own order, and its own rule, spelled out
      -- here for one reason: NOTHING ON THIS BILL IS POSTED YET. The
      -- picker reads `v_lot_balances`, which is built from movements,
      -- and this sale's movements are written when the invoice posts —
      -- after this loop has finished with every line. So two lines of
      -- the same tracked item on one bill (a cashier scanning the same
      -- box twice, which is how a till is used) would both see the full
      -- balance and both claim the same batch, and the shop would hand
      -- over two boxes having recorded one twice.
      --
      -- What this sale has already claimed comes off the balance the
      -- next line picks from.
      v_got := 0;
      for v_pick in
        select b.lot_id, s.lot_ref, s.expiry_date, s.manufactured_on,
               s.supplier_lot_ref,
               b.quantity - coalesce(c.claimed, 0) as spare
          from public.v_lot_balances b
          join public.stock_lots s on s.id = b.lot_id
          left join lateral (
            select sum(d.quantity) as claimed
              from public.document_line_lots d
              join public.sales_document_lines dl on dl.id = d.sales_line_id
             where dl.document_id = v_inv
               and dl.item_id = v_line.item_id
               and d.lot_ref = s.lot_ref
          ) c on true
         where b.item_id = v_line.item_id
           and b.warehouse_id = v_wh
           and b.quantity - coalesce(c.claimed, 0) > 0
         order by b.expiry_date asc nulls last, b.lot_ref
      loop
        exit when v_got >= v_need;
        insert into public.document_line_lots
          (org_id, sales_line_id, lot_ref, quantity, expiry_date,
           manufactured_on, supplier_lot_ref)
        values (v_sale.org_id, v_dl, v_pick.lot_ref,
                least(v_pick.spare, v_need - v_got),
                v_pick.expiry_date, v_pick.manufactured_on,
                v_pick.supplier_lot_ref);
        v_got := v_got + least(v_pick.spare, v_need - v_got);
      end loop;

      -- And if the shelf cannot cover it, said in words a cashier can
      -- act on. Without this the sale would post with the invoice
      -- naming less than the movement took, which is a traceability
      -- hole written down rather than a refusal: the batches on the
      -- paper would not add up to the units that left.
      if v_got < v_need then
        raise exception
          '% is tracked by %, and only % of the % asked for is on the '
          'shelf at %. Receive the stock, or take the line off the bill.',
          v_line.description, v_track, trim_scale(v_got),
          trim_scale(v_need), v_outlet.name
          using errcode = '23514';
      end if;
    end if;
  end loop;

  -- After the lines, because the totals trigger fires on line changes
  -- and would otherwise impose the organization's rounding on a card
  -- sale. See the header: this is POS taking a number the trigger
  -- normally owns, and the test asserts the result.
  update public.sales_documents d
     set rounding_amount = v_adj,
         -- The redemption AND the bill discount, on the header rather
         -- than spread across the lines. `sales_documents.discount_amount`
         -- is exactly the field for a discount that belongs to the
         -- document, and `prepare_einvoice` already maps it to the
         -- MyInvois total discount, so what LHDN is told matches what
         -- was charged. Both are added because both came off the same
         -- header: reporting only one of them would understate the
         -- discount on every bill a manager touched.
         discount_amount = coalesce(v_sale.loyalty_discount, 0)
                         + coalesce(v_sale.bill_discount, 0)
                         + coalesce(v_sale.promo_discount, 0),
         -- The ride, on the field the ledger already knows what to do
         -- with. 0013 posts shipping_amount to 4900 on its own, so the
         -- courier charge lands in its own revenue account instead of
         -- in food sales, and the journal still balances because the
         -- receivable was always the header total.
         shipping_amount = coalesce(v_sale.delivery_fee, 0),
         -- The service charge, on its own header field so it posts to
         -- 4250 rather than disappearing into food sales, and its tax
         -- added to what the lines already carry. The lines' trigger
         -- owns `tax_amount` and recomputes it from the lines; this
         -- runs after the last line and the document is frozen the
         -- moment it posts, so the addition stands. Same bargain as
         -- `rounding_amount` two fields up, and for the same reason.
         service_charge_amount = coalesce(v_sale.service_charge, 0),
         -- 0418. The tax on the charge, and the code it was charged
         -- under, kept on the document rather than only inside the
         -- header total. The SST-02 return is built by tax type, and a
         -- figure folded into `tax_amount` with no code on it cannot be
         -- put in a column of that return -- which is how eighty sen in
         -- every hundred ringgit went undeclared.
         service_charge_tax = coalesce(v_sale.service_charge_tax, 0),
         service_charge_tax_code_id = v_outlet.service_charge_tax_code_id,
         tax_amount = round(coalesce(d.tax_amount, 0)
                          + coalesce(v_sale.service_charge_tax, 0), 2),
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  -- Before the posting, not after. `app.enforce_credit_limit` fires on
  -- the document being posted and has to be able to tell how much
  -- credit this counter sale is extending -- which is the on-account
  -- tender, not the basket. It asks `pos_sales` by `invoice_id`, and a
  -- link written after the posting is a link that is not there when the
  -- question is asked. The rest of the sale's completion still happens
  -- below, in one statement, as it did. See 0467.
  update public.pos_sales s
     set invoice_id = v_inv, on_account_amount = v_onacct
   where s.id = p_sale;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- What actually arrived. An on-account tender is a promise, so the
  -- receipt is for the rest of the basket and the remainder stays on
  -- the invoice for the customer to settle later.
  v_recv := round(v_sale.total_amount + v_adj - v_onacct, 2);

  -- Banked against the first tender's account, skipping any that went
  -- on account -- those have no bank account and never will, and a null
  -- one falls back to the current account, which is the whole failure
  -- being fixed here. A shop splitting one sale across two accounts is
  -- real and is not this migration's problem; what matters is that the
  -- money lands somewhere named rather than in the current account by
  -- default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from jsonb_array_elements(p_tenders) with ordinality as e(t, ord)
    join public.pos_tender_types tt on tt.id = (t ->> 'type')::uuid
   where tt.kind <> 'on_account'
   order by e.ord
   limit 1;

  -- A receipt unless the whole basket went on account. Not `v_recv > 0`
  -- on its own: a basket cleared entirely by loyalty points also comes
  -- to nothing, and `0212` deliberately gives that one a receipt for
  -- zero so the sale is a completed sale rather than a stuck one. The
  -- two zeroes mean different things and only one of them means no
  -- money was taken.
  if v_onacct = 0 or v_recv > 0 then
    v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

    insert into public.receipts (
      org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
      bank_account_id, currency, exchange_rate, amount, base_amount,
      status, notes, created_by)
    values (
      v_sale.org_id, v_no, app.today(), v_contact, v_mode, v_bank,
      'MYR', 1, v_recv, v_recv,
      'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
    returning id into v_rcp;
  end if;

  -- Only when there is something to allocate. `payment_allocations`
  -- checks that its amount is positive, and it is right to: an
  -- allocation of nothing is not an allocation. A basket cleared by
  -- points leaves an invoice for zero, which already owes nothing, so
  -- there is nothing for a receipt to settle against it.
  if v_recv > 0 then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_by)
    values
      (v_sale.org_id, v_rcp, v_inv, v_recv, v_sale.sold_by);
  end if;

  if v_rcp is not null then
    perform app.post_receipt_internal(v_rcp);
  end if;

  -- --------------------------------------------------------------
  -- And the tenders, now that they are known to be good
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference' as reference,
           row_number() over () as rn,
           count(*) over () as total_rows
      from jsonb_array_elements(p_tenders) e
  loop
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id;
    insert into public.pos_tenders
      (org_id, sale_id, tender_type_id, kind, amount, change_given, reference)
    values
      (v_sale.org_id, p_sale, v_t.type_id, v_kind, v_t.amount,
       -- Change comes out of the last tender offered, which is the one
       -- the customer is standing there waiting for.
       case when v_t.rn = v_t.total_rows then v_change else 0 end,
       v_t.reference);
  end loop;

  update public.pos_sales s
     set status = 'completed',
         completed_at = now(),
         contact_id = v_contact,
         rounding_amount = v_adj,
         total_amount = round(v_sale.total_amount + v_adj, 2),
         invoice_id = v_inv,
         receipt_id = v_rcp,
         on_account_amount = v_onacct
   where s.id = p_sale;

  -- --------------------------------------------------------------
  -- And the points, last
  -- --------------------------------------------------------------
  -- Nothing above this line touches the loyalty ledger. A parked sale
  -- holds no points: it can be abandoned, and a customer whose balance
  -- fell when a cashier changed their mind has been robbed by a
  -- transaction that never happened.
  -- On the food, not on the ride. A shop that pays points on a courier
  -- charge is paying points on money it hands straight to a rider.
  perform app.pos_settle_loyalty(
    p_sale,
    greatest(round(v_sale.total_amount + v_adj
                   - coalesce(v_sale.delivery_fee, 0), 2), 0));

  sale_id := p_sale;
  select d.doc_no into invoice_no from public.sales_documents d where d.id = v_inv;
  -- Scaled to the sen on the way out. `numeric` with no declared scale
  -- is exact and prints as 10.8500000000000000, which reaches the till
  -- as a string and is the one number a customer reads back off a
  -- receipt. Correct is not the same as legible.
  total := round(v_sale.total_amount + v_adj, 2);
  cash_due := round(v_cashdue, 2);
  change_due := round(v_change, 2);
  rounding := round(v_adj, 2);
  return next;
end;
$function$;
