# Mutants for public.apply_deposit (0747) -- a customer's deposit put
# against an invoice, or ours against a supplier's bill: Dr the deposit
# account Cr the control (or the other way), an allocation that moves
# the document, and since 0747 the day it happened written on that
# allocation so the aged listings can read it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0747_the_three_ways_of_being_paid_the_listings_never_saw.sql \
#       supabase/tests/deposits.sql \
#       supabase/tests/mutants/apply_deposit.py
#
# then again against `aged_balances.sql`, which is where `applied_on`
# is read. The function was swept once before (deposits.sql's "Wang
# Muka" block records it: five of seventeen, and the assertions that
# took it the rest of the way); the mutants were not kept then. These
# are.
#
# RESULT: (pending)

m("a stranger applies a deposit",
  "apply_deposit",
  "  if not app.can_write_module(v_note.org_id,",
  "  if false and not app.can_write_module(v_note.org_id,  -- stranger",
  "-- stranger")

m("a voided deposit is applied",
  "apply_deposit",
  "  if v_note.status = 'void' then\n    raise exception 'That deposit was voided.'",
  "  if false then  -- void applied\n    raise exception 'That deposit was voided.'",
  "-- void applied")

m("nothing is applied",
  "apply_deposit",
  "  if v_amount <= 0 then",
  "  if v_amount < 0 then  -- zero applied",
  "-- zero applied")

m("more than the deposit holds is applied",
  "apply_deposit",
  "  if v_amount > v_note.balance_amount then",
  "  if false then  -- over deposit",
  "-- over deposit")

m("another company's invoice is settled",
  "apply_deposit",
  "     where d.id = p_document and d.org_id = v_note.org_id\n       and d.doc_type = 'invoice' and d.deleted_at is null;",
  "     where d.id = p_document  -- any org\n       and d.doc_type = 'invoice' and d.deleted_at is null;",
  "-- any org")

m("a deleted invoice is settled",
  "apply_deposit",
  "       and d.doc_type = 'invoice' and d.deleted_at is null;",
  "       and d.doc_type = 'invoice';  -- deleted",
  "-- deleted")

m("a document that is not outstanding is settled",
  "apply_deposit",
  "  if v_status not in ('posted', 'partial') then",
  "  if false then  -- any status",
  "-- any status")

m("a deposit in another currency is applied",
  "apply_deposit",
  "  if v_cur <> v_note.currency then",
  "  if false then  -- any currency",
  "-- any currency")

m("another party's deposit is applied",
  "apply_deposit",
  "  if v_contact <> v_note.contact_id then",
  "  if false then  -- any party",
  "-- any party")

m("more than the invoice owes is applied",
  "apply_deposit",
  "  if v_amount > v_bal then",
  "  if false then  -- over invoice",
  "-- over invoice")

m("the date somebody typed is thrown away",
  "apply_deposit",
  "  v_on   := coalesce(p_date, app.today());",
  "  v_on   := app.today();  -- typed date lost",
  "-- typed date lost")

m("a customer's own receivable account is ignored for 1210",
  "apply_deposit",
  "    select coalesce(c.receivable_account_id,\n                    (select a.id from public.accounts a\n                      where a.org_id = v_note.org_id and a.code = '1210'))",
  "    select coalesce(null::uuid,  -- 1210 always\n                    (select a.id from public.accounts a\n                      where a.org_id = v_note.org_id and a.code = '1210'))",
  "-- 1210 always")

m("a supplier's own payable account is ignored for 2110",
  "apply_deposit",
  "    select coalesce(c.payable_account_id,\n                    (select a.id from public.accounts a\n                      where a.org_id = v_note.org_id and a.code = '2110'))",
  "    select coalesce(null::uuid,  -- 2110 always\n                    (select a.id from public.accounts a\n                      where a.org_id = v_note.org_id and a.code = '2110'))",
  "-- 2110 always")

m("a customer's deposit is applied the wrong way round",
  "apply_deposit",
  "      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,\n        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,\n        'debit', v_amount, 'credit', 0),",
  "      jsonb_build_object('account_id', v_held, 'contact_id', v_note.contact_id,\n        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,\n        'debit', 0, 'credit', v_amount),  -- flipped\n      jsonb_build_object('account_id', v_ctrl, 'contact_id', v_note.contact_id,\n        'description', 'Deposit ' || v_note.deposit_no || ' to ' || v_no,\n        'debit', v_amount, 'credit', 0),",
  "-- flipped")

m("the allocation does not say when (customer)",
  "apply_deposit",
  "      (org_id, deposit_id, invoice_id, amount, allocated_by, applied_on)\n    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);",
  "      (org_id, deposit_id, invoice_id, amount, allocated_by, applied_on)\n    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), null);  -- no day",
  "-- no day")

m("the allocation says today, not the day typed (customer)",
  "apply_deposit",
  "      (org_id, deposit_id, invoice_id, amount, allocated_by, applied_on)\n    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);",
  "      (org_id, deposit_id, invoice_id, amount, allocated_by, applied_on)\n    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), app.today());  -- today",
  "-- today")

m("the allocation does not say when (supplier)",
  "apply_deposit",
  "      (org_id, deposit_id, bill_id, amount, allocated_by, applied_on)\n    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), v_on);",
  "      (org_id, deposit_id, bill_id, amount, allocated_by, applied_on)\n    values (v_note.org_id, p_deposit, p_document, v_amount, auth.uid(), null);  -- no day s",
  "-- no day s")

m("the journal is dated today, not the day typed",
  "apply_deposit",
  "    v_note.org_id, v_on, 'deposit', v_lines,",
  "    v_note.org_id, app.today(), 'deposit', v_lines,  -- journal today",
  "-- journal today")

m("the deposit's balance is never recomputed",
  "apply_deposit",
  "  perform app.refresh_deposit(p_deposit);",
  "  -- no refresh",
  "-- no refresh")

m("CONTROL: a comment inside the block",
  "apply_deposit",
  "    -- The asset is used up by the bill it was paid against.",
  "    -- CONTROL\n    -- The asset is used up by the bill it was paid against.",
  "-- CONTROL")
