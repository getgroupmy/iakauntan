# Mutants for app.request_decision_is_the_databases (0795) -- on
# expense claims and leave requests, a client's own statement files a
# claim only as a draft or submitted and leave only as a draft, with no
# decision, posting or payment on either; writes no status; changes
# nothing once a request has left draft, and on a draft not whose it is
# nor its decision; deletes only a draft. The functions pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0795_a_decision_is_the_approvers.sql \
#       supabase/tests/request_decisions.sql \
#       supabase/tests/mutants/a_decision_is_the_approvers.py
#
# RESULT: 23 mutants and a control, all 23 killed by
# `request_decisions.sql`, new in `0795`. The file asks every column of
# a submitted and an approved claim and leave request from the
# catalogue (eighty), so the mutants are about which statements and
# which columns the guard lets through, not one per column. Two of the
# draft mutants ("no column is asked", "a draft is entirely the
# employee's") are first caught on `org_id`, where RLS's own WITH CHECK
# refuses a company with no HR module; `employee_id` and the decision
# columns are the guard's alone, and are asked too.
#
# SECURITY DEFINER flipped by hand: the file fails on its first refusal
# ("a claim is not filed approved: it was not refused at all");
# restored, it passes.

F = "request_decision_is_the_databases"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")
m("a client's own statement passes at depth one", F,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")
m("the functions are refused too", F,
  "     or pg_trigger_depth() > 1 then",
  "     and pg_trigger_depth() > 1 then  -- owner asked",
  "-- owner asked")

m("a decided request may be deleted", F,
  "    if old.status <> 'draft' then\n      raise exception\n        'A % that is % is the record",
  "    if false then  -- deletable\n      raise exception\n        'A % that is % is the record",
  "-- deletable")
m("a draft may not be deleted", F,
  "    if old.status <> 'draft' then\n      raise exception\n        'A % that is % is the record",
  "    if true then  -- drafts kept\n      raise exception\n        'A % that is % is the record",
  "-- drafts kept")

m("leave may be filed by hand", F,
  "    if tg_table_name = 'leave_requests' and new.status <> 'draft' then",
  "    if false then  -- leave filed by hand",
  "-- leave filed by hand")
m("no leave at all by hand, not even a draft", F,
  "    if tg_table_name = 'leave_requests' and new.status <> 'draft' then",
  "    if tg_table_name = 'leave_requests' then  -- no drafts",
  "-- no drafts")
m("a claim may be filed approved", F,
  "    if new.status not in ('draft', 'submitted') then",
  "    if new.status not in ('draft', 'submitted', 'approved') then  -- filed approved",
  "-- filed approved")
m("a claim may not be filed submitted", F,
  "    if new.status not in ('draft', 'submitted') then",
  "    if new.status not in ('draft') then  -- drafts only",
  "-- drafts only")
m("a claim may be filed with an approved amount", F,
  "          and coalesce((v_new ->> v_col)::numeric, 0) <> 0)",
  "          and false)  -- amount free",
  "-- amount free")
m("the approved amount is asked as text", F,
  "          and coalesce((v_new ->> v_col)::numeric, 0) <> 0)",
  "          and coalesce(v_new ->> v_col, '0') <> '0')  -- as text",
  "-- as text")
m("filed with a decision, posting or payment", F,
  "         or (v_col <> 'approved_amount' and v_new ->> v_col is not null) then",
  "         or false then  -- decision free",
  "-- decision free")
m("the payment is not the database's", F,
  "    'gl_entry_id', 'posted_at', 'paid_at'];",
  "    'gl_entry_id', 'posted_at', 'no_paid_at'];  -- payment free",
  "-- payment free")
m("the approver is not the database's", F,
  "    'approved_amount', 'approver_id', 'decided_at', 'decision_note',",
  "    'approved_amount', 'no_approver_id', 'decided_at', 'decision_note',  -- approver free",
  "-- approver free")

m("the status is not asked", F,
  "  if new.status is distinct from old.status then",
  "  if false then  -- status free",
  "-- status free")
m("a draft's status is free", F,
  "  if new.status is distinct from old.status then",
  "  if old.status <> 'draft' and new.status is distinct from old.status then  -- draft status free",
  "-- draft status free")

m("no column is asked", F,
  "    if (v_new -> v_col) is distinct from (v_old -> v_col) then",
  "    if false then  -- no column asked",
  "-- no column asked")
m("a draft is frozen too", F,
  "    continue when old.status = 'draft'\n              and v_col <> all (v_decision || array['org_id', 'employee_id']);",
  "    continue when false;  -- drafts frozen",
  "-- drafts frozen")
m("a draft is entirely the employee's", F,
  "    continue when old.status = 'draft'\n              and v_col <> all (v_decision || array['org_id', 'employee_id']);",
  "    continue when old.status = 'draft';  -- drafts free",
  "-- drafts free")
m("whose a draft is, is the employee's", F,
  "              and v_col <> all (v_decision || array['org_id', 'employee_id']);",
  "              and v_col <> all (v_decision);  -- claimant free",
  "-- claimant free")
m("a submitted request is still the client's", F,
  "    continue when old.status = 'draft'\n",
  "    continue when old.status in ('draft', 'submitted')  -- submitted free\n",
  "-- submitted free")
m("the updated time is a client's", F,
  "  for v_col in select k from jsonb_object_keys(v_new) k order by k loop",
  "  for v_col in select k from jsonb_object_keys(v_new) k where k <> 'updated_at' order by k loop  -- updated free",
  "-- updated free")

m("the two tables answer in each other's words", F,
  "                    when 'expense_claims' then 'claim' else 'leave request' end;",
  "                    when 'expense_claims' then 'leave request' else 'claim' end;  -- swapped",
  "-- swapped")

m("CONTROL", F,
  "  v_new   jsonb;\n",
  "  v_new   jsonb;  -- control\n",
  "-- control")
