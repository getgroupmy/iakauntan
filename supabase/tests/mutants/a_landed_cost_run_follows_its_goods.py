# Mutants for 0928 -- a landed cost run is not dated before the goods
# on any bill it spreads over arrived, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0928_a_landed_cost_run_follows_its_goods.sql \
#       supabase/tests/a_landed_cost_run_follows_its_goods.sql \
#       supabase/tests/mutants/a_landed_cost_run_follows_its_goods.py
#
# Not mutated, as equivalent: reading only the note and not the bill's
# own receipt -- a bill that receives its own goods dates their
# movement by its own date, which is the fallback; `quantity > 0` -- a
# bill's and a note's movements are receipts, returns are documents of
# their own; and the target branch's company filter, which the
# target's tenant key already holds.

A = 'landed_cost_goods_arrived'
T = 'a_landed_cost_run_follows_its_goods'

m('a bill raised from a note is not followed to the note',
  A,
  "               and m.source_id in (d.id, d.parent_id)\n",
  "               and m.source_id = d.id  -- bill only\n",
  '-- bill only')

m('a bill that received nothing is not asked',
  A,
  "           d.doc_date)\n",
  "           null::date)  -- no fallback\n",
  '-- no fallback')

m('the run may be dated the day before',
  T,
  "  if v_arrived is not null and v_run.run_date < v_arrived then\n",
  "  if v_arrived is not null and v_run.run_date < v_arrived - 1 then  -- a day early\n",
  '-- a day early')

m('the run may not be dated on the day',
  T,
  "  if v_arrived is not null and v_run.run_date < v_arrived then\n",
  "  if v_arrived is not null and v_run.run_date <= v_arrived then  -- not on the day\n",
  '-- not on the day')

m('a bill put on a run is not asked',
  T,
  "  if tg_table_name = 'landed_cost_targets' then\n",
  "  if tg_table_name = 'landed_cost_targets' then\n    return new;  -- targets free\n",
  '-- targets free')

m('a run is not asked at posting',
  T,
  "    if not (new.status = 'posted' and old.status is distinct from 'posted') then\n",
  "    if true then  -- posting free\n",
  '-- posting free')

m('at posting, the earliest of its bills is asked',
  T,
  "     order by x.arrived desc, d.doc_no\n",
  "     order by x.arrived asc, d.doc_no  -- earliest\n",
  '-- earliest')

m('the refusal is a permission error, not a rule',
  T,
  "      v_run.run_no, v_run.run_date, v_doc_no, v_arrived, v_arrived\n      using errcode = '23514';\n",
  "      v_run.run_no, v_run.run_date, v_doc_no, v_arrived, v_arrived\n      using errcode = '42501';  -- permission\n",
  '-- permission')

m('the refusal names the run date as the arrival',
  T,
  "      v_run.run_no, v_run.run_date, v_doc_no, v_arrived, v_arrived\n",
  "      v_run.run_no, v_run.run_date, v_doc_no, v_run.run_date, v_arrived  -- wrong date\n",
  '-- wrong date')

m('CONTROL: a comment inside the trigger function',
  T,
  "    -- A run: asked when it is posted.\n",
  "    -- A run: asked when it is posted. (control)\n",
  '(control)')
