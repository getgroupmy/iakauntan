# Mutants for public.file_sst_return (0455) -- an SST-02 return recorded
# as filed: by somebody who may post, only for a taxable period that has
# ended, against the company's own period boundaries, with its due date
# stamped, and a refiling replacing what was declared.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0455_two_months_and_the_month_after.sql \
#       supabase/tests/sst_taxable_period.sql \
#       supabase/tests/mutants/file_sst_return.py
#
# RESULT: 7 of 8 killed by `sst_taxable_period.sql`, control surviving.
# Two only after the refiling assertions (the figure and the reference a
# second filing replaces). The eighth, "a period is filed on its last
# day" (`>=` to `>`), is DATE-DEPENDENT rather than equivalent: it
# differs only when a period ends TODAY, and `app.today()` is `now()` in
# Kuala Lumpur, which a test cannot pin. On the last day of a period the
# existing "nor before the period has ended" picks that period and kills
# it; on every other day nothing can.

m("anybody files a return",
  "file_sst_return",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("any date is a period end",
  "file_sst_return",
  "  if v_p.period_end is null or v_p.period_end <> p_period_end then",
  "  if false then  -- any date",
  "-- any date")

m("a date inside a period is taken as its end",
  "file_sst_return",
  "  if v_p.period_end is null or v_p.period_end <> p_period_end then",
  "  if v_p.period_end is null then  -- inside",
  "-- inside")

m("a period still running is filed",
  "file_sst_return",
  "  if p_period_end >= app.today() then",
  "  if false then  -- early",
  "-- early")

m("a period is filed on its last day",
  "file_sst_return",
  "  if p_period_end >= app.today() then",
  "  if p_period_end > app.today() then  -- last day",
  "-- last day")

m("the due date is not stamped on the return",
  "file_sst_return",
  "  values (p_org_id, v_p.period_start, v_p.period_end, v_p.due_date,",
  "  values (p_org_id, v_p.period_start, v_p.period_end, null,  -- undated",
  "-- undated")

m("refiling keeps the first figure",
  "file_sst_return",
  "     set tax_declared = excluded.tax_declared,",
  "     set tax_declared = sst_returns.tax_declared,  -- first figure",
  "-- first figure")

m("refiling keeps the first reference",
  "file_sst_return",
  "         reference    = excluded.reference,",
  "         reference    = sst_returns.reference,  -- first ref",
  "-- first ref")

m("CONTROL: a comment inside the block",
  "file_sst_return",
  "  if p_period_end >= app.today() then",
  "  if p_period_end >= app.today() then  -- (control)",
  "(control)")
