# Mutants for public.platform_close_account (0619) -- the operator closes
# a login, a company or a ledger account from the console: platform
# administrators only; never the operator's own login from here; a
# ledger account must exist and not be closed already, is recorded in
# the closure log with what it was (code, name, whether active), and is
# then switched off AND marked deleted; any other kind is refused.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0619_gone_from_the_product_not_from_the_record.sql \
#       supabase/tests/account_closure.sql \
#       supabase/tests/mutants/platform_close_account.py
#
# RESULT: 8 mutants and a control, all killed by `account_closure.sql`;
# one before its rule-by-rule block (somebody who is not an operator).
# The file's ledger close was of an account the ledger revives at the
# next posting, and it read the account only after that -- so nothing
# saw the state the close itself leaves, and no refusal was asked for.

m("anybody closes accounts from the console",
  "platform_close_account",
  "  if not app.is_platform_admin() then\n    raise exception 'Platform administrator access required'\n      using errcode = '42501';\n  end if;\n\n  if p_kind = 'user' then",
  "  if false then  -- whoever asks\n    raise exception 'Platform administrator access required'\n      using errcode = '42501';\n  end if;\n\n  if p_kind = 'user' then",
  "-- whoever asks")

m("the operator closes their own login from the console",
  "platform_close_account",
  "    if p_subject_id = auth.uid() then",
  "    if false then  -- own login",
  "-- own login")

m("a ledger account that does not exist is not said so",
  "platform_close_account",
  "    if v_a.id is null then\n      raise exception 'No such account.'",
  "    if false then  -- no such account\n      raise exception 'No such account.'",
  "-- no such account")

m("a ledger account is closed twice",
  "platform_close_account",
  "    if v_a.deleted_at is not null then",
  "    if false then  -- twice",
  "-- twice")

m("the closure does not record whether it was active",
  "platform_close_account",
  "                         'was_active', v_a.is_active),",
  "                         'was_active', true),  -- always active",
  "-- always active")

m("a closed ledger account stays switched on",
  "platform_close_account",
  "       set is_active = false, deleted_at = now() where id = v_a.id;",
  "       set deleted_at = now() where id = v_a.id;  -- still active",
  "-- still active")

m("a closed ledger account is not marked deleted",
  "platform_close_account",
  "       set is_active = false, deleted_at = now() where id = v_a.id;",
  "       set is_active = false where id = v_a.id;  -- not deleted",
  "-- not deleted")

m("an unknown kind is quietly ignored",
  "platform_close_account",
  "  raise exception 'Unknown kind of account: %', p_kind",
  "  return null;  -- ignored\n  raise exception 'Unknown kind of account: %', p_kind",
  "-- ignored")

m("CONTROL: a comment inside the block",
  "platform_close_account",
  "    if v_a.deleted_at is not null then",
  "    if v_a.deleted_at is not null then  -- (control)",
  "(control)")
