# Mutants for public.match_bank_transaction (0772, restated from 0085) --
# a statement line matched to the posted document the bank saw: by
# somebody who may post, never on a line a completed reconciliation
# holds, only to a document of this company that has a journal, whose
# journal went through THIS line's bank account (0772), never to one
# already matched to another line, and recording the journal so
# completion can see it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0772_a_statement_line_is_matched_to_its_own_account.sql \
#       supabase/tests/bank_reconciliation.sql \
#       supabase/tests/mutants/match_bank_transaction.py
#
# RESULT: 17 mutants and a control, all killed by `bank_reconciliation.sql`.
# Swept first against `0085`'s text, before `0772`: 9 of 13, the four
# alive being the line that does not exist and another company's
# payment, expense or journal -- each refused by the company filter with
# its own sentence and, without it, by a foreign key with somebody
# else's. Asserted by the whole message in the `0772` block, with the
# four mutants of the new account rule.

m("a line that does not exist is not said so",
  "match_bank_transaction",
  "  if not found then\n    raise exception 'Statement line % not found', p_transaction_id",
  "  if false then  -- no such line\n    raise exception 'Statement line % not found', p_transaction_id",
  "-- no such line")

m("anybody matches",
  "match_bank_transaction",
  "  if not app.can_post(t.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a line in a completed reconciliation is matched again",
  "match_bank_transaction",
  "  if t.reconciliation_id is not null then",
  "  if false then  -- completed",
  "-- completed")

m("a receipt of another company is matched",
  "match_bank_transaction",
  "      (select gl_entry_id from public.receipts where id = p_source_id and org_id = t.org_id)",
  "      (select gl_entry_id from public.receipts where id = p_source_id)  -- any company's receipt",
  "-- any company's receipt")

m("a supplier payment of another company is matched",
  "match_bank_transaction",
  "      (select gl_entry_id from public.purchase_payments where id = p_source_id and org_id = t.org_id)",
  "      (select gl_entry_id from public.purchase_payments where id = p_source_id)  -- any company's payment",
  "-- any company's payment")

m("an expense of another company is matched",
  "match_bank_transaction",
  "      (select gl_entry_id from public.expenses where id = p_source_id and org_id = t.org_id)",
  "      (select gl_entry_id from public.expenses where id = p_source_id)  -- any company's expense",
  "-- any company's expense")

m("a journal of another company is matched",
  "match_bank_transaction",
  "      (select id from public.gl_entries where id = p_source_id and org_id = t.org_id)",
  "      (select id from public.gl_entries where id = p_source_id)  -- any company's journal",
  "-- any company's journal")

m("a document with no journal is matched",
  "match_bank_transaction",
  "  if v_entry is null then\n    raise exception\n      'Nothing posted found",
  "  if false then  -- nothing posted\n    raise exception\n      'Nothing posted found",
  "-- nothing posted")

m("a document already matched to another line is matched again",
  "match_bank_transaction",
  "  if exists (select 1 from public.bank_transactions b\n              where b.matched_table = p_source_table",
  "  if false and exists (select 1 from public.bank_transactions b  -- twice\n              where b.matched_table = p_source_table",
  "-- twice")

m("re-matching the same line to the same document is refused",
  "match_bank_transaction",
  "                and b.id <> p_transaction_id) then",
  "                and true) then  -- not even the same line",
  "-- not even the same line")

m("the journal is not recorded on the line",
  "match_bank_transaction",
  "         gl_entry_id = v_entry, is_reconciled = true,",
  "         gl_entry_id = null, is_reconciled = true,  -- no journal",
  "-- no journal")

m("the line is not marked reconciled",
  "match_bank_transaction",
  "         gl_entry_id = v_entry, is_reconciled = true,",
  "         gl_entry_id = v_entry, is_reconciled = false,  -- not reconciled",
  "-- not reconciled")

m("the document is not recorded on the line",
  "match_bank_transaction",
  "     set matched_table = p_source_table, matched_id = p_source_id,",
  "     set matched_table = p_source_table, matched_id = null,  -- no document",
  "-- no document")


m("a document from any of the company's bank accounts is matched (0772 gone)",
  "match_bank_transaction",
  "  if not exists (select 1 from public.gl_lines l\n                  where l.entry_id = v_entry and l.account_id = v_bank.account_id) then",
  "  if false then  -- any account",
  "-- any account")

m("a document is matched if its journal touched ANY bank account",
  "match_bank_transaction",
  "                  where l.entry_id = v_entry and l.account_id = v_bank.account_id) then",
  "                  where l.entry_id = v_entry and l.account_id in (select account_id from public.bank_accounts where org_id = t.org_id)) then  -- any bank",
  "-- any bank")

m("the refusal does not say where the money went",
  "match_bank_transaction",
  "      coalesce(v_doc, 'That document'), coalesce(v_went, 'no bank account'),",
  "      coalesce(v_doc, 'That document'), 'no bank account',  -- nowhere",
  "-- nowhere")

m("the refusal does not name the document",
  "match_bank_transaction",
  "      coalesce(v_doc, 'That document'), coalesce(v_went, 'no bank account'),",
  "      'That document', coalesce(v_went, 'no bank account'),  -- unnamed",
  "-- unnamed")

m("CONTROL: a comment inside the block",
  "match_bank_transaction",
  "  if t.reconciliation_id is not null then",
  "  if t.reconciliation_id is not null then  -- (control)",
  "(control)")
