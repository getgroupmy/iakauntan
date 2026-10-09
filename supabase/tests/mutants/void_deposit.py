# Mutants for public.void_deposit (0421) -- a deposit taken in error,
# undone: it must exist; the caller must write the module its side
# belongs to (sales for a customer's, purchases for a supplier's); not
# twice; not once any of it has been applied, given back or kept; never
# without a reason. Its entry reversed TODAY (0421: a void is dated the
# day it is made, unlike a bank transfer's), the bank's running figure
# moved back -- down for money that came in, up for money that went out
# -- and the note left void, empty, and saying who, why and when.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/deposits.sql \
#       supabase/tests/mutants/void_deposit.py
#
# RESULT: 20 mutants and a control, all killed by `deposits.sql`;
# thirteen before its rule-by-rule block. Every deposit the file voided
# was taken today, so a reversal dated the deposit's day and one dated
# today were the same entry; and nothing read who voided it, when, why
# (trimmed), what the function handed back, or a deposit that does not
# exist.

m("a deposit that does not exist is not said so",
  "void_deposit",
  "  if v_note.id is null then\n    raise exception 'No such deposit.'",
  "  if false then  -- no such deposit\n    raise exception 'No such deposit.'",
  "-- no such deposit")

m("anybody voids",
  "void_deposit",
  "  if not app.can_write_module(v_note.org_id,",
  "  if false and not app.can_write_module(v_note.org_id,  -- whoever asks",
  "-- whoever asks")

m("a supplier's deposit is checked against sales",
  "void_deposit",
  "        case when v_note.kind = 'customer' then 'sales' else 'purchases' end) then",
  "        'sales') then  -- sales always",
  "-- sales always")

m("a customer's deposit is checked against purchases",
  "void_deposit",
  "        case when v_note.kind = 'customer' then 'sales' else 'purchases' end) then",
  "        'purchases') then  -- purchases always",
  "-- purchases always")

m("a void deposit is voided again",
  "void_deposit",
  "  if v_note.status = 'void' then",
  "  if false then  -- twice",
  "-- twice")

m("a used deposit is voided",
  "void_deposit",
  "  if v_note.balance_amount <> v_note.amount then",
  "  if false then  -- already used",
  "-- already used")

m("a blank reason will do",
  "void_deposit",
  "  if coalesce(trim(p_reason), '') = '' then",
  "  if p_reason is null then  -- blank will do",
  "-- blank will do")

m("the entry is left in the ledger",
  "void_deposit",
  "  if v_note.gl_entry_id is not null then",
  "  if false then  -- ledger left",
  "-- ledger left")

m("the reversal is dated the deposit's day",
  "void_deposit",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, app.today());",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, v_note.deposit_date);  -- deposit's day",
  "-- deposit's day")

m("the bank is not moved back",
  "void_deposit",
  "  if v_note.bank_account_id is not null then",
  "  if false then  -- bank left",
  "-- bank left")

m("money that came in is added again",
  "void_deposit",
  "             + case when v_note.kind = 'customer' then -v_note.amount",
  "             + case when v_note.kind = 'customer' then v_note.amount  -- in added",
  "-- in added")

m("money that went out is taken again",
  "void_deposit",
  "                    else v_note.amount end",
  "                    else -v_note.amount end  -- out taken",
  "-- out taken")

m("the note is not marked void",
  "void_deposit",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set void_entry_id = v_rev, void_reason = trim(p_reason),  -- not void",
  "-- not void")

m("the note forgets its reversal",
  "void_deposit",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set status = 'void', void_reason = trim(p_reason),  -- reversal forgotten",
  "-- reversal forgotten")

m("the reason is kept untrimmed",
  "void_deposit",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set status = 'void', void_entry_id = v_rev, void_reason = p_reason,  -- untrimmed",
  "-- untrimmed")

m("the reason is not kept",
  "void_deposit",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set status = 'void', void_entry_id = v_rev,  -- no reason",
  "-- no reason")

m("nobody is said to have voided it",
  "void_deposit",
  "         voided_at = now(), voided_by = auth.uid(), balance_amount = 0",
  "         voided_at = now(), balance_amount = 0  -- by nobody",
  "-- by nobody")

m("nor when",
  "void_deposit",
  "         voided_at = now(), voided_by = auth.uid(), balance_amount = 0",
  "         voided_by = auth.uid(), balance_amount = 0  -- no time",
  "-- no time")

m("the void note can still be spent",
  "void_deposit",
  "         voided_at = now(), voided_by = auth.uid(), balance_amount = 0",
  "         voided_at = now(), voided_by = auth.uid()  -- still spendable",
  "-- still spendable")

m("the reversal is not handed back",
  "void_deposit",
  "  return v_rev;",
  "  return null;  -- nothing back",
  "-- nothing back")

m("CONTROL: a comment inside the block",
  "void_deposit",
  "  if v_note.status = 'void' then",
  "  if v_note.status = 'void' then  -- (control)",
  "(control)")
