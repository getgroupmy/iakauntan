# Mutants for public.receive_stock_transfer -- the other end of a branch
# transfer: counting in what arrived, writing off what did not, and
# emptying goods in transit.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0422_what_day_the_work_was_done.sql \
#       supabase/tests/stock_transfers.sql \
#       supabase/tests/mutants/receive_stock_transfer.py
#
# then again against `lot_allocation_shapes.sql`,
# `lots_across_the_new_sources.sql` and `idempotency.sql`.
#
# RESULT, 5 October: 35 mutants (34 plus a control). 20 killed on
# `stock_transfers.sql` and 15 survived; 32 of 34 across all four
# files, with two proven EQUIVALENT. The control lived.
#
#   stock_transfers.sql             kills 20, then 32
#   lot_allocation_shapes.sql       kills the movement's source line
#   lots_across_the_new_sources.sql the same
#   idempotency.sql                 kills nothing new
#
# THE PAIR DID NOT GET SYMMETRIC COVERAGE, which is the lesson
# revalue_foreign_balances gave an hour earlier. `send_stock_transfer`
# scored 19 of 23 and 23 of 23 across its files; its other half scored
# 20 of 35.
#
# Receiving has one rule sending does not: a SHORTFALL. Sending is one
# quantity per line; receiving is two -- what was sent and what turned
# up -- so the journal has three shapes and all three balance:
#
#   all arrived    1310 + 1320, two lines
#   some arrived   1310 + 5900 + 1320, three lines
#   none arrived   5900 + 1320, two lines
#
# Nothing in the suite had ever counted a line in at NOUGHT, so the
# third shape was unreachable -- and `if v_got < 0` widened to `<= 0`
# refused a van that never got there, which is an ordinary event.
#
# AND A COUNT MATCHED TO THE WRONG LINE survived because the fixtures
# counted one line, or counted two the same. Two lines received at 8 of
# 10 and 15 of 20 is what distinguishes "the count for THIS line" from
# "a count".
#
# THE FIFTH ZERO-VALUE FINDING OF THE SWEEP, and the first where the
# right answer is NO JOURNAL. A promotional case taken into stock at
# nought moves between warehouses like anything else: the quantity is
# real and the value is not, so `v_arrived` and `v_short` are both zero
# and the function posts nothing. Every item in the suite had a cost, so
# the test was always true and `if true` changed nothing observable.
#
# `send_stock_transfer` scored 19 of 23 on the first run and 23 of 23
# across its three files (see `stock_transfers.py`). This is its pair,
# and the lesson from `revalue_foreign_balances` an hour ago says to
# expect the halves to differ: six rules asserted on one side of a
# symmetric thing and five on the other is the commonest shape there is.
#
# What is NOT symmetric here is the shortfall. Sending is one quantity
# per line; receiving is two -- what was sent and what turned up -- and
# the difference is written off to 5900. So the arithmetic has three
# cases (all arrived, some arrived, none arrived), each of which puts a
# different set of legs on the journal, and all three balance.

m("anybody can receive a transfer",
  "receive_stock_transfer",
  "  if not app.can_write_module(v_t.org_id, 'inventory') then",
  "  if false then  -- receive write guard dropped",
  "-- receive write guard dropped")

m("a transfer that was never SENT can be received",
  "receive_stock_transfer",
  "  if v_t.status <> 'sent' then",
  "  if false then  -- sent-status guard dropped",
  "-- sent-status guard dropped")

m("the count given for a line is ignored for what was sent",
  "receive_stock_transfer",
  "    v_got := coalesce(v_got, v_line.sent_quantity);",
  "    v_got := v_line.sent_quantity;  -- counts ignored",
  "-- counts ignored")

m("a line nobody counted arrives as NOTHING instead of in full",
  "receive_stock_transfer",
  "    v_got := coalesce(v_got, v_line.sent_quantity);",
  "    v_got := coalesce(v_got, 0);  -- uncounted lines arrive empty",
  "-- uncounted lines arrive empty")

m("the count is matched to the wrong line",
  "receive_stock_transfer",
  "     where (e ->> 'line')::uuid = v_line.id;",
  "     where (e ->> 'line')::uuid is not null;  -- count matched to any line",
  "-- count matched to any line")

m("a NEGATIVE count is accepted",
  "receive_stock_transfer",
  "    if v_got < 0 then",
  "    if false then  -- negative count accepted",
  "-- negative count accepted")

m("a count of ZERO is refused as negative",
  "receive_stock_transfer",
  "    if v_got < 0 then",
  "    if v_got <= 0 then  -- zero count refused",
  "-- zero count refused")

