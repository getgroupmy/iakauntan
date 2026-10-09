# Mutants for public.set_received_einvoice_status (0650) -- a received
# e-Invoice set aside or brought back: only to 'received' or 'ignored'
# (never 'billed', which only drafting a bill makes true), by somebody
# who may write, and never once it is on a bill.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0650_the_invoice_a_supplier_sent_us.sql \
#       supabase/tests/received_einvoice.sql \
#       supabase/tests/mutants/set_received_einvoice_status.py
#
# RESULT: 4 mutants and a control, all killed by `received_einvoice.sql`.
# One only after "a billed document is not set aside under its bill".

m("any status can be typed, billed included",
  "set_received_einvoice_status",
  "  if p_status is null or p_status not in ('received', 'ignored') then",
  "  if p_status is null then  -- any status",
  "-- any status")

m("a document that does not exist is not said so",
  "set_received_einvoice_status",
  "    raise exception 'No such received e-Invoice' using errcode = 'P0002';",
  "    raise notice 'No such received e-Invoice';  -- said only",
  "-- said only")

m("anybody sets it aside",
  "set_received_einvoice_status",
  "  if not app.can_write(v_row.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a billed document is set aside under its bill",
  "set_received_einvoice_status",
  "  if v_row.status = 'billed' then",
  "  if false then  -- under the bill",
  "-- under the bill")

m("CONTROL: a comment inside the block",
  "set_received_einvoice_status",
  "  if v_row.status = 'billed' then",
  "  if v_row.status = 'billed' then  -- (control)",
  "(control)")
