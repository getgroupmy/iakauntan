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

## Loyalty and memberships are modules of their own

Both were built inside `pos` and gated by it, which made them free with
the till and unavailable without it. Neither matches how they are sold:
a salon runs memberships and a minimart runs a points card, and a shop
that wants only the till should not be paying for either. `0231` gives
them their own codes — `loyalty` and `memberships`, RM29 each.

Registering the codes was the small part, and moving the guards turned
out not to be the whole of it either: `app.module_access` never read
`org_modules`, so entitlement was enforced only in the Flutter client.
`0232` fixes that for every module at once — see `docs/modules.md`.
The split above is what found it.

Moving the guards still mattered. The gate is the guard inside
each SECURITY DEFINER function, because those bypass RLS by definition —
a policy on `loyalty_accounts` does not stop `enrol_loyalty_member`
writing to it. So the work was ten guards moved, two added, and a set of
policies rebuilt.

**The migration derives rather than restates.** Pasting thirteen
function bodies with one word changed in each is six hundred lines in
which the reader has to find thirteen differences — precisely the diff
nobody can check that this repository objects to. Instead
`pg_get_functiondef` returns what is installed, the module argument is
replaced by a regex that only matches the second argument of
`can_read_module` / `can_write_module`, and the result is executed. Both
blocks refuse to finish unless they changed something, because a replace
that silently matched nothing would leave the feature gated on `pos`
while the module list claimed otherwise — a hole that looks like a
working feature.

**It found a real one.** The assertion fired on the first pass:
`adjust_loyalty_points` and `expire_loyalty_points` are gated by
`app.can_admin` and by nothing else, so an owner of a company that never
bought the till could hand out or sweep points. Those two are restated
with a module check *added*, which is why they appear in the diff in
full — a check being added should be visible in the change that adds it.

**The policies are derived for a sharper reason.** These tables do not
carry a uniform set and must not be given one. `loyalty_entries`,
`pos_membership_sessions` and `pos_membership_subscriptions` have a read
policy and no write policy at all, deliberately — they are ledgers,
written only through the functions, and a block that created a write
policy on each would have handed clients the ability to grant themselves
points. `loyalty_programs_write` is not module-gated but narrower, and
replacing it would have widened who can change a company's earning rate.
So each existing policy is rebuilt as itself with one word changed, and
anything that never named the till is left alone.

**Nothing that works today stops working.** Every organization with the
till switched on gets both new modules switched on. Withdrawing a
running loyalty scheme in a migration and calling it a refactor would be
taking a feature away from people mid-service.

Going forward they are genuinely separate: a *new* company buying the
till does not get either. The demo warung buys loyalty explicitly, in
the seed that demonstrates it.

Memberships have no Flutter screen yet — the SQL is built and asserted,
and nothing in the client calls it. So the module gate there is real but
currently invisible, and the salon's package still lives in data only.

## Loyalty at the counter

0212 built the ledger and left its two acts with no caller. Wiring them
to the tender sheet needed two things that did not exist, both of them
the database's job:

- **A cashier has a phone number, not a contact id.**
  `loyalty_account_balance(contact)` answers the question you can only
  ask once you know who somebody is. `loyalty_lookup(org, text)` takes
  the one string the customer actually said and searches card number,
  mobile and name. Exact card matches sort first and the till takes a
  single one without asking, because a scanned card is an answer rather
  than a shortlist.
- **A sale has to know whose points these are.**
  `redeem_loyalty_points` reads `pos_sales.contact_id`, and nothing
  could set it on a parked bill: the contact was passed when the sale
  opened or when it completed, and neither is the moment a card comes
  out. `name_pos_sale_customer` fills that, and refuses once the sale
  has completed — renaming an issued invoice is
  `request_einvoice_for_sale`, with LHDN's rules attached. It also
  refuses to move a bill that still carries somebody else's redemption,
  since points belong to an account.

`pos_sale_member(sale)` returns the whole panel in one read, so it
cannot show a name and a balance belonging to two different customers.

**The panel shows two balances, and that is the point.** Redemption
records the intent on the sale and writes the ledger entries only when
the sale completes — so a parked bill that is abandoned costs the
customer nothing, and the balance genuinely has not moved yet. A panel
showing only "506 points" beside "300 being used" would have the cashier
reading out a figure the customer is about to spend, so it says both:
what is on the card now, and what will be left after paying.

The earning figure is labelled as an estimate because it is one.
`pos_settle_loyalty` earns on what was actually paid, which includes the
five-sen rounding, and the rounding is not decided until somebody says
how much of the bill is cash.

**The demo card carries an opening balance**, and it has to. The member
earns six points from one RM6.50 sale against a scheme that redeems from
a hundred, so without one the panel demonstrates itself by refusing —
"Redeems from 100", greyed out, on the only tenant that has a card at
all.

It is not invented sales. It is what every shop does on the day it
installs a scheme: put the customer's existing points on the card, with
`adjust_loyalty_points`, which insists on a reason and refuses anyone
who is not an owner or admin. So the seed demonstrates three rules
rather than fabricating a balance. It tops up *to* 500 rather than *by*
an amount, because `demo_rebuild` is safe to run twice and this has to
be. `demo_rebuild.sql` asserts the balance clears the programme's own
minimum — not a number typed in the test — so raising the minimum fails
CI instead of quietly making the demo useless again.

The sheet does no arithmetic that matters. `redeem_loyalty_points`
decides how many points a basket can absorb, floors them so a redemption
never takes more than the goods are worth, and returns the new total —
and the till reports what came back rather than what was asked for.

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

## The questions a shop asks, and where it edits them

0214 built modifiers and the till has asked them since. Nothing could
create one: `pos_modifier_groups`, `pos_modifiers` and
`item_modifier_groups` were writable by RLS and written by nobody, so
the only shop with any was the demo warung a migration seeded. 0250 is
the missing half — `upsert_pos_modifier_group`, `upsert_pos_modifier`,
`retire_pos_modifier_group`, `retire_pos_modifier` and
`set_item_modifier_groups`.

Three rules live in those functions rather than in the screen.

