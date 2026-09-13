-- =====================================================================
-- iAkauntan :: 0574 create or replace, the whole thing
--
-- Sixth slice: the `upsert_*` family, all eighteen.
--
-- An upsert carries a hazard the other verbs do not, and it is the
-- thing a caller most needs told: **the ones that take lines REPLACE
-- them wholesale.** `upsert_stock_transfer`, `upsert_landed_cost_run`,
-- `upsert_item_conversion` and `upsert_pos_recipe` each delete every
-- line the record had and write what was sent. Send a shorter list and
-- the difference is gone. None of them merges, and a caller assuming
-- otherwise loses rows silently.
--
-- The second thing: all four are DRAFT ONLY, and each says what the
-- draft protects. Once a transfer is sent the note is a record of what
-- went on the van; once a landed-cost run is applied the freight is
-- inside what every item is carried at.
--
-- ---------------------------------------------------------------------
-- The one that is a rule rather than a validation
--
-- `upsert_pos_recipe` refuses a dish that keeps its own stock, and the
-- refusal is the whole design of recipes rather than a check on an
-- argument: selling a stock-tracked dish already moves it, so a recipe
-- would take the ingredients out a second time. The message names both
-- ways out -- turn tracking off for the dish, or use a manufacturing
-- order -- because "no" without a way forward is how a shopkeeper ends
-- up with neither.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The four that replace their lines
-- ---------------------------------------------------------------------

comment on function public.upsert_stock_transfer(uuid, uuid, uuid, uuid, date, jsonb, text) is
  'Creates or edits a draft transfer between two of this company''s own '
  'warehouses. REPLACES EVERY LINE: what is sent becomes the whole '
  'list, and a line left out is deleted. DRAFT ONLY -- once the '
  'transfer is sent, the note is a record of what went on the van, and '
  'editing it would change what was recorded as having left. Refuses '
  'the same store at both ends, a store that is not this company''s, '
  'and a transfer with no origin or destination. Needs the `inventory` '
  'module.';

comment on function public.upsert_landed_cost_run(uuid, uuid, date, jsonb, jsonb, text) is
  'Creates or edits a draft landed-cost run -- freight, duty and '
  'handling to be spread across the items on one or more bills. '
  'REPLACES EVERY TARGET AND CHARGE: both lists are deleted and '
  'rewritten from what is sent. DRAFT ONLY, because once applied those '
  'costs are inside what each item is carried at and every sale since '
  'has taken its cost of sales from that figure. A bill must be posted, '
  'partly paid or completed to be a target: only a posted bill has '
  'moved any stock, and freight can only go onto stock that is there. '
  'Needs the `inventory` module.';

comment on function public.upsert_item_conversion(uuid, uuid, text, text, uuid, numeric, text, jsonb, boolean) is
  'Creates or edits a conversion -- one item broken down into several, '
  'a carcass into cuts, a drum into bottles. REPLACES EVERY OUTPUT. '
  'Refuses a conversion that starts with nothing, produces nothing, or '
  'names an item that is not this company''s, and every output needs '
  'both an item and a quantity above nought. Needs the `inventory` '
  'module.';

comment on function public.upsert_pos_recipe(uuid, uuid, numeric, jsonb, text, boolean) is
  'Creates or edits what a dish is made of, so selling one takes the '
  'ingredients off the shelf. REPLACES EVERY LINE. REFUSES A DISH THAT '
  'KEEPS ITS OWN STOCK, and that refusal is the design rather than a '
  'validation: selling a stock-tracked item already moves it, so a '
  'recipe would take the ingredients out a second time. The message '
  'names both ways out -- turn tracking off for the dish, or make it '
  'with a manufacturing order. Also refuses an item as its own '
  'ingredient, and a yield of nothing. Needs the `pos` module.';

-- ---------------------------------------------------------------------
-- Figures and definitions
-- ---------------------------------------------------------------------

comment on function public.upsert_budget(uuid, uuid, uuid, text, text, text) is
  'Creates or renames a budget for a financial year. An APPROVED budget '
  'is refused: it is what variance is reported against, and changing it '
  'underneath a report already circulated would change what people were '
  'told without changing the report. The lines are `set_budget_lines`, '
  'separately and under the same rule. Needs the `accounting` module.';

comment on function public.upsert_cash_forecast_item(uuid, uuid, text, text, numeric, date, text, date, text) is
  'Creates or edits one of the things only a person knows -- a payment '
  'expected or promised that no invoice or bill has yet recorded -- so '
  'the thirteen-week forecast can include it. Refuses a description '
  'like "Payment" that tells a later reader nothing, an amount of '
  'nothing, and a recurrence that ends before it starts. Needs the '
  '`accounting` module.';

comment on function public.upsert_custom_field(uuid, text, text, text, text, boolean, jsonb, text, text, numeric, numeric, integer, boolean, integer) is
  'Creates or edits a custom field on a master record. THE KEY IS '
  'DERIVED FROM THE LABEL THE FIRST TIME AND FROZEN AFTER: renaming the '
  'label later changes what people read and not where the values live, '
  'so existing data stays attached. Refuses an entity that cannot carry '
  'custom fields, a label nobody can read, and a kind outside text, '
  'number, date, boolean, select and lookup. Needs `can_admin`.';

