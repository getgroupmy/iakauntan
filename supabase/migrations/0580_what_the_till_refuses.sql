-- =====================================================================
-- iAkauntan :: 0580 what the till refuses
--
-- Tenth slice, and the second chosen by what the functions do. The
-- twenty-eight here are the restaurant: the bill, the table, the
-- kitchen, the kiosk, the loyalty card, the menu and the promotions.
--
-- This module is different from the rest of the schema in one way that
-- decides everything below. Almost every other write in this database
-- is made by somebody sitting down, who can read a refusal and think
-- about it. These are made by somebody standing at a counter with a
-- customer in front of them, one-handed, on a screen the size of a
-- postcard, at the busiest hour of the day. A refusal they cannot act
-- on instantly is a queue.
--
-- So the module refuses in a particular shape, and it is the shape
-- nobody wrote down:
--
--   * The ones that CANNOT be undone refuse hardest. `merge_pos_sales`
--     destroys a bill; it will not merge two deliveries because one
--     address would be lost, and losing an address sends food to the
--     wrong house.
--   * The ones that can be undone do not refuse at all. Tapping
--     `enrol_loyalty_member` twice enrols one member and hands back the
--     account they already had, because arguing with a cashier holding
--     a card is worse than doing nothing.
--   * The ones that guard money refuse on WHO rather than on what.
--     `adjust_loyalty_points` and `expire_loyalty_points` need
--     `can_admin` and not `can_write_module('pos')`, alone in this
--     slice: handing out points is handing out money, and a cashier who
--     can do it unwitnessed is a control nobody has.
--
-- ---------------------------------------------------------------------
-- The distinction worth the whole migration
--
-- `retire_*` never deletes and `delete_*` always does, and which you
-- get is not a matter of taste — it is a matter of what cascades.
--
-- `retire_kitchen_station` switches a counter off because
-- `pos_kitchen_tickets.station_id` cascades on delete: removing the row
-- would remove every docket that counter ever received, and a day of
-- kitchen history would be destroyed by somebody tidying a list.
--
-- `delete_pos_report` really deletes, and says why in its own body: a
-- report is a question, not a record of anything that happened.
--
-- A caller who assumes `retire_` frees the name for re-use, or that
-- `delete_` is reversible, has each got it exactly backwards. Until now
-- the only way to know which was which was to read the body and notice
-- what the foreign key does.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The bill: opening it, adding to it, and joining two of them
-- ---------------------------------------------------------------------

comment on function public.open_pos_sale(uuid, uuid, uuid) is
  'Opens a bill on a register and returns its id. Refuses a register '
  'that is retired or switched off, so a till taken out of service '
  'cannot quietly start selling again. `p_client_uuid` is the till''s '
  'own idea of this sale and is what makes the call idempotent: a '
  'tablet that loses the reply and taps again gets the SAME bill back '
  'rather than a second one, which is the difference between one '
  'basket and two on a floor where nobody is watching the screen. '
  'Needs `can_write_module(''pos'')`.';

comment on function public.add_pos_sale_line(uuid, uuid, numeric, numeric, numeric, text) is
  'Rings an item onto a bill and returns the new line. A null price '
  'takes the item''s price for this outlet, including whatever menu '
  'schedule is running at this minute — passing a price overrides it, '
  'which is what a manager keying a one-off does. Refuses a bill that '
  'does not exist; the rest of the refusals are in '
  '`app.add_pos_sale_line_internal`, which is also what the offline '
  'queue replays into. Needs `can_write_module(''pos'')`.';

comment on function public.merge_pos_sales(uuid, uuid) is
  'Folds one parked bill into another and DESTROYS the emptied one, '
  'returning how many lines moved. Both must still be parked and in the '
  'same outlet. What it carries across is decided by whether keeping '
  'one of two would be a decision nobody made: a redemption and a '
  'discount travel only when the receiving bill has none of its own, '
  'the kitchen dockets always follow the food, and TWO DELIVERY '
  'ADDRESSES REFUSE OUTRIGHT rather than picking, because quietly '
  'keeping one would send food to the wrong house. A bill already out '
  'with a driver cannot be folded into anything. Irreversible: the '
  'absorbed bill is deleted, not voided. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.move_pos_sale(uuid, uuid) is
  'Moves a parked bill to another table, or to none when the table is '
  'null. Refuses a bill that is already settled or voided — there is '
  'nobody left at that table to move — and refuses a table in a '
  'different outlet. Needs `can_write_module(''pos'')`.';

comment on function public.seat_table(uuid, uuid, integer) is
  'Seats a table from a register and returns the bill to work on, '
  'opening one only if the table has none. Tapping an occupied table '
  'therefore RESUMES that bill rather than starting a second, which is '
  'what a waiter walking back to a table means. Covers can be corrected '
  'on the way past: a two-top that became a four-top is the normal '
  'case, not an error. Refuses a table out of service, a table in '
  'another outlet — a waiter cannot seat a table they are not standing '
  'in — and a table with more than one bill open, where it asks which. '
  'Needs `can_write_module(''pos'')`.';