m("MORE can arrive than was ever sent",
  "receive_stock_transfer",
  "    if v_got > v_line.sent_quantity then",
  "    if false then  -- over-receipt accepted",
  "-- over-receipt accepted")

m("receiving EXACTLY what was sent is refused as too much",
  "receive_stock_transfer",
  "    if v_got > v_line.sent_quantity then",
  "    if v_got >= v_line.sent_quantity then  -- exact receipt refused",
  "-- exact receipt refused")

m("what arrived is not written on the line",
  "receive_stock_transfer",
  "       set received_quantity = v_got where l.id = v_line.id;",
  "       set received_quantity = v_line.sent_quantity where l.id = v_line.id;"
  "  -- received quantity not recorded",
  "-- received quantity not recorded")

m("a line that arrived EMPTY still makes a stock movement of nothing",
  "receive_stock_transfer",
  "    if v_got > 0 then\n      insert into public.stock_movements (",
  "    if v_got >= 0 then  -- nil movement created\n"
  "      insert into public.stock_movements (",
  "-- nil movement created")

m("the stock arrives in the warehouse it LEFT",
  "receive_stock_transfer",
  "        v_t.to_warehouse_id, v_got,",
  "        v_t.from_warehouse_id, v_got,  -- received into the wrong store",
  "-- received into the wrong store")

m("what arrived is taken in at the quantity SENT",
  "receive_stock_transfer",
  "        v_t.to_warehouse_id, v_got,",
  "        v_t.to_warehouse_id, v_line.sent_quantity,"
  "  -- movement takes the sent quantity",
  "-- movement takes the sent quantity")

m("the stock is taken in at NO cost, so the destination holds it free",
  "receive_stock_transfer",
  "        coalesce(v_line.sent_unit_cost, 0),\n        'stock_transfers', p_id, v_line.id,",
  "        0,  -- taken in at no cost\n        'stock_transfers', p_id, v_line.id,",
  "-- taken in at no cost")

m("the movement does not say which line it came from",
  "receive_stock_transfer",
  "        'stock_transfers', p_id, v_line.id,",
  "        'stock_transfers', p_id, null,  -- source line forgotten",
  "-- source line forgotten")

m("the arrival is valued at the quantity SENT rather than received",
  "receive_stock_transfer",
  "    v_arrived := v_arrived + round(v_got * coalesce(v_line.sent_unit_cost, 0), 2);",
  "    v_arrived := v_arrived\n"
  "      + round(v_line.sent_quantity * coalesce(v_line.sent_unit_cost, 0), 2);"
  "  -- arrived valued at sent",
  "-- arrived valued at sent")

m("the SHORTFALL is valued at what arrived rather than what is missing",
  "receive_stock_transfer",
  "    v_short   := v_short\n"
  "      + round((v_line.sent_quantity - v_got) * coalesce(v_line.sent_unit_cost, 0), 2);",
  "    v_short   := v_short\n"
  "      + round(v_got * coalesce(v_line.sent_unit_cost, 0), 2);"
  "  -- shortfall valued at arrival",
  "-- shortfall valued at arrival")

m("a transfer where nothing moved still posts a journal",
  "receive_stock_transfer",
  "  if round(v_arrived, 2) <> 0 or round(v_short, 2) <> 0 then",
  "  if true then  -- empty receipt still posts",
  "-- empty receipt still posts")

m("a transfer where EVERYTHING was lost posts no journal at all",
  "receive_stock_transfer",
  "  if round(v_arrived, 2) <> 0 or round(v_short, 2) <> 0 then",
  "  if round(v_arrived, 2) <> 0 then  -- shortfall-only receipt posts nothing",
  "-- shortfall-only receipt posts nothing")

# EQUIVALENT. `accounts` is unique on (org_id, code) -- which is why
# app.cheque_account revives a retired row rather than inserting a
# second one of the same code -- so that select returns at most one row
# and no ordering can change which. The 1310 heading trap 0727/0728
# closed was a FALLBACK to the parent, not an ordering, and there is no
# fallback here.
m("the stock arrives on the 1310 HEADING rather than the real account",
  "receive_stock_transfer",
  "    v_inv     := (select a.id from public.accounts a\n"
  "                   where a.org_id = v_t.org_id and a.code = '1310');",
  "    v_inv     := (select a.id from public.accounts a\n"
  "                   where a.org_id = v_t.org_id and a.code = '1310'\n"
  "                   order by a.is_group desc);  -- 1310 heading preferred",
  "-- 1310 heading preferred")

m("a receipt with NOTHING arrived still debits inventory",
  "receive_stock_transfer",
  "    if round(v_arrived, 2) <> 0 then\n"
  "      v_lines := v_lines || jsonb_build_object('account_id', v_inv,",
  "    if true then  -- nil inventory leg posted\n"
  "      v_lines := v_lines || jsonb_build_object('account_id', v_inv,",
  "-- nil inventory leg posted")