**A default has to fit inside the maximum.** The till opens with every
`is_default` answer already selected — that is what a default is for —
so two defaults in a choose-one group would open the sheet over the
limit and `pos_modifier_max` would refuse the second one at the counter,
mid service, to somebody who configured nothing. Making an answer the
default in a choose-one group therefore clears the previous one in the
same transaction, and a default beyond the maximum of a larger group is
refused by name. Tightening a maximum below the defaults already ticked
is the same fault arriving from the other side, and is refused too.

**Retired, never deleted.** `pos_sale_line_modifiers` snapshots the name
and the price, so a bill survives its modifier being deleted — but
`modifier_id` is `on delete set null`, and that column is how anybody
asks how many extra eggs a month sells. Nothing here deletes; `is_active`
goes false, which is what `item_modifier_options` already filters on.
Retiring a group keeps its `item_modifier_groups` rows, so bringing the
question back brings the thirty dishes with it.

**Attaching states the order.** `set_item_modifier_groups` takes the
whole array and writes `sort_order` from the position, because the order
the questions are asked is a decision the screen has already made.

The editor is reached from Items rather than from a till: a question
belongs to the company, is asked the same way at both branches, and is
attached to a dish. The item editor carries the attachments; the app-bar
button beside Price levels keeps the questions themselves. Retired
questions stay on that list — `(org_id, code)` is unique, so hiding them
would leave somebody re-creating one under a code they cannot use.

**An answer that is not on the list.** 0251 adds `allows_free_text` to a
group and `add_line_free_modifier` beside `add_line_modifier`. A typed
answer is an ordinary `pos_sale_line_modifiers` row with `modifier_id`
left null — a name, a price and a group, snapshotted at the moment of
ordering exactly like a listed one, so the receipt, the kitchen docket,
the repricing and the consolidated e-Invoice need to know nothing about
the difference. `pos_line_modifier_gaps` counts rows per group without
looking at `modifier_id`, so a typed answer closes a required question;
`pos_modifier_max` counts them too, so the group's maximum still holds.

Two limits, both in SQL. The price may not be negative: a surcharge is
what this is for, and a negative would be a discount entered by whoever
is holding the till with no reason recorded and no grant asked for —
the shape 0247 closed on the void. And the name is capped at sixty
characters and refused rather than truncated, because it goes on a
kitchen docket and half an instruction is how the wrong plate goes out.
The kiosk is never offered it at all: a customer alone with a field that
adds money to their own bill will put nought in it.

## The day, across every outlet

Every other POS screen takes an outlet and answers about that outlet,
which is right for whoever is standing in it and useless to whoever owns
three. `pos_day_board` (0252) is the owner's view: one row per shop for
a trading day — bills, gross, cash and non-cash taken, the average bill,
what was written off — ranked by takings, with the quiet shops still on
it, because a missing row reads as "no problem" when it is the problem.

One column is on a different clock and is labelled that way. Open bills
are open *now*: a parked bill has no trading day yet, and the useful
reading is "four still open at this moment". Everything else is about
the day named, in Asia/Kuala_Lumpur, the same boundary 0248 uses.

Cash is net of change — `amount - change_given`, the arithmetic
`app.pos_expected_cash` does for one shift — because gross is what was
sold and cash is what should be in the drawer, and an owner comparing
shops is usually comparing the second one.

The same function feeds a digest. `app.queue_sales_digest` hangs off the
nightly `run_daily_jobs` at one in the morning, builds a plain-text
table of yesterday's outlets, and queues it to whatever address
`email_settings.sales_digest_to` holds — empty by default, because a
mail nobody asked for is spam however useful it is. A day with no
trading at all sends nothing; a day with nothing but write-offs does,
since that is the day worth asking about. The body is composed in SQL
rather than through `app.render_email`: every other message is a
sentence with an amount substituted into it, and this one is a table
whose row count is the number of shops.

## Loyalty is a name, not only a number

0212 made points a ledger and 0227 put the card at the counter. What
neither gave a shop is the thing customers talk about: that somebody is
*Emas*. 0253 adds `loyalty_tiers` — bands with a name, a threshold and
an `earn_multiplier`.

**Measured on what was earned, never on the balance.** The obvious
implementation is a threshold against the account balance, and it is
wrong in a way that takes months to notice: redeeming demotes you, so
the scheme punishes the exact behaviour it exists to encourage.
`app.loyalty_earned` counts `earn` entries only, over
`loyalty_programs.tier_window_months` (null is for ever). An adjustment
a manager makes to settle an argument is not spending either, so a
goodwill gesture cannot buy a tier.

**A tier that does nothing is a badge**, so each carries a multiplier.
`app.pos_settle_loyalty` reads the member's band as the sale settles —
before this sale's own points land, so a bill that crosses a threshold
earns at the old rate and the next one earns at the new; any other
reading makes the rate depend on the order two tills happened to settle
in. The multiplication happens before the floor, because rounding up
pays points for money nobody handed over. A company with no tiers
configured is exactly where it was: the lookup finds nothing and one is
the identity.

The multiplier has its own internal function that asks no question
about who is looking. `loyalty_member_tier` is screen-facing and checks
`can_read_module`; settling must not, or a Gold member would quietly
earn at the plain rate whenever their sale landed from an offline
device rather than a counter.

The tiers list shows how many members are sitting in each band, which
is how a shop finds out whether Gold is an achievement or a
participation prize. Retiring a band drops its members to the one below
and deletes nothing.

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

## The device's half of selling with no signal

0219 built the landing half — `ingest_offline_sales` takes a batch,
lands each payload in its own subtransaction, and is safe to call twice
because a sale already there is reported rather than repeated. Nothing
in the client produced such a batch, which made "works offline" true of
the database and false of the product.

`app/lib/src/features/pos/offline_store.dart` is the device's half.

**Offline is a separate selling surface, not a mode woven through the
till.** With no server there is no sale to open, no line to price and no
shift to check — almost nothing is shared. What is left is the outlet's
menu as the device last saw it, a basket held in memory, and one write
to disk when the money changes hands.

**The menu is cached the moment it is read**, because that is the only
moment the device is certain it is current. A till that has never been
online for a given outlet says so rather than showing an empty grid.

**The client uuid is the whole idempotence story.** It is generated on
the device before any attempt to send, from `Random.secure()` — two
phones seeded from the same clock tick would otherwise collide, and the
unique index on `(org_id, client_uuid)` would make one shop's sale
silently swallow another's.