comment on function public.refresh_pos_sale_promotions(uuid) is
  'Re-runs every active promotion against a bill and returns the new '
  'total. Promotions are recomputed rather than remembered, so this is '
  'what makes a basket that has just crossed a threshold — spend 50, '
  'get 5 off — pick the offer up without the line being re-rung. Safe '
  'to call repeatedly; it replaces what it found. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.remove_pos_sale_promotion(uuid) is
  'Takes one promotion off a parked bill and returns the bill it was '
  'on. No line was ever rewritten to apply it, so there is no price to '
  'put back and nothing else changes. Refuses once the bill is settled '
  'or voided. Note that `refresh_pos_sale_promotions` will re-apply the '
  'same offer if it still qualifies — to hold a bill without it, remove '
  'the reason rather than the row. Needs `can_write_module(''pos'')`.';

-- ---------------------------------------------------------------------
-- Modifiers: the choices a cook cannot guess
-- ---------------------------------------------------------------------

comment on function public.add_line_modifier(uuid, uuid, integer) is
  'Adds a choice to a rung line — no onions, extra cheese, medium rare '
  '— and returns the row. The price consequence, whether the modifier '
  'is allowed on that item, and whether it clashes with one already '
  'chosen are all decided in `app.add_line_modifier_internal`, which is '
  'also what the offline queue replays into. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.remove_line_modifier(uuid) is
  'Takes a choice back off a line and re-prices the line. Refuses once '
  'the bill is no longer parked. Silent on a row that is already gone, '
  'because a cashier tapping the same X twice has not made a mistake '
  'worth a dialog. Needs `can_write_module(''pos'')`.';

-- ---------------------------------------------------------------------
-- The kitchen
-- ---------------------------------------------------------------------

comment on function public.send_order_to_kitchen(uuid) is
  'Prints the dockets: takes every line the kitchen has NOT yet seen, '
  'routes each to its station, and returns one row per docket made. '
  'Sending twice sends only what was added since — the second round '
  'does not re-cook the first, and a station that already had a ticket '
  'from an earlier round gets a new one rather than having a line '
  'appended to something that may already be cooking. A PAID bill can '
  'still be sent: a kiosk and a fast-food counter take the money and '
  'then cook. Only a voided one refuses, along with a bill that still '
  'has unanswered "choose one" questions — a cook cannot guess — or a '
  'dish nothing routes and no default station to catch it. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.bump_kitchen_ticket(uuid, app.pos_ticket_status) is
  'Moves a docket along the kitchen screen — new, cooking, ready, '
  'served — and stamps the time it reached that state. A TICKET GOES '
  'FORWARD ONLY: it refuses a status at or behind where the ticket '
  'already is, so a mis-tap on a busy pass cannot silently un-cook '
  'something. `cancelled` is the exception and may be called from '
  'anywhere, but a cancelled ticket cannot be revived. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.retire_kitchen_station(uuid) is
  'Switches a counter off. RETIRED, NEVER DELETED — '
  '`pos_kitchen_tickets.station_id` cascades on delete, so removing the '
  'row would remove every docket the counter ever received and destroy '
  'a day of kitchen history for somebody tidying a list. Refuses while '
  'any ticket on it is still new, cooking or ready: retiring the '
  'station takes those off every screen at once, and the plate does not '
  'stop existing because a list was tidied. Refuses to retire the '
  'outlet''s default counter while another is active — make something '
  'else the default first, or unrouted dishes have nowhere to go. '
  'Needs `can_write_module(''pos'')`.';

comment on function public.route_item_to_station(uuid, uuid, uuid) is
  'Says which counter makes this dish IN THIS OUTLET — the same item in '
  'another shop keeps its own routing, which is why the table is not '
  'unique on item alone. A null station clears the rule and lets the '
  'item fall back to its category''s. Refuses a counter that is not in '
  'the named outlet. Needs `can_write_module(''pos'')`.';

comment on function public.route_category_to_station(uuid, uuid, uuid) is
  'The same rule one level up: which counter makes everything in this '
  'category, in this outlet. An item with its own routing wins over '
  'this; a null station clears it and lets the category fall back to '
  'the outlet default. Refuses a counter that is not in the named '
  'outlet. Needs `can_write_module(''pos'')`.';

-- ---------------------------------------------------------------------
-- The kiosk: a till with nobody behind it
-- ---------------------------------------------------------------------

comment on function public.start_kiosk_order(uuid, uuid) is
  'Opens a bill a customer is ringing themselves. REFUSES A STAFF '
  'TILL: a kiosk order on one would be a sale with nobody behind it on '
  'a register that has a cash drawer. Still needs an open shift, like '
  'any other sale — a kiosk selling into a day nobody opened is a day '
  'whose takings belong to no count at all. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.complete_kiosk_order(uuid, uuid, numeric, text) is
  'Takes payment for a self-service order, assigns the order number the '
  'customer watches for, and sends it to the kitchen if the outlet has '
  'one. REFUSES CASH, always: a kiosk has no drawer, and the customer '
  'has to be sent to the counter. The order number is taken BEFORE the '
  'sale completes, so somebody who has paid always has one — taking it '
  'afterwards leaves a window in which the money is gone and nothing on '
  'the screen belongs to them. Refuses a tender this company does not '
  'accept or has switched off. Needs `can_write_module(''pos'')`.';

