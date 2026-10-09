# Mutants for public.adjust_loyalty_points(uuid, integer, text) (0231)
# -- points handed out or taken back by hand: the account must exist,
# the company must run a programme, and ONLY an owner or admin may do
# it (handing out points is handing out money); never nothing, never
# without a reason, never below zero -- though down to exactly zero is
# allowed; written as an adjustment, its reason trimmed, saying who;
# the new balance handed back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0231_loyalty_and_memberships_of_their_own.sql \
#       supabase/tests/pos_loyalty.sql \
#       supabase/tests/mutants/adjust_loyalty_points.py
#
# RESULT: 11 mutants and a control, all killed by `pos_loyalty.sql`;
# four before its rule-by-rule block. The rule `0580` names as the
# point of this function -- only an owner or admin hands out points --
# survived: every adjustment in the file was made by the owner. So did
# an adjustment of nothing, an account taken to exactly zero (allowed;
# `>=` refused it), the trimmed reason, who made it, and the return
# value. "Written as earned" died only to a check constraint on a
# negative adjustment; the block now reads the kind of a positive one.

m("an account that does not exist is not said so",
  "adjust_loyalty_points",
  "  if v_org is null then\n    raise exception 'No such loyalty account.'",
  "  if false then  -- no such account\n    raise exception 'No such loyalty account.'",
  "-- no such account")

m("a company with no programme adjusts points",
  "adjust_loyalty_points",
  "  if not app.can_read_module(v_org, 'loyalty') then",
  "  if false then  -- no programme",
  "-- no programme")

m("a cashier hands out points",
  "adjust_loyalty_points",
  "  if not app.can_admin(v_org) then",
  "  if false then  -- any seller",
  "-- any seller")

m("an adjustment of nothing is written",
  "adjust_loyalty_points",
  "  if p_points = 0 then",
  "  if false then  -- nothing",
  "-- nothing")

m("a blank reason will do",
  "adjust_loyalty_points",
  "  if nullif(btrim(coalesce(p_note, '')), '') is null then",
  "  if p_note is null then  -- blank will do",
  "-- blank will do")

m("an account is taken below zero",
  "adjust_loyalty_points",
  "  if p_points < 0 and -p_points > app.loyalty_balance(p_account) then",
  "  if false then  -- below zero",
  "-- below zero")

m("an account cannot be taken to exactly zero",
  "adjust_loyalty_points",
  "  if p_points < 0 and -p_points > app.loyalty_balance(p_account) then",
  "  if p_points < 0 and -p_points >= app.loyalty_balance(p_account) then  -- not to zero",
  "-- not to zero")

m("it is written as something other than an adjustment",
  "adjust_loyalty_points",
  "  values (v_org, p_account, 'adjust', p_points, btrim(p_note), auth.uid());",
  "  values (v_org, p_account, 'earn', p_points, btrim(p_note), auth.uid());  -- as earned",
  "-- as earned")

m("the reason is kept untrimmed",
  "adjust_loyalty_points",
  "  values (v_org, p_account, 'adjust', p_points, btrim(p_note), auth.uid());",
  "  values (v_org, p_account, 'adjust', p_points, p_note, auth.uid());  -- untrimmed",
  "-- untrimmed")

m("nobody is said to have done it",
  "adjust_loyalty_points",
  "  values (v_org, p_account, 'adjust', p_points, btrim(p_note), auth.uid());",
  "  values (v_org, p_account, 'adjust', p_points, btrim(p_note), null);  -- by nobody",
  "-- by nobody")

m("the change is handed back instead of the balance",
  "adjust_loyalty_points",
  "  return app.loyalty_balance(p_account);\nend;",
  "  return p_points;  -- the change\nend;",
  "-- the change")

m("CONTROL: a comment inside the block",
  "adjust_loyalty_points",
  "  if p_points = 0 then",
  "  if p_points = 0 then  -- (control)",
  "(control)")