**Change is the one rule implemented twice, deliberately.** A cashier
cannot wait for a server to say what coins to hand back, so `cashDue()`
mirrors `app.pos_cash_due` — five sen, by multiplying by 20, rounding
and dividing back. It is not the authority: when the batch lands,
`complete_pos_sale` computes it again and that answer is what posts. The
two are written to agree, and `app/test/offline_store_test.dart` asserts
the same worked examples `supabase/tests/pos.sql` asserts.

**Every outcome comes off the queue, including `rejected`.** Keeping a
rejected payload would retry it on every flush for ever. It is not
lost — `app.pos_record_reject` has already written it to
`pos_offline_rejects`, where `pos_offline_problems` shows it to somebody
who can act on it. The device is the wrong place for a payload nobody is
looking at.

**Going offline is explicit as well as automatic.** A connectivity check
tells you the phone has a bar, not that the database is reachable, and a
van driving through a town gets a bar every few minutes without ever
completing a request. A stallholder who knows the market has no signal
says so once, rather than discovering it one failed sale at a time.
Coming back is a decision too: nothing flushes on its own, because a
flush that starts mid-sale on a flaky connection is slow at the worst
possible moment.

The banner stays up while anything is queued, even after signal returns.
Sales still sitting on a device are the most important thing about a
till holding them, and a banner that vanished when the bars came back
would hide exactly that.

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

## The kiosk's own face

`start_kiosk_order` and `complete_kiosk_order` had no screen: the board
customers watch was built, the touchscreen they order from was not. It
is at `/kiosk`, and it is the only screen in this application whose
reader is a stranger — somebody using it once, holding a tray, who will
not read anything and cannot be corrected. That decides most of its
design: large targets, one decision at a time, and categories always
before items, because a cashier knows the menu and a customer does not.

Four rules it enforces that the till does not need to:

- **Only a kiosk register is offered.** `start_kiosk_order` refuses a
  staff till — a kiosk order on one would be a sale with nobody behind
  it and a drawer that could take cash. The screen filters the list
  rather than making that refusal reachable.
- **Cash is not on the list.** `complete_kiosk_order` refuses it, and a
  customer told "no" by a machine has nobody to ask why.
- **Nothing is written until an item is tapped.** Walking up starts no
  sale, because an empty parked sale would be worse than untidy:
  `close_pos_shift` refuses while anything is parked, so a day of people
  tapping the screen and leaving would stop the shop closing its drawer.
- **It returns to "Tap to order" by itself** — after paying, and after
  two minutes of nothing. A kiosk still showing the last customer's
  basket charges the next person for food they did not order.

An abandoned basket *with* something in it is left parked rather than
voided. It holds no money and no number, and a till can settle it if the
customer comes to the counter saying the machine ate their order — which
is the one recovery a kiosk has, and it is reachable now that every till
lists every open bill in the shop.

The number comes before the thanks because `complete_kiosk_order` takes
it before the sale completes, so a customer who has paid always has one.

## Setting up a counter, and saying what goes to it

0215 built the routing and asserted it. It was reachable only by writing
SQL: a shop that wanted a bar had no way to say so. `/counters` is where
a shopkeeper states it now, over three functions in 0228 that exist
because doing the same thing directly goes wrong.

- **One default, cleared in the same transaction.**
  `pos_kitchen_stations_one_default` is a unique partial index, so
  making a second counter the default has to clear the first or the
  write fails. Two client calls would leave a moment with no default at
  all — which is exactly the moment `send_order_to_kitchen` refuses an
  unrouted dish.
- **One counter per dish per outlet.** `item_kitchen_stations` is unique
  on `(item_id, station_id)` and has to allow two rows, because the same
  dish in two shops is two rows. But `app.pos_route_item` takes
  `limit 1`, so two rows in *one* outlet means the bar and the kitchen
  take turns receiving the drink and nobody can say why.
  `route_item_to_station` clears that outlet's other rules first.
- **Retired, never deleted.** `pos_kitchen_tickets.station_id` cascades,
  so deleting a counter would delete every docket it ever received — a
  day of kitchen history removed by somebody tidying a list. Retiring
  sets `is_active` false, which is what routing already checks, and
  refuses while tickets are still in play or while it is the counter
  unrouted dishes fall back to.

**The screen shows the reason, not just the answer.**
`pos_station_routing` returns, for every sellable item, where it goes
*and* which of the three rules decided — the dish, its category, or the
outlet default. Without that column a default and a deliberate rule look
identical, and somebody meaning to change one dish changes every drink
on the menu instead. It is why the list is grouped by category: that is
where the rule covering most of a menu actually lives, and the rows
under it are the exceptions.

## How the order arrived

`pos_outlets.business_type` says what shape of shop this is — a counter,
a dining room, a van, a salon, a machine by the door. It has never said
how an order *reached* it, and those are different questions: one warung
takes a bill at a table, a bag over the counter, a phone call and a
delivery app, and every one of those is the same shop. Nothing in the
module could tell them apart, so nothing could answer the questions a
shopkeeper actually asks — how much of Friday was delivery, is the
dining room worth the seats, did the app pay for itself.

`app.pos_order_channel` names eight: `walk_in`, `dine_in`, `takeaway`,
`delivery`, `reservation`, `phone`, `online`, `mobile_app`. The labels
live in Dart, because they are wording rather than data — a shop that
calls takeaway "bungkus" is changing what a screen says, not what a
report groups by.

**Three levels, resolved on insert.** A sale takes the register's
channel, else the outlet's default, else `walk_in`. A kiosk register
gets `takeaway` on insert — a kiosk added to a dining room later would
otherwise inherit `dine_in` and report every order at the door as
somebody sitting down. So a kiosk is takeaway and a waiter's tablet is
dine-in, so on most devices nobody ever touches
it — which is the point: a control the cashier has to set on every sale
is a control that gets set wrong.

It is a trigger rather than an argument to `open_pos_sale`, and that is
a deliberate trade. Adding a parameter would restate a function 0209
wrote and 0212 already restated once, for a default that is pure
derivation, and a 250-line diff to add one resolved column is a diff
nobody checks.

