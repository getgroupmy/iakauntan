# Mutants for public.set_document_numbering (0480) -- setting a number
# series: admins only, a known series, a prefix and suffix of up to
# twelve plain characters, padding of 1 to 12, a reset policy of never,
# yearly or monthly, a next number of 1 to 999999999999 and never below
# the last issued while the series keeps its prefix, suffix and policy
# -- then the series is written and the next number's sample returned.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0480_what_the_next_invoice_is_called.sql \
#       supabase/tests/document_numbering.sql \
#       supabase/tests/mutants/set_document_numbering.py
#
# RESULT: 22 mutants and a control, all 22 killed by
# `document_numbering.sql` -- 21 as it stood, and the floor ignoring the
# reset policy once a case asked that a new policy may restart from 1.
#
# Noted, not raised: the floor is asked of the series AS IT STANDS. A
# prefix (or suffix, or policy) switched away and then back, with the
# next number set low, re-issues numbers already on documents; nothing
# skips a taken number, so the next save fails on the table's
# `unique (org_id, doc_type, doc_no)` -- loudly, in the constraint's
# words, until an admin sets the number above the last one used.

F = "set_document_numbering"

m("anybody may set a series", F,
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an unknown series is set", F,
  "  if v_label is null then\n    raise exception 'Unknown series %'",
  "  if false then  -- unknown taken\n    raise exception 'Unknown series %'",
  "-- unknown taken")

m("any prefix is taken", F,
  "  if v_prefix !~ '^[A-Za-z0-9/_.#-]{0,12}$' then",
  "  if false then  -- any prefix",
  "-- any prefix")

m("a thirteen-character prefix is taken", F,
  "  if v_prefix !~ '^[A-Za-z0-9/_.#-]{0,12}$' then",
  "  if v_prefix !~ '^[A-Za-z0-9/_.#-]{0,13}$' then  -- thirteen",
  "-- thirteen")

m("any suffix is taken", F,
  "  if v_suffix !~ '^[A-Za-z0-9/_.#-]{0,12}$' then",
  "  if false then  -- any suffix",
  "-- any suffix")

m("no padding is padding", F,
  "  if p_padding is null or p_padding < 1 or p_padding > 12 then",
  "  if p_padding is null or p_padding < 0 or p_padding > 12 then  -- zero pad",
  "-- zero pad")

m("thirteen digits of padding", F,
  "  if p_padding is null or p_padding < 1 or p_padding > 12 then",
  "  if p_padding is null or p_padding < 1 or p_padding > 13 then  -- wide pad",
  "-- wide pad")

m("any reset policy", F,
  "     or p_reset_policy not in ('never', 'yearly', 'monthly') then",
  "     or false then  -- any policy",
  "-- any policy")

m("the next number may be zero", F,
  "  if p_next_value is null or p_next_value < 1",
  "  if p_next_value is null or p_next_value < 0  -- zero next",
  "-- zero next")

m("the next number has no ceiling", F,
  "     or p_next_value > 999999999999 then",
  "     or false then  -- no ceiling",
  "-- no ceiling")

m("a new period does not restart the count", F,
  "  if v_seq.reset_policy <> 'never'\n     and v_seq.period_key is distinct from",
  "  if false  -- never restarts\n     and v_seq.period_key is distinct from",
  "-- never restarts")

m("the next number may go below the last issued", F,
  "  if p_next_value < v_effective\n     and v_prefix = v_seq.prefix",
  "  if false  -- may go below\n     and v_prefix = v_seq.prefix",
  "-- may go below")

m("the floor ignores the prefix", F,
  "     and v_prefix = v_seq.prefix\n",
  "     and true  -- prefix ignored\n",
  "-- prefix ignored")

m("the floor ignores the suffix", F,
  "     and v_suffix = v_seq.suffix\n",
  "     and true  -- suffix ignored\n",
  "-- suffix ignored")

m("the floor ignores the policy", F,
  "     and p_reset_policy = v_seq.reset_policy then",
  "     and true then  -- policy ignored",
  "-- policy ignored")

m("the prefix is not written", F,
  "     set prefix       = v_prefix,",
  "     set prefix       = prefix,  -- prefix kept",
  "-- prefix kept")

m("the suffix is not written", F,
  "         suffix       = v_suffix,",
  "         suffix       = suffix,  -- suffix kept",
  "-- suffix kept")

m("the padding is not written", F,
  "         padding      = p_padding,",
  "         padding      = padding,  -- padding kept",
  "-- padding kept")

m("the policy is not written", F,
  "         reset_policy = p_reset_policy,",
  "         reset_policy = reset_policy,  -- policy kept",
  "-- policy kept")

m("the next number is not written", F,
  "         next_value   = p_next_value,",
  "         next_value   = next_value,  -- next kept",
  "-- next kept")

m("the period is not started", F,
  "         period_key   = v_period_key",
  "         period_key   = period_key  -- period kept",
  "-- period kept")

m("the sample uses the old padding", F,
  "    v_prefix, v_period_key, p_next_value, p_padding, v_suffix);",
  "    v_prefix, v_period_key, p_next_value, v_seq.padding, v_suffix);  -- old pad",
  "-- old pad")

m("CONTROL", F,
  "  v_period_key text;",
  "  v_period_key text;  -- control",
  "-- control")
