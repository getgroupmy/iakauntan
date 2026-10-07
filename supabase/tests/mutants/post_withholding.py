# Mutants for public.post_withholding (0099) -- a withholding tax
# certificate posted: the supplier owed less, the tax owed to LHDN more,
# and the bill it was withheld from brought down by the same amount.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0099_withholding_tax.sql \
#       supabase/tests/withholding_shapes.sql \
#       supabase/tests/mutants/post_withholding.py
#
# RESULT: 13 mutants and a control, all killed by `withholding_shapes.sql`.
# Two only after assertions added there. The allocation against a
# foreign bill made at the BASE amount: a USD1,000 certificate brought a
# USD10,000 bill down by 4,500 dollars, and the one foreign certificate
# in the file had never been read back on the bill side. And
# `posted_by`, which nothing read.
#
# `withholding.sql` alone kills only three; it is the older file and
# reads the bill, not the certificate.

m("a certificate that does not exist posts nothing in silence",
  "post_withholding",
  "  if not found then",
  "  if false then  -- no such",
  "-- no such")

m("anybody posts a certificate",
  "post_withholding",
  "  if not app.can_post(c.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a certificate is posted twice",
  "post_withholding",
  "  if c.gl_entry_id is not null then",
  "  if false then  -- twice",
  "-- twice")

m("a certificate for nothing is posted",
  "post_withholding",
  "  if c.tax_amount = 0 then",
  "  if false then  -- nothing",
  "-- nothing")

m("the supplier's own payable account is ignored",
  "post_withholding",
  "  select coalesce(ct.payable_account_id,\n",
  "  select coalesce(null,  -- default only\n",
  "-- default only")

m("a supplier with no account of its own has nowhere to post",
  "post_withholding",
  "                    where org_id = c.org_id and code = '2110'))",
  "                    where false))  -- no default",
  "-- no default")

m("a foreign certificate posts in its own currency's units",
  "post_withholding",
  "  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);",
  "  v_base := round(c.tax_amount, 2);  -- unconverted",
  "-- unconverted")

m("the supplier is owed more, not less",
  "post_withholding",
  "        'debit', v_base, 'credit', 0, 'contact_id', c.contact_id),",
  "        'debit', 0, 'credit', v_base, 'contact_id', c.contact_id),  -- flipped",
  "-- flipped")

m("the bill is not brought down",
  "post_withholding",
  "  if c.bill_id is not null then",
  "  if false then  -- bill untouched",
  "-- bill untouched")

m("the bill comes down by the base amount",
  "post_withholding",
  "    values (c.org_id, c.id, c.bill_id, c.tax_amount, auth.uid());",
  "    values (c.org_id, c.id, c.bill_id, v_base, auth.uid());  -- base",
  "-- base")

m("a posted certificate does not say so",
  "post_withholding",
  "     set gl_entry_id = v_entry, status = 'posted',",
  "     set gl_entry_id = v_entry, status = status,  -- still draft",
  "-- still draft")

m("a posted certificate does not say who",
  "post_withholding",
  "         posted_at = now(), posted_by = auth.uid()",
  "         posted_at = now(), posted_by = null  -- nobody",
  "-- nobody")

m("the entry is not returned",
  "post_withholding",
  "  return v_entry;",
  "  return null;  -- nothing back",
  "-- nothing back")

m("CONTROL: a comment inside the block",
  "post_withholding",
  "  if c.tax_amount = 0 then",
  "  if c.tax_amount = 0 then  -- (control)",
  "(control)")
