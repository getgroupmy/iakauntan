# Mutants for public.platform_publish_statutory_schedule (0404) -- an
# EPF, SOCSO, EIS or PCB table every company's payroll is computed from:
# platform administrators only, never empty or unnamed, closing the
# table it supersedes the day before, never rewriting one payslips were
# calculated on, and never published with a hole between its bands.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0404_the_wage_that_fell_between_two_bands.sql \
#       supabase/tests/statutory_schedules.sql \
#       supabase/tests/mutants/platform_publish_statutory_schedule.py
#
# RESULT: 16 mutants and a control. `statutory_schedules.sql` kills 14
# after its "`platform_publish_statutory_schedule`, rule by rule" block,
# which added five: an empty table, a nameless one, closing only tables
# that started earlier, a table closed earlier keeping its date, and an
# explicit null not being a claim of verification. The other two --
# anybody publishing, and any rounding mode -- are killed by
# `hr_reference.sql` (the rounding one by the table's own check
# constraint as well). The four payslip-guard mutants die by the foreign
# key from `payslips` before the function's own message: a table
# payslips used is protected twice.

m("anybody publishes a statutory table",
  "platform_publish_statutory_schedule",
  "  if not app.is_platform_admin() then",
  "  if false then  -- anybody",
  "-- anybody")

m("a table with no rates is published",
  "platform_publish_statutory_schedule",
  "  if jsonb_typeof(p_rates) <> 'array' or jsonb_array_length(p_rates) = 0 then",
  "  if false then  -- no rates",
  "-- no rates")

m("a table with no name is published",
  "platform_publish_statutory_schedule",
  "  if coalesce(btrim(p_name), '') = '' then",
  "  if false then  -- nameless",
  "-- nameless")

m("any rounding mode is taken",
  "platform_publish_statutory_schedule",
  "  if p_result_rounding not in ('nearest_cent', 'nearest_5sen', 'up_ringgit') then",
  "  if false then  -- any rounding",
  "-- any rounding")

m("the superseded table runs on through the new one's first day",
  "platform_publish_statutory_schedule",
  "     set effective_to = p_effective_from - 1",
  "     set effective_to = p_effective_from  -- overlap",
  "-- overlap")

m("the superseded table is never closed",
  "platform_publish_statutory_schedule",
  "     set effective_to = p_effective_from - 1",
  "     set effective_to = effective_to  -- left open",
  "-- left open")

m("a later table is closed too",
  "platform_publish_statutory_schedule",
  "     and effective_from < p_effective_from\n",
  "     and true  -- any start\n",
  "-- any start")

m("a table already closed before the new one is closed again",
  "platform_publish_statutory_schedule",
  "     and (effective_to is null or effective_to >= p_effective_from);",
  "     ;  -- reclosed",
  "-- reclosed")

m("a table payslips used is rewritten",
  "platform_publish_statutory_schedule",
  "    if exists (select 1 from public.payslips ps",
  "    if false and exists (select 1 from public.payslips ps  -- rewritten",
  "-- rewritten")

m("SOCSO payslips do not hold their table",
  "platform_publish_statutory_schedule",
  "                   or ps.socso_schedule_id = v_prior",
  "                   or false  -- socso free",
  "-- socso free")

m("EIS payslips do not hold their table",
  "platform_publish_statutory_schedule",
  "                   or ps.eis_schedule_id   = v_prior",
  "                   or false  -- eis free",
  "-- eis free")

m("PCB payslips do not hold their table",
  "platform_publish_statutory_schedule",
  "                   or ps.pcb_schedule_id   = v_prior) then",
  "                   or false) then  -- pcb free",
  "-- pcb free")

m("an unverified table is published as verified",
  "platform_publish_statutory_schedule",
  "          nullif(btrim(p_source), ''), coalesce(p_is_verified, false),",
  "          nullif(btrim(p_source), ''), coalesce(p_is_verified, true),  -- verified",
  "-- verified")

m("a band with no lower bound starts at one ringgit",
  "platform_publish_statutory_schedule",
  "      coalesce((v_rate ->> 'wage_from')::numeric, 0),",
  "      coalesce((v_rate ->> 'wage_from')::numeric, 1),  -- from one",
  "-- from one")

m("a band with no category is filed under another",
  "platform_publish_statutory_schedule",
  "      coalesce(nullif(v_rate ->> 'category', ''), 'default'),",
  "      coalesce(nullif(v_rate ->> 'category', ''), 'other'),  -- other",
  "-- other")

m("a table with a hole in it is published",
  "platform_publish_statutory_schedule",
  "  perform app.assert_statutory_bands(v_id);",
  "  perform 1;  -- holes",
  "-- holes")

m("CONTROL: a comment inside the block",
  "platform_publish_statutory_schedule",
  "  if coalesce(btrim(p_name), '') = '' then",
  "  if coalesce(btrim(p_name), '') = '' then  -- (control)",
  "(control)")
