# Mutants for 0841 -- app.a_company_always_has_an_owner refuses a
# client's own update of a membership's seat columns, and one that
# leaves a company with no active owner.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0841_a_company_always_has_an_owner.sql \
#       supabase/tests/company_keeps_its_owner.sql \
#       supabase/tests/mutants/a_company_always_has_an_owner.py
#
# RESULT: 18 of 19 killed, the control surviving. The survivor, "a
# statement one trigger down is a client too", is equivalent: every
# function that writes a membership is a definer, which runs as the
# owner at any depth -- the test says so beside its owner assertion.
# Each seat column is asked alone, and each half of the owner rule:
# a demotion and a suspension, another owner of this company, active,
# and not the row itself.

m('nobody is asked',
  'a_company_always_has_an_owner',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'a_company_always_has_an_owner',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('the org_id is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['user_id', 'invited_email', 'invited_by', 'invite_token', 'invite_expires_at', 'joined_at', 'via_firm_id'];  -- no org_id",
  '-- no org_id')

m('the user_id is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'invited_email', 'invited_by', 'invite_token', 'invite_expires_at', 'joined_at', 'via_firm_id'];  -- no user_id",
  '-- no user_id')

m('the invited_email is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_by', 'invite_token', 'invite_expires_at', 'joined_at', 'via_firm_id'];  -- no invited_email",
  '-- no invited_email')

m('the invited_by is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email', 'invite_token', 'invite_expires_at', 'joined_at', 'via_firm_id'];  -- no invited_by",
  '-- no invited_by')

m('the invite_token is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email', 'invited_by', 'invite_expires_at', 'joined_at', 'via_firm_id'];  -- no invite_token",
  '-- no invite_token')

m('the invite_expires_at is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email', 'invited_by', 'invite_token', 'joined_at', 'via_firm_id'];  -- no invite_expires_at",
  '-- no invite_expires_at')

m('the joined_at is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email', 'invited_by', 'invite_token', 'invite_expires_at', 'via_firm_id'];  -- no joined_at",
  '-- no joined_at')

m('the via_firm_id is open',
  'a_company_always_has_an_owner',
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email',\n    'invited_by', 'invite_token', 'invite_expires_at', 'joined_at',\n    'via_firm_id'];",
  "  c_seat constant text[] := array['org_id', 'user_id', 'invited_email', 'invited_by', 'invite_token', 'invite_expires_at', 'joined_at'];  -- no via_firm_id",
  '-- no via_firm_id')

m("the owner's row is not asked",
  'a_company_always_has_an_owner',
  "  if old.role = 'owner' and old.status = 'active'",
  "  if false and old.status = 'active'  -- owner unasked",
  '-- owner unasked')

m('a demotion is not leaving',
  'a_company_always_has_an_owner',
  "     and (new.role <> 'owner' or new.status <> 'active')",
  "     and (new.status <> 'active')  -- demotion free",
  '-- demotion free')

m('a suspension is not leaving',
  'a_company_always_has_an_owner',
  "     and (new.role <> 'owner' or new.status <> 'active')",
  "     and (new.role <> 'owner')  -- suspension free",
  '-- suspension free')

m('the sole owner may leave',
  'a_company_always_has_an_owner',
  "     and not exists (select 1 from public.org_members m\n                      where m.org_id = old.org_id and m.id <> old.id\n                        and m.role = 'owner' and m.status = 'active') then",
  '     and false then  -- leaving free',
  '-- leaving free')

m('a co-owner is never enough',
  'a_company_always_has_an_owner',
  "     and not exists (select 1 from public.org_members m\n                      where m.org_id = old.org_id and m.id <> old.id\n                        and m.role = 'owner' and m.status = 'active') then",
  '     and true then  -- co-owner ignored',
  '-- co-owner ignored')

m("another company's owner will do",
  'a_company_always_has_an_owner',
  '                      where m.org_id = old.org_id and m.id <> old.id',
  '                      where true and m.id <> old.id  -- any company',
  '-- any company')

m('the owner will do for themselves',
  'a_company_always_has_an_owner',
  '                      where m.org_id = old.org_id and m.id <> old.id',
  '                      where m.org_id = old.org_id and true  -- itself',
  '-- itself')

m('any member will do',
  'a_company_always_has_an_owner',
  "                        and m.role = 'owner' and m.status = 'active') then",
  "                        and m.status = 'active') then  -- any member",
  '-- any member')

m('a suspended co-owner will do',
  'a_company_always_has_an_owner',
  "                        and m.role = 'owner' and m.status = 'active') then",
  "                        and m.role = 'owner') then  -- suspended counts",
  '-- suspended counts')

m('CONTROL: a comment inside a_company_always_has_an_owner',
  'a_company_always_has_an_owner',
  '  return new;\nend $$;',
  '  return new;  -- (control)\nend $$;',
  '(control)')
