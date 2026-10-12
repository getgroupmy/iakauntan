# Mutants for 0846 -- app.a_claim_is_what_was_decided freezes a claim's
# lines to the claimant once the claim has left draft or submitted, or
# once any step has been approved or rejected; HR passes.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0846_a_claim_is_what_was_decided.sql \
#       supabase/tests/claim_lines_kept.sql \
#       supabase/tests/mutants/a_claim_is_what_was_decided.py
#
# RESULT: 7 of 9 killed, the control surviving. Two survivors, both
# equivalent and both said in the test: the depth clause (every claim
# function is a definer, the owner at any depth) and "a rejected step
# does not count" (`decide_claim_step` rejects the whole claim the moment
# a step is rejected, so the claim's state already refuses).

m('nobody is asked',
  'a_claim_is_what_was_decided',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'a_claim_is_what_was_decided',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('the claim a line leaves is not asked',
  'a_claim_is_what_was_decided',
  "      case when tg_op <> 'INSERT' then old.claim_id end,",
  '      null::uuid,  -- leaving free',
  '-- leaving free')

m('the claim a line joins is not asked',
  'a_claim_is_what_was_decided',
  "      case when tg_op <> 'DELETE' then new.claim_id end], null)",
  '      null::uuid], null)  -- joining free',
  '-- joining free')

m('HR is held to it too',
  'a_claim_is_what_was_decided',
  '    continue when c.org_id is null or app.can_manage_hr(c.org_id);',
  '    continue when c.org_id is null;  -- HR held',
  '-- HR held')

m("the claim's state is not asked",
  'a_claim_is_what_was_decided',
  "    if c.status not in ('draft', 'submitted')\n       or exists",
  '    if false  -- state unasked\n       or exists',
  '-- state unasked')

m('a draft is frozen too',
  'a_claim_is_what_was_decided',
  "    if c.status not in ('draft', 'submitted')\n       or exists",
  "    if c.status not in ('submitted')  -- drafts frozen\n       or exists",
  '-- drafts frozen')

m('a decided step is not asked',
  'a_claim_is_what_was_decided',
  '       or exists (select 1 from public.claim_approvals a',
  '       or false and exists (select 1 from public.claim_approvals a  -- steps unasked',
  '-- steps unasked')

m('a rejected step does not count',
  'a_claim_is_what_was_decided',
  "                     and a.status in ('approved', 'rejected')) then",
  "                     and a.status = 'approved') then  -- rejections free",
  '-- rejections free')

m('CONTROL: a comment inside a_claim_is_what_was_decided',
  'a_claim_is_what_was_decided',
  '  return coalesce(new, old);\nend $$;',
  '  return coalesce(new, old);  -- (control)\nend $$;',
  '(control)')
