# Mutants for public.claim_pos_sale (0226) -- a bill taken onto this
# till: it must exist, be the caller's to sell on and still be open;
# the till must exist in the bill's company and outlet, and its drawer
# be open; the bill moves to the till AND its shift, remembering where
# it was rung up the first time.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0226_every_open_bill_in_the_shop.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/claim_pos_sale.py
#
# RESULT: 11 mutants and a control. 10 killed by `pos_fnb.sql`; before
# its assertions, 4 -- another outlet, a closed drawer, the shift, the
# bill returned. Nothing had asked about a missing bill, a missing
# till, another company's till, a settled bill, a stranger, or where a
# bill taken back to its first till says it started.
#
# One is EQUIVALENT: a bill already on this till moved onto it again.
# The only difference would be the shift, and a parked bill's shift is
# always the open one -- `close_pos_shift` refuses while any bill on it
# is parked.

F = "claim_pos_sale"

m("a bill that does not exist is not refused in words", F,
  "  if v_sale.id is null then\n    raise exception 'No such sale.'",
  "  if false then  -- no such sale\n    raise exception 'No such sale.'",
  "-- no such sale")

m("anybody may claim a bill", F,
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a settled bill is claimed", F,
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("a till that does not exist is not refused in words", F,
  "  if v_reg.id is null or v_reg.org_id <> v_sale.org_id then",
  "  if v_reg.org_id <> v_sale.org_id then  -- missing till passes",
  "-- missing till passes")

m("another company's till takes the bill", F,
  "  if v_reg.id is null or v_reg.org_id <> v_sale.org_id then",
  "  if v_reg.id is null then  -- any company",
  "-- any company")

m("a bill already here is moved anyway", F,
  "  if v_sale.register_id = p_register then\n    return p_sale;",
  "  if false then  -- always moved\n    return p_sale;",
  "-- always moved")

m("another outlet's till takes the bill", F,
  "  if v_reg.outlet_id <> v_sale.outlet_id then",
  "  if false then  -- any outlet",
  "-- any outlet")

m("a closed drawer takes the bill", F,
  "  if v_shift is null then",
  "  if false then  -- no drawer needed",
  "-- no drawer needed")

m("the shift stays behind", F,
  "         shift_id    = v_shift,",
  "         shift_id    = s.shift_id,  -- shift left",
  "-- shift left")

m("where it started is rewritten every time", F,
  "           coalesce(s.opened_on_register_id, s.register_id),",
  "           s.register_id,  -- last stop",
  "-- last stop")

m("the bill is not returned", F,
  "  return p_sale;\nend;",
  "  return null;  -- nothing back\nend;",
  "-- nothing back")

m("CONTROL", F,
  "  select * into v_reg from public.pos_registers where id = p_register;",
  "  select * into v_reg from public.pos_registers where id = p_register;  -- control",
  "-- control")
