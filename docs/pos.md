# Point of sale

One module, `pos`, and five kinds of shop behind it. A convenience store,
a warung, a market stall, a salon and a self-service kiosk are not five
products here — they are one till with different parts of it switched on,
because the money underneath is the same money and it has to reach the
same ledger.

`supabase/migrations/0206` … `0221` build it. The assertions are in
`supabase/tests/pos*.sql`, all seven run in CI.

## Where the shop sits

```
pos_outlets      the shop: a warehouse it sells out of, a walk-in
                 contact, receipt header and footer, whether its
                 prices include tax
  pos_registers  a till in it — counter terminal, tablet, phone, kiosk
    pos_shifts   one person, one drawer, one session, counted at the end
      pos_sales  the basket, its lines, its tenders
```

`pos_outlets.business_type` is one of `retail`, `food_beverage`,
`mobile`, `service`, `kiosk`, and a register may override it: the same
café runs a counter terminal, a waiter's tablet and a kiosk by the door.
The type does not gate the SQL — every function works on every outlet —
it tells the client which of the till's faces to put on the screen.

## The sale posts an ordinary invoice

`complete_pos_sale()` raises a `sales_documents` row of type `invoice`,
posts it, records a receipt and allocates it, and moves the stock. It
does not keep a parallel retail ledger.

That is the same decision `docs/property.md` describes for a management
corporation's Charges, for the same reason: aged receivables, statements,
credit notes, e-Invoice, the P&L and the stock valuation all work on the
day the till ships, instead of each needing a shop-shaped copy. A counter
sale is receivable and then immediately received, in exactly the sense
the rest of this system already understands.

## Rounding belongs to the tender, not to the document

Bank Negara withdrew the one sen coin in 2008, so a cash total is settled
to the nearest five sen. A card total is not: a card can pay 12.97 and
does.

So the rounding is computed **per tender**, not on the basket:

- the basket totals to the sen, and the invoice is raised for that;
- the **cash portion** rounds, and the difference posts as a rounding
  adjustment;
- a basket paid entirely by card carries no adjustment at all;
- a basket split between the two rounds only the remainder that the cash
  is settling.

`pos_settings.round_cash_to_5sen` turns it off for a company that does
not want it, and `pos.sql` asserts the untouched case as well as the
rounded one — an assertion that only counts differences passes vacuously
if nothing was compared, so the test also counts the sen amounts it
checked.

## The shift is what makes the drawer countable

A register with no open shift will not sell — the first assertion in
`pos.sql`. Closing counts the float plus the net **cash** taken, ignores
the card, and refuses while a sale is still parked, because a parked
basket is money that has not decided yet.
`pos_settings.variance_tolerance` decides how far out the count may be
before somebody has to explain it.

## What LHDN is owed, and how it is not five hundred documents

A shop doing five hundred sales a day would owe five hundred e-Invoices,
each to a buyer who bought a drink and will never be identified. The
guideline's answer is the consolidated e-Invoice, and `0210` fills the
tables `0007` built for it.

The split is **derived, not declared**: a sale gets its own e-Invoice
when it is billed to somebody with a TIN, and rolls up when it is not.
The walk-in has no TIN by construction, which is what makes it the
walk-in.

`request_einvoice_for_sale()` is deliberately separate from completing
the sale, because across a real counter the request comes late — the
customer pays, then says "boss, I need it under the company name". It
refuses once the sale has been consolidated, because that submission has
already told LHDN this sale had no identified buyer; that needs a credit
note and a re-issue, not an edit.

`consolidate_pos_einvoices()` is idempotent — the consolidation is keyed
on (org, period start, period end) and its items on (consolidation,
document), so running it twice adds nothing. That matters more than it
sounds: this is the kind of function somebody runs again because they are
not sure the first one worked.

**Submitting** the consolidation is still manual. The rollup runs and
starts the seven-day clock; the scheduler holds no MyInvois credentials.

## Retail — a size, a colour and a barcode

A variant **is an item**. `items.parent_item_id` points at the style and
`items.variant_attributes` holds `{"Size": "M", "Colour": "Navy"}`, so a
navy medium has its own code, its own price, its own stock and its own
cost, and every report that already understands an item understands it.

