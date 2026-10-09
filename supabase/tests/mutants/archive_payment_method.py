# Mutants for public.archive_payment_method (0635) -- a way of being paid
# taken off the list, softly, because receipts already name it: it must
# exist and not be archived already; somebody who can write; marked
# deleted and switched off.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0635_the_fee_the_bank_took_and_where_it_lands.sql \
#       supabase/tests/payment_methods.sql \
#       supabase/tests/mutants/archive_payment_method.py
#
# RESULT: 5 mutants and a control, all killed by `payment_methods.sql`;
# two before its rule-by-rule block. One live method was archived once,
# and only `deleted_at` was ever read back.

m("a method that is not there is not said so",
  "archive_payment_method",
  "  if v_org is null then\n    raise exception 'Payment method % not found'",
  "  if false then  -- not there\n    raise exception 'Payment method % not found'",
  "-- not there")

m("an archived method is archived again",
  "archive_payment_method",
  "   where id = p_id and deleted_at is null;\n  if v_org is null then",
  "   where id = p_id;  -- archived too\n  if v_org is null then",
  "-- archived too")

m("anybody archives a method",
  "archive_payment_method",
  "  if not app.can_write(v_org) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("an archived method is not marked deleted",
  "archive_payment_method",
  "     set deleted_at = now(), is_active = false",
  "     set is_active = false  -- not deleted",
  "-- not deleted")

m("an archived method stays switched on",
  "archive_payment_method",
  "     set deleted_at = now(), is_active = false",
  "     set deleted_at = now()  -- still on",
  "-- still on")

m("CONTROL: a comment inside the block",
  "archive_payment_method",
  "  if not app.can_write(v_org) then",
  "  if not app.can_write(v_org) then  -- (control)",
  "(control)")
