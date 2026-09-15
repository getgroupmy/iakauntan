-- =====================================================================
-- iAkauntan :: 0593 delete, and what goes with it
--
-- The eighth slice of the undocumented writes: the four whose names
-- promise a tidy-up. Three of them really delete, and each takes
-- something with it that the name does not mention. The fourth is a
-- soft delete wearing an honest name.
--
-- These are the small verbs on a settings screen, pressed by somebody
-- clearing up a list they no longer use, and none of them refuses. The
-- published description said `delete_item_uom_pack(uuid, text)` and
-- nothing else, which tells a caller the one thing they already knew.
--
-- ---------------------------------------------------------------------
-- What each one takes with it, checked rather than assumed
--
-- `item_conversions` is referenced by `item_conversion_outputs` twice,
-- both ON DELETE CASCADE. Deleting the conversion deletes what it
-- produced, in the same statement, with nothing said.
--
-- `item_uom_packs` is referenced by nothing at all -- and that is the
-- dangerous one. `sales_document_lines`, `purchase_document_lines`,
-- `pos_sale_lines` and `stock_transfer_lines` each carry `uom_code` as
-- free text, and `app.uom_qty` resolves it by looking the pack up. Take
-- the pack away and a line that reads "3 CTN" keeps the word and loses
-- the arithmetic: `uom_qty` falls through to the dimension factors in
-- `ref_uom_factors` and, failing those, raises 22023 -- "There is no
-- way to turn CTN into EA". A constraint would have refused the
-- delete; there is none, so the refusal arrives later, at whoever
-- re-derives a quantity from an old document.
--
-- And there is a worse half to that one, found by writing the test
-- rather than by reading the function. Where the unit HAS a standard
-- factor, `uom_qty` does not raise: it falls through to the factor and
-- answers a different number to the same question. A company selling
-- ten to the dozen box, whose pack said so, re-derives at the standard
-- twelve once the pack is gone. Thirty becomes thirty-six and nothing
-- anywhere says a word. `delete_takes_more_than_it_says.sql` asserts
-- both halves.
--
-- `scale_barcode_formats` is read by `app.parse_scale_barcode`. A
-- weighed label printed under a format that has been deleted stops
-- being readable at the till.
--
-- ---------------------------------------------------------------------
-- And one that answers differently
--
-- The three hard deletes return false for a row that is not there. So
-- "I deleted it" and "there was nothing to delete" are the same answer,
-- and a caller cannot tell them apart. `retire_cash_forecast_item`
-- raises `P0002` instead.
--
-- That inconsistency is described rather than changed. Two of the three
-- are called from a settings list where the row was on screen a moment
-- ago and false means the list is stale, which is a reasonable thing
-- for them to say; changing the contract of a published function is a
-- different migration from writing down what it currently is.
-- =====================================================================

comment on function public.delete_item_conversion(uuid) is
  'Deletes a conversion, AND ITS OUTPUT LINES WITH IT: '
  '`item_conversion_outputs` is ON DELETE CASCADE, so what the '
  'conversion produced goes in the same statement. Nothing is checked '
  'first -- there is no refusal if the conversion has been run. Returns '
  'false when there is no such row, which is the same answer as a '
  'successful delete of a row that is now gone; a caller cannot tell '
  'the two apart. Needs the inventory module.';

comment on function public.delete_item_uom_pack(uuid, text) is
  'Removes a pack size from an item -- the row that says one CT is '
  'twelve. NOTHING REFERENCES IT AND THAT IS THE PROBLEM: document '
  'lines carry `uom_code` as text, so an invoice reading "3 CT" keeps '
  'the word and loses the arithmetic. `app.uom_qty` resolves a unit by '
  'looking this table up first, then by the standard factors in '
  '`ref_uom_factors`. Which of the two comes next decides how badly '
  'this goes. Where there is no standard factor -- CT is not one -- it '
  'raises 22023, "There is no way to turn CT into EA", and somebody '
  'sees it. WHERE THERE IS ONE IT DOES NOT REFUSE AT ALL: a company '
  'selling ten to the dozen box had a pack saying so, and with the '
  'pack gone the same line re-derives against the standard twelve. '
  'Thirty becomes thirty-six, on a stock take, with no error anywhere. '
  'Either way the delete succeeds and the consequence arrives later. '
  'Returns false when there was no such pack. Needs the inventory '
  'module.';

comment on function public.delete_scale_format(uuid) is
  'Deletes a scale barcode format. `app.parse_scale_barcode` reads '
  'these to take the weight and the price out of a label a scale '
  'printed, so a label already on a package, printed under the format '
  'being deleted, stops being readable at the till. Nothing is checked '
  'and nothing refuses. Returns false when there is no such row. Needs '
  'the POS module.';

comment on function public.retire_cash_forecast_item(uuid) is
  'Switches a standing forecast line off. NOT A DELETE, despite '
  'sitting beside three that are: it sets `is_active` false, because a '
  'forecast circulated last month was run against these rows and '
  'deleting one makes it impossible to explain why the figure was what '
  'it was. Raises `P0002` for a row that is not there rather than '
  'returning false, which is the opposite of the three deletes in this '
  'migration. Needs the accounting module.';
