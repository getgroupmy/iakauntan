# Mutants for public.record_tax_filing (0669) -- marking an LHDN
# obligation filed, in preparation or not applicable, against the
# obligation the company actually has.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0669_a_deadline_that_never_clears_is_a_deadline_nobody_reads.sql \
#       supabase/tests/tax_filings_recorded.sql \
#       supabase/tests/mutants/record_tax_filing.py
#
# then again against `tax_dashboard_tile.sql` and `tax_stack_end_to_end.sql`.
#
# RESULT: 9 mutants and a control. 9 killed in tax_filings_recorded.sql.
#
#   The first sweep killed 8 there; nothing asked WHO recorded the
#   filing. One assertion beside the first recording kills it.

m("a reader records a filing",
  "record_tax_filing",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an unknown form is recorded",
  "record_tax_filing",
  "  if not exists (select 1 from public.tax_filing_types t\n                  where t.code = p_filing_type) then",
  "  if false then  -- any form",
  "-- any form")

m("an obligation the company does not have is recorded",
  "record_tax_filing",
  "    if v_row.id is null then",
  "    if false then  -- any obligation",
  "-- any obligation")

m("a filing is recorded with no date",
  "record_tax_filing",
  "               then coalesce(p_filed_on, app.today()) else p_filed_on end,",
  "               then p_filed_on else p_filed_on end,  -- no default",
  "-- no default")

m("the date given is replaced by today",
  "record_tax_filing",
  "               then coalesce(p_filed_on, app.today()) else p_filed_on end,",
  "               then app.today() else p_filed_on end,  -- today",
  "-- today")

m("the due date is not carried onto the record",
  "record_tax_filing",
  "          coalesce(v_found.due_date, v_row.due_date),",
  "          null,  -- no due",
  "-- no due")

m("recording again does not change the status",
  "record_tax_filing",
  "     set status = excluded.status,",
  "     set status = tax_filings.status,  -- kept",
  "-- kept")

m("recording again keeps the old reference",
  "record_tax_filing",
  "         reference = excluded.reference,",
  "         reference = tax_filings.reference,  -- kept",
  "-- kept")

m("who recorded it is not kept",
  "record_tax_filing",
  "          p_reference, p_notes, auth.uid())",
  "          p_reference, p_notes, null)  -- nobody",
  "-- nobody")

m("CONTROL: a comment inside the block",
  "record_tax_filing",
  "  -- `filed` with no date defaults to today rather than being refused.",
  "  -- CONTROL\n  -- `filed` with no date defaults to today rather than being refused.",
  "-- CONTROL")