**An outlet accepts what it says it accepts.** `pos_outlet_channels` is
the list, and `app.pos_default_channels(business_type)` is where the
starting set lives — used twice, by the backfill and by a trigger on
`pos_outlets`, so the two can never drift. A backfill alone was the
first version and it was wrong: it left every outlet created *after* the
migration with no channels at all, so a shop opening a second branch
next week would have one that could record nothing and a
`set_pos_sale_channel` that refused everything. CI caught it, because
the test creates its own outlet.

A market stall that does not deliver cannot record a delivery, because a
report split by a channel nobody sells has a row that can only be a
mistake. The default moves rather than disappearing: naming a new one
clears the old in the same statement, and switching a channel off gives
up its default flag, since a default nobody can order through is not a
default.

**A completed sale keeps how it arrived.** `set_pos_sale_channel`
refuses once the sale is issued — the channel is on the invoice by then
and part of what was reported for the day, and an issued document does
not change because somebody re-categorised it.

The chip sits on the open bill rather than in settings, because "this
one is takeaway" is a fact about this order. It shows the resolved
channel even when nobody chose it, so a cashier can see the till's
assumption before it becomes what the day gets reported as.

`pos_sales_by_channel(org, from, to)` splits completed sales by it, with
covers on the dine-in row only — reporting a null as a zero would make
an empty column look like an empty dining room.

## Seven screens, seven readers

The module is not one face but seven, and what separates them is who is
holding the device rather than which feature they reach.

| Screen | Route | Read by |
|---|---|---|
| Till | `/till` | A cashier, at a counter, with a queue |
| Floor | `/floor` | A waiter, crossing a room, at a distance |
| Kitchen | `/kitchen` | A cook, hands full, further away still |
| Diary | `/diary` | A receptionist, on a phone, mid-sentence |
| Kiosk | `/kiosk` | **A customer**, ordering for themselves |
| Outlet setup | `/counters` | Whoever runs the shop, once |
| Order board | `/order-board` | **A customer**, holding a tray |

They share a register picker and nothing else, because the thing that
makes a POS screen good is different in each case. The board shows the
least of anything in this application; the till shows the most. The two
customer-facing screens are the only ones built for somebody who will
use them once and cannot be trained or corrected.

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

**Taking something off is two acts, and `sent_to_kitchen_at` is the
whole test.** Before the kitchen is told, a line is a keystroke: it
comes off with no dialog, no reason and no trace. After, food exists —
somebody stood at a pan — so the line can only be voided with a reason
and a name against it, and `pos_sale_line_voids` keeps what it said,
what it was worth and whether it had been sent. `pos_void_summary()`
groups the day by reason, because one void is an accident and thirty
"never came out" in a week is a conversation.

The line is *deleted* rather than flagged, which is the decision worth
recording: a `voided_at` column would have forced `recalc_pos_sale`,
the "a sale has to have a line" guard, the invoice loop and the
loyalty basket each to remember to exclude it — four places, one of
them the invoice, and forgetting any one bills the customer for a
plate that was taken off. Deleting means the arithmetic simply sees
fewer lines. The kitchen docket survives untouched because 0215 made
`pos_kitchen_ticket_lines.sale_line_id` `on delete set null`, with the
comment that the food was cooked whatever the bill ends up saying.

That decision is about a line, and the bill void below deliberately
goes the other way — see "Writing a bill off".

What the database does *not* do is invent a cashier role. It enforces
that a sent line needs a reason and a name; where the action is
offered — the till, not the floor plan — is the client's half of the
same rule.

**On a phone the bill is a count, and the lines are a tap away.** The
narrow layout used to give the basket a fixed share of the height,
which on an ordinary phone was enough to show one item and clip it. It
is now one row — how many items, what they come to — opening a
scrollable sheet with every line and its modifiers.

That hiding creates an obligation, and the till meets it: **the two
actions that leave the till show the bill first.** Sending to the
kitchen and taking payment both open the sheet with the agreement on
its button, because a cashier who cannot check what is about to be
cooked finds out from the customer. A counter and a tablet skip the
step — the lines are already on screen there, and a confirmation that
repeats what you are looking at is ceremony rather than a check.

Every figure on the tender sheet — the total, the cash due, the change,
the rounding — comes back from `complete_pos_sale()` rather than being
recomputed in Dart. A till that does its own arithmetic is a till that
can disagree with the receipt it just printed.

## The card on the table, and the table itself

A dine-in bill has to end up pointing at a table, and for a long time
the only way to put it there was the floor plan — a second screen, a
drawn room, a tap. That is right for a waiter crossing the floor and
wrong for a cashier at a counter taking an order for table seven.

**What a shop puts on the table is a card**, and every reader sold into
this market for one — the tag readers, the barcode guns, the QR pads —
presents to the device as a keyboard: it types what it read and presses
enter. So the till needed no new hardware path, only a way to turn the
string that arrives into a table. `pos_table_by_code()` does the
normalisation, and it is deliberately not in the client: a bare `T7`, a
URL `https://iakauntan.com/t/T7` for a sticker a customer might also
point a phone at, and a `table:T7` token from a tag writer are all the
same table, and a shop that changes its sticker printer must not need
an app release. It also reports how many bills are already open on the
table, because two on one is legitimate — a split leaves exactly that —
and is a fact to show rather than a reason to refuse.

**The cards are printed from the floor plan**, six to an A4 sheet. The
QR holds the bare code, not a URL, which is worth writing down because
the lookup would accept either: a short payload makes a coarser QR that
survives being wiped down and read at an angle, and a URL is a promise
this app does not keep — there is no page at `/t/T7`, and a customer who
points a phone at one has been misled by us. The code is printed in
plain text underneath too, because the fallback for every scanner that
fails is somebody reading it and typing it, which the same sheet
accepts.

**A long table is two tables.** Two unrelated parties down one
twelve-seater is the ordinary Friday in a warung, and the room had one
place for them: one bill between strangers, or two bills on a table
`seat_table` refuses to disambiguate on purpose. `split_pos_table()`
turns T1 into T1-A and T1-B as *real rows* in `pos_tables`, which is
the whole design — seating, moving a party, the floor plan, a scanned
card and the printed sheet all work on them with nothing changed,
where a virtual part would have had to be taught to every one.

