# Mutants for app.post_sales_document_internal -- the journal every
# invoice, credit note, debit note and refund note posts.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0691_the_matter_a_bill_and_an_invoice_belong_to.sql \
#       supabase/tests/control_accounts.sql \
#       supabase/tests/mutants/post_sales_document.py
#
# NOTE: the function is declared `CREATE OR REPLACE FUNCTION` in UPPER
# CASE in 0691. A case-sensitive grep does not find it, which is also
# how 0530 hid from a search for calc_pcb. `mutate_sql.py` reads with
# re.I and refuses a superseded migration, so let it find the file.
#
# RESULT, 5 October: 8 mutants, all accounted for, across TWELVE files.
# No single file kills more than three.
#
#   control_accounts.sql     the contact's own receivable account
#                            ignored (its whole purpose), and a
#                            receivable line with both sides positive
#                            (a check constraint)
#   credit_note_return.sql   the credit-note sign, and the exchange rate
#   revenue_recognition.sql  the deferral dropped, and a credit note
#                            opening a deferral of its own
#   sst_return_declares_what_was_charged.sql
#                            output tax moved off 2130 -- caught by that
#                            file's positive control, "there is tax to
#                            declare in the first place". NEARLY
#                            reported as a statutory gap after nine
#                            files; it was the tenth that killed it.
#   control_accounts.sql     the debit-note sign -- but only after 5
#                            October, because:
#
# THE REAL GAP. Adding 'debit_note' to the credit-note sign list is a
# one-word edit that REVERSES the journal, and it survived twelve files.
# The type is handled by the function and required by the e-Invoice
# rules, and the two places that build one never get a journal out of
# it: credit_control.sql posts one only to watch the credit limit REFUSE
# it, and sst_summary.sql inserts a row already marked 'posted' without
# going through the function. A reversed debit note moves a customer's
# balance the wrong way by twice its value and balances perfectly.
# Two assertions were added to control_accounts.sql and it now dies.

m("a contact's own receivable account is ignored, so everything goes to 1210",
  "post_sales_document_internal",
  "  select coalesce(c.receivable_account_id,\n"
  "                  (select id from public.accounts\n"
  "                    where org_id = v_doc.org_id and code = '1210'))",
  "  select coalesce(null::uuid,\n"
  "                  (select id from public.accounts\n"
  "                    where org_id = v_doc.org_id and code = '1210'))",
  "coalesce(null::uuid,")

m("output tax is credited to the rounding account",
  "post_sales_document_internal",
  "  select id into v_tax_account from public.accounts\n"
  "   where org_id = v_doc.org_id and code = '2130';",
  "  select id into v_tax_account from public.accounts\n"
  "   where org_id = v_doc.org_id and code = '4990';  -- tax to rounding",
  "-- tax to rounding")

m("a credit note is posted the same way round as an invoice",
  "post_sales_document_internal",
  "  v_sign := case when v_doc.doc_type in ('credit_note', 'refund_note')"
  " then -1 else 1 end;",
  "  v_sign := 1;  -- sign dropped",
  "-- sign dropped")

m("a debit note is reversed like a credit note",
  "post_sales_document_internal",
  "in ('credit_note', 'refund_note') then -1 else 1 end;",
  "in ('credit_note', 'refund_note', 'debit_note') then -1 else 1 end;",
  "'refund_note', 'debit_note') then -1")

m("the exchange rate is ignored, so a foreign invoice posts at face value",
  "post_sales_document_internal",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := 1;  -- rate dropped",
  "-- rate dropped")

m("the receivable line debits and credits the same amount",
  "post_sales_document_internal",
  "    'debit',       greatest(v_amount, 0),\n"
  "    'credit',      greatest(-v_amount, 0),",
  "    'debit',       greatest(v_amount, 0),\n"
  "    'credit',      greatest(v_amount, 0),  -- both sides positive",
  "-- both sides positive")

m("an unearned line credits revenue on the day after all",
  "post_sales_document_internal",
  "    if v_line.service_start is not null and v_sign = 1 then",
  "    if false then  -- deferral dropped",
  "-- deferral dropped")

m("a credit note opens a deferral of its own",
  "post_sales_document_internal",
  "    if v_line.service_start is not null and v_sign = 1 then",
  "    if v_line.service_start is not null then  -- sign test dropped",
  "-- sign test dropped")

m("CONTROL -- a comment inside the function block",
  "post_sales_document_internal",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
