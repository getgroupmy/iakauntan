# Mutants for public.decide_claim_step (0752, restating 0119's) -- an expense claim going up the line: the step in front and
# only that one, who may decide it, and when the claim itself is
# approved.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0752_a_claim_step_is_nobodys_unless_it_is_yours.sql \
#       supabase/tests/claim_approval_chain.sql \
#       supabase/tests/mutants/decide_claim_step.py
#
# then again against `expense_claims.sql`.
#
# RESULT: 23 mutants and a control. 21 killed: `expense_claims.sql`
# takes the approved amount (its part-approval), and
# `claim_approval_chain.sql` the rest, thirteen of them only after a rule-by-rule
# block there: nothing read who decided a step, when, or what they said,
# nor who approved or refused the claim and why; no refused claim was
# offered to anybody again; nobody refused at the LAST step, where a
# refusal that carried on would find nothing pending and approve; a
# claim with nothing pending was never decided; a missing claim was
# refused, but with another message.
#
# Swept first against 0119, where the block's own assertions found that
# a NULL from `may_decide_claim_step` was taken as permission -- by HR,
# by an accountant, by a stranger from another company. Fixed in 0752.
#
# Two EQUIVALENT:
#
#   a NULL answer is permission again  0752 closed both ends. With
#   (0119's test)                      `may_decide_claim_step` no longer
#                                      able to answer NULL, `not x` and
#                                      `x is not true` agree; the other
#                                      end is killed in its own file.
#   a decision with no note wipes the  a step is decided only while
#   step's note                        pending, and `build_claim_chain`
#                                      writes every pending step with no
#                                      note -- its notes are the reasons
#                                      a step was SKIPPED.

m("a claim that does not exist is decided in silence",
  "decide_claim_step",
  "  if v_claim.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("a decided claim is decided again",
  "decide_claim_step",
  "  if v_claim.status <> 'submitted' then",
  "  if false then  -- twice",
  "-- twice")

m("the last step is decided first",
  "decide_claim_step",
  "   order by step_no limit 1;",
  "   order by step_no desc limit 1;  -- back to front",
  "-- back to front")

m("a decided step is decided again",
  "decide_claim_step",
  "   where claim_id = p_claim_id and status = 'pending'\n   order by step_no limit 1;",
  "   where claim_id = p_claim_id  -- any step\n   order by step_no limit 1;",
  "-- any step")

m("a claim with no step waiting is decided anyway",
  "decide_claim_step",
  "  if v_step.id is null then",
  "  if false then  -- nobody asked",
  "-- nobody asked")

m("anybody decides the step",
  "decide_claim_step",
  "  if app.may_decide_claim_step(v_step.id) is not true then",
  "  if false then  -- by anyone",
  "-- by anyone")

m("a NULL answer is permission again (0119's test)",
  "decide_claim_step",
  "  if app.may_decide_claim_step(v_step.id) is not true then",
  "  if not app.may_decide_claim_step(v_step.id) then  -- not null",
  "-- not null")

m("a rejection approves the step",
  "decide_claim_step",
  "     set status = case when p_approve then 'approved'::app.claim_step_status\n                       else 'rejected'::app.claim_step_status end,",
  "     set status = 'approved'::app.claim_step_status,  -- always yes",
  "-- always yes")

m("the step does not say who decided it",
  "decide_claim_step",
  "         decided_by = auth.uid(),\n         decided_at = now(),\n         note",
  "         decided_by = null,  -- anonymous\n         decided_at = now(),\n         note",
  "-- anonymous")

m("the step does not say when",
  "decide_claim_step",
  "         decided_at = now(),\n         note",
  "         decided_at = null,  -- whenever\n         note",
  "-- whenever")

m("a decision with no note wipes the step's note",
  "decide_claim_step",
  "         note = coalesce(p_note, note)",
  "         note = p_note  -- wiped",
  "-- wiped")

m("the step's note is not kept",
  "decide_claim_step",
  "         note = coalesce(p_note, note)",
  "         note = note  -- unsaid",
  "-- unsaid")

m("a rejection leaves the claim waiting",
  "decide_claim_step",
  "  if not p_approve then\n    update public.expense_claims",
  "  if false then  -- carry on\n    update public.expense_claims",
  "-- carry on")

m("a rejected claim keeps an amount",
  "decide_claim_step",
  "       set status = 'rejected', approved_amount = 0,",
  "       set status = 'rejected', approved_amount = total_amount,  -- still owed",
  "-- still owed")

m("a rejection names no approver",
  "decide_claim_step",
  "       set status = 'rejected', approved_amount = 0,\n           approver_id = auth.uid(),",
  "       set status = 'rejected', approved_amount = 0,\n           approver_id = null,  -- nobody refused\n          ",
  "-- nobody refused")

m("a rejection keeps no reason",
  "decide_claim_step",
  "           approver_id = auth.uid(), decided_at = now(), decision_note = p_note\n     where id = p_claim_id;\n    return;",
  "           approver_id = auth.uid(), decided_at = now(), decision_note = null  -- unsaid\n     where id = p_claim_id;\n    return;",
  "-- unsaid")

m("a rejection carries on up the chain",
  "decide_claim_step",
  "     where id = p_claim_id;\n    return;",
  "     where id = p_claim_id;\n    null;  -- keep going",
  "-- keep going")

m("the claim is approved at the first step",
  "decide_claim_step",
  "  if v_remaining = 0 then",
  "  if true then  -- first yes",
  "-- first yes")

m("the claim is never approved",
  "decide_claim_step",
  "  if v_remaining = 0 then",
  "  if false then  -- never",
  "-- never")

m("the approved amount is always what was claimed",
  "decide_claim_step",
  "           approved_amount = coalesce(p_approved_amount, total_amount),",
  "           approved_amount = total_amount,  -- as claimed",
  "-- as claimed")

m("an approval without an amount approves nothing",
  "decide_claim_step",
  "           approved_amount = coalesce(p_approved_amount, total_amount),",
  "           approved_amount = coalesce(p_approved_amount, 0),  -- nothing",
  "-- nothing")

m("an approval names no approver",
  "decide_claim_step",
  "       set status = 'approved',\n           approved_amount = coalesce(p_approved_amount, total_amount),\n           approver_id = auth.uid(),",
  "       set status = 'approved',\n           approved_amount = coalesce(p_approved_amount, total_amount),\n           approver_id = null,  -- nobody approved\n          ",
  "-- nobody approved")

m("an approval keeps no note",
  "decide_claim_step",
  "           approver_id = auth.uid(), decided_at = now(), decision_note = p_note\n     where id = p_claim_id;\n  end if;",
  "           approver_id = auth.uid(), decided_at = now(), decision_note = null  -- unsaid\n     where id = p_claim_id;\n  end if;",
  "-- unsaid")

m("CONTROL: a comment inside the block",
  "decide_claim_step",
  "  -- Approved by everybody the chain asked. Only now is it approved.",
  "  -- Approved by everybody the chain asked. Only now is it approved. (control)",
  "(control)")
