# Mutants for public.create_contra -- setting what a customer owes us
# against what we owe the same party as a supplier.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/contra.sql \
#       supabase/tests/mutants/create_contra.py
#
# then again against `allocation_party.sql`, the other file reaching it.
#
# First target from the NINETEEN functions that were invisible to
# `scripts/mutation_targets.py` until its dead `app.post_journal`
# signature was replaced with the real `app.create_gl_entry_internal`.
# Three definitions, two test files.
#
# RESULT, 5 October: 25 mutants, FOURTEEN killed on the first run and
# ten survived. `allocation_party.sql`, the only other file reaching it,
# killed nothing new. 23 of 25 killed after the work; the two left are
# proven equivalent.
#
# THE EIGHT GAPS, and the largest was a fixture collapse worth naming:
# every contra in the suite used ONE contact for both sides. But
# `app.same_party` allows TWO -- the whole point of
# `0272_the_customer_who_is_also_the_supplier` is that a party may be
# kept as two records carrying one TIN -- and with one contact,
#
#   the customer IS the supplier
#   so the receivable line's contact IS the payable line's contact
#   and the note's customer_contact_id IS its supplier_contact_id
#
# so three separate claims had the same value and none could be tested.
# NOTHING IN THE SUITE CONTRA'D TWO RECORDS OF ONE PARTY AT ALL, which
# is the case the function's hardest condition exists for.
#
# The other five: the two module rights (which had to be defeated by
# DIFFERENT means, because `sales` is a core module a company always
# holds while `purchases` is not -- so one needed a company without
# purchases and the other a clerk with sales set to `read`), the
# credit-note-as-invoice half of a shared `if`, the contact's own
# control accounts, and the no-control-accounts refusal.
#
# THE TWO EQUIVALENTS, proven by shape rather than by survival:
#
#  1. dropping `deleted_at is null` from the SEED lookup. The loop below
#     looks every invoice up again WITH the filter, including the first,
#     and raises the same `No such invoice.` with the same P0002. An
#     assertion that a deleted invoice is refused was added anyway --
#     the behaviour is worth pinning -- and it does NOT kill this
#     mutant, which is the clearest possible demonstration of what an
#     equivalent mutant is.
#  2. building the journal from `v_bill_tot` instead of `v_inv_tot`. By
#     that line `v_inv_tot <> v_bill_tot` has already raised, so the two
#     are the same number by construction. Proven the same way as the
#     currency equivalence in record_group_payment: the mutant that
#     DISABLES the equal-sides check is killed, so the check
#     demonstrably fires.
#
# A contra is defined by two conditions that nothing else in the schema
# has, and both get mutants:
#
#   * the SAME PARTY on both sides, which `app.same_party` allows to be
#     two different contacts carrying the same TIN. A fixture using one
#     contact for both roles cannot tell "the same contact" from "the
#     same party".
#   * the two sides EQUAL. A contra cancels; a difference is something
#     somebody still has to pay.
#
# And a shape worth a mutant of its own: the note is INSERTED with
# `amount = 1` and the customer contact in BOTH contact columns, because
# the allocations must point at a row that exists and neither column is
# nullable -- then corrected at the end. Dropping the correction leaves
# a contra note claiming one ringgit and the customer as its own
# supplier, with a correct journal beside it.
#
# One mutant below is EXPECTED to be equivalent, and is included to be
# proven rather than assumed: the journal is built from `v_inv_tot`, and
# by that line `v_inv_tot <> v_bill_tot` has already raised -- so using
# `v_bill_tot` instead cannot change a figure.

m("a user who may write sales but not purchases can contra",
  "create_contra",
  "     or not app.can_write_module(p_org, 'purchases') then",
  "     or false then  -- purchases guard dropped",
  "-- purchases guard dropped")

m("a user who may write purchases but not sales can contra",
  "create_contra",
  "  if not app.can_write_module(p_org, 'sales')\n"
  "     or not app.can_write_module(p_org, 'purchases') then",
  "  if false\n     or not app.can_write_module(p_org, 'purchases') then"
  "  -- sales guard dropped",
  "-- sales guard dropped")

