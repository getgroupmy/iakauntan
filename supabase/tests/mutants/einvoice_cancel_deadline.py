# Mutants for app.set_einvoice_cancel_deadline (0007) -- LHDN lets a
# validated e-Invoice be cancelled for seventy-two hours, and not after.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0007_einvoice.sql \
#       supabase/tests/einvoice_statutory.sql \
#       supabase/tests/mutants/einvoice_cancel_deadline.py
#
# then again against `einvoice_payload_shapes.sql`.
#
# RESULT: (pending)

m("seventy-two hours is three days of twenty-four, counted as 48",
  "set_einvoice_cancel_deadline",
  "    else new.validated_at + interval '72 hours'",
  "    else new.validated_at + interval '48 hours'  -- 48",
  "-- 48")

m("the window runs from now, not from validation",
  "set_einvoice_cancel_deadline",
  "    else new.validated_at + interval '72 hours'",
  "    else now() + interval '72 hours'  -- from now",
  "-- from now")

m("an unvalidated invoice has a deadline",
  "set_einvoice_cancel_deadline",
  "    when new.validated_at is null then null",
  "    when new.validated_at is null then now() + interval '72 hours'  -- unvalidated",
  "-- unvalidated")

m("CONTROL: a comment inside the block",
  "set_einvoice_cancel_deadline",
  "  new.cancel_deadline := case",
  "  -- CONTROL\n  new.cancel_deadline := case",
  "-- CONTROL")
