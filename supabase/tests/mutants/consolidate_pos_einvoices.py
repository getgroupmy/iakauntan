# Mutants for public.consolidate_pos_einvoices (0501) -- the month's
# consolidated e-Invoice for counter sales nobody claimed: by somebody
# who may file e-Invoices and write, never reopening one already
# submitted, over exactly the calendar month, totals derived from the
# items.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0501_filing_a_return_is_not_a_reading_job.sql \
#       supabase/tests/pos_einvoice_consolidation.sql \
#       supabase/tests/mutants/consolidate_pos_einvoices.py
#
# RESULT: 8 mutants and a control. `pos_einvoice_consolidation.sql`
# kills 7; "a submitted consolidation is reopened" is killed by
# `pos.sql` ("absorbed a sale into a submitted consolidation").
#
# NOT mutated, and NOT YET RAISED: `p_month` defaults to
# `date_trunc('month', CURRENT_DATE) - 1 month` -- the SESSION's date,
# which is UTC, so from midnight to 8am Kuala Lumpur on the first of a
# month the default is TWO months back. `0739` moved thirty-nine
# `DEFAULT CURRENT_DATE`s onto `app.today()` and this one, an expression
# around it, was not among them. The app always passes the month, so
# only a caller that omits it is affected.

m("a company without the e-Invoice module consolidates",
  "consolidate_pos_einvoices",
  "  if not app.can_write_module(p_org, 'einvoice') then",
  "  if false then  -- no module",
  "-- no module")

m("a read-only member files the month",
  "consolidate_pos_einvoices",
  "  if not app.can_write(p_org) then",
  "  if false then  -- read-only",
  "-- read-only")

m("a submitted consolidation is reopened",
  "consolidate_pos_einvoices",
  "  if v_con is not null and v_status not in ('draft', 'generated') then",
  "  if false then  -- reopened",
  "-- reopened")

m("a generated consolidation is refused as if submitted",
  "consolidate_pos_einvoices",
  "  if v_con is not null and v_status not in ('draft', 'generated') then",
  "  if v_con is not null and v_status not in ('draft') then  -- generated locked",
  "-- generated locked")

m("the month runs into the first of the next",
  "consolidate_pos_einvoices",
  "  v_to     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;",
  "  v_to     date := (date_trunc('month', p_month) + interval '1 month')::date;  -- one day over",
  "-- one day over")

m("the total is the largest sale, not the sum",
  "consolidate_pos_einvoices",
  "         total_amount   = (select coalesce(sum(i.amount), 0)",
  "         total_amount   = (select coalesce(max(i.amount), 0)  -- largest",
  "-- largest")

m("the count is not kept",
  "consolidate_pos_einvoices",
  "     set document_count = (select count(*) from public.einvoice_consolidation_items i",
  "     set document_count = (select 0 from public.einvoice_consolidation_items i  -- uncounted",
  "-- uncounted")

m("the caller is not told how many were added",
  "consolidate_pos_einvoices",
  "  v_added := app.pos_consolidation_absorb(p_org, v_con, v_from, v_to);",
  "  perform app.pos_consolidation_absorb(p_org, v_con, v_from, v_to);  -- untold",
  "-- untold")

m("CONTROL: a comment inside the block",
  "consolidate_pos_einvoices",
  "  if not app.can_write(p_org) then",
  "  if not app.can_write(p_org) then  -- (control)",
  "(control)")