The whole table goes out of service while it is split, because it is
not a place anybody can be seated at while two parties are in its
halves; every read already filters `is_active`, so that is the entire
mechanism. Merging deactivates the halves rather than deleting them:
`pos_sales.table_id` is `on delete set null`, so deleting T1-A would
erase which table last Tuesday's bills were served at, and a shop that
splits its long table every Friday would lose a night of per-table
history a week. It also means splitting again is the same T1-A, whose
history accumulates. Split and merge are symmetric about the party in
the middle — one party already sitting goes to the first half with
their bill and comes back the same way; two parties are refused in
both directions, which is the ambiguity the arrangement exists to
avoid.

## Writing a bill off

Taking one line off is above. Taking the whole thing off is a different
act and was missing entirely — a party walking out on six lines meant
six voids, six reasons and six records for one event. `0206` had been
assuming otherwise since long before it was true: it refuses to close a
shift over a parked sale and tells the cashier to "finish or void" it.

`void_pos_sale()` **keeps the lines and the total**, which is the
opposite of the line void and for the opposite reason. A line void
deletes because the bill carries on and has to re-total without it; a
written-off bill stops there, and what was on it is the evidence.
Deleting would leave a voided sale of nothing, and "RM 86.00 walked
out" is the fact a manager needs. `status` becomes `voided`, which
every aggregate here already excludes — expected cash, the floor plan,
the open orders list, the consolidated e-Invoice, the channel report —
so nothing had to learn to ignore it. Live dockets are cancelled so the
kitchen stops; one already served stays served, because that food went
out and rewriting it would make the pass disagree with the room.

**It needs the `pos_void` grant every time.** The first cut asked only
when the kitchen had cooked, on the reasoning that an uncooked bill is
keystrokes the cashier could remove one at a time anyway. That is wrong
about what the control is for: a shop that takes voids away has decided
that making a bill *disappear* is a supervisor's act, and a bill that
vanishes before the kitchen saw it is exactly the shape of an order
rung up, paid in cash and quietly removed. Removing a single unsent
line is untouched and still needs nothing — it leaves the bill, and the
cashier still has to account for it.

The cost is intended rather than incidental: a cashier without the
grant who opens a bill by mistake cannot clear it and cannot close
their own drawer. A shop avoids that by granting `pos_void` to whoever
closes the till.

**And it has to show somewhere.** `pos_void_summary()` reads line
voids, so a bill written off before anything was cooked wrote nothing
to it — the one case the grant was tightened for produced no value in
any report. `pos_voided_bills()` lists them: which bill, what it came
to, why, the note and who. Listed rather than grouped, which is
deliberately the reverse of the line report — those are grouped because
one is an accident and thirty is a conversation, while these are few,
each is a whole order, and the question is which one and whose. The
cooked count sits beside the line count, because food lost and an order
that never existed are different facts.

## Every open bill in the shop, and whose drawer it lands in

A till used to list only the baskets parked on itself. That is right for
a corner shop with one register and wrong for everything else this
module sells to: a waiter opens table 6 on a tablet, the customer walks
to the counter, and the counter cannot see the bill at all.

`pos_open_orders(outlet)` answers the question the room actually asks —
what is open in this shop — and the till lists that instead. Each row
carries what people say out loud: the table, the covers, how long it has
been open, how many lines the kitchen already has, and whose name is on
it. The register appears only when the bill belongs to another till,
because on your own it is noise.

**Seeing a bill and taking it are two different acts.** Settling
somebody else's bill moves money between drawers, so it is a deliberate
second step:

- `app.pos_expected_cash` counts by `pos_sales.shift_id`. A bill settled
  in cash at the counter while its shift still points at the tablet puts
  the counter's cash into the tablet's expected figure — and both
  drawers then fail their count, in opposite directions, for a reason
  neither cashier can see.
- `close_pos_shift` refuses while a sale is parked against the shift, so
  a waiter holding a bill the counter is about to settle cannot go home.

`claim_pos_sale(sale, register)` moves the bill — **register and shift
together**, since separating them is what causes the first problem — and
keeps where it started in `pos_sales.opened_on_register_id`. That column
exists so "why is a bill from the tablet in my drawer" has an answer in
the row rather than in somebody's memory. Nothing else moves: the lines,
the modifiers, the kitchen tickets and the invoice numbering are
untouched, because this is a change of till and not a change of sale.

The till asks before it claims, and the question names the consequence
rather than asking whether you are sure — what changes is which drawer
has to account for the bill, and that is the only part worth telling a
cashier.

An open bill also has a way back to the list. Without one the till is a
one-way street whose only exit is taking money, and a waiter called from
table 3 to table 5 would have to settle the first to leave it. Parking
writes nothing: a sale is `parked` from the moment it opens.

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
| `food_beverage` | `warung@iakauntan.com` | **Warung Sedap Enterprise** — two rooms, seven tables, two kitchen stations, a menu with modifier groups, a loyalty card with 500 points on it, two parties seated with orders in the kitchen and one bill already settled |
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

## A price the manager takes off

`add_pos_sale_line` has taken a `p_discount` since 0209 and
`pos_sale_lines` has carried `discount_percent` and `discount_amount`
since 0208. Nothing ever passed either. The till had no discount button,
so a cashier asked to knock two ringgit off re-rang the line at a
made-up price — which works, reports nothing, and is indistinguishable
from theft. 0255 gave the storage a caller.

**Who may.** `pos_discount`, an entry in 0244's `access_permissions`,
which is the same answer voiding got. A company that has never defined
an access type is unaffected and every cashier may discount. A company
that has defined them must grant it, which is the point.

**A reason, in words.** A void has an enum because the kitchen cares
which of four things happened to the food. A discount has no such short
list — "staff meal", "hair in the soup", "regular, third time this week"
are all real — so the field is free text and required. What matters is
that somebody typed a sentence and their name went on it.

**A rate is not an amount.** "Ten per cent off" still means ten per cent
after another plate arrives; "four ringgit off" still means four
ringgit. Both are stored, and `recalc_pos_sale` re-derives the
percentage every time the basket changes. Anything else would mean a
waiter bringing another round silently shrinking the discount the
customer was promised.

**Where the money comes off.** A line discount reduces that line's
subtotal and therefore its tax, which is right: SST is charged on what
was paid. A bill discount cannot be pushed into the lines without
inventing which plate absorbed it, so it sits on the header where 0212
put the loyalty redemption, and `complete_pos_sale` adds the two into
the invoice's `discount_amount` — the field `prepare_einvoice` maps to
the MyInvois total discount. Before that, an invoice charging RM 36 for
RM 40 of food would have declared a discount of nothing, and the lines
on the e-Invoice would not have added up to its total.

