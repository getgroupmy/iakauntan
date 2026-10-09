# Mutants for public.raise_rent_invoices (0585) -- a month's rent raised
# for a site: by somebody who may post, in a company with the module,
# never twice over the same days, each tenancy invoiced, posted, dated
# and due as asked, and the run carrying what it raised.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0585_the_way_back_from_a_billing_run.sql \
#       supabase/tests/property.sql \
#       supabase/tests/mutants/raise_rent_invoices.py
#
# RESULT: 16 mutants and a control, all killed by `property.sql`. Ten
# only after its "`raise_rent_invoices`, rule by rule" block. Three of
# those were SHADOWED rather than missing: `rent_preview` refuses a
# stranger and a company without the module as well, as "Not your
# site", so the older assertions passed whichever guard spoke. A viewer
# is what separates them -- a member, whom `rent_preview` lets through,
# who may not post. The lock is not mutated: two sessions are not
# something one transaction can stage.

m("a site that does not exist is not said so",
  "raise_rent_invoices",
  "  if v_org is null then",
  "  if false then  -- no such site",
  "-- no such site")

m("anybody raises rent",
  "raise_rent_invoices",
  "  if not app.can_post(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a company without the module raises rent",
  "raise_rent_invoices",
  "  if not app.has_module(v_org, 'property_nonstrata') then",
  "  if false then  -- no module",
  "-- no module")

m("only an identical period is a clash",
  "raise_rent_invoices",
  "      && daterange(p_period_from, p_period_to, '[]')",
  "      = daterange(p_period_from, p_period_to, '[]')  -- identical only",
  "-- identical only")

m("a voided run still blocks the period",
  "raise_rent_invoices",
  "     and rr.voided_at is null",
  "     and true  -- voided counts",
  "-- voided counts")

m("no clash is ever refused",
  "raise_rent_invoices",
  "  if v_clash.id is not null then",
  "  if false then  -- billed twice",
  "-- billed twice")

m("the due date asked for is ignored",
  "raise_rent_invoices",
  "  v_due := coalesce(p_due_date, p_period_from);",
  "  v_due := p_period_from;  -- due ignored",
  "-- due ignored")

m("with no due date, rent falls due at the end of the period",
  "raise_rent_invoices",
  "  v_due := coalesce(p_due_date, p_period_from);",
  "  v_due := coalesce(p_due_date, p_period_to);  -- due late",
  "-- due late")

m("the invoice is dated the end of the period",
  "raise_rent_invoices",
  "      p_period_from, v_due, v_line.tenant_contact_id,",
  "      p_period_to, v_due, v_line.tenant_contact_id,  -- dated late",
  "-- dated late")

m("the invoice says nothing of the unit",
  "raise_rent_invoices",
  "      format('Rent — %s', v_line.unit_no),",
  "      'Rent',  -- no unit",
  "-- no unit")

m("the line does not say which days",
  "raise_rent_invoices",
  "            format('Rent for %s, %s to %s',",
  "            format('Rent for %s%s%s',  -- no days",
  "-- no days")

m("the run line records a whole month whatever was billed",
  "raise_rent_invoices",
  "    values (v_org, v_run, v_line.tenancy_id, v_line.months, v_line.amount,",
  "    values (v_org, v_run, v_line.tenancy_id, 1, v_line.amount,  -- one month",
  "-- one month")

m("the invoices are left drafts",
  "raise_rent_invoices",
  "    perform app.post_sales_document_internal(v_invoice);",
  "    perform 1;  -- unposted",
  "-- unposted")

m("a site with nobody to bill makes an empty run",
  "raise_rent_invoices",
  "  if v_count = 0 then",
  "  if false then  -- empty run",
  "-- empty run")

m("the run's total is the last tenancy's",
  "raise_rent_invoices",
  "    v_total := v_total + v_line.amount;",
  "    v_total := v_line.amount;  -- last only",
  "-- last only")

m("the run does not say how many it billed",
  "raise_rent_invoices",
  "     set tenancies = v_count, total_rent = v_total",
  "     set tenancies = 0, total_rent = v_total  -- uncounted",
  "-- uncounted")

m("CONTROL: a comment inside the block",
  "raise_rent_invoices",
  "  if v_count = 0 then",
  "  if v_count = 0 then  -- (control)",
  "(control)")