m("the stock arriving is CREDITED to inventory",
  "receive_stock_transfer",
  "        'debit', round(v_arrived, 2), 'credit', 0);",
  "        'debit', 0, 'credit', round(v_arrived, 2));  -- inventory side swapped",
  "-- inventory side swapped")

m("a transfer that arrived in full still writes something off",
  "receive_stock_transfer",
  "    if round(v_short, 2) <> 0 then",
  "    if true then  -- nil shortfall leg posted",
  "-- nil shortfall leg posted")

m("a chart with no 5900 writes the shortfall off silently",
  "receive_stock_transfer",
  "      if v_shrink is null then",
  "      if false then  -- missing 5900 no longer refused",
  "-- missing 5900 no longer refused")

m("the shortfall is written off to INVENTORY rather than to 5900",
  "receive_stock_transfer",
  "      v_lines := v_lines || jsonb_build_object('account_id', v_shrink,",
  "      v_lines := v_lines || jsonb_build_object('account_id', v_inv,"
  "  -- shortfall posted to inventory",
  "-- shortfall posted to inventory")

m("goods in transit is emptied of what ARRIVED and not of what left",
  "receive_stock_transfer",
  "      'debit', 0, 'credit', round(v_arrived + v_short, 2));",
  "      'debit', 0, 'credit', round(v_arrived, 2));  -- transit short-credited",
  "-- transit short-credited")

m("goods in transit is DEBITED again on arrival",
  "receive_stock_transfer",
  "      'debit', 0, 'credit', round(v_arrived + v_short, 2));",
  "      'debit', round(v_arrived + v_short, 2), 'credit', 0);"
  "  -- transit side swapped",
  "-- transit side swapped")

m("the receipt journal does not point back at the transfer",
  "receive_stock_transfer",
  "      'Stock transfer received ' || v_t.transfer_no, 'stock_transfers', p_id);",
  "      'Stock transfer received ' || v_t.transfer_no, 'stock_transfers', null);"
  "  -- source transfer forgotten",
  "-- source transfer forgotten")

m("the movements are not linked to the journal that valued them",
  "receive_stock_transfer",
  "    update public.stock_movements sm set gl_entry_id = v_entry",
  "    update public.stock_movements sm set gl_entry_id = null"
  "  -- movement link not written",
  "-- movement link not written")

# EQUIVALENT, proven by the SENDER's own update rather than by this
# function. `send_stock_transfer` links every unvalued movement of the
# transfer with NO type filter at all, so by the time a receipt runs the
# outbound movements already carry the send journal and
# `and sm.gl_entry_id is null` excludes them on its own. The only state
# where they are unvalued is a transfer worth nothing, and there the
# receipt posts no journal either, so the update never runs. Right to
# keep -- it says what the statement means, and it is the only thing
# between the two journals if the sender's filter is ever tightened.
m("the OUTBOUND movements are relinked to the receipt journal too",
  "receive_stock_transfer",
  "       and sm.movement_type = 'transfer_in' and sm.gl_entry_id is null;",
  "       and sm.gl_entry_id is null;  -- movement type no longer filtered",
  "-- movement type no longer filtered")

m("a received transfer still reads as on its way",
  "receive_stock_transfer",
  "     set status = 'received', received_at = now(), received_by = auth.uid(),",
  "     set received_at = now(), received_by = auth.uid(),"
  "  -- status not advanced",
  "-- status not advanced")

m("WHEN it arrived is not recorded",
  "receive_stock_transfer",
  "     set status = 'received', received_at = now(), received_by = auth.uid(),",
  "     set status = 'received', received_at = null, received_by = auth.uid(),"
  "  -- received_at not recorded",
  "-- received_at not recorded")

m("WHO received it is not recorded",
  "receive_stock_transfer",
  "     set status = 'received', received_at = now(), received_by = auth.uid(),",
  "     set status = 'received', received_at = now(), received_by = null,"
  "  -- received_by not recorded",
  "-- received_by not recorded")

m("the transfer does not remember the journal that received it",
  "receive_stock_transfer",
  "         receipt_entry_id = v_entry, updated_at = now()",
  "         receipt_entry_id = null, updated_at = now()"
  "  -- receipt entry not kept",
  "-- receipt entry not kept")

m("CONTROL -- a comment beside the line loop",
  "receive_stock_transfer",
  "    v_got := coalesce(v_got, v_line.sent_quantity);",
  "    v_got := coalesce(v_got, v_line.sent_quantity);"
  "  -- CONTROL: this cannot change a count.",
  "-- CONTROL: this cannot change a count.")