**Splitting and merging.** A rate travels to the second bill and
re-applies to whatever landed there; a flat amount does not, because
there is no honest way to decide how much of four ringgit belongs to the
plates that moved. Merging is the other way round: the bill being
absorbed is about to stop existing, so its discount travels rather than
vanishing — the same rule 0216 already applied to a redemption.

**A cooked plate has two answers.** Tapping a sent line used to go
straight to the void reasons. It now asks which: taking money off leaves
the plate on the bill and the cost where it fell, voiding takes the line
away. A burnt steak is usually the first. The `pos_void` grant is
checked down the voiding branch only, so a cashier who may discount and
may not void reaches the half they hold.

**The report.** `pos_discount_summary` is what the permission exists
for — one row per person per day per shop, line discounts and bill
discounts in separate columns because they are different acts. Bills
that were later written off are excluded, or the same money would be
reported here and in the void report. `pos_void_summary` answers where
the food went; this answers where the price went, and a shop reads both
on a Monday morning. Both live on one screen — `/voids`, renamed "Off
the bills", because a manager checking one is checking the other and a
page named after voiding is not where anybody would look for a
discount.

## A price the shop decided in advance

0255's discount button is the right control for "the steak was burnt"
and the wrong mechanism for "teh tarik is two ringgit before eleven". A
happy hour typed in by hand is wrong on the till nobody told, missing on
the Tuesday the manager was off, and unreportable afterwards because
every application looks like a cashier's judgement. 0256 lets the shop
write the rule down once.

**Three kinds.** A percentage, a flat amount, and buy-X-get-Y. The last
one is done the way a supermarket does it: every qualifying unit at its
own price, sorted dearest first, cut into blocks of (buy + get), and the
cheapest `get` of each **complete** block discounted. Five units on a
three-for-two frees one, not one and two thirds.

**Every window is empty-means-always.** Dates, weekdays, an hours
window, outlets, order channels, a minimum spend. A promotion with no
conditions is a name and a number. `starts_at` later than `ends_at` is a
window that crosses midnight, which is what a late bar means by "ten
till two". All of it in Asia/Kuala_Lumpur, like every other POS day
calculation.

**A promotion never touches a line.** The obvious implementation —
reprice the line — is a trap: once the line is rewritten there is no way
back to what it cost, so removing a promotion means remembering the old
price somewhere, and that somewhere is a second copy of live state.
Instead each application is a row in `pos_sale_promotions` and
`pos_sales.promo_discount` is the sum of those rows. Deleting the row is
the whole of removing the promotion. The cost of this choice is that a
promotion comes off the header rather than the line and so does not
reduce that line's SST — already true of the loyalty redemption and the
manual bill discount, and one rule applied three ways beats three rules.

**Re-evaluated, not remembered.** `refresh_pos_promotions` throws away
every automatic application and works them out again from the basket as
it stands. Anything else rots within one order: ten per cent off a
basket that has shrunk is no longer ten per cent, and "spend fifty, get
five off" must stop the moment somebody takes the fiftieth ringgit back
off. It runs from the till after a change and again inside
`complete_pos_sale`, so a bill parked at ten to eleven and settled at
five past is settled outside the happy hour — and a kiosk order or an
offline sale landing hours later cannot miss a promotion because nobody
refreshed a screen.

**A coupon behaves differently on purpose.** Somebody typed it, so it
stays attached even when it stops qualifying, carrying a
`blocked_reason` the till prints: "Raya five needs 50.00 and this bill is
43.00". A voucher that silently vanished would leave a cashier
explaining something they cannot see. It comes back on its own when the
basket goes back over the line, without being retyped.

**Usage caps are counted, never incremented.** A counter has to decide
whether parking a bill burns a use and whether voiding gives it back,
and every answer is a bug waiting for the other case. Counting
completed, un-voided sales answers both at once and cannot drift.

**The header discount is load-bearing.** `post_sales_document_internal`
derives the credit side from the lines less the header discount and
checks it against the debit side. Leave a promotion out of
`sales_documents.discount_amount` and the two disagree by exactly what
it took off — the sale fails at the counter with *Journal does not
balance: debits 55.00, credits 60.00*. The same field is what
`prepare_einvoice` maps to the MyInvois total discount.

**Not gated on `pos_discount`.** That grant is about a cashier deciding
to reduce a price. Honouring a code the shop printed is the opposite —
the decision was made in advance by whoever wrote the promotion, and a
till that could not accept its own voucher cannot do its job.

## A number and a wait

What the queue replaces is a scrap of paper by the door. The paper
cannot tell the next customer how long they are likely to stand there,
cannot be read from the floor by the waiter who just cleared table 6,
and does not exist by Monday — so nobody ever learns whether Saturday's
wait is twenty minutes or fifty.

**The number is shouted across a room**, so it is small and starts again
every morning: per outlet per trading day, taken as the highest issued
today plus one under a transaction advisory lock keyed on the outlet and
the date, so two hosts at the door at once cannot hand out the same one.
Derived rather than kept in a counter row, because a counter has to be
reset by something and the something is always missing on the morning it
matters. `queue_date` is stored beside it only so the unique index can
exist — an index needs an immutable expression and `at time zone` is
merely stable.

**The quoted wait is measured or it is not given.** It is the median of
what parties within two of your size actually waited at this outlet
today, and it is null under three seated parties. A shop that has just
opened is told nothing rather than told a guess, because a guess that is
wrong twice teaches the staff to stop reading it. The median rather than
the mean, so one party who wandered off to the car park does not move
everybody else's quote. Rounded up to the next five minutes: nobody says
"eleven minutes", and a quote that reads precise is one somebody will
hold the shop to.

**Five states, and no way back out of the last three.** waiting → called
→ seated is the happy path. A party who has been *called* is still
counted as ahead of you — they have not sat down, and a queue that said
otherwise would move everybody up one and then move them back. `left`
and `no_show` are separate because they are different problems: the
first is the wait being too long, the second is somebody standing
outside on the phone, and a shop reading "twelve gave up" cannot tell
which it had.

