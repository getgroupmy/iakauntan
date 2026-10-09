# Mutants for `apply_tax_submission` and `dismiss_tax_submission` (0626)
# -- a customer's own tax details, sent through a link, accepted over
# what the contact held or set aside: by somebody who may write, and
# with a record of what was taken and by whom.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0626_the_number_only_the_customer_has.sql \
#       supabase/tests/tax_details.sql \
#       supabase/tests/mutants/tax_submission.py
#
# RESULT: 8 mutants and a control, all killed by `tax_details.sql`. Four
# only after its "`apply_tax_submission`, rule by rule" block: a missing
# submission, who accepted it, accepting what had been set aside, and
# the fields the public form took staying on the record. `statutory.sql`
# also reaches these functions and kills none of the eight.

m("a submission that does not exist is not said so",
  "apply_tax_submission",
  "  if s.id is null then",
  "  if false then  -- no such submission",
  "-- no such submission")

m("anybody accepts a customer's tax details",
  "apply_tax_submission",
  "  if not app.can_write(s.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("accepting only fills blanks",
  "apply_tax_submission",
  "  v_done := app.tax_submission_apply(p_submission_id, false);",
  "  v_done := app.tax_submission_apply(p_submission_id, true);  -- blanks only",
  "-- blanks only")

m("what was taken before is forgotten",
  "apply_tax_submission",
  "             from unnest(applied_fields || v_done) as k),",
  "             from unnest(v_done) as k),  -- forgotten",
  "-- forgotten")

m("nobody is recorded as having accepted it",
  "apply_tax_submission",
  "         applied_by = auth.uid(),",
  "         applied_by = null,  -- anonymous",
  "-- anonymous")

m("a dismissed submission stays dismissed when accepted",
  "apply_tax_submission",
  "         dismissed_at = null,",
  "         dismissed_at = dismissed_at,  -- still dismissed",
  "-- still dismissed")

m("anybody sets one aside",
  "dismiss_tax_submission",
  "  if v_org is null or not app.can_write(v_org) then",
  "  if v_org is null then  -- anybody",
  "-- anybody")

m("setting one aside records nothing",
  "dismiss_tax_submission",
  "     set dismissed_at = now(), dismissed_by = auth.uid()",
  "     set dismissed_by = auth.uid()  -- not dismissed",
  "-- not dismissed")

m("CONTROL: a comment inside the block",
  "apply_tax_submission",
  "  if s.id is null then",
  "  if s.id is null then  -- (control)",
  "(control)")
