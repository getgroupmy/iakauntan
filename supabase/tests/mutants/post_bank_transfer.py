# Mutants for public.post_bank_transfer (0635) -- money moved between two
# of the company's own bank accounts: out of one at its rate, into the
# other at its rate, the fee to bank charges, any difference to exchange.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0635_the_fee_the_bank_took_and_where_it_lands.sql \
#       supabase/tests/bank_transfers.sql \
#       supabase/tests/mutants/post_bank_transfer.py
#
# RESULT: 16 mutants and a control, all killed by `bank_transfers.sql`.
# Three only after a second cross-currency transfer was added there: the
# one foreign transfer had no fee and lost on exchange, so a fee booked
# at the RECEIVING rate and a gain sent to the loss account (6500) both
# passed; and nothing read `posted_by`.

m("a deleted transfer is posted",
  "post_bank_transfer",
  "  select * into r from public.bank_transfers where id = p_id and deleted_at is null;",
  "  select * into r from public.bank_transfers where id = p_id;  -- deleted",
  "-- deleted")

m("a transfer that does not exist posts nothing in silence",
  "post_bank_transfer",
  "  if not found then",
  "  if false then  -- no such",
  "-- no such")

m("anybody posts a transfer",
  "post_bank_transfer",
  "  if not app.can_post(r.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a transfer is posted twice",
  "post_bank_transfer",
  "  if r.gl_entry_id is not null then",
  "  if false then  -- twice",
  "-- twice")

m("the amount sent is not converted",
  "post_bank_transfer",
  "  v_sent := round(r.amount_sent * r.from_rate, 2);",
  "  v_sent := round(r.amount_sent, 2);  -- unconverted out",
  "-- unconverted out")

m("the amount received is not converted",
  "post_bank_transfer",
  "  v_received := round(r.amount_received * r.to_rate, 2);",
  "  v_received := round(r.amount_received, 2);  -- unconverted in",
  "-- unconverted in")

m("the fee is converted at the receiving rate",
  "post_bank_transfer",
  "  v_charges := round(r.bank_charges * r.from_rate, 2);",
  "  v_charges := round(r.bank_charges * r.to_rate, 2);  -- wrong rate",
  "-- wrong rate")

m("the fee is not booked",
  "post_bank_transfer",
  "  if v_charges > 0 then",
  "  if false then  -- no fee",
  "-- no fee")

m("an exchange difference is not booked",
  "post_bank_transfer",
  "  if r.fx_difference <> 0 then",
  "  if false then  -- no difference",
  "-- no difference")

m("a gain and a loss go to the same account",
  "post_bank_transfer",
  "                                      then '6500' else '4920' end),",
  "                                      then '6500' else '6500' end),  -- one account",
  "-- one account")

m("an exchange difference lands on the wrong side",
  "post_bank_transfer",
  "      'debit', greatest(r.fx_difference, 0),\n      'credit', greatest(-r.fx_difference, 0));",
  "      'debit', greatest(-r.fx_difference, 0),\n      'credit', greatest(r.fx_difference, 0));  -- flipped",
  "-- flipped")

m("the fee comes off the sending balance twice",
  "post_bank_transfer",
  "     set current_balance = current_balance - v_sent\n",
  "     set current_balance = current_balance - v_sent - v_charges  -- twice\n",
  "-- twice")

m("the sending balance does not move",
  "post_bank_transfer",
  "     set current_balance = current_balance - v_sent\n",
  "     set current_balance = current_balance  -- unmoved out\n",
  "-- unmoved out")

m("the receiving balance does not move",
  "post_bank_transfer",
  "     set current_balance = current_balance + v_received\n",
  "     set current_balance = current_balance  -- unmoved in\n",
  "-- unmoved in")

m("a posted transfer does not say so",
  "post_bank_transfer",
  "     set gl_entry_id = v_entry, status = 'posted',",
  "     set gl_entry_id = v_entry, status = status,  -- still draft",
  "-- still draft")

m("a posted transfer does not say who",
  "post_bank_transfer",
  "         posted_at = now(), posted_by = auth.uid()",
  "         posted_at = now(), posted_by = null  -- nobody",
  "-- nobody")

m("CONTROL: a comment inside the block",
  "post_bank_transfer",
  "  if v_charges > 0 then",
  "  if v_charges > 0 then  -- (control)",
  "(control)")
