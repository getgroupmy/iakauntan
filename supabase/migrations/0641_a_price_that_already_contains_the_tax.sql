-- =====================================================================
-- iAkauntan :: 0641 a price that already contains the tax
--
-- Tax-inclusive pricing existed in two halves that had never met.
--
-- `app.calc_document_line` has always honoured `is_tax_inclusive` on a
-- document line: given the flag, it divides the gross by one plus the
-- rate instead of adding the rate on top. And `tax_codes.is_inclusive`
-- has been a column since `0003`.
--
-- Nothing connected them. `LineDraft.isTaxInclusive` in the Flutter
-- client is `false` and no widget ever changed it; no SQL function ever
-- read `tax_codes.is_inclusive`; and the tax code dialog never offered
-- it. So the flag on the line could only ever be false, the flag on the
-- code could only ever be false, and no document in this product could
-- be raised at a price that includes its tax.
--
-- Found by sweeping every column in `public` for one that nothing --
-- no function, no view, no constraint, no index, no Dart, no edge
-- function, no assertion -- mentions at all. `is_inclusive` was one of
-- twenty.
--
-- ---------------------------------------------------------------------
-- Why it is the tax code that decides
--
-- Because that is where the answer belongs and where the column already
-- was. "Prices include SST" is a property of how a business quotes,
-- which in Malaysia follows the tax it is registered for -- not
-- something to be re-chosen on every line of every invoice, which is
-- how a document ends up half inclusive and half not.
--
-- The POS side already works this way and reaches the same conclusion
-- from a different direction: `app.add_pos_sale_line_internal` reads
-- `prices_include_tax` off the OUTLET, because a menu price is
-- inclusive for the whole shop or for none of it. Documents have no
-- outlet, and the tax code is the nearest thing that carries the same
-- meaning.
--
-- ---------------------------------------------------------------------
-- Resolved when the code is CHOSEN, then left alone
--
-- On insert, and on an update that changes `tax_code_id`. Not on every
-- update, and that is the whole of the care in this migration.
--
-- The line already keeps its own `tax_rate` rather than reading the
-- code's, deliberately -- `sst_taxable_period.sql` says why: a rate
-- that moves would otherwise restate every invoice that ever used the
-- code. Whether the price includes the tax is the same kind of fact
-- about the same moment, so it is snapshotted the same way. Re-reading
-- it on every update would mean that marking a code inclusive today
-- silently re-computes any draft line touched tomorrow, on a price
-- somebody typed as exclusive.
--
-- Changing the code ON a line is a new choice, so it resolves again.
-- That is the case a plain `tg_op = 'INSERT'` guard would get wrong:
-- swapping a line from an exclusive code to an inclusive one would
-- keep computing it the old way.
--
-- ---------------------------------------------------------------------
-- The code may turn it ON. It may not turn it off
--
-- On insert the code's answer is OR-ed with what the row arrived with,
-- and this is the part that was written the other way round first.
--
-- Replacing the row's flag outright broke the POS, and `pos.sql` said
-- so in one line: `Journal does not balance: debits 108.00, credits
-- 116.64`. A shop whose menu prices include the tax stamps the flag on
-- the sale line from the OUTLET -- `add_pos_sale_line_internal` has
-- always done this -- and the invoice that sale becomes carries it. An
-- override resolved that invoice line against the tax code instead,
-- found `is_inclusive = false`, and charged 8.64 of tax on a plate the
-- till had taken 108.00 in cash for. Sixty-four sen of tax on money
-- nobody paid, on every line of every bill, and the SST-02 return is
-- built from that figure.
--
-- So the two sources are not ranked; neither may cancel the other. The
-- code knows how the business QUOTES; the till knows what the shop
-- actually charged. Both are authoritative where they speak, and a
-- false from a caller that has no opinion must not read as a denial.
--
-- Changing the code ON an existing line is the one place the code
-- answers in both directions, because there is no till in that story --
-- somebody is choosing a code on a document, and a line that went on
-- computing inclusively against a code that says otherwise could never
-- be put right.
--
-- It changes nothing that exists. Every tax code in every deployment
-- has `is_inclusive = false` -- the column has never been writable --
-- and every document line has `is_tax_inclusive = false`, so this
-- migration is a no-op on all present data and starts mattering only
-- when somebody marks a code inclusive, which is the intent.
--
-- A line with NO tax code keeps whatever it arrived with. There is
-- nothing to resolve from, and zero-rated lines are computed the same
-- way either way.
--
-- The Flutter editor resolves it from the code at the same two moments
-- (`applyItemToLine`, and the tax picker's `onChanged`), because
-- `computeLine` mirrors this function to show a total before the row is
-- saved. A screen that showed the exclusive total for a line the
-- trigger stores inclusive would be worse than not offering it.
--
-- Restated whole from what is applied, with the resolution added and
-- nothing else changed.
-- =====================================================================

create or replace function app.calc_document_line()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$

declare
  v_gross     numeric(18, 4);
  v_discount  numeric(18, 2);
  v_net       numeric(18, 2);
  v_tax       numeric(18, 2);
  v_incl      boolean;
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

  -- Whether the price already contains the tax is a property of the TAX
  -- CODE, resolved the moment the code is chosen and then left on the
  -- line. See the migration header: `tax_codes.is_inclusive` had never
  -- been read by anything, and no document could be raised at a price
  -- that included its tax.
  --
  -- Insert, or an update that changes the code. NOT every update: the
  -- line keeps its own `tax_rate` rather than reading the code's so
  -- that a rate which moves does not restate old documents, and this is
  -- the same fact about the same moment.
  --
  -- `v_incl` comes back null for a line with no code, which is why
  -- there is no `is not null` guard: on insert the line then keeps its
  -- own flag, and on an update that clears the code it loses it, which
  -- is what both mean.
  if tg_op = 'INSERT'
     or new.tax_code_id is distinct from old.tax_code_id then
    select t.is_inclusive into v_incl
      from public.tax_codes t where t.id = new.tax_code_id;
    new.is_tax_inclusive := case
      -- On insert the caller may know something the code does not: the
      -- POS stamps this from the OUTLET, and a menu price that includes
      -- the tax is not made exclusive by the tax code saying nothing.
      -- OR-ed, so the code can turn it on and cannot turn it off.
      when tg_op = 'INSERT'
        then coalesce(new.is_tax_inclusive, false) or coalesce(v_incl, false)
      -- Choosing a different code is choosing again, and there the code
      -- answers both ways.
      else coalesce(v_incl, false)
    end;
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

$function$;
