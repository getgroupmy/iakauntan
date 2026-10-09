# Mutants for public.reopen_opportunity (0373) -- see
# `mutants/close_opportunity.py`.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0373_a_deal_died_and_nobody_asked_why.sql \
#       supabase/tests/win_loss.sql \
#       supabase/tests/mutants/reopen_opportunity.py
#
# RESULT: 9 mutants and a control, all killed by `win_loss.sql`; six
# before its block: nothing reopened into another pipeline's stage, and
# no refusal but "already open" was asked.

m("a deal that does not exist is not said so",
  "reopen_opportunity",
  "  if v_o.id is null then\n    raise exception 'No such opportunity.'",
  "  if false then  -- no such deal\n    raise exception 'No such opportunity.'",
  "-- no such deal")

m("anybody reopens a deal",
  "reopen_opportunity",
  "  if not app.can_write(v_o.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("an open deal is reopened",
  "reopen_opportunity",
  "  if v_o.status = 'open' then",
  "  if false then  -- already open",
  "-- already open")

m("a stage asked for is ignored",
  "reopen_opportunity",
  "   where s.id = p_stage and s.pipeline_id = v_o.pipeline_id\n     and s.stage_type = 'open';",
  "   where false;  -- asked stage ignored\n",
  "-- asked stage ignored")

m("a stage in another pipeline is taken",
  "reopen_opportunity",
  "   where s.id = p_stage and s.pipeline_id = v_o.pipeline_id\n     and s.stage_type = 'open';",
  "   where s.id = p_stage\n     and s.stage_type = 'open';  -- any pipeline",
  "-- any pipeline")

m("a closing stage is taken to reopen into",
  "reopen_opportunity",
  "   where s.id = p_stage and s.pipeline_id = v_o.pipeline_id\n     and s.stage_type = 'open';",
  "   where s.id = p_stage and s.pipeline_id = v_o.pipeline_id;  -- any stage\n",
  "-- any stage")

m("the last open stage is the fallback",
  "reopen_opportunity",
  "     order by s.sort_order limit 1;",
  "     order by s.sort_order desc limit 1;  -- last open",
  "-- last open")

m("the close date stays",
  "reopen_opportunity",
  "    actual_close_date = null,",
  "    actual_close_date = actual_close_date,  -- date kept",
  "-- date kept")

m("the lost reason stays",
  "reopen_opportunity",
  "    lost_reason       = null,",
  "    lost_reason       = lost_reason,  -- reason kept",
  "-- reason kept")

m("CONTROL: a comment inside the block",
  "reopen_opportunity",
  "  if v_o.status = 'open' then",
  "  if v_o.status = 'open' then  -- (control)",
  "(control)")