One level only, enforced by trigger: a variant cannot have variants, and
a style with children cannot itself be sold or put in a bag.
`create_item_variants()` takes the axes and makes the cartesian product
with derived codes, and is re-runnable — adding a third colour creates
only the three combinations that are new.

`item_barcodes` is separate from `items.barcode` because a carton label
and a unit label are different things: a barcode row carries a
`pack_quantity`, so scanning the carton rings up six.
`pos_lookup_item()` resolves a scan in order — barcode table, then the
item's own barcode, then code, then name — and an item with stock on hand
cannot be retro-split into variants, because the stock would have nowhere
truthful to go.

## Loyalty is a ledger, not a number on a card

`loyalty_entries` is append-only with a read-only policy, and the balance
is `sum()` over it. Nothing anywhere increments a stored total. Points
are earned on **what was paid**, not on the basket before the discount,
and a redemption is held on the sale rather than written to the ledger
until the sale completes — so the till can say what the balance will be
without having moved it.

Redeeming again replaces the earlier redemption rather than stacking on
it, clearing it restores the basket, and a basket cleared entirely by
points still completes: it raises an invoice for nothing and a posted
receipt behind it, which is what the shop's books have to show.

## Food and beverage — the room, the plate and the kitchen

`pos_tables` sit in `pos_floor_areas`. Occupancy is derived from whether
an open bill points at the table, never accumulated, so a crashed tablet
cannot leave a table permanently "occupied". `seat_table()` returns the
**existing** bill when there is one and refuses when there is more than
one; `move_pos_sale()` takes the bill and everything ordered on it to
another table and frees the first in the same breath.

A modifier snapshots its name and price delta onto the line, because "no
onions, add egg" has to still read correctly on next year's receipt after
the menu changed. `pos_sale_lines.base_unit_price` stays null until a
modifier touches the line, which is why adding modifiers did not require
restating how an ordinary line is added.

`send_order_to_kitchen()` routes each line to a station — by item, then by
category — and marks it sent, so a second tap sends only what is new.
Splitting a bill moves whole lines; `pos_even_split()` floors the shares
and puts the remainder on the first, so the parts sum to the whole
exactly. Merging repoints the kitchen tickets before it deletes the
emptied sale, because a ticket pointing at nothing is a plate nobody
collects.

## Service — a slot that cannot be sold twice

The double-booking rule is a **constraint**, not a function:

```sql
exclude using gist (
  provider_id with =,
  tstzrange(starts_at, ends_at, '[)') with &&
) where (status not in ('cancelled', 'no_show'))
```

`pos_service.sql` asserts both that `book_appointment()` refuses the
overlap and that a direct insert past it is refused too — a rule enforced
only in the function is not enforced.

A booking runs for the service duration plus its turnaround, and nobody
is booked outside the hours they work or while they are away. Checking in
**opens a sale** with the service on it at the quoted price rather than
setting a status, because arrival is a claim about money; checking in
twice reaches the same sale.

A membership is billed by the recurring-document machinery from `0097`
rather than a second scheduler, and its included sessions are counted
from the lines that consumed them. `cover_line_with_membership()` takes
the line to nothing to pay and leaves it on the bill, because what was
given still has to be visible.

## Selling with no signal, and landing it once

A market stall loses its signal. The till keeps selling and posts the
batch later, and the whole problem is that the batch may arrive twice.

Each offline sale carries a client-generated `client_uuid` and its own
`offline_sold_at` — the till's clock kept alongside the server's, not
instead of it. `ingest_offline_sales()` runs each payload in its own
subtransaction, so one poisoned sale does not roll back the good ones
beside it; a re-sent batch lands nothing and says so rather than failing,
and a retry returns the invoice the till already has.

What genuinely cannot land goes to `pos_offline_rejects`, unique on
`(org, client_uuid)` — one row per sale, not one per attempt — where somebody can read what failed and what
it was worth. A sale arriving for a drawer that has already been counted
is parked rather than lost, and the next shift takes it.

## Kiosk — a customer serving themselves

`pos_registers.is_kiosk` marks the till, and it changes three things: a
kiosk will not take cash (there is nobody to give change), the order
takes a **number** from a per-outlet, per-day counter, and completing it
tells the kitchen without anybody tapping anything.

The counter is race-free by construction rather than by locking:

