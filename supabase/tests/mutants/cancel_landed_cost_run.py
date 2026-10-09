# Mutants for public.cancel_landed_cost_run (0271) -- a landed cost run
# withdrawn before it revalues anything: by somebody who may write
# inventory, only while it is a draft, and that run alone.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0271_the_freight_is_part_of_what_it_cost.sql \
#       supabase/tests/landed_cost.sql \
#       supabase/tests/mutants/cancel_landed_cost_run.py
#
# RESULT: 6 mutants and a control, all killed by `landed_cost.sql`.
# "Every draft run of the company" only after a second draft stood
# beside the one cancelled.

m("a run that does not exist is not said so",
  "cancel_landed_cost_run",
  "  if v_run.id is null then\n    raise exception 'No such landed cost run.'",
  "  if false then  -- no such run\n    raise exception 'No such landed cost run.'",
  "-- no such run")

m("anybody cancels a run",
  "cancel_landed_cost_run",
  "  if not app.can_write_module(v_run.org_id, 'inventory') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a run that has revalued stock is cancelled",
  "cancel_landed_cost_run",
  "  if v_run.status <> 'draft' then",
  "  if false then  -- any status",
  "-- any status")

m("the run is not marked cancelled",
  "cancel_landed_cost_run",
  "  update public.landed_cost_runs set status = 'cancelled' where id = p_run;",
  "  perform 1;  -- still draft",
  "-- still draft")

m("every draft run of the company is cancelled",
  "cancel_landed_cost_run",
  "  update public.landed_cost_runs set status = 'cancelled' where id = p_run;",
  "  update public.landed_cost_runs set status = 'cancelled' where org_id = v_run.org_id and status = 'draft';  -- every draft",
  "-- every draft")

m("the answer says it was not cancelled",
  "cancel_landed_cost_run",
  "  return true;\nend;",
  "  return false;  -- says no\nend;",
  "-- says no")

m("CONTROL: a comment inside the block",
  "cancel_landed_cost_run",
  "  if v_run.status <> 'draft' then",
  "  if v_run.status <> 'draft' then  -- (control)",
  "(control)")
