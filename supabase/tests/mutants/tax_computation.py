# Mutants for the Form C computation (0666): app.tax_business_income --
# accounts profit to statutory income, through add-backs, deductions,
# balancing charges and capital allowances -- and public.tax_computation
# on top of it: losses brought forward, the SME test and band, zakat,
# s.110 credits and CP204 instalments to the tax payable.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0666_three_forms_one_business_income.sql \
#       supabase/tests/tax_computation.sql \
#       supabase/tests/mutants/tax_computation.py


#
# RESULT, 6 October: 21 mutants, ALL 21 KILLED, control alive, across
# tax_computation.sql, tax_stack_end_to_end.sql, tax_estimates.sql and
# tax_forms_b_and_p.sql. One needed an assertion: unabsorbed capital
# allowances carried forward were computed as "this year's allowances
# less what was used", dropping whatever was brought forward unused --
# negative in a year with none of its own. tax_computation.sql never
# read ca_carried_forward in the block with allowances brought forward;
# it now does, with b/f both inside and beyond the income.

m("expenses ADD to the profit",
  "tax_business_income",
  "                           then pl.amount else -pl.amount end), 0)",
  "                           then pl.amount else pl.amount end), 0)  -- expenses added",
  "-- expenses added")

m("add-backs and deductions are swapped",
  "tax_business_income",
  "  select coalesce(sum(case when l.kind = 'add_back' then l.amount end), 0),\n"
  "         coalesce(sum(case when l.kind = 'deduct'   then l.amount end), 0)",
  "  select coalesce(sum(case when l.kind = 'deduct' then l.amount end), 0),  -- swapped\n"
  "         coalesce(sum(case when l.kind = 'add_back'   then l.amount end), 0)",
  "-- swapped")

m("a balancing allowance is not claimed",
  "tax_business_income",
  "  select coalesce(sum(s.claimed + s.balancing_allowance), 0),",
  "  select coalesce(sum(s.claimed), 0),  -- balancing allowance dropped",
  "-- balancing allowance dropped")

m("a balancing charge is not taxed",
  "tax_business_income",
  "  v_adj := round(v_pbt + v_add + v_bc - v_ded, 2);",
  "  v_adj := round(v_pbt + v_add - v_ded, 2);  -- balancing charge dropped",
  "-- balancing charge dropped")

m("deductions are added instead of taken off",
  "tax_business_income",
  "  v_adj := round(v_pbt + v_add + v_bc - v_ded, 2);",
  "  v_adj := round(v_pbt + v_add + v_bc + v_ded, 2);  -- deductions added",
  "-- deductions added")

m("an adjusted loss is not recorded",
  "tax_business_income",
  "    v_loss := -v_adj;",
  "    v_loss := 0;  -- loss forgotten",
  "-- loss forgotten")

m("an adjusted loss is left negative instead of nil",
  "tax_business_income",
  "    v_loss := -v_adj;\n    v_adj  := 0;",
  "    v_loss := -v_adj;  -- adjusted left negative",
  "-- adjusted left negative")

m("capital allowances brought forward are ignored",
  "tax_business_income",
  "  v_ca_av  := round(v_ca_cur + c.capital_allowance_bf, 2);",
  "  v_ca_av  := round(v_ca_cur, 2);  -- CA b/f dropped",
  "-- CA b/f dropped")

m("capital allowances are used beyond the adjusted income",
  "tax_business_income",
  "  v_ca_use := least(v_ca_av, v_adj);",
  "  v_ca_use := v_ca_av;  -- CA cap dropped",
  "-- CA cap dropped")

m("unused allowances carried forward lose what was brought forward",
  "tax_business_income",
  "    round(v_ca_use, 2), round(v_ca_av - v_ca_use, 2),",
  "    round(v_ca_use, 2), round(v_ca_cur - v_ca_use, 2),  -- c/f from current only",
  "-- c/f from current only")

m("losses brought forward are used beyond the statutory income",
  "tax_computation",
  "  v_lu := least(c.loss_bf, b.statutory_income);",
  "  v_lu := c.loss_bf;  -- loss cap dropped",
  "-- loss cap dropped")

m("losses brought forward reduce nothing",
  "tax_computation",
  "  v_ci := round(b.statutory_income - v_lu, 2);",
  "  v_ci := round(b.statutory_income, 2);  -- loss relief dropped",
  "-- loss relief dropped")

m("a company whose capital and turnover are unknown is treated as an SME",
  "tax_computation",
  "  v_known := c.paid_up_capital is not null\n"
  "             and c.gross_business_income is not null;",
  "  v_known := true;  -- unknown treated as known",
  "-- unknown treated as known")

m("a company AT the capital limit is not an SME",
  "tax_computation",
  "           and c.paid_up_capital <= r.sme_capital_limit",
  "           and c.paid_up_capital < r.sme_capital_limit  -- limit exclusive",
  "-- limit exclusive")

m("the turnover limit is not applied",
  "tax_computation",
  "           and c.gross_business_income <= r.sme_turnover_limit;",
  "           ;  -- turnover test dropped",
  "-- turnover test dropped")

m("an SME pays the SME rate on all of its income",
  "tax_computation",
  "    v_tax := round(least(v_ci, r.sme_band_limit) * r.sme_rate, 2)",
  "    v_tax := round(v_ci * r.sme_rate, 2)  -- band dropped",
  "-- band dropped")

m("an SME's income above the band is not taxed",
  "tax_computation",
  "             + round(greatest(v_ci - r.sme_band_limit, 0)\n"
  "                       * r.standard_rate, 2);",
  "             + 0;  -- above-band income untaxed",
  "-- above-band income untaxed")

m("zakat rebates more than the tax",
  "tax_computation",
  "  v_zakat := least(c.zakat_paid, v_tax);",
  "  v_zakat := c.zakat_paid;  -- zakat cap dropped",
  "-- zakat cap dropped")

m("this year's adjusted loss is not carried forward",
  "tax_computation",
  "    round(c.loss_bf - v_lu + b.adjusted_loss, 2),",
  "    round(c.loss_bf - v_lu, 2),  -- current loss not carried",
  "-- current loss not carried")

m("CP204 instalments paid are not credited",
  "tax_computation",
  "    round(v_tax - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);",
  "    round(v_tax - v_zakat - c.s110_tax_deducted, 2);  -- CP204 dropped",
  "-- CP204 dropped")

m("s.110 tax already deducted is not credited",
  "tax_computation",
  "    round(v_tax - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);",
  "    round(v_tax - v_zakat - c.cp204_paid, 2);  -- s110 dropped",
  "-- s110 dropped")

m("CONTROL -- a comment inside the function block",
  "tax_computation",
  "  v_zakat := least(c.zakat_paid, v_tax);",
  "  v_zakat := least(c.zakat_paid, v_tax);  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
