# Mutants for public.settle_deposit (0728) -- a deposit given back or
# kept: never more than is left, a reason for keeping one, the bank
# account the refund left named and this company's, and the right side
# of the books for a customer's deposit and for one the company paid.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0728_the_rest_of_the_money_that_went_to_the_heading.sql \
#       supabase/tests/deposits.sql \
#       supabase/tests/mutants/settle_deposit.py
#
# RESULT: 19 mutants and a control, all killed by `deposits.sql`. Five
# only after the "Settling a deposit, rule by rule" block there: a
# deposit that is not there, the deposit's own account as the default, a
# pre-0728 row naming none, somebody on purchases but not sales, and a
# SUPPLIER's refund coming back into the bank.
#
# Checked on the way: a deposit is posted in base currency at 1 because
# `create_deposit` only ever writes base-currency deposits, so settling
# one unconverted is consistent -- not 0760's defect again.

m("a deposit that does not exist is settled in silence",
  "settle_deposit",
  "  if v_note.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody settles a deposit",
  "settle_deposit",
  "  if not app.can_write_module(v_note.org_id,",
  "  if false and not app.can_write_module(v_note.org_id,  -- anybody",
  "-- anybody")

m("a supplier deposit needs sales, not purchases",
  "settle_deposit",
  "        case when v_note.kind = 'customer' then 'sales' else 'purchases' end) then",
  "        'sales') then  -- wrong module",
  "-- wrong module")

m("a voided deposit is settled",
  "settle_deposit",
  "  if v_note.status = 'void' then",
  "  if false then  -- void",
  "-- void")

m("a deposit is settled some third way",
  "settle_deposit",
  "  if p_kind not in ('refund', 'forfeit') then",
  "  if false then  -- third way",
  "-- third way")

m("a settlement of nothing is made",
  "settle_deposit",
  "  if v_amount <= 0 then",
  "  if false then  -- nothing",
  "-- nothing")

m("more is settled than is left",
  "settle_deposit",
  "  if v_amount > v_note.balance_amount then",
  "  if false then  -- overdrawn",
  "-- overdrawn")

m("a deposit is kept without a reason",
  "settle_deposit",
  "  if p_kind = 'forfeit' and coalesce(trim(p_reason), '') = '' then",
  "  if false then  -- no reason",
  "-- no reason")

m("another company's bank account is used",
  "settle_deposit",
  "        where b.id = v_bank_id and b.org_id = v_note.org_id) then",
  "        where b.id = v_bank_id) then  -- any company",
  "-- any company")

m("the deposit's own bank account is not the default",
  "settle_deposit",
  "  v_bank_id := coalesce(p_bank, v_note.bank_account_id);",
  "  v_bank_id := p_bank;  -- no default",
  "-- no default")

m("a refund from no account is allowed",
  "settle_deposit",
  "    if v_bank_id is null then\n      raise exception\n        'Say which account the refund is paid out of.",
  "    if false then  -- from nowhere\n      raise exception\n        'Say which account the refund is paid out of.",
  "-- from nowhere")

m("a kept customer deposit is a loss, not income",
  "settle_deposit",
  "                 case when v_note.kind = 'customer' then 'income' else 'expense' end);",
  "                 'expense');  -- always a loss",
  "-- always a loss")

m("a kept supplier deposit is income, not a loss",
  "settle_deposit",
  "                 case when v_note.kind = 'customer' then 'income' else 'expense' end);",
  "                 'income');  -- always income",
  "-- always income")

m("a customer deposit is settled the wrong way round",
  "settle_deposit",
  "  if v_note.kind = 'customer' then\n    -- The liability goes; the money leaves, or becomes income.",
  "  if v_note.kind <> 'customer' then  -- swapped\n    -- The liability goes; the money leaves, or becomes income.",
  "-- swapped")

m("the event does not say why",
  "settle_deposit",
  "          v_amount, nullif(trim(coalesce(p_reason, '')), ''),",
  "          v_amount, null,  -- unexplained",
  "-- unexplained")

m("a forfeit is recorded against a bank account",
  "settle_deposit",
  "          case when p_kind = 'refund' then v_bank_id end,",
  "          v_bank_id,  -- banked forfeit",
  "-- banked forfeit")

m("a refund does not move the bank balance",
  "settle_deposit",
  "  if p_kind = 'refund' then\n    update public.bank_accounts",
  "  if false then  -- unmoved\n    update public.bank_accounts",
  "-- unmoved")

m("a supplier's refund comes out of the bank, not into it",
  "settle_deposit",
  "             + case when v_note.kind = 'customer' then -v_amount else v_amount end",
  "             - v_amount  -- always out",
  "-- always out")

m("the deposit's balance is not refreshed",
  "settle_deposit",
  "  perform app.refresh_deposit(p_deposit);",
  "  perform 1;  -- stale",
  "-- stale")

m("CONTROL: a comment inside the block",
  "settle_deposit",
  "  if v_amount <= 0 then",
  "  if v_amount <= 0 then  -- (control)",
  "(control)")
