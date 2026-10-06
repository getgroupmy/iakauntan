# Mutants for public.report_asset_movements (0739) -- the fixed asset
# note: by category, cost and accumulated depreciation brought forward,
# additions, disposals, the period's charge, and what is carried forward.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/depreciation_schedule.sql \
#       supabase/tests/mutants/report_asset_movements.py
#
# RESULT, 6 October: 26 mutants, 25 KILLED, 1 equivalent, control
# alive, across depreciation_schedule.sql and asset_disposal_shapes.sql
# -- which between them kill every edge of the period from both sides.
# One clause lived in both: the period's charge reading runs after its
# end. Every note asked for ran to 31 December, after the last run.
# depreciation_schedule.sql's "A period that ends between two runs" now
# asks for half a year.
#
# Equivalent: accumulated depreciation brought forward on an asset bought
# inside the period. Nothing charged it before it was bought, so the
# filter changes a sum of nils. The writer.
#
# One anchor ended part way through a comment line; the pre-flight
# refused the whole file before anything ran, which is what it is for.

m("anybody reads the note",
  "report_asset_movements",
  "  if not app.can_read_ledger(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("with no start date the period starts today",
  "report_asset_movements",
  "  v_from date := coalesce(p_from, date '0001-01-01');",
  "  v_from date := coalesce(p_from, app.today());  -- starts today",
  "-- starts today")

m("an asset with no category is dropped",
  "report_asset_movements",
  "  with asset as (\n    select fa.id, coalesce(nullif(trim(fa.category), ''), 'Uncategorised')",
  "  with asset as (\n    select fa.id, nullif(trim(fa.category), '')  -- no fallback",
  "-- no fallback")

m("an asset bought on the first day was already held",
  "report_asset_movements",
  "           (fa.acquisition_date < v_from\n            and (fa.disposal_date is null or fa.disposal_date >= v_from))\n             as was_held,",
  "           (fa.acquisition_date <= v_from  -- le held\n            and (fa.disposal_date is null or fa.disposal_date >= v_from))\n             as was_held,",
  "-- le held")

m("an asset sold on the first day was not held at the start",
  "report_asset_movements",
  "           (fa.acquisition_date < v_from\n            and (fa.disposal_date is null or fa.disposal_date >= v_from))\n             as was_held,",
  "           (fa.acquisition_date < v_from\n            and (fa.disposal_date is null or fa.disposal_date > v_from))  -- gt sold\n             as was_held,",
  "-- gt sold")

m("an asset sold on the last day is still held",
  "report_asset_movements",
  "            and (fa.disposal_date is null or fa.disposal_date > p_to))\n             as still_held,",
  "            and (fa.disposal_date is null or fa.disposal_date >= p_to))  -- ge still\n             as still_held,",
  "-- ge still")

m("an asset bought on the last day is not held at the end",
  "report_asset_movements",
  "           (fa.acquisition_date <= p_to\n            and (fa.disposal_date is null or fa.disposal_date > p_to))\n             as still_held,",
  "           (fa.acquisition_date < p_to  -- lt end\n            and (fa.disposal_date is null or fa.disposal_date > p_to))\n             as still_held,",
  "-- lt end")

m("an addition on the first day is not an addition",
  "report_asset_movements",
  "           (fa.acquisition_date >= v_from and fa.acquisition_date <= p_to)\n             as came_in,",
  "           (fa.acquisition_date > v_from and fa.acquisition_date <= p_to)  -- gt in\n             as came_in,",
  "-- gt in")

m("an addition on the last day is not an addition",
  "report_asset_movements",
  "           (fa.acquisition_date >= v_from and fa.acquisition_date <= p_to)\n             as came_in,",
  "           (fa.acquisition_date >= v_from and fa.acquisition_date < p_to)  -- lt in\n             as came_in,",
  "-- lt in")

m("a disposal on the first day is not a disposal",
  "report_asset_movements",
  "            and fa.disposal_date >= v_from and fa.disposal_date <= p_to)\n             as went_out,",
  "            and fa.disposal_date > v_from and fa.disposal_date <= p_to)  -- gt out\n             as went_out,",
  "-- gt out")

