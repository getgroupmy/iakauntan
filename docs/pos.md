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

## On a counter, a tablet and a phone

`app/lib/src/features/pos/till_screen.dart` is one screen at three
widths: a two-pane layout at 900px and up, stacked below it. There is no
separate mobile till, because a shop that buys a second tablet should not
be buying a second product.

A closed drawer renders **only** the card that opens it — no scan box, no
"take payment" — and `app/test/till_screen_test.dart` asserts the absence
rather than the presence, because a disabled button is still a button
somebody taps.

Every figure on the tender sheet — the total, the cash due, the change,
the rounding — comes back from `complete_pos_sale()` rather than being
recomputed in Dart. A till that does its own arithmetic is a till that
can disagree with the receipt it just printed.

## Somewhere to look at it

`warung@iakauntan.com` — **Warung Sedap Enterprise**, a sole proprietor
café with two rooms and seven tables,
three registers (counter, waiter's tablet, kiosk), two kitchen stations,
a menu with modifier groups, a loyalty scheme with a member on it, two
tables mid-service with orders in the kitchen, one settled counter sale
and one kiosk order waiting to be collected. Seeded by
`app.demo_warung()` and asserted by `supabase/tests/demo_rebuild.sql`.

## Not built yet

- Submitting the consolidated e-Invoice to MyInvois (the rollup runs; the
  scheduler holds no credentials)
- Card terminal integration. A tender records an authorisation code
  because somebody typed or pasted it; nothing talks to a payment
  terminal
- Cash drawer and receipt printer drivers. The receipt renders; opening a
  physical drawer is between the browser and the hardware
- Screens for most of what the SQL supports: the floor plan, the kitchen
  display, the diary and the kiosk all exist as functions with no Flutter
  route yet. The till itself is the one face that is built