**Minutes waited is computed on the server.** A phone with a wrong clock
would otherwise show a different queue from the tablet beside it, and
the argument that follows is with a customer.

`pos_queue_day` is why the paper was worth replacing: joined, seated,
walked away, no-shows, still waiting, and the median and longest wait,
per outlet. A shop that cannot say how long Saturday's wait was cannot
decide whether to open another section.

## Breakfast stops at eleven

A kitchen that serves nasi lemak until eleven and burgers after it has
one menu in its head and one on the till, and the till's does not know
what time it is. The cashier remembers, until the Saturday somebody else
is on the counter.

**The schedule governs the menu, never the ledger.** This is the
decision the rest of 0258 hangs off, and it is not the obvious one. The
obvious implementation refuses the sale — a check in
`add_pos_sale_line`, or beside the variant rule in the
`pos_sale_line_sellable` trigger. It would lose real money: 0219 lets a
van sell with no signal and land the batch later, *by calling
`add_pos_sale_line`*. A breakfast set sold at half past ten from a gerai
with no coverage, landing at two o'clock when the driver gets back into
town, would be refused by a clock check — and the food is eaten, the
cash is in the tin, and the till would be saying it never happened. The
same holds for a bill parked at 10:55 and settled at 11:05. So a
schedule decides what the shop *offers*; what was sold is what was sold.

**Greyed and explained, not hidden.** `pos_menu` still returns a dish
that is off, with `available` false and an `off_reason`. A tile that
vanishes reads as a broken menu; one greyed out saying "From 07:00"
reads as a shop with a breakfast menu, and is the only version a cashier
can answer a customer from.

**A schedule is a thing, not two columns on an item.** Times on each
dish would mean typing 07:00–11:00 forty times and getting it wrong
once. A schedule is named and dishes hang off it. A dish on no schedule
is always on — the same empty-means-always rule the promotions use — and
a dish on several is on when *any* of them is open, because "breakfast,
and also all day Sunday" is two rules and both say yes.

**Eighty-sixing is separate and wins.** `stop_pos_item` takes a dish off
for today at one outlet: the branch that ran out of ayam is not the shop
that has plenty, and tomorrow it is back. There is no end date to forget
to clear — the row belongs to today, and today ends. When a dish is both
out of hours and sold out, the kitchen's answer is the one shown,
because "sold out" is the more useful half for the customer to hear. It
is guarded on writing the till rather than configuring the company: the
person who notices is the person on the counter, and on the grid it is a
long press, because the tiles are tapped hundreds of times an hour and
this happens twice.

`app.pos_window_open` is where the recurring-window arithmetic now
lives, in Asia/Kuala_Lumpur, nulls meaning always, and a start later
than the end meaning the window crosses midnight — which is what a late
bar means by "ten till two", and what a naive `BETWEEN` gets exactly
backwards.

## An address, a fee and a driver

0229 taught the module that an order can arrive by delivery and nothing
else about it: the address lived in the note field, the fee was rung up
as an item called DELIVERY, and the driver was a name somebody shouted
at the door.

**The fee is a shipping charge, not a plate of food.** A fee rung up as
a line item lands in food revenue, is counted in the item ranking, is
discounted by every promotion naming "all items", and earns loyalty
points. `sales_documents.shipping_amount` has existed since 0005 and
0013 already posts it to 4900 by itself, so `complete_pos_sale` puts the
fee there. No new account, no new line type, no change to the posting
function, and the journal still balances because the receivable was
always the header total. Points settle against the total *less* the fee,
because a shop paying points on a courier charge is paying points on
money it hands straight to a rider.

**A zone is a name and a list of postcodes.** Malaysian addresses are
reliably identified by five digits and unreliably by anything else. A
zone naming the postcode wins; a zone with an empty list is the
catch-all — "anywhere else we will go" — and is only reached when no
other zone matches. Postcodes are normalised on the way in, so matching
is an equality test rather than a function somebody has to remember to
call.

**The fee is derived, on every recalculation.** `recalc_pos_sale`
rebuilds it from the zone before it touches the totals, so `free_above`
comes true the moment the plate that qualifies is added rather than at
the till's next guess. A fee somebody typed is marked `fee_is_manual`
and left alone — and typing one *below* what the zone says needs
`pos_discount`, because a fee a cashier can quietly set to zero is a
discount wearing a different hat.

**The ride survives every discount.** The order is: the food, less the
manual discount, less the promotions, less the redemption, floored at
nothing — and then the fee on top. A hundred per cent staff discount on
a delivery bill still owes the courier, and an arithmetic that let the
fee be discounted away would have the shop paying the rider out of its
own margin without anybody deciding to.

**A minimum is checked when the money is taken.** Every shop with a
minimum order takes the address first and the order second, so refusing
at the door refuses the wrong thing. `app.pos_delivery_blocked` returns
a sentence with the shortfall in it — the same shape as a blocked
promotion — and it becomes an error only in `complete_pos_sale`, which
is the one moment the basket is final.

**Five states, and the driver is required for three.** pending →
assigned → collected → delivered is the run; `failed` is nobody home, a
refused order, an address that is not one, and it carries a reason
because "failed" alone tells a shop nothing it can act on. Assigned,
collected and delivered all require a driver, enforced by a constraint
rather than by the function that sets them. Delivered and failed are
terminal. A driver with orders still out cannot be stood down, and a
bill already with a driver cannot be folded into another one — merging
two delivery bills is refused outright rather than quietly keeping one
of the addresses, because the alternative is food at the wrong house.

On the screens: the till's bill menu carries "Where is it going?", the
fee shows as its own row above the total with the zone's name on it, and
the shortfall sentence sits under it in the warning colour while the
customer can still add to the order. **Deliveries** is the board of
everything not yet landed, oldest first, with minutes waiting computed
on the server and whether the driver is collecting the money — and its
own screen behind it for zones and drivers.

## What goes on the receipt

`pos_outlets.receipt_header` and `receipt_footer` have existed since
0206 and nothing ever read them. The till's "receipt" was a dialog with
four numbers on it, and a customer had never been handed anything.

**The paper is rendered on the server.** `pos_receipt_text` returns the
receipt as plain text, wrapped to the outlet's own roll — 32 columns for
58mm, 48 for 80mm. That is what a thermal printer takes, and it means
the counter, the phone, the kiosk, the van that was offline this morning
and a reprint an hour later all produce the same document. It also makes
the choices assertable: "turn the cashier's name off and it is not on
the paper" is a test, where "one fewer `Text` in the widget tree" would
be a test of the wrong thing.

