# Mutants for public.allocate_with_discount and
# allocate_payment_with_discount (0760, restating 0734's) -- taking a
# settlement discount when an invoice or bill is paid: only on terms
# that offer one, inside the window, no more than offered, cash and
# discount no more than is owed, and posted at the document's rate.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0760_a_settlement_discount_is_converted.sql \
#       supabase/tests/settlement_discount.sql \
#       supabase/tests/mutants/settlement_discounts.py
#
# RESULT: 20 mutants and a control, all killed by `settlement_discount.sql`.
# The sweep was begun against 0734's text and found 0760 before it ran:
# every document in the file was in ringgit, so posting the discount
# unconverted was invisible. Five more survived the first run against
# 0760: a receipt or payment that is not there, another company's
# invoice or bill settled with this one's money by somebody who belongs
# to both, and a supplier discount on terms that offer none.

m("a discount on a dollar invoice is posted as ringgit (0734's shape)",
  "allocate_with_discount",
  "    v_disc_base := round(v_discount * coalesce(v_inv.exchange_rate, 1), 2);",
  "    v_disc_base := v_discount;  -- unconverted",
  "-- unconverted")

m("the invoice discount journal is in ringgit",
  "allocate_with_discount",
  "      v_inv.currency, coalesce(v_inv.exchange_rate, 1));",
  "      app.base_currency(v_rcp.org_id), 1);  -- base",
  "-- base")

m("a receipt that does not exist is allocated in silence",
  "allocate_with_discount",
  "  if v_rcp.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody allocates a receipt",
  "allocate_with_discount",
  "  if not app.can_post(v_rcp.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("another company's invoice is settled",
  "allocate_with_discount",
  "  if v_inv.id is null or v_inv.org_id <> v_rcp.org_id then",
  "  if v_inv.id is null then  -- any company",
  "-- any company")

m("an allocation of nothing is made",
  "allocate_with_discount",
  "  if coalesce(p_amount, 0) <= 0 then",
  "  if false then  -- nothing",
  "-- nothing")

m("a discount on terms that offer none",
  "allocate_with_discount",
  "    if v_offer.deadline is null then",
  "    if false then  -- no offer",
  "-- no offer")

m("a discount after it ran out",
  "allocate_with_discount",
  "    if v_offer.deadline < v_as_at then",
  "    if false then  -- expired",
  "-- expired")

m("more discount than the terms allow",
  "allocate_with_discount",
  "    if v_discount > v_offer.amount then",
  "    if false then  -- generous",
  "-- generous")

m("cash and discount beyond what is owed",
  "allocate_with_discount",
  "    if round(p_amount + v_discount, 2)\n       > round(coalesce(v_inv.balance_amount, 0), 2) then",
  "    if false then  -- overpaid",
  "-- overpaid")

m("the discount is not posted",
  "allocate_with_discount",
  "  if v_discount > 0 then\n    select coalesce(c.receivable_account_id,",
  "  if false then  -- unposted\n    select coalesce(c.receivable_account_id,",
  "-- unposted")

m("the allocation does not name its journal",
  "allocate_with_discount",
  "          v_discount, v_entry, auth.uid())",
  "          v_discount, null, auth.uid())  -- unnamed",
  "-- unnamed")

m("a discount on a dollar bill is posted as ringgit (0734's shape)",
  "allocate_payment_with_discount",
  "    v_disc_base := round(v_discount * coalesce(v_bill.exchange_rate, 1), 2);",
  "    v_disc_base := v_discount;  -- unconverted",
  "-- unconverted")

m("a payment that does not exist is allocated in silence",
  "allocate_payment_with_discount",
  "  if v_pay.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody allocates a payment",
  "allocate_payment_with_discount",
  "  if not app.can_post(v_pay.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("another company's bill is settled",
  "allocate_payment_with_discount",
  "  if v_bill.id is null or v_bill.org_id <> v_pay.org_id then",
  "  if v_bill.id is null then  -- any company",
  "-- any company")

m("a supplier discount on terms that offer none",
  "allocate_payment_with_discount",
  "    if v_offer.deadline is null then",
  "    if false then  -- no offer",
  "-- no offer")

m("a supplier discount after it ran out",
  "allocate_payment_with_discount",
  "    if v_offer.deadline < v_as_at then",
  "    if false then  -- expired",
  "-- expired")

m("more supplier discount than the terms allow",
  "allocate_payment_with_discount",
  "    if v_discount > v_offer.amount then",
  "    if false then  -- generous",
  "-- generous")

m("cash and supplier discount beyond what is owed",
  "allocate_payment_with_discount",
  "    if round(p_amount + v_discount, 2)\n       > round(coalesce(v_bill.balance_amount, 0), 2) then",
  "    if false then  -- overpaid",
  "-- overpaid")

m("CONTROL: a comment inside the block",
  "allocate_with_discount",
  "    if v_offer.deadline is null then",
  "    if v_offer.deadline is null then  -- (control)",
  "(control)")
