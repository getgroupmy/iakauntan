# Mutants for public.set_requires_self_billed (0801, from 0611) -- a
# bill's self-billed e-Invoice obligation set by hand: a bill that
# exists, for somebody who may write, not once one is with LHDN; taking
# it off withdraws one prepared and not yet sent and leaves the bill
# owing none; putting it back clears a withdrawal that never reached
# LHDN.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0801_a_self_billed_invoice_goes_with_the_obligation.sql \
#       supabase/tests/self_billed_einvoice.sql \
#       supabase/tests/mutants/a_self_billed_invoice_goes_with_the_obligation.py
#
# RESULT: 9 mutants and a control. 8 killed by `self_billed_einvoice.sql`.
#
# EQUIVALENT: "a valid one is withdrawn too". `app.sync_einvoice_status`
# copies a document's status onto its bill, so a valid e-Invoice makes
# its bill 'valid', and the function refuses that bill before it reaches
# the withdrawal ("a filed e-Invoice is not un-ticked here", asserted).

F = "set_requires_self_billed"

m("a filed one is un-ticked", F,
  "  if v_doc.einvoice_status in ('submitted', 'valid') then",
  "  if false then  -- filed unticked",
  "-- filed unticked")
m("the tick does not stick", F,
  "     set requires_self_billed = coalesce(p_required, false)",
  "     set requires_self_billed = requires_self_billed  -- ignored",
  "-- ignored")
m("a prepared one is left queued", F,
  "  if not coalesce(p_required, false) then\n    update public.einvoice_documents e",
  "  if false then  -- left queued\n    update public.einvoice_documents e",
  "-- left queued")
m("a failed one is left to be retried", F,
  "       and e.status in ('draft', 'queued', 'failed', 'invalid');",
  "       and e.status in ('draft', 'queued', 'invalid');  -- failed left",
  "-- failed left")
m("a valid one is withdrawn too", F,
  "       and e.status in ('draft', 'queued', 'failed', 'invalid');",
  "       and e.status in ('draft', 'queued', 'failed', 'invalid', 'valid');  -- valid withdrawn",
  "-- valid withdrawn")
m("the withdrawal says nothing of when", F,
  "           cancelled_at = now(),",
  "           cancelled_at = null,  -- when unsaid",
  "-- when unsaid")
m("the bill still says pending", F,
  "         set einvoice_status = 'not_applicable', einvoice_id = null",
  "         set einvoice_id = null  -- pending kept",
  "-- pending kept")
m("the bill still points at it", F,
  "         set einvoice_status = 'not_applicable', einvoice_id = null",
  "         set einvoice_status = 'not_applicable'  -- still pointing",
  "-- still pointing")
m("ticked again, the withdrawal stays on it", F,
  "       set cancelled_at = null, cancellation_reason = null",
  "       set cancelled_at = cancelled_at  -- withdrawal kept",
  "-- withdrawal kept")

m("CONTROL", F,
  "declare v_doc public.purchase_documents;",
  "declare v_doc public.purchase_documents;  -- control",
  "-- control")