m("a one-sided contra is allowed",
  "create_contra",
  "  if jsonb_array_length(coalesce(p_invoices, '[]'::jsonb)) = 0\n"
  "     or jsonb_array_length(coalesce(p_bills, '[]'::jsonb)) = 0 then",
  "  if false then  -- both-sides guard dropped",
  "-- both-sides guard dropped")

m("a deleted invoice may seed the note",
  "create_contra",
  "   where d.id = (p_invoices->0->>'document')::uuid and d.org_id = p_org\n"
  "     and d.deleted_at is null;",
  "   where d.id = (p_invoices->0->>'document')::uuid and d.org_id = p_org;"
  "  -- deleted_at dropped on the seed",
  "-- deleted_at dropped on the seed")

m("a credit note can be contra'd as though it were an invoice",
  "create_contra",
  "    if v_doc.doc_type <> 'invoice' or v_doc.status not in"
  " ('posted', 'partial') then",
  "    if v_doc.status not in ('posted', 'partial') then"
  "  -- invoice doc_type check dropped",
  "-- invoice doc_type check dropped")

m("a DRAFT invoice can be contra'd",
  "create_contra",
  "    if v_doc.doc_type <> 'invoice' or v_doc.status not in"
  " ('posted', 'partial') then",
  "    if v_doc.doc_type <> 'invoice' or v_doc.status not in"
  " ('posted', 'partial', 'draft') then  -- draft invoice allowed",
  "-- draft invoice allowed")

m("a foreign-currency invoice can be contra'd",
  "create_contra",
  "    if v_doc.currency <> v_base then\n      raise exception\n"
  "        'Invoice % is in %,",
  "    if false then  -- invoice currency check dropped\n"
  "      raise exception\n        'Invoice % is in %,",
  "-- invoice currency check dropped")

m("a contra line for nothing is allowed on the invoice side",
  "create_contra",
  "    v_amt := round((v_e->>'amount')::numeric, 2);\n"
  "    if v_amt <= 0 then\n"
  "      raise exception 'A contra line has to be for something.'\n"
  "        using errcode = '23514';\n    end if;\n"
  "    if v_amt > v_doc.balance_amount then\n      raise exception\n"
  "        'Invoice % has % outstanding",
  "    v_amt := round((v_e->>'amount')::numeric, 2);\n"
  "    if v_amt < 0 then  -- zero allowed on the invoice side\n"
  "      raise exception 'A contra line has to be for something.'\n"
  "        using errcode = '23514';\n    end if;\n"
  "    if v_amt > v_doc.balance_amount then\n      raise exception\n"
  "        'Invoice % has % outstanding",
  "-- zero allowed on the invoice side")

m("contra'ing exactly what the invoice has outstanding is refused",
  "create_contra",
  "    if v_amt > v_doc.balance_amount then\n      raise exception\n"
  "        'Invoice % has % outstanding",
  "    if v_amt >= v_doc.balance_amount then  -- exact invoice refused\n"
  "      raise exception\n        'Invoice % has % outstanding",
  "-- exact invoice refused")

m("invoices of two different customers may be contra'd together",
  "create_contra",
  "    elsif v_cust <> v_doc.contact_id then\n      raise exception\n"
  "        'Those invoices are not all the same customer.'",
  "    elsif false then  -- same-customer check dropped\n"
  "      raise exception\n"
  "        'Those invoices are not all the same customer.'",
  "-- same-customer check dropped")

m("a DRAFT bill can be contra'd",
  "create_contra",
  "    if v_doc.doc_type <> 'bill' or v_doc.status not in"
  " ('posted', 'partial') then",
  "    if v_doc.doc_type <> 'bill' or v_doc.status not in"
  " ('posted', 'partial', 'draft') then  -- draft bill allowed",
  "-- draft bill allowed")

