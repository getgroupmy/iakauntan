# Mutants for app.build_claim_chain (0121) -- the four steps a submitted
# expense claim must clear: the manager, the unit head, HR and finance,
# with who is skipped and why.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0121_a_claim_with_nobody_to_ask.sql \
#       supabase/tests/claim_approval_chain.sql \
#       supabase/tests/mutants/build_claim_chain.py
#
# then again against `expense_claims.sql`.
#
# RESULT: 20 mutants and a control. 20 killed, all by
# `claim_approval_chain.sql`, ten of them only after a rule-by-rule block
# there. Every company in both files had an owner, so the HR and finance
# steps were always somebody's and the notes saying why one was skipped
# were never written; nobody claimed against themselves through the org
# chart; no claim sat exactly on the threshold; and only one company set
# a threshold, so reading anybody's did. The block's companies each lack
# one role, one employee is their own manager and head, and two
# companies with different thresholds take the same 500.

m("the threshold is read from another company",
  "build_claim_chain",
  "    from public.claim_approval_settings s where s.org_id = v_claim.org_id;",
  "    from public.claim_approval_settings s limit 1;  -- any company",
  "-- any company")

m("a claim AT the threshold takes the short path",
  "build_claim_chain",
  "  v_full := v_claim.total_amount >= v_threshold;",
  "  v_full := v_claim.total_amount > v_threshold;  -- above only",
  "-- above only")

m("every claim takes the full chain",
  "build_claim_chain",
  "  v_full := v_claim.total_amount >= v_threshold;",
  "  v_full := true;  -- always full",
  "-- always full")

m("a claimant who is their own manager approves it",
  "build_claim_chain",
  "  if v_manager = v_claim.employee_id then v_manager := null; end if;",
  "  null;  -- own manager",
  "-- own manager")

m("a claimant who heads the department approves it",
  "build_claim_chain",
  "  if v_head = v_claim.employee_id then v_head := null; end if;",
  "  null;  -- own head",
  "-- own head")

m("a missing manager is not explained",
  "build_claim_chain",
  "    v_note := 'No manager is set for this employee.';",
  "    v_note := null;  -- unexplained",
  "-- unexplained")

m("the manager is not remembered as asked",
  "build_claim_chain",
  "    v_seen := v_seen || v_manager;",
  "    null;  -- forgotten",
  "-- forgotten")

m("the manager's step is never skipped",
  "build_claim_chain",
  "          case when v_manager is null then 'skipped'::app.claim_step_status\n               else 'pending'::app.claim_step_status end,\n          v_manager, v_note);",
  "          'pending'::app.claim_step_status,  -- stuck\n          v_manager, v_note);",
  "-- stuck")

m("below the threshold the full chain is asked anyway",
  "build_claim_chain",
  "  if not v_full and v_manager is not null then return; end if;",
  "  null;  -- everybody",
  "-- everybody")

m("below the threshold with no manager, the claim is stuck",
  "build_claim_chain",
  "  if not v_full and v_manager is not null then return; end if;",
  "  if not v_full then return; end if;  -- stranded",
  "-- stranded")

m("a missing head is not explained",
  "build_claim_chain",
  "    v_note := 'No head is set for this department.';",
  "    v_note := null;  -- unexplained",
  "-- unexplained")

m("the head who is the manager is asked twice",
  "build_claim_chain",
  "  elsif v_head = any (v_seen) then",
  "  elsif false then  -- twice",
  "-- twice")

m("the head's step is never skipped",
  "build_claim_chain",
  "          case when v_head is null then 'skipped'::app.claim_step_status\n               else 'pending'::app.claim_step_status end,\n          v_head, v_note);",
  "          'pending'::app.claim_step_status,  -- stuck\n          v_head, v_note);",
  "-- stuck")

m("the HR step is skipped in every company",
  "build_claim_chain",
  "              and m.role in ('owner', 'admin', 'hr_manager'))\n         then 'pending'::app.claim_step_status",
  "              and false)  -- nobody\n         then 'pending'::app.claim_step_status",
  "-- nobody")

m("an accountant fills the HR step",
  "build_claim_chain",
  "              and m.role in ('owner', 'admin', 'hr_manager'))\n         then 'pending'::app.claim_step_status",
  "              and m.role in ('owner', 'admin', 'hr_manager', 'accountant'))  -- books\n         then 'pending'::app.claim_step_status",
  "-- books")

m("an HR step nobody holds is not explained",
  "build_claim_chain",
  "         then null else 'Nobody in this company holds an HR role.' end;",
  "         then null else null end;  -- unexplained",
  "-- unexplained")

m("the finance step is skipped in every company",
  "build_claim_chain",
  "              and m.role in ('owner', 'admin', 'accountant'))\n         then 'pending'::app.claim_step_status",
  "              and false)  -- nobody\n         then 'pending'::app.claim_step_status",
  "-- nobody")

m("HR fills the finance step",
  "build_claim_chain",
  "              and m.role in ('owner', 'admin', 'accountant'))\n         then 'pending'::app.claim_step_status",
  "              and m.role in ('owner', 'admin', 'accountant', 'hr_manager'))  -- HR\n         then 'pending'::app.claim_step_status",
  "-- HR")

m("a finance step nobody holds is not explained",
  "build_claim_chain",
  "         then null else 'Nobody in this company holds a finance role.' end;",
  "         then null else null end;  -- unexplained",
  "-- unexplained")

m("another company's members fill a role",
  "build_claim_chain",
  "            where m.org_id = v_claim.org_id\n              and m.role in ('owner', 'admin', 'accountant'))\n         then 'pending'",
  "            where true  -- anyone anywhere\n              and m.role in ('owner', 'admin', 'accountant'))\n         then 'pending'",
  "-- anyone anywhere")

m("CONTROL: a comment inside the block",
  "build_claim_chain",
  "  -- 1. The manager who knows whether it happened.",
  "  -- 1. The manager who knows whether it happened. (control)",
  "(control)")