-- ---------------------------------------------------------------------
-- Loyalty: the two that hand out money, and the rest
-- ---------------------------------------------------------------------

comment on function public.enrol_loyalty_member(uuid, text) is
  'Puts a customer on the loyalty programme and returns the account. '
  'IDEMPOTENT ON PURPOSE: a cashier who taps twice enrols one member '
  'and gets back the account they already had, rather than an error '
  'they have to explain to somebody holding a card — and a card number '
  'passed on the second tap is written to the existing account. '
  'Refuses when the company has no programme running. Needs '
  '`can_write_module(''loyalty'')`.';

comment on function public.adjust_loyalty_points(uuid, integer, text) is
  'Adds or removes points by hand and returns the new balance. NEEDS '
  '`can_admin`, not the till permission — handing out points is handing '
  'out money, and a cashier who can do it unwitnessed is a control '
  'nobody has. Refuses an adjustment of zero, refuses one with no '
  'reason given — an unexplained adjustment is the one the auditor asks '
  'about — and refuses to take an account below zero. Written as a '
  'ledger entry, so the adjustment stays visible beside what earned and '
  'spent the rest.';

comment on function public.redeem_loyalty_points(uuid, integer) is
  'Spends points against a parked bill and returns what was applied. '
  'Points cannot buy more than the basket: rather than refuse, it takes '
  'only what is needed and LEAVES THE REST ON THE ACCOUNT, rounding the '
  'points DOWN so that over-redeeming never takes one more point than '
  'the basket is worth. Zero clears a redemption thought better of, '
  'without voiding the sale. The basket is read from the lines rather '
  'than from `total_amount`, which already has any earlier redemption '
  'off it — reading that would let two calls stack until the sale was '
  'free. Refuses a bill that is not parked, a sale not on a member''s '
  'account, and anything under the programme''s minimum. Needs '
  '`can_write_module(''loyalty'')`.';

comment on function public.expire_loyalty_points(uuid) is
  'Zeroes the balance of every account dormant longer than the '
  'programme allows, and returns who lost what so somebody can look '
  'before it is believed. NEEDS `can_admin`, for the same reason as '
  'adjusting. Does nothing at all when the programme sets no dormancy '
  'period, which is the default. Dormancy is measured from the last '
  'ledger entry, or from the joining date for an account that never '
  'earned anything. Written as ledger entries naming the date it went '
  'quiet, so a member who asks can be told.';

comment on function public.retire_loyalty_tier(uuid) is
  'Switches a tier off. Retired rather than deleted: members drop to '
  'whichever band is below it, and a shop that retired one by mistake '
  'can put it back. Needs `can_write_module(''loyalty'')`.';

-- ---------------------------------------------------------------------
-- The menu, the offers and the shop floor
-- ---------------------------------------------------------------------

comment on function public.resume_pos_item(uuid, uuid) is
  'Puts a dish back on TODAY, undoing an 86. Returns whether there was '
  'anything to undo. The stop is dated in Kuala Lumpur time and is '
  'only ever for today, so a kitchen that runs out at eight does not '
  'have to remember to put it back tomorrow morning. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.retire_pos_menu_schedule(uuid) is
  'Switches a menu period off — breakfast, happy hour. The dishes on '
  'it go back to always-on rather than losing their grouping, which is '
  'why this is a switch and not a delete. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.retire_pos_menu_link(uuid) is
  'Switches off a public ordering link. Switched off rather than '
  'deleted: the orders that came in through it still name it. A sticker '
  'somebody has to go and peel off is a sticker that should STOP '
  'WORKING the moment it is switched off, which is what this does. '
  'Needs `can_write_module(''pos'')`.';

comment on function public.retire_pos_promotion(uuid) is
  'Switches an offer off. Bills it already discounted keep the '
  'discount — `refresh_pos_sale_promotions` only stops applying it to '
  'new ones — so this ends an offer rather than reversing it. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.retire_pos_delivery_zone(uuid) is
  'Switches a delivery area off. Retired, never deleted: every delivery '
  'already taken names the zone it was charged under, and the fee it '
  'was charged at has to stay explicable. Needs '
  '`can_write_module(''pos'')`.';

comment on function public.delete_pos_recipe(uuid) is
  'Removes the ingredient list behind a dish. A real delete: a recipe '
  'is what the next sale will consume, not a record of anything that '
  'happened, and stock already taken was written against the sale '
  'rather than against this. Returns false rather than raising when it '
  'was already gone. Needs `can_write_module(''pos'')`.';

comment on function public.delete_pos_report(uuid) is
  'Removes a saved report. A REAL DELETE, and the one place in this '
  'module where that is right: a report is a question, not a record of '
  'anything that happened. Nothing points at it and no history is lost. '
  'Needs `can_write_module(''pos'')`.';