m("contra'ing exactly what the bill has outstanding is refused",
  "create_contra",
  "    if v_amt > v_doc.balance_amount then\n      raise exception\n"
  "        'Bill % has % outstanding",
  "    if v_amt >= v_doc.balance_amount then  -- exact bill refused\n"
  "      raise exception\n        'Bill % has % outstanding",
  "-- exact bill refused")

m("bills of two different suppliers may be contra'd together",
  "create_contra",
  "    elsif v_sup <> v_doc.contact_id then\n      raise exception\n"
  "        'Those bills are not all the same supplier.'",
  "    elsif false then  -- same-supplier check dropped\n"
  "      raise exception\n"
  "        'Those bills are not all the same supplier.'",
  "-- same-supplier check dropped")

m("THE FIRST DEFINING CONDITION: two different parties may contra",
  "create_contra",
  "  if not app.same_party(v_cust, v_sup) then",
  "  if false then  -- same-party check dropped",
  "-- same-party check dropped")

m("THE SECOND: the two sides need not come to the same figure",
  "create_contra",
  "  if v_inv_tot <> v_bill_tot then",
  "  if false then  -- equal-sides check dropped",
  "-- equal-sides check dropped")

m("the customer's own receivable account is ignored for 1210",
  "create_contra",
  "  select coalesce(c.receivable_account_id,",
  "  select coalesce(null::uuid,  -- contact receivable ignored",
  "-- contact receivable ignored")

m("the supplier's own payable account is ignored for 2110",
  "create_contra",
  "  select coalesce(c.payable_account_id,",
  "  select coalesce(null::uuid,  -- contact payable ignored",
  "-- contact payable ignored")

m("a company with no control accounts contras anyway",
  "create_contra",
  "  if v_ar is null or v_ap is null then",
  "  if false then  -- control-account guard dropped",
  "-- control-account guard dropped")

m("the receivable is debited and the payable credited",
  "create_contra",
  "    jsonb_build_object('account_id', v_ap, 'contact_id', v_sup,\n"
  "      'description', 'Contra settlement', 'debit', v_inv_tot, 'credit', 0),",
  "    jsonb_build_object('account_id', v_ap, 'contact_id', v_sup,\n"
  "      'description', 'Contra settlement', 'debit', 0, 'credit', v_inv_tot),"
  "  -- payable side swapped",
  "-- payable side swapped")

m("the contact on each journal line is the other party",
  "create_contra",
  "    jsonb_build_object('account_id', v_ap, 'contact_id', v_sup,",
  "    jsonb_build_object('account_id', v_ap, 'contact_id', v_cust,"
  "  -- payable line's contact swapped",
  "-- payable line's contact swapped")

# Expected EQUIVALENT: by this line `v_inv_tot <> v_bill_tot` has
# already raised, so the two are the same number.
m("the journal is built from the bill side instead of the invoice side",
  "create_contra",
  "      'description', 'Contra settlement', 'debit', v_inv_tot, 'credit', 0),",
  "      'description', 'Contra settlement', 'debit', v_bill_tot, 'credit', 0),"
  "  -- journal reads the bill total",
  "-- journal reads the bill total")

m("the note keeps the seeded amount of one ringgit",
  "create_contra",
  "         amount = v_inv_tot\n   where id = v_id;",
  "         amount = 1  -- seeded amount not corrected\n   where id = v_id;",
  "-- seeded amount not corrected")

m("the note keeps the customer as its own supplier",
  "create_contra",
  "     set customer_contact_id = v_cust,\n         supplier_contact_id = v_sup,",
  "     set customer_contact_id = v_cust,\n         supplier_contact_id = v_cust,"
  "  -- seeded supplier not corrected",
  "-- seeded supplier not corrected")

m("the note does not remember its journal",
  "create_contra",
  "  update public.contra_notes set gl_entry_id = v_entry where id = v_id;",
  "  update public.contra_notes set gl_entry_id = null where id = v_id;"
  "  -- entry not recorded",
  "-- entry not recorded")

m("CONTROL -- a comment inside the function block",
  "create_contra",
  "  v_cust := null;",
  "  v_cust := null;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