comment on function public.upsert_item_uom_pack(uuid, text, numeric) is
  'Says how many base units are in a pack -- a dozen, a case of '
  'twenty-four -- so an order in cases becomes a quantity in the books. '
  'Refuses a pack of nothing, and refuses the item''s OWN base unit: a '
  'base unit is one by definition, and a row saying otherwise would '
  'silently rescale every quantity the item has. Needs the `inventory` '
  'module.';

comment on function public.upsert_loyalty_tier(uuid, text, text, integer, numeric, uuid, boolean) is
  'Creates or edits a tier on a loyalty programme -- the points at '
  'which it starts and what it multiplies earning by. Refuses a tier '
  'starting below nothing, and refuses a MULTIPLIER OF NOUGHT OR LESS: '
  'a tier that earns nothing is a punishment dressed as a reward, and a '
  'shop that means "no points" should turn earning off on the scheme '
  'itself. Needs the `loyalty` module.';

comment on function public.upsert_scale_format(uuid, uuid, text, text, integer, integer, app.scale_value_kind, boolean, boolean) is
  'Describes how a weighing scale''s barcodes are laid out, so the till '
  'can read a price or a weight out of the label. The prefix must be '
  'one to three digits, and prefix plus code digits plus value digits '
  'must come to a length a scanner actually produces -- twelve or '
  'thirteen with a check digit, eight for the short ones. A format that '
  'does not add up would silently mis-read every label it was applied '
  'to. Needs the `pos` module.';

-- ---------------------------------------------------------------------
-- Shop and outlet configuration
-- ---------------------------------------------------------------------

comment on function public.upsert_pos_delivery_zone(uuid, uuid, text, text[], numeric, numeric, numeric, integer, integer, boolean) is
  'Creates or edits a delivery zone for an outlet: the postcodes it '
  'covers, the fee, the minimum order, the amount above which delivery '
  'is free, and the expected minutes. Postcodes are NORMALISED ON THE '
  'WAY IN, so matching an address later is an equality test rather than '
  'a function somebody has to remember to call. Needs the `pos` module.';

comment on function public.upsert_pos_stall(uuid, uuid, text, text, uuid, numeric, boolean) is
  'Creates or edits a stall in a food court, with the operator who runs '
  'it and the commission the court takes. The operator must be a '
  'contact of this company. Needs the `pos` module.';

comment on function public.upsert_pos_menu_link(uuid, app.pos_menu_link_kind, uuid, uuid, text, timestamp with time zone, boolean, uuid, boolean) is
  'Creates or edits a QR menu link -- the sticker on a table or beside '
  'a register. A table must belong to the outlet the link is for, '
  'refused by name. `p_single` makes it single-use and `p_expires` '
  'gives it a life; both are what stop a photographed sticker ordering '
  'for ever. Needs the `pos` module.';

comment on function public.upsert_pos_menu_schedule(uuid, text, smallint[], time without time zone, time without time zone, date, date, uuid[], uuid, boolean) is
  'Creates or edits a menu schedule -- which dishes are orderable on '
  'which days and between which hours. Weekdays run 1 (Monday) to 7 '
  '(Sunday), and an hours window needs both ends. The item list is '
  'checked BEFORE anything is written, so a bad list does not leave a '
  'schedule behind it: `pos_menu_schedule_items_item_same_org` refuses '
  'it too since `0522`, but a constraint cannot name the dish. Needs '
  'the `pos` module.';

comment on function public.upsert_kitchen_station(uuid, text, text, uuid, integer, boolean, boolean) is
  'Creates or edits a kitchen counter that orders are routed to. '
  'Making one the default clears the previous one IN THE SAME '
  'TRANSACTION: the unique partial index rejects a second default '
  'outright, and doing it as two calls from the client would leave a '
  'moment with no default at all -- which is exactly the moment '
  '`send_order_to_kitchen` refuses an unrouted order. Needs the `pos` '
  'module.';

comment on function public.upsert_pos_driver(uuid, uuid, text, text, text, text, uuid, uuid, boolean) is
  'Creates or edits a delivery driver, optionally tied to a user '
  'account. THE USER SHOULD BE SOMEBODY WHO WORKS HERE: pointing the '
  'row at a stranger does not fail, and the run is simply assigned and '
  'never seen, because row-level security keeps them out of the very '
  'rows the app would fetch for them. Needs the `pos` module.';

-- ---------------------------------------------------------------------
-- The platform's own catalogue
-- ---------------------------------------------------------------------

comment on function public.upsert_ai_provider(text, text, text, text, text, text, boolean, boolean, integer) is
  'Creates or edits an AI provider in the platform''s catalogue -- how '
  'to reach it, whether it needs a key, and what a key looks like so an '
  'operator can tell they have pasted the right thing. Platform '
  'administrators only.';

comment on function public.upsert_ai_model(text, text, text, text, boolean, integer, text, boolean, integer) is
  'Creates or edits one model under a provider, with its context window '
  'and whether it is free. Refuses a provider that does not exist and a '
  'model with no id: a model has to be named to be called. Platform '
  'administrators only.';
