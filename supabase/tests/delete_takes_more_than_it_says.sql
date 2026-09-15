-- =====================================================================
-- iAkauntan :: what a delete takes with it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/delete_takes_more_than_it_says.sql
--
-- `0593` publishes four claims about the small delete verbs, and a
-- published claim that quietly stops being true is worse than no claim
-- at all: a caller reads the description, believes it, and finds out
-- otherwise in front of a customer.
--
-- Each of the three below is a claim somebody could undo without
-- meaning to. A future migration that adds `on delete restrict` to
-- `item_conversion_outputs` would make the first one false and nothing
-- would say so. A future `uom_qty` that returned the quantity
-- unconverted rather than raising would make the second false, and
-- would be far worse than the raise it replaced -- a line reading
-- "3 CTN" silently counted as three.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org  uuid;
  v_from uuid;
  v_to   uuid;
  v_conv uuid;
  v_item uuid;
  v_fc   uuid;
  v_n    integer;
  v_act  boolean;
begin
  v_org := pg_temp.test_org('Delete Test Sdn Bhd');

  -- ------------------------------------------------------------------
  -- A conversion takes its outputs with it
  -- ------------------------------------------------------------------
  insert into public.items (org_id, code, name, uom_code)
  values (v_org, 'RAW', 'Sack of rice', 'EA') returning id into v_from;
  insert into public.items (org_id, code, name, uom_code)
  values (v_org, 'PACK', 'Bag of rice', 'EA') returning id into v_to;

  insert into public.item_conversions
    (org_id, code, name, from_item_id, from_quantity, from_uom_code)
  values (v_org, 'C-1', 'Repack', v_from, 1, 'EA')
  returning id into v_conv;

  insert into public.item_conversion_outputs
    (org_id, conversion_id, line_no, item_id, quantity, uom_code, cost_share)
  values (v_org, v_conv, 1, v_to, 20, 'EA', 1);

  perform pg_temp.check_true('the conversion has an output',
    (select count(*) from public.item_conversion_outputs o
      where o.conversion_id = v_conv) = 1);

  perform public.delete_item_conversion(v_conv);

  select count(*) into v_n from public.item_conversion_outputs o
   where o.conversion_id = v_conv;
  -- The claim in 0593: the cascade is the behaviour, not an accident,
  -- and the description says so because nothing else does.
  perform pg_temp.check_eq('deleting it took its outputs too', v_n, 0);

  -- And "deleted" and "there was nothing there" are the same answer.
  perform pg_temp.check_true('a second delete says false rather than raising',
    public.delete_item_conversion(v_conv) = false);

  -- ------------------------------------------------------------------
  -- A pack size is what turns a word on a document into a quantity
  -- ------------------------------------------------------------------
  insert into public.items (org_id, code, name, uom_code)
  values (v_org, 'TIN', 'Tin of milk', 'EA') returning id into v_item;

  insert into public.item_uom_packs (org_id, item_id, uom_code, qty_in_stock_uom)
  values (v_org, v_item, 'CT', 12);

  perform pg_temp.check_eq('a carton is twelve while the pack exists',
    app.uom_qty(v_item, 3, 'CT'), 36);

  perform pg_temp.check_true('and the pack is deleted without a murmur',
    public.delete_item_uom_pack(v_item, 'CT') = true);

  -- A document line still reads "3 CT"; there is no longer anything
  -- that says what a CT is, and `uom_qty` raises rather than guessing.
  -- A future version that returned 3 would be far worse than this
  -- refusal -- three cartons counted as three tins, silently, on a
  -- stock take.
  perform pg_temp.check_refused(
    'and the word on the old document can no longer be turned into a quantity',
    format('select app.uom_qty(%L, 3, %L)', v_item, 'CT'),
    '%no way to turn CT into EA%');

  perform pg_temp.check_true('deleting a pack that is not there says false',
    public.delete_item_uom_pack(v_item, 'CT') = false);

  -- ------------------------------------------------------------------
  -- The worse half: where the fallback SUCCEEDS
  -- ------------------------------------------------------------------
  --
  -- `CT` has no row in `ref_uom_factors`, so deleting its pack ends in
  -- a refusal somebody sees. `DZN` does have one -- a dozen is twelve
  -- everywhere -- and a company that sells them ten to the box is
  -- entitled to say so with a pack of its own.
  --
  -- Delete that pack and `uom_qty` does not refuse. It falls through to
  -- the standard factor and answers a DIFFERENT NUMBER to the same
  -- question, with no error anywhere: the same line, re-derived, is
  -- twelve to the box instead of ten. This is why 0593 says the delete
  -- succeeds and the failure arrives later.
  insert into public.item_uom_packs (org_id, item_id, uom_code, qty_in_stock_uom)
  values (v_org, v_item, 'DZN', 10);

  perform pg_temp.check_eq('the company''s own pack is what counts',
    app.uom_qty(v_item, 3, 'DZN'), 30);

  perform pg_temp.check_true('delete it',
    public.delete_item_uom_pack(v_item, 'DZN') = true);

  perform pg_temp.check_eq(
    'and the same line now answers the standard dozen instead, silently',
    app.uom_qty(v_item, 3, 'DZN'), 36);

  -- ------------------------------------------------------------------
  -- And the one that is not a delete at all
  -- ------------------------------------------------------------------
  insert into public.cash_forecast_items
    (org_id, direction, description, amount, expected_on)
  values (v_org, 'out', 'Rent', 4500, app.today() + 30)
  returning id into v_fc;

  perform public.retire_cash_forecast_item(v_fc);

  select is_active into v_act from public.cash_forecast_items where id = v_fc;
  -- A forecast circulated last month was run against this row, so it
  -- is switched off rather than removed: deleting it would make the
  -- figure in that forecast impossible to explain.
  perform pg_temp.check_true('a retired forecast line is still on file',
    v_act is false);

  -- The inconsistency 0593 describes rather than changes: this one
  -- raises where the three deletes return false.
  perform pg_temp.check_refused(
    'and retiring one that does not exist raises rather than saying false',
    format('select public.retire_cash_forecast_item(%L)', gen_random_uuid()),
    '%No such item%');
end;
$$;

rollback;
