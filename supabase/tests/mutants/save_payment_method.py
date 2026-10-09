# Mutants for public.save_payment_method (0635) -- a way of being paid,
# with the bank it lands in and the fee the bank takes: somebody who
# can write; a name, trimmed; at most one default, so making this one
# the default clears the OTHER default of THIS company first; charges
# left out are nought; an edit finds only this company's live method,
# and one that is not there is said so.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0635_the_fee_the_bank_took_and_where_it_lands.sql \
#       supabase/tests/payment_methods.sql \
#       supabase/tests/mutants/save_payment_method.py
#
# RESULT: 10 mutants and a control, all killed by `payment_methods.sql`;
# three before its rule-by-rule block. The file saved new methods with
# clean names in one company and never edited one, so trimming, the
# company scope of clearing a default, every edit refusal and an edited
# fee were unasked.

m("anybody saves a payment method",
  "save_payment_method",
  "  if not app.can_write(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a method with a blank name is saved",
  "save_payment_method",
  "  if coalesce(trim(p_name), '') = '' then",
  "  if p_name is null then  -- blank will do",
  "-- blank will do")

m("a new default leaves the old one standing",
  "save_payment_method",
  "  if p_is_default then\n    update public.payment_methods set is_default = false",
  "  if false then  -- old default kept\n    update public.payment_methods set is_default = false",
  "-- old default kept")

m("a new default clears other companies' defaults",
  "save_payment_method",
  "     where org_id = p_org_id and is_default and deleted_at is null\n       and (p_id is null or id <> p_id);",
  "     where is_default and deleted_at is null  -- every company\n       and (p_id is null or id <> p_id);",
  "-- every company")

m("a new method's name is kept untrimmed",
  "save_payment_method",
  "      p_org_id, trim(p_name), p_payment_mode_code, p_bank_account_id,",
  "      p_org_id, p_name, p_payment_mode_code, p_bank_account_id,  -- untrimmed",
  "-- untrimmed")

m("an edited name is kept untrimmed",
  "save_payment_method",
  "      name = trim(p_name),",
  "      name = p_name,  -- untrimmed",
  "-- untrimmed")

m("an edit reaches another company's method",
  "save_payment_method",
  "     where id = p_id and org_id = p_org_id and deleted_at is null",
  "     where id = p_id and deleted_at is null  -- any company",
  "-- any company")

m("an edit reaches an archived method",
  "save_payment_method",
  "     where id = p_id and org_id = p_org_id and deleted_at is null",
  "     where id = p_id and org_id = p_org_id  -- archived too",
  "-- archived too")

m("an edit of nothing is not said so",
  "save_payment_method",
  "    if v_id is null then\n      raise exception 'Payment method % not found'",
  "    if false then  -- nothing edited\n      raise exception 'Payment method % not found'",
  "-- nothing edited")

m("an edit leaves the fee as it was",
  "save_payment_method",
  "      charge_percent = coalesce(p_charge_percent, 0),",
  "      charge_percent = charge_percent,  -- fee kept",
  "-- fee kept")

m("CONTROL: a comment inside the block",
  "save_payment_method",
  "  if coalesce(trim(p_name), '') = '' then",
  "  if coalesce(trim(p_name), '') = '' then  -- (control)",
  "(control)")
