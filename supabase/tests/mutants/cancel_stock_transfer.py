# Mutants for public.cancel_stock_transfer (0265) -- a transfer that has
# not moved stock withdrawn: false for one that does not exist, by
# somebody who may write inventory, only while it is a draft.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0265_the_van_and_the_chicken_that_becomes_eight_pieces.sql \
#       supabase/tests/stock_transfers.sql \
#       supabase/tests/mutants/cancel_stock_transfer.py
#
# RESULT: 6 mutants and a control, all killed by `stock_transfers.sql`.
# "Every draft of the company" only after a second draft stood beside
# the one called off -- with one, this transfer and every draft were the
# same row.

m("a transfer that does not exist is cancelled, says the answer",
  "cancel_stock_transfer",
  "  if v_t.id is null then\n    return false;",
  "  if v_t.id is null then\n    return true;  -- says yes",
  "-- says yes")

m("anybody cancels a transfer",
  "cancel_stock_transfer",
  "  if not app.can_write_module(v_t.org_id, 'inventory') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a transfer that has moved stock is cancelled",
  "cancel_stock_transfer",
  "  if v_t.status <> 'draft' then",
  "  if false then  -- any status",
  "-- any status")

m("the transfer is not marked cancelled",
  "cancel_stock_transfer",
  "     set status = 'cancelled', updated_at = now() where t.id = p_id;",
  "     set updated_at = now() where t.id = p_id;  -- still draft",
  "-- still draft")

m("every draft of the company is cancelled",
  "cancel_stock_transfer",
  "     set status = 'cancelled', updated_at = now() where t.id = p_id;",
  "     set status = 'cancelled', updated_at = now() where t.org_id = v_t.org_id and t.status = 'draft';  -- every draft",
  "-- every draft")

m("the answer says it was not cancelled",
  "cancel_stock_transfer",
  "  return true;\nend;",
  "  return false;  -- says no\nend;",
  "-- says no")

m("CONTROL: a comment inside the block",
  "cancel_stock_transfer",
  "  if v_t.status <> 'draft' then",
  "  if v_t.status <> 'draft' then  -- (control)",
  "(control)")
