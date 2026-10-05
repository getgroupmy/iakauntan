# Mutants for app.annual_tax -- progressive tax on annual chargeable
# income. calc_pcb leans on it TWICE, so every PCB figure on every
# payslip comes through here.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0029_hrms_statutory_functions.sql \
#       supabase/tests/statutory.sql \
#       supabase/tests/mutants/annual_tax.py
#
# RESULT, 5 October: 10 mutants, all accounted for.
#
#   statutory.sql   kills 8 -- both rebate rules and its threshold, band
#                   selection, the cumulative tax of lower bands, the
#                   marginal rate's base, and the floor at zero
#   tax_bands.sql   kills the 9th: "sen in the chargeable income are
#                   ignored" catches floor() becoming ceil(). Every call
#                   in statutory.sql is whole ringgit, so that file
#                   cannot see it
#   EQUIVALENT      the 10th. `if p_chargeable <= 0` weakened to `< 0`
#                   returns 0 either way -- the lowest band starts at
#                   0.00 and `greatest(..., 0)` floors the result.
#                   PROVED by applying the mutant and calling the
#                   function, not by reading it. There is no assertion to
#                   write; the note is in statutory.sql beside the
#                   "tax on 5,000" check.

m("the small-income rebate given to everybody",
  "annual_tax",
  "  if p_chargeable <= 35000 then",
  "  if p_chargeable <= 350000 then",
  "if p_chargeable <= 350000 then")

m("the small-income rebate removed",
  "annual_tax",
  "    v_tax := v_tax - 400;",
  "    v_tax := v_tax;  -- rebate dropped",
  "-- rebate dropped")

m("the rebate is ten times too big",
  "annual_tax",
  "    v_tax := v_tax - 400;\n  end if;",
  "    v_tax := v_tax - 4000;\n  end if;",
  "v_tax := v_tax - 4000;")

m("the lowest band wins instead of the one the income reaches",
  "annual_tax",
  "   order by b.chargeable_from desc\n   limit 1;",
  "   order by b.chargeable_from asc\n   limit 1;",
  "order by b.chargeable_from asc")

m("the tax on the bands below is dropped",
  "annual_tax",
  "  v_tax := v_b.cumulative_tax\n         + (floor(p_chargeable)",
  "  v_tax := 0\n         + (floor(p_chargeable)",
  "v_tax := 0\n         + (floor(p_chargeable)")

m("the marginal rate charged on the whole income, not the excess",
  "annual_tax",
  "         + (floor(p_chargeable) - floor(v_b.chargeable_from))"
  " * v_b.rate_percent / 100;",
  "         + (floor(p_chargeable)) * v_b.rate_percent / 100;",
  "+ (floor(p_chargeable)) * v_b.rate_percent / 100;")

m("sen rounded UP into the chargeable income instead of ignored",
  "annual_tax",
  "         + (floor(p_chargeable) - floor(v_b.chargeable_from))",
  "         + (ceil(p_chargeable) - floor(v_b.chargeable_from))",
  "+ (ceil(p_chargeable)")

m("a negative tax is handed back as a refund",
  "annual_tax",
  "  return greatest(round(v_tax, 2), 0);",
  "  return round(v_tax, 2);  -- floor at zero dropped",
  "-- floor at zero dropped")

m("a nil chargeable income is taxed, the guard losing its equals",
  "annual_tax",
  "  if p_chargeable <= 0 then return 0; end if;",
  "  if p_chargeable < 0 then return 0; end if;",
  "if p_chargeable < 0 then return 0; end if;")

m("CONTROL -- a comment inside the function block",
  "annual_tax",
  "begin\n  if p_chargeable <= 0 then",
  "begin\n  -- CONTROL: this line cannot change a number.\n"
  "  if p_chargeable <= 0 then",
  "-- CONTROL: this line cannot change a number.")
