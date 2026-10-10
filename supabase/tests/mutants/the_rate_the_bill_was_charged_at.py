# Mutants for 0800 -- the service charge rate kept on the bill by
# app.recalc_pos_sale, and printed from the bill by
# public.pos_receipt_text, written as a person writes it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0800_the_rate_the_bill_was_charged_at.sql \
#       supabase/tests/pos_service_charge.sql \
#       supabase/tests/mutants/the_rate_the_bill_was_charged_at.py
#
# RESULT: 5 mutants and a control, all 5 killed by
# `pos_service_charge.sql`. The backfill of bills charged before `0800`
# runs once, at apply time, on rows the suite does not have; production
# held none.

R = "recalc_pos_sale"
P = "pos_receipt_text"

m("the bill keeps no rate", R,
  "         service_charge_percent = coalesce(v_svc_pct, 0),",
  "         service_charge_percent = 0,  -- no rate",
  "-- no rate")
m("the receipt prints the outlet's rate today", P,
  "    v_pct := nullif(v_sale.service_charge_percent, 0);",
  "    select o.service_charge_percent into v_pct from public.pos_outlets o where o.id = v_sale.outlet_id;  -- outlet's",
  "-- outlet's")
m("the point is left behind", P,
  "        || coalesce(' ' || rtrim(to_char(v_pct, 'FM990.99'), '.') || '%', ''),",
  "        || coalesce(' ' || trim(to_char(v_pct, 'FM990.99')) || '%', ''),  -- point kept",
  "-- point kept")
m("the fraction is rounded away", P,
  "        || coalesce(' ' || rtrim(to_char(v_pct, 'FM990.99'), '.') || '%', ''),",
  "        || coalesce(' ' || to_char(v_pct, 'FM990') || '%', ''),  -- whole",
  "-- whole")
m("the rate is not printed", P,
  "        || coalesce(' ' || rtrim(to_char(v_pct, 'FM990.99'), '.') || '%', ''),",
  "        || '',  -- no rate printed",
  "-- no rate printed")

m("CONTROL", P,
  "    v_pct := nullif(v_sale.service_charge_percent, 0);",
  "    v_pct := nullif(v_sale.service_charge_percent, 0);  -- control",
  "-- control")
