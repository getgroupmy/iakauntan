# Mutants for public.post_expense_claim (0049) -- an approved expense
# claim reaches the ledger: the expense debited by claim type, and the
# employee's money credited to accruals or to the bank that paid it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0049_hrms_claim_expense_allocation.sql \
#       supabase/tests/expense_claims.sql \
#       supabase/tests/mutants/post_expense_claim.py
#
# RESULT: 21 mutants and a control. 21 killed, eight only after a
# rule-by-rule block in `expense_claims.sql`:
#
#   the journal is dated today, does not point at the claim, carries no
#   reference, and its line says nothing of the claim -- four
#   particulars of the journal that nothing read.
#
#   a claim that does not exist, an unapproved claim, a claim with
#   nothing to post -- refusals asserted only by SQLSTATE, or not at
#   all. Without the status check an undecided claim is STILL refused
#   with 22023, by the unbalanced journal its missing approved amount
#   makes; the assertion now uses a REJECTED claim and reads the words.
#
#   accruals may be a heading -- the `not is_group` in this function is
#   the ONLY thing between a claim and a 2120 heading. The ledger takes
#   a line on a heading (manual journals post to 1120 as a ledger
#   account, by design -- `docs/handoff.md`, "The twelve accounts"), so
#   with it gone the claim posted there. Without it the claim is refused,
#   with a NOT NULL on `gl_lines.account_id` rather than a sentence, and
#   the assertion takes any refusal so as not to pin that wording.
#
# Also asserted, though no mutant reaches it: a claim paid from ANOTHER
# company's bank account is refused -- not by this function, which reads
# the bank account by id alone, but by `gl_lines_account_same_org`.

m("a claim that does not exist is posted in silence",
  "post_expense_claim",
  "  if v_claim.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody posts to the ledger",
  "post_expense_claim",
  "  if not app.can_post(v_claim.org_id) then",
  "  if false then  -- by anyone",
  "-- by anyone")

m("an unapproved claim is posted",
  "post_expense_claim",
  "  if v_claim.status <> 'approved' then",
  "  if false then  -- undecided",
  "-- undecided")

m("a posted claim is posted again",
  "post_expense_claim",
  "  if v_claim.gl_entry_id is not null then",
  "  if false then  -- twice",
  "-- twice")

m("a payroll claim is posted here too",
  "post_expense_claim",
  "  if v_claim.pay_with_payroll then",
  "  if false then  -- payroll too",
  "-- payroll too")

m("the line says nothing of the claim",
  "post_expense_claim",
  "      'description', coalesce(v_claim.title, v_claim.claim_no),",
  "      'description', 'Expense',  -- anonymous line",
  "-- anonymous line")

m("the debit is the whole claim on every line",
  "post_expense_claim",
  "      'debit', v_alloc.amount, 'credit', 0));",
  "      'debit', v_claim.approved_amount, 'credit', 0));  -- every line whole",
  "-- every line whole")

m("a claim with nothing to post is posted",
  "post_expense_claim",
  "  if jsonb_array_length(v_lines) = 0 then",
  "  if false then  -- empty",
  "-- empty")

m("the bank that paid is ignored",
  "post_expense_claim",
  "  if p_bank_account_id is not null then\n    select account_id into v_credit",
  "  if false then  -- no bank\n    select account_id into v_credit",
  "-- no bank")

m("the bank's own id is taken for its ledger account",
  "post_expense_claim",
  "    select account_id into v_credit from public.bank_accounts",
  "    select id into v_credit from public.bank_accounts  -- wrong id",
  "-- wrong id")

m("accruals are looked for in any company",
  "post_expense_claim",
  "     where org_id = v_claim.org_id and code = '2120' and not is_group limit 1;",
  "     where code = '2120' and not is_group limit 1;  -- any company",
  "-- any company")

m("accruals may be a heading",
  "post_expense_claim",
  "     where org_id = v_claim.org_id and code = '2120' and not is_group limit 1;",
  "     where org_id = v_claim.org_id and code = '2120' limit 1;  -- heading",
  "-- heading")

m("the credit is what was claimed, not approved",
  "post_expense_claim",
  "    'debit', 0, 'credit', v_claim.approved_amount));",
  "    'debit', 0, 'credit', v_claim.total_amount));  -- as claimed",
  "-- as claimed")

m("the journal is dated today",
  "post_expense_claim",
  "    p_entry_date   => v_claim.claim_date,",
  "    p_entry_date   => current_date,  -- today",
  "-- today")

m("the journal does not point at the claim",
  "post_expense_claim",
  "    p_source_id    => p_claim_id,",
  "    p_source_id    => null,  -- orphan",
  "-- orphan")

m("the journal carries no reference",
  "post_expense_claim",
  "    p_reference    => v_claim.claim_no);",
  "    p_reference    => null);  -- unreferenced",
  "-- unreferenced")

m("the claim does not carry its journal",
  "post_expense_claim",
  "     set gl_entry_id = v_entry,",
  "     set gl_entry_id = null,  -- unlinked",
  "-- unlinked")

m("the claim is not marked posted",
  "post_expense_claim",
  "         posted_at = now(),",
  "         posted_at = null,  -- unposted",
  "-- unposted")

m("an accrual marks the claim paid",
  "post_expense_claim",
  "         paid_at = case when p_bank_account_id is not null\n                        then now() else paid_at end",
  "         paid_at = now()  -- paid regardless",
  "-- paid regardless")

m("a bank payment does not mark it paid",
  "post_expense_claim",
  "         paid_at = case when p_bank_account_id is not null\n                        then now() else paid_at end",
  "         paid_at = paid_at  -- never paid",
  "-- never paid")

m("another claim is updated",
  "post_expense_claim",
  "   where id = p_claim_id;\n\n  return v_entry;",
  "   where true;  -- every claim\n\n  return v_entry;",
  "-- every claim")

m("CONTROL: a comment inside the block",
  "post_expense_claim",
  "  if jsonb_array_length(v_lines) = 0 then",
  "  if jsonb_array_length(v_lines) = 0 then  -- (control)",
  "(control)")