m("a disposal on the last day is not a disposal",
  "report_asset_movements",
  "            and fa.disposal_date >= v_from and fa.disposal_date <= p_to)\n             as went_out,",
  "            and fa.disposal_date >= v_from and fa.disposal_date < p_to)  -- lt out\n             as went_out,",
  "-- lt out")

m("the period's charge includes runs before it",
  "report_asset_movements",
  "               and r.run_date >= v_from and r.run_date <= p_to)",
  "               and r.run_date <= p_to)  -- charge from start",
  "-- charge from start")

m("the period's charge includes runs after it",
  "report_asset_movements",
  "               and r.run_date >= v_from and r.run_date <= p_to)",
  "               and r.run_date >= v_from)  -- charge to end",
  "-- charge to end")

m("accumulated brought forward includes the first day",
  "report_asset_movements",
  "           app.accumulated_charged_at(fa.id, v_from - 1) as accum_before,",
  "           app.accumulated_charged_at(fa.id, v_from) as accum_before,  -- first day",
  "-- first day")

m("another company's assets are in the note",
  "report_asset_movements",
  "     where fa.org_id = p_org_id and fa.deleted_at is null",
  "     where fa.deleted_at is null  -- any org",
  "-- any org")

m("a deleted asset is in the note",
  "report_asset_movements",
  "     where fa.org_id = p_org_id and fa.deleted_at is null",
  "     where fa.org_id = p_org_id  -- deleted",
  "-- deleted")

m("an asset bought after the period is in it",
  "report_asset_movements",
  "       and fa.acquisition_date <= p_to\n       -- Gone before the period opened: it belongs to an earlier note,",
  "       and true  -- future asset\n       -- Gone before the period opened: it belongs to an earlier note,",
  "-- future asset")

m("an asset gone before the period is in it",
  "report_asset_movements",
  "       and (fa.disposal_date is null or fa.disposal_date >= v_from))\n  select a.category,",
  "       and true)  -- gone earlier\n  select a.category,",
  "-- gone earlier")

m("the count is of every asset, not those held at the end",
  "report_asset_movements",
  "         (count(*) filter (where a.still_held))::integer,",
  "         (count(*))::integer,  -- all counted",
  "-- all counted")

m("cost brought forward is cost carried forward",
  "report_asset_movements",
  "         coalesce(sum(a.cost) filter (where a.was_held), 0),\n         coalesce(sum(a.cost) filter (where a.came_in), 0),",
  "         coalesce(sum(a.cost) filter (where a.still_held), 0),  -- bf is cf\n         coalesce(sum(a.cost) filter (where a.came_in), 0),",
  "-- bf is cf")

m("disposals at cost are left off",
  "report_asset_movements",
  "         coalesce(sum(a.cost) filter (where a.went_out), 0),\n         coalesce(sum(a.cost) filter (where a.still_held), 0),\n         coalesce(sum(a.accum_before)",
  "         0::numeric,  -- no disposals\n         coalesce(sum(a.cost) filter (where a.still_held), 0),\n         coalesce(sum(a.accum_before)",
  "-- no disposals")

m("accumulated brought forward counts assets bought in the period",
  "report_asset_movements",
  "         coalesce(sum(a.accum_before) filter (where a.was_held), 0),",
  "         coalesce(sum(a.accum_before), 0),  -- all bf",
  "-- all bf")

m("depreciation that left with a disposal is not taken off",
  "report_asset_movements",
  "         coalesce(sum(a.accumulated_depreciation) filter (where a.went_out), 0),",
  "         0::numeric,  -- nothing left",
  "-- nothing left")

m("accumulated carried forward counts assets sold",
  "report_asset_movements",
  "         coalesce(sum(a.accum_after) filter (where a.still_held), 0),\n         coalesce(sum(a.cost)",
  "         coalesce(sum(a.accum_after), 0),  -- sold in cf\n         coalesce(sum(a.cost)",
  "-- sold in cf")

m("net book value ignores depreciation",
  "report_asset_movements",
  "           - coalesce(sum(a.accum_after) filter (where a.still_held), 0)\n    from asset a",
  "           - 0  -- nbv is cost\n    from asset a",
  "-- nbv is cost")

m("CONTROL: a comment inside the block",
  "report_asset_movements",
  "  return query\n  with asset as (",
  "  return query\n  -- CONTROL\n  with asset as (",
  "-- CONTROL")
