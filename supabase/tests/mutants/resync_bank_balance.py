# Mutants for public.resync_bank_balance (0175) -- a bank account's
# balance rebuilt from its opening figure and every POSTED line on its
# own ledger account, by somebody who may post, and that account alone.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0175_write_down_what_production_already_does.sql \
#       supabase/tests/bank_balance_resync.sql \
#       supabase/tests/mutants/resync_bank_balance.py
#
# RESULT: 7 of 8 killed by `bank_balance_resync.sql`, the control
# surviving. "An account that does not exist" only after its message was
# asserted -- the permission check refuses a null company too.
#
# EQUIVALENT: "draft and void journals count". Nothing writes a journal
# that is not posted (0102 stopped reverse_gl_entry voiding the original,
# the column defaults to 'posted', the ledger is closed to the API), so
# removing the filter changes no answer -- the test file's own header
# says so, and this sweep agrees.

m("an account that does not exist is not said so",
  "resync_bank_balance",
  "  if not found then\n    raise exception 'Bank account % not found', p_bank_account_id;",
  "  if false then  -- no such account\n    raise exception 'Bank account % not found', p_bank_account_id;",
  "-- no such account")

m("anybody rebuilds a balance",
  "resync_bank_balance",
  "  if not app.can_post(v_bank.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("draft and void journals count",
  "resync_bank_balance",
  "     and e.status = 'posted';",
  "     and true;  -- any status",
  "-- any status")

m("credits and debits the wrong way round",
  "resync_bank_balance",
  "  select coalesce(sum(l.debit - l.credit), 0) into v_balance",
  "  select coalesce(sum(l.credit - l.debit), 0) into v_balance  -- reversed",
  "-- reversed")

m("the opening figure is left out",
  "resync_bank_balance",
  "     set current_balance = v_bank.opening_balance + v_balance",
  "     set current_balance = v_balance  -- no opening",
  "-- no opening")

m("the balance is not written back",
  "resync_bank_balance",
  "     set current_balance = v_bank.opening_balance + v_balance\n   where id = p_bank_account_id;",
  "     set current_balance = current_balance  -- not written\n   where id = p_bank_account_id;",
  "-- not written")

m("every account of the company is overwritten",
  "resync_bank_balance",
  "     set current_balance = v_bank.opening_balance + v_balance\n   where id = p_bank_account_id;",
  "     set current_balance = v_bank.opening_balance + v_balance\n   where org_id = v_bank.org_id;  -- every account",
  "-- every account")

m("what is returned is not what was written",
  "resync_bank_balance",
  "  return v_bank.opening_balance + v_balance;",
  "  return v_balance;  -- returns less",
  "-- returns less")

m("CONTROL: a comment inside the block",
  "resync_bank_balance",
  "  if not app.can_post(v_bank.org_id) then",
  "  if not app.can_post(v_bank.org_id) then  -- (control)",
  "(control)")
