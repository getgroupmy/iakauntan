# Mutants for public.raise_strata_charges (0585) -- a period's
# maintenance charges and sinking fund raised for a strata scheme: by
# somebody who may post, in a company with the module, never twice over
# the same days, at the rate in force, to each parcel's owner, posted,
# and the run carrying what it raised.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0585_the_way_back_from_a_billing_run.sql \
#       supabase/tests/property.sql \
#       supabase/tests/mutants/raise_strata_charges.py
#
# RESULT: 19 mutants and a control, all killed by `property.sql`.
# Thirteen only after its "`raise_strata_charges`, rule by rule" block:
# the strata side had NO assertion that a period is not raised twice --
# the same quarter, an overlapping one, or a voided one raised again --
# though the rent side had asserted all three since `0584`. Nor the
# rate in force when the period starts (a quarter straddling an AGM's
# new rate), the sinking fund's own account, the due date by default,
# the parcel's name, an unowned parcel, an empty scheme, a viewer, or a
# company without the module. The lock is not mutated, as for rent.

m("a scheme that does not exist is not said so",
  "raise_strata_charges",
  "  if not found then",
  "  if false then  -- no such scheme",
  "-- no such scheme")

m("anybody raises charges",
  "raise_strata_charges",
  "  if not app.can_post(s.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a company without the module raises charges",
  "raise_strata_charges",
  "  if not app.has_module(s.org_id, 'property_strata') then",
  "  if false then  -- no module",
  "-- no module")

m("only an identical period is a clash",
  "raise_strata_charges",
  "      && daterange(p_period_from, p_period_to, '[]')",
  "      = daterange(p_period_from, p_period_to, '[]')  -- identical only",
  "-- identical only")

m("a voided run still blocks the period",
  "raise_strata_charges",
  "     and cr.voided_at is null",
  "     and true  -- voided counts",
  "-- voided counts")

m("no clash is ever refused",
  "raise_strata_charges",
  "  if v_clash.id is not null then",
  "  if false then  -- billed twice",
  "-- billed twice")

m("charges are raised with no rate in force",
  "raise_strata_charges",
  "  if r.id is null then",
  "  if false then  -- no rate",
  "-- no rate")

m("the rate is the one in force at the end of the period",
  "raise_strata_charges",
  "  r := app.strata_rate_on(p_scheme_id, p_period_from);",
  "  r := app.strata_rate_on(p_scheme_id, p_period_to);  -- rate late",
  "-- rate late")

m("the due date asked for is ignored",
  "raise_strata_charges",
  "  v_due := coalesce(p_due_date, p_period_from);",
  "  v_due := p_period_from;  -- due ignored",
  "-- due ignored")

m("with no due date, charges fall due at the end of the period",
  "raise_strata_charges",
  "  v_due := coalesce(p_due_date, p_period_from);",
  "  v_due := coalesce(p_due_date, p_period_to);  -- due late",
  "-- due late")

m("the sinking fund is credited to maintenance",
  "raise_strata_charges",
  "  v_sink_ac := app.property_income_account(s.org_id, 'sinking');",
  "  v_sink_ac := app.property_income_account(s.org_id, 'maintenance');  -- one pot",
  "-- one pot")

m("a parcel with no owner is skipped in silence",
  "raise_strata_charges",
  "    if v_line.owner_contact_id is null then",
  "    if false then  -- no owner",
  "-- no owner")

m("the invoice says nothing of the parcel",
  "raise_strata_charges",
  "      format('Maintenance charges — %s', v_line.unit_no),",
  "      'Maintenance charges',  -- no parcel",
  "-- no parcel")

m("the run line records no share units",
  "raise_strata_charges",
  "    values (s.org_id, v_run, v_line.unit_id, v_line.share_units,",
  "    values (s.org_id, v_run, v_line.unit_id, 0,  -- no units",
  "-- no units")

m("the invoices are left drafts",
  "raise_strata_charges",
  "    perform app.post_sales_document_internal(v_invoice);",
  "    perform 1;  -- unposted",
  "-- unposted")

m("a scheme with nothing chargeable makes an empty run",
  "raise_strata_charges",
  "  if v_parcels = 0 then",
  "  if false then  -- empty run",
  "-- empty run")

m("the run's sinking fund is the last parcel's",
  "raise_strata_charges",
  "    v_sink := v_sink + v_line.sinking_amount;",
  "    v_sink := v_line.sinking_amount;  -- last only",
  "-- last only")

m("the run's charges are the last parcel's",
  "raise_strata_charges",
  "    v_maint := v_maint + v_line.maintenance_amount;",
  "    v_maint := v_line.maintenance_amount;  -- last only",
  "-- last only")

m("the run does not say how many parcels",
  "raise_strata_charges",
  "     set parcels = v_parcels, total_maintenance = v_maint, total_sinking = v_sink",
  "     set parcels = 0, total_maintenance = v_maint, total_sinking = v_sink  -- uncounted",
  "-- uncounted")

m("CONTROL: a comment inside the block",
  "raise_strata_charges",
  "  if v_parcels = 0 then",
  "  if v_parcels = 0 then  -- (control)",
  "(control)")