**The choices are per outlet, and so is the text.** One row in
`pos_receipt_settings`; the header and footer stay on `pos_outlets`
where 0206 put them rather than being copied. `upsert_pos_receipt_settings`
writes both in one call, so there is no moment where a shop has saved
half of it. An outlet with no row prints the defaults — nothing about
this makes a shop configure it before the till works.

**Money is never optional.** The switches cover the cashier's name, the
table, the customer, the channel, item codes, the tax line and the
points balance. There is deliberately no switch for a discount, a
promotion, a delivery fee or a tender, and `pos_receipt.sql` asserts
that with everything switched off the discount, its reason and the total
are all still on the paper. A receipt that can be configured not to
mention money that changed hands is a receipt that can be used to hide
it.

A parked bill prints too — "bill please" is a print — and says
`*** NOT PAID ***` where the change would be rather than showing a
change of nothing, which reads like a settled sale at a glance. A voided
one is marked on its own paper.

On the screens: **Outlet setup → Receipt** carries the settings with a
live preview rendered through the same function the printer uses,
against the last bill the outlet actually settled. The till's bill menu
has "Print the bill", and the tender sheet's "Receipt" opens the paper
once the money is in.

## Publish the menu, and let a phone order from it

Everything the till knows was behind a login. A customer sitting at
table seven could not see the menu, could not see that the nasi lemak
ran out an hour ago, and could not order without catching somebody's
eye — which on a Saturday is the whole problem.

**A token, and nothing else.** `pos_menu_links` is a published menu:
outlet, kind (a table sticker, a takeaway poster, a delivery link), an
optional table, an optional expiry, an optional single use. The token is
the whole credential — `public_pos_menu`, `public_pos_menu_modifiers`
and `place_public_pos_order` are the only POS functions granted to
`anon`, they take a token and never an organization id, and they resolve
the shop from the link row. A static QR and a dynamic one are the same
row with `expires_at` and `single_use` filled in or not, because the
difference is a policy rather than a mechanism.

**The price is the shop's.** `p_items` carries an item and a quantity
and nothing else. A price arriving from a browser is a price somebody
typed, and `pos_public_menu.sql` asserts that one sent anyway is
ignored.

**Availability is checked when the customer taps**, not when the page
loaded: 0258's scheduler and the sold-out list decide, so a menu left
open on a phone since ten o'clock cannot order breakfast at four.

**And only into an open shift.** A shop that has not counted its float
in is closed, and "closed" is the honest answer to a phone at seven in
the morning. Past that the order is an ordinary parked bill: it joins
the bill already on the table when the sticker names one, it goes to the
kitchen, it takes the shop's promotions, it can be delivered, and it
prints the same receipt — none of which knows a phone put it there.

**One copy of the arithmetic.** `open_pos_sale`, `add_pos_sale_line` and
`add_line_modifier` each begin with a permission check and continue with
the part a public order needs verbatim. Rather than a second copy that
drifts, each is now `app.*_internal` plus a thin guarded wrapper, and
the public path calls the internal. The arithmetic has one home and the
guard has another.

The allow-list in `supabase/tests/statutory.sql` is where the three new
`anon` grants had to be argued for; it now names seven functions instead
of four, and asserts both that nothing else is exposed and that these
have not silently lost the grant.

On the screens: **Outlet setup → Published menus** publishes a link per
table, a poster for takeaway or a one-time link, and copies the URL to
print as a QR. `/menu/<token>` is the page a customer's phone lands on —
outside the shell and outside sign-in, like the signing and share pages
before it.

## A report somebody builds, rather than one we wrote

The module has a dozen reports in it and every one answers a question we
thought of. The question a shopkeeper has on a Tuesday is "which dishes
sell after nine at the Bangsar branch", and nobody is going to ship a
migration for it.

**A saved report is a declaration, not a query.** It names a source,
some dimensions and some measures, and every one of those names is a key
in an allow-list inside `app.pos_report_dimension` and
`app.pos_report_measure`. A key that is not on the list raises rather
than being interpolated, so the worst a malicious report can contain is
a word those functions do not recognise. That is the whole safety
argument, and it is why this is a builder rather than a SQL box: a SQL
box in a multi-tenant database is a way to read somebody else's books.
The only values that reach the query are bound parameters — the org, the
two dates and the two filter arrays.

**Two sources, because there are two kinds of question.** `sales` is one
row per bill and answers how many, how much, when and who. `lines` is
one row per thing sold and answers what.

**The period is a word, not a pair of dates.** "This month" saved as the
first and last of August is a report that is wrong in September, so the
word is stored and `app.pos_report_period` resolves it in
Asia/Kuala_Lumpur when the report runs.

**And the arithmetic is the same arithmetic.** `pos_reports.sql` asserts
that what the builder totals for an outlet today equals what
`pos_day_board` says it took — two answers to one question is one answer
too many.

The keys are checked when a report is saved as well as when it runs, so
a report that cannot run cannot be saved. A report is private to its
author until it is shared, and it is the one thing in this module that
is deleted rather than retired: it is a question, not a record of
anything that happened.

`pos_report_fields` is what the picker offers, read from the same
allow-list the query uses — a column can never be offered that the query
would then refuse. On the screen, **Report builder** lists what a shop
has built, opens one to a table, and copies it out as comma-separated
text, because what everybody does with a report is open it in a
spreadsheet.

## Not built yet

- Submitting the consolidated e-Invoice to MyInvois (the rollup runs; the
  scheduler holds no credentials)
- Card terminal integration. A tender records an authorisation code
  because somebody typed or pasted it; nothing talks to a payment
  terminal
- Cash drawer and receipt printer drivers. The receipt now renders as
  the text a thermal printer takes, and the screen will hand it over;
  pushing those bytes at a USB or Bluetooth printer, and opening a
  physical drawer, is between the browser and the hardware
- Reading a table card with the device's own camera. The wedge readers a
  counter has — tag, barcode, QR pad — type and press enter, and that is
  the whole interface; pointing a phone camera at the sticker is a
  different thing and needs a scanner package the app does not carry
