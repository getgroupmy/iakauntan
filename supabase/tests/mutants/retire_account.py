# Mutants for public.retire_account (0619) -- a ledger account closed: by
# somebody who may post, never twice, never one the ledger posts to by
# number, never one with live accounts under it, the closure recorded
# with what the account was, and the account switched off and hidden
# but kept.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0619_gone_from_the_product_not_from_the_record.sql \
#       supabase/tests/account_closure.sql \
#       supabase/tests/mutants/retire_account.py
#
# RESULT: 11 mutants and a control, all killed across two files, the
# control surviving. `account_closure.sql` kills seven, three of them only
# after its rule-by-rule assertions (the account that does not exist,
# `was_active` and `posted_lines` -- read off an account that had always
# been on and never posted to, so the real values and hard-coded ones
# were the same); `chart_of_accounts.sql` kills the other four (who may,
# the posting-code account, and both readings of "accounts under it").

m("an account that does not exist is not said so",
  "retire_account",
  "  if v_a.id is null then\n    raise exception 'No such account.'",
  "  if false then  -- no such account\n    raise exception 'No such account.'",
  "-- no such account")

m("anybody closes an account",
  "retire_account",
  "  if not app.can_post(v_a.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an account already closed is closed again",
  "retire_account",
  "  if v_a.deleted_at is not null then\n    raise exception 'Account % is already closed.'",
  "  if false then  -- twice\n    raise exception 'Account % is already closed.'",
  "-- twice")

m("an account the ledger posts to by number is closed",
  "retire_account",
  "  if exists (select 1 from app.posting_account_codes() c\n              where c.code = v_a.code) then",
  "  if false then  -- posting code",
  "-- posting code")

m("an account with live accounts under it is closed",
  "retire_account",
  "  if exists (select 1 from public.accounts a\n              where a.parent_id = p_id and a.deleted_at is null) then",
  "  if false then  -- has children",
  "-- has children")

m("closed accounts under it still hold it open",
  "retire_account",
  "              where a.parent_id = p_id and a.deleted_at is null) then",
  "              where a.parent_id = p_id) then  -- closed children count",
  "-- closed children count")

m("the closure is not recorded",
  "retire_account",
  "    null, 'self_service', auth.uid());",
  "    null, 'self_service', auth.uid()) where false;  -- no record",
  "-- no record")

m("the closure does not say whether it was active",
  "retire_account",
  "      'was_active', v_a.is_active,",
  "      'was_active', true,  -- always active",
  "-- always active")

m("the closure does not count what was posted to it",
  "retire_account",
  "      'posted_lines', (select count(*) from public.gl_lines l\n                        where l.account_id = v_a.id)),",
  "      'posted_lines', 0),  -- nothing posted",
  "-- nothing posted")

m("the account is left switched on",
  "retire_account",
  "     set is_active = false, deleted_at = now()",
  "     set deleted_at = now()  -- still active",
  "-- still active")

m("the account is not hidden",
  "retire_account",
  "     set is_active = false, deleted_at = now()",
  "     set is_active = false  -- not hidden",
  "-- not hidden")

m("CONTROL: a comment inside the block",
  "retire_account",
  "  if not app.can_post(v_a.org_id) then",
  "  if not app.can_post(v_a.org_id) then  -- (control)",
  "(control)")
