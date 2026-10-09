# Mutants for public.adjust_loyalty_points(uuid, integer, text, text)
# (0736) -- the keyed form: the same key with the same request hands
# back the balance the first call left, without adjusting again; the
# request is the account, the points and the note, so the same key with
# different points is not the same request; the result recorded, and
# an unknown account passed through to the three-argument form to say so.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0736_the_pos_back_office_and_a_double_handful_of_points.sql \
#       supabase/tests/idempotency.sql \
#       supabase/tests/mutants/adjust_loyalty_points_idempotent.py
#
# RESULT: 6 mutants and a control, all killed by `idempotency.sql`; four
# before two refusals were added. Nothing reused a key for a different
# request, so a request that ignored the points or the note -- and
# replayed an old balance for an adjustment never made -- passed.

m("a key is never looked up",
  "adjust_loyalty_points",
  "  if v_org is not null then\n    v_seen := app.idempotency_begin(",
  "  if false then  -- no key\n    v_seen := app.idempotency_begin(",
  "-- no key")

m("a replay adjusts again",
  "adjust_loyalty_points",
  "    if v_seen is not null then",
  "    if false then  -- no replay",
  "-- no replay")

m("a replay hands back nothing",
  "adjust_loyalty_points",
  "      return coalesce((v_seen ->> 'balance')::integer, 0);",
  "      return 0;  -- replay says nothing",
  "-- replay says nothing")

m("the points are not part of the request",
  "adjust_loyalty_points",
  "    jsonb_build_object('account', p_account, 'points', p_points,",
  "    jsonb_build_object('account', p_account,  -- points unread",
  "-- points unread")

m("the note is not part of the request",
  "adjust_loyalty_points",
  "    jsonb_build_object('account', p_account, 'points', p_points,\n                       'note', p_note));",
  "    jsonb_build_object('account', p_account, 'points', p_points));  -- note unread\n",
  "-- note unread")

m("the result is never recorded",
  "adjust_loyalty_points",
  "    perform app.idempotency_end(v_org, p_idempotency_key,\n                                jsonb_build_object('balance', v_n));",
  "    perform 1;  -- never recorded\n",
  "-- never recorded")

m("CONTROL: a comment inside the block",
  "adjust_loyalty_points",
  "    if v_seen is not null then",
  "    if v_seen is not null then  -- (control)",
  "(control)")
