# Mutants for Forms B and P (0666): app.individual_tax_on -- the
# resident individual's scale -- and public.tax_computation_individual:
# business income plus other income, approved donations, reliefs, the
# s.6A rebate, zakat, s.110 credits and instalments to the tax payable.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0666_three_forms_one_business_income.sql \
#       supabase/tests/tax_forms_b_and_p.sql \
#       supabase/tests/mutants/tax_computation_individual.py

#
# RESULT, 6 October: 20 mutants, ALL 20 KILLED, control alive. 13 died
# against the files as they were (tax_forms_b_and_p.sql,
# tax_stack_end_to_end.sql). Seven needed assertions:
#
#   - THE SCALE LOOKUP, four of them: the PCB body, started by the day,
#     not yet ended, the newest of those. The seeded data has ONE PCB
#     schedule with brackets, so every rule picked the same rows. A new
#     block adds competing schedules -- older and still in force, newer
#     and already ended, not yet started, another body's -- each at 90%,
#     inside the file's transaction, and asserts the tax on 104,500
#     does not move. The fixture trap, in reference data.
#   - nil chargeable income short-circuits even with no scale in force
#   - the RM400 rebate stops at the tax: every case had a tax larger
#     than the rebate, so paying the full 400 on a tax of 20 was unseen
#   - CP500 instalments come off the tax payable

m("a chargeable income of nil is put through the scale",
  "individual_tax_on",
  "  if p_chargeable is null or p_chargeable <= 0 then",
  "  if p_chargeable is null then  -- nil not short-circuited",
  "-- nil not short-circuited")

m("the scale is read from a schedule that has ended",
  "individual_tax_on",
  "     and (s.effective_to is null or s.effective_to > p_on)",
  "     and true  -- expiry ignored",
  "-- expiry ignored")

m("the scale is read from a schedule not yet in force",
  "individual_tax_on",
  "     and s.effective_from <= p_on\n",
  "     -- start ignored\n",
  "-- start ignored")

m("the PCB body is not checked, so any schedule's brackets will do",
  "individual_tax_on",
  "   where s.body = 'pcb'\n",
  "   where true  -- body ignored\n",
  "-- body ignored")

m("the LOWEST bracket is used rather than the one the income reaches",
  "individual_tax_on",
  "   order by s.effective_from desc, tb.chargeable_from desc",
  "   order by s.effective_from desc, tb.chargeable_from asc  -- lowest bracket",
  "-- lowest bracket")

m("the OLDEST schedule in force is used",
  "individual_tax_on",
  "   order by s.effective_from desc, tb.chargeable_from desc",
  "   order by s.effective_from asc, tb.chargeable_from desc  -- oldest schedule",
  "-- oldest schedule")

m("the bracket's cumulative tax is dropped",
  "individual_tax_on",
  "    b.cumulative_tax\n    + (p_chargeable",
  "    0  -- cumulative dropped\n    + (p_chargeable",
  "-- cumulative dropped")

m("the whole income is taxed at the top rate",
  "individual_tax_on",
  "    + (p_chargeable - floor(b.chargeable_from)) * b.rate_percent / 100,",
  "    + p_chargeable * b.rate_percent / 100,  -- marginal dropped",
  "-- marginal dropped")

m("other income is left out of the aggregate",
  "tax_computation_individual",
  "  v_agg := round(b.statutory_income + v_other, 2);",
  "  v_agg := round(b.statutory_income, 2);  -- other income dropped",
  "-- other income dropped")

m("other income is read from every computation",
  "tax_computation_individual",
  "   where oi.computation_id = p_computation_id;",
  "   where true;  -- other income unscoped",
  "-- other income unscoped")

m("donations are allowed beyond the aggregate income",
  "tax_computation_individual",
  "  v_don := least(c.approved_donations, v_agg);",
  "  v_don := c.approved_donations;  -- donation cap dropped",
  "-- donation cap dropped")

m("donations are not deducted",
  "tax_computation_individual",
  "  v_total := round(v_agg - v_don, 2);",
  "  v_total := round(v_agg, 2);  -- donations dropped",
  "-- donations dropped")

m("reliefs are not deducted",
  "tax_computation_individual",
  "  v_ci := round(greatest(v_total - v_rel, 0), 2);",
  "  v_ci := round(greatest(v_total, 0), 2);  -- reliefs dropped",
  "-- reliefs dropped")

m("reliefs larger than the income leave a NEGATIVE chargeable income",
  "tax_computation_individual",
  "  v_ci := round(greatest(v_total - v_rel, 0), 2);",
  "  v_ci := round(v_total - v_rel, 2);  -- floor dropped",
  "-- floor dropped")

m("the rebate is given above the threshold",
  "tax_computation_individual",
  "  if v_thr is not null and v_ci > 0 and v_ci <= v_thr.threshold then",
  "  if v_thr is not null and v_ci > 0 then  -- threshold dropped",
  "-- threshold dropped")

m("the rebate is not given AT the threshold",
  "tax_computation_individual",
  "  if v_thr is not null and v_ci > 0 and v_ci <= v_thr.threshold then",
  "  if v_thr is not null and v_ci > 0 and v_ci < v_thr.threshold then  -- strict",
  "-- strict")

m("the rebate exceeds the tax",
  "tax_computation_individual",
  "    v_reb := least(v_thr.amount, v_tax);",
  "    v_reb := v_thr.amount;  -- rebate cap dropped",
  "-- rebate cap dropped")

m("zakat is rebated against tax the rebate already removed",
  "tax_computation_individual",
  "  v_zakat := least(c.zakat_paid, greatest(v_tax - v_reb, 0));",
  "  v_zakat := least(c.zakat_paid, v_tax);  -- rebate ignored in zakat cap",
  "-- rebate ignored in zakat cap")

m("instalments paid are not credited",
  "tax_computation_individual",
  "    round(v_tax - v_reb - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);",
  "    round(v_tax - v_reb - v_zakat - c.s110_tax_deducted, 2);  -- instalments dropped",
  "-- instalments dropped")

m("the rebate is not taken off the tax payable",
  "tax_computation_individual",
  "    round(v_tax - v_reb - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);",
  "    round(v_tax - v_zakat - c.s110_tax_deducted - c.cp204_paid, 2);  -- rebate dropped",
  "-- rebate dropped")

m("CONTROL -- a comment inside the function block",
  "tax_computation_individual",
  "  v_agg := round(b.statutory_income + v_other, 2);",
  "  v_agg := round(b.statutory_income + v_other, 2);  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
