# Mutants for public.bill_statutory_charge (0387) -- quit rent or an
# assessment turned into a posted bill: once, never over a date typed
# as paid, never for nothing, to this company's supplier, and linked to
# the charge only after the bill is posted.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0387_the_quit_rent_that_was_paid_by_typing_a_date.sql \
#       supabase/tests/statutory_charges.sql \
#       supabase/tests/mutants/bill_statutory_charge.py
#
# RESULT: 15 mutants and a control, all killed by `statutory_charges.sql`.
# Five only after the "`bill_statutory_charge`, rule by rule" block there:
# the first sweep left a charge that does not exist, the property
# module, the half-year in the description, the account a caller names
# and the date a caller asks for with nothing to tell them from their
# absence. The block above it was headed "a company that never bought
# the module" and never asked one -- `test_org` with no list is every
# module. Chasing the named account found that a HEADING was taken
# too, and its expense left the trial balance: that became `0765`, and
# "an account named for it is ignored" is now killed by the heading's
# refusal as well as by the leaf it names. "Another company's supplier"
# is killed by the same-company key on `purchase_documents`, not the
# function's own message -- either way the bill is not made.

m("a charge that does not exist is billed in silence",
  "bill_statutory_charge",
  "  if v_ch.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody bills a charge",
  "bill_statutory_charge",
  "  if not app.can_post(v_ch.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a company without the property module bills one",
  "bill_statutory_charge",
  "  if not app.has_property_module(v_ch.org_id) then",
  "  if false then  -- no module",
  "-- no module")

m("a charge is billed twice",
  "bill_statutory_charge",
  "  if v_ch.bill_document_id is not null then",
  "  if false then  -- billed again",
  "-- billed again")

m("a charge typed as paid is billed as well",
  "bill_statutory_charge",
  "  if v_ch.paid_on is not null then",
  "  if false then  -- paid twice",
  "-- paid twice")

m("a nil charge is billed",
  "bill_statutory_charge",
  "  if round(coalesce(v_ch.amount, 0), 2) <= 0 then",
  "  if false then  -- nil",
  "-- nil")

m("another company's supplier is billed",
  "bill_statutory_charge",
  "   where id = p_supplier and org_id = v_ch.org_id;",
  "   where id = p_supplier;  -- any company",
  "-- any company")

m("the half-year is left off the description",
  "bill_statutory_charge",
  "  v_period := case when v_ch.period_half is null then v_ch.period_year::text",
  "  v_period := case when true then v_ch.period_year::text  -- whole year",
  "-- whole year")

m("an account named for it is ignored",
  "bill_statutory_charge",
  "  v_acct := coalesce(p_account,",
  "  v_acct := coalesce(null,  -- default only",
  "-- default only")

m("the bill is dated today whatever was asked",
  "bill_statutory_charge",
  "  v_date := coalesce(p_doc_date,",
  "  v_date := coalesce(null,  -- today",
  "-- today")

m("the bill falls due when it is raised",
  "bill_statutory_charge",
  "    v_date, v_ch.due_date, p_supplier,",
  "    v_date, v_date, p_supplier,  -- due now",
  "-- due now")

m("the bill does not carry the council's account number",
  "bill_statutory_charge",
  "    p_supplier_doc_no, v_ch.account_no,",
  "    p_supplier_doc_no, null,  -- unreferenced",
  "-- unreferenced")

m("the description drops the account number",
  "bill_statutory_charge",
  "                else format(' (account %s)', v_ch.account_no) end),",
  "                else '' end),  -- unnumbered",
  "-- unnumbered")

m("the bill is left a draft",
  "bill_statutory_charge",
  "  perform app.post_purchase_document_internal(v_bill);",
  "  perform 1;  -- unposted",
  "-- unposted")

m("the charge is never linked to its bill",
  "bill_statutory_charge",
  "     set bill_document_id = v_bill, updated_at = now()",
  "     set updated_at = now()  -- unlinked",
  "-- unlinked")

m("CONTROL: a comment inside the block",
  "bill_statutory_charge",
  "  if v_ch.id is null then",
  "  if v_ch.id is null then  -- (control)",
  "(control)")
