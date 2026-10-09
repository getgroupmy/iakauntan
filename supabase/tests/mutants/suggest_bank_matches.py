# Mutants for public.suggest_bank_matches (0772, restated from 0085) --
# the candidates for a statement line: receipts for money in, supplier
# payments and expenses for money out, and since 0772 only those whose
# journal went through this line's bank account.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0772_a_statement_line_is_matched_to_its_own_account.sql \
#       supabase/tests/bank_reconciliation.sql \
#       supabase/tests/mutants/suggest_bank_matches.py
#
# RESULT: 4 mutants and a control, all killed by `bank_reconciliation.sql`
# (its `0772` block), the control surviving.
#
# The earlier filters (sign, charge, window, taken, company, posted,
# order) were swept on 5 October and are asserted in the block that
# says so; these are 0772's three.

m("receipts from any account are offered",
  "suggest_bank_matches",
  "                    where l.entry_id = r.gl_entry_id and l.account_id = v_bank_gl)",
  "                    where l.entry_id = r.gl_entry_id)  -- any account receipts",
  "-- any account receipts")

m("supplier payments from any account are offered",
  "suggest_bank_matches",
  "                    where l.entry_id = p.gl_entry_id and l.account_id = v_bank_gl)",
  "                    where l.entry_id = p.gl_entry_id)  -- any account payments",
  "-- any account payments")

m("expenses from any account are offered",
  "suggest_bank_matches",
  "                    where l.entry_id = e.gl_entry_id and l.account_id = v_bank_gl)",
  "                    where l.entry_id = e.gl_entry_id)  -- any account expenses",
  "-- any account expenses")

m("the account is never found, so nothing is offered",
  "suggest_bank_matches",
  "    from public.bank_accounts b where b.id = t.bank_account_id;",
  "    from public.bank_accounts b where false;  -- no account",
  "-- no account")

m("CONTROL: a comment inside the block",
  "suggest_bank_matches",
  "    from public.bank_accounts b where b.id = t.bank_account_id;",
  "    from public.bank_accounts b where b.id = t.bank_account_id;  -- (control)",
  "(control)")