```sql
insert into public.pos_order_counters (outlet_id, on_date, last_no)
values (p_outlet, (now() at time zone 'Asia/Kuala_Lumpur')::date, 1)
on conflict (outlet_id, on_date)
  do update set last_no = pos_order_counters.last_no + 1
returning last_no;
```

Two kiosks pressing "pay" in the same millisecond get different numbers.
`kiosk_order_board()` is the screen customers watch: preparing on one
side, ready on the other, and a collected order leaves it.

## Five screens, five readers

The module is not one face but five, and what separates them is who is
holding the device rather than which feature they reach.

| Screen | Route | Read by |
|---|---|---|
| Till | `/till` | A cashier, at a counter, with a queue |
| Floor | `/floor` | A waiter, crossing a room, at a distance |
| Kitchen | `/kitchen` | A cook, hands full, further away still |
| Diary | `/diary` | A receptionist, on a phone, mid-sentence |
| Order board | `/order-board` | **A customer**, holding a tray |

They share a register picker and nothing else, because the thing that
makes a POS screen good is different in each case. The board shows the
least of anything in this application; the till shows the most.

## On a counter, a tablet and a phone

`app/lib/src/features/pos/till_screen.dart` is one screen at three
widths: a two-pane layout at 900px and up, stacked below it. There is no
separate mobile till, because a shop that buys a second tablet should not
be buying a second product.

A closed drawer renders **only** the card that opens it — no scan box, no
"take payment" — and `app/test/till_screen_test.dart` asserts the absence
rather than the presence, because a disabled button is still a button
somebody taps.

**The till browses as well as scans.** The resting pane used to read
"Ready — scan an item", which is true and useless to most of the shops
this module is sold to: a barcode is a retail assumption, and nasi
lemak, a haircut and a roti john all have no label. It now shows the
menu, from `pos_menu()`, which applies the same sellability rules as
the scan path — so a style with variants under it never becomes a tile
that raises when a thumb lands on it.

Items or categories is decided by measurement rather than by a
threshold: the tiles that fit the pane are counted, and the whole menu
is shown when the whole menu fits. Otherwise the categories are shown
with a count on each and tapping one drills in. The same rule gives a
phone categories where a counter terminal shows items, which is why
desktop web, mobile web and the app need no special-casing between
them. One category is never turned into a choice, however long the list.

**A plate's questions are asked on the tap that orders it.** An item
with modifier groups opens a sheet before anything is written: "choose
one" is drawn as a single-select that replaces rather than refuses,
"up to two" caps and drops the oldest choice, and a required group
leaves the button disabled and named — `Choose Pedas` rather than a
silent dead button. `min_select` and `max_select` are enforced by
`add_line_modifier` regardless; the sheet repeats them so the refusal
never has to happen, because a queue is a bad place to learn a form was
incomplete. Backing out writes nothing, since the line does not exist
until the questions are answered.

**"Can we pay separately?" is two questions, and the till keeps them
apart.** Splitting by item moves lines onto a second bill — two
invoices, two receipts, two e-Invoices if anybody asks. Splitting
evenly moves nothing: one supply, one document, several tenders. 0216
separated them in the database because conflating them is how a till
issues four invoices for one meal, and the screen follows that
division rather than offering one "split" button that guesses.

Moving every line is refused before it is attempted, since that is a
rename rather than a split and would leave an empty bill behind. The
even-split dialog shows what the shares add up to as well as the
shares, because the sum is the property that matters — ten ringgit
three ways is 3.34 + 3.33 + 3.33, and a split that quietly collected
9.99 would leave a sen on the table for ever.

Every figure on the tender sheet — the total, the cash due, the change,
the rounding — comes back from `complete_pos_sale()` rather than being
recomputed in Dart. A till that does its own arithmetic is a till that
can disagree with the receipt it just printed.

## The room, the pass, the diary and the board

**Floor** (`floor_plan_screen.dart`) draws tables as tiles grouped by
area, because "which tables are taken" is read at three metres and a
list of rows is not. Tapping is the same gesture on both states —
`seat_table()` returns the existing bill rather than raising, so the
server settled what a second tap means. Covers are asked for only on the
way in, defaulting to the table's seats, which is the assumption
`seat_table()` itself makes when given nothing. Moving a party offers
only free tables, because `move_pos_sale` refuses an occupied one.

