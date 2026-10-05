# Mutants for app.calc_pcb -- monthly tax deduction under the PCB Rules.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0530_a_disabled_child_in_higher_education.sql \
#       supabase/tests/statutory.sql \
#       supabase/tests/mutants/calc_pcb.py
#
# NOTE THE MIGRATION. `0530` is the current definition, NOT `0446`, whose
# name makes it look like the last word on this function. Naming `0446`
# downgrades the live function; `mutate_sql.py` now refuses it, and the
# story is in docs/handoff.md.
#
# RESULT, 5 October: 10 of 10 killed by `statutory.sql` ALONE, control
# surviving. Unlike calc_statutory, this one needs no second file.

m("the bonus is annualised too, taxing it every month (the 0446 defect)",
  "calc_pcb",
  "               + p_taxable_this_month * v_n;",
  "               + (p_taxable_this_month + v_add) * v_n;",
  "(p_taxable_this_month + v_add) * v_n;")

m("the EPF relief cap removed, so a big contributor over-reliefs",
  "calc_pcb",
  "  v_relief := v_relief + least(v_epf_used, v_epf_cap);",
  "  v_relief := v_relief + v_epf_used;  -- cap dropped",
  "-- cap dropped")

m("the SOCSO/EIS relief cap removed",
  "calc_pcb",
  "  v_relief := v_relief + least(\n"
  "    v_ytd_socso + p_socso_eis_this_month * v_n, v_soc_cap);",
  "  v_relief := v_relief +\n"
  "    (v_ytd_socso + p_socso_eis_this_month * v_n);  -- soc cap dropped",
  "-- soc cap dropped")

m("zakat paid is not deducted from the year's tax",
  "calc_pcb",
  "  v_tax := greatest(v_tax - v_zakat_year, 0);",
  "  v_tax := greatest(v_tax, 0);  -- zakat ignored",
  "-- zakat ignored")

m("a disabled child gets the ordinary child relief",
  "calc_pcb",
  "        when d.is_disabled then 6000",
  "        when d.is_disabled then 2000",
  "when d.is_disabled then 2000")

m("the child's relief claim percentage is ignored",
  "calc_pcb",
  "      end * d.relief_claim_percent / 100), 0)",
  "      end * 1), 0)  -- claim percent ignored",
  "-- claim percent ignored")

m("the remainder is spread over twelve months, not the months left",
  "calc_pcb",
  "    greatest(app.round_statutory(v_remaining / v_n, 'nearest_5sen'), 0)",
  "    greatest(app.round_statutory(v_remaining / 12, 'nearest_5sen'), 0)",
  "v_remaining / 12")

m("the months remaining in the year is always twelve",
  "calc_pcb",
  "  v_n := greatest(12 - v_month + 1, 1);",
  "  v_n := 12;  -- months-left dropped",
  "-- months-left dropped")

m("PCB already deducted this year is not credited",
  "calc_pcb",
  "  v_remaining := v_tax - v_ytd_pcb - coalesce(v_open.pcb_paid, 0);",
  "  v_remaining := v_tax;  -- paid-to-date ignored",
  "-- paid-to-date ignored")

m("spouse relief given even when the spouse is working",
  "calc_pcb",
  "  if v_emp.marital_status = 'married' and not v_emp.spouse_is_working then",
  "  if v_emp.marital_status = 'married' then  -- spouse test dropped",
  "-- spouse test dropped")

m("CONTROL -- a comment inside the function block",
  "calc_pcb",
  "begin\n  select * into v_emp from public.employees e where e.id = p_employee_id;",
  "begin\n  -- CONTROL: this line cannot change a number.\n"
  "  select * into v_emp from public.employees e where e.id = p_employee_id;",
  "-- CONTROL: this line cannot change a number.")