**Kitchen** (`kitchen_screen.dart`) is the screen with the least in
common with the rest of this app. One control per ticket, labelled with
a verb — Start, Ready, Away — rather than the status it sets, because a
cook does not need to be told a ticket is "new". Colour carries **age**
rather than status: which ticket has been waiting is the question a
kitchen actually asks. It polls every ten seconds, alone among these
screens, because nobody is going to pull-to-refresh with their hands
full and a board thirty seconds stale sends the wrong plate.

Sending is not part of tendering. An order is cooked long before it is
paid for, so one button doing both would mean cooking on credit or
serving a cold plate. `send_order_to_kitchen` sends only what has not
gone, which makes the button safe to press again after a second course.

**Diary** (`diary_screen.dart`) is a column per provider rather than one
list sorted by hour, because "who is free at three" is a question about
people. Every provider gets a column whether or not they are booked —
that is what the left join in `pos_day_sheet` is for — and an empty one
says "Free all day" rather than being left blank, since blank reads as
not-loaded and the good news should not look like a failure. Checking in
calls `check_in_booking`, so the button says "Check in" and what it does
is start charging; nothing here can mark somebody arrived without
opening their bill.

**Order board** (`kiosk_board_screen.dart`) has no navigation, no detail
and nothing to tap — a test asserts the absence of every kind of button,
because a board on a wall that can be pressed is one somebody will
press. Numbers rather than names: a counter that calls out a name is a
counter that has collected one.

## Somewhere to look at it

Every business type the module sells has a tenant, and
`demo_rebuild.sql` counts them against the enum rather than listing
them — so a sixth business type fails CI until it has somewhere to be
looked at.

| Type | Login | What is going on in it |
|---|---|---|
| `retail` | `demo@iakauntan.com` | Sinar's trade counter, selling out of the warehouse the forecast is about |
| `food_beverage` | `warung@iakauntan.com` | **Warung Sedap Enterprise** — two rooms, seven tables, two kitchen stations, a menu with modifier groups, a loyalty card, two parties seated with orders in the kitchen and one bill already settled |
| `kiosk` | `warung@iakauntan.com` | The screen by the warung's door: an order paid by card, given a number, waiting on the board |
| `service` | `salon@iakauntan.com` | **Seri Ayu Salon & Spa** — two chairs on different hours, four services, a monthly facial package, and a day holding all four states a slot can be in |
| `mobile` | `stall@iakauntan.com` | **Roti Warisan Enterprise** — one phone in a van, and a lunchtime rush that landed from the offline queue |

Two of these carry evidence rather than claims, which is the point of
seeding them at all:

**The salon's day has one of each.** One appointment done and paid,
one *in the chair with the bill still open*, two still to come and one
no-show. Writing the seed is what established that `arrived` is a state
you pass through rather than rest in — `app.pos_booking_follows_sale`
moves the booking to `completed` the moment its sale completes, so a
demo that checked somebody in and then took their money would show
nobody in the chair at all. The test asserts all four states, because
that is exactly the kind of thing a later edit undoes without noticing.

**The stall sends its batch twice.** `app.demo_stall` calls
`ingest_offline_sales` with the same three sales a second time, the way
a van coming back into signal retries what it is not sure went. Three
land, three come back `already`, and the tenant ends with four completed
sales rather than seven. The idempotence the whole offline design exists
for is therefore visible in the demo data, not only asserted in
`pos_offline.sql`.

## Not built yet

- Submitting the consolidated e-Invoice to MyInvois (the rollup runs; the
  scheduler holds no credentials)
- Card terminal integration. A tender records an authorisation code
  because somebody typed or pasted it; nothing talks to a payment
  terminal
- Cash drawer and receipt printer drivers. The receipt renders; opening a
  physical drawer is between the browser and the hardware
- The kiosk's own ordering face. `start_kiosk_order` and
  `complete_kiosk_order` have no screen: the board customers watch is
  built, but the touchscreen they order from is not, so a kiosk order
  still has to be started from the till
- Loyalty at the counter. `enrol_loyalty_member` and
  `redeem_loyalty_points` are not on the tender sheet
- Landing an offline batch. `ingest_offline_sales` expects a payload
  from a till that queued sales locally; nothing in the Flutter client
  queues them yet, so the offline path is server-ready and
  client-unbuilt — which is the honest half of "works offline"
