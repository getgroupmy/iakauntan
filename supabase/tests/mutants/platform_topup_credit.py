# Mutants for public.platform_topup_credit (0421) -- scanning credit sold
# to a company: by a platform administrator, for more than nothing, to a
# company that exists; an invoice numbered PREFIX-YEAR-NNNN in this
# year's sequence, carrying SST only when the issuer is registered, for
# the amount plus the tax; and the credit -- the amount, not the tax --
# added to the company's balance.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/ocr_credit.sql \
#       supabase/tests/mutants/platform_topup_credit.py
#
# RESULT: 15 mutants and a control, all killed by `ocr_credit.sql`. Seven
# only after its rule-by-rule assertions: nothing and no amount, a
# company that does not exist, the note, the total answered, the KH
# default (the seeded issuer always named KH, so it was never reached)
# and a new year's own count (nothing from last year existed to carry
# on from). `scan_surfaces.sql` asserted none of the seven.

m("anybody tops up credit",
  "platform_topup_credit",
  "  if not app.is_platform_admin() then",
  "  if false then  -- anybody",
  "-- anybody")

m("a top-up of nothing is sold",
  "platform_topup_credit",
  "  if p_amount is null or p_amount <= 0 then",
  "  if p_amount is null or p_amount < 0 then  -- zero allowed",
  "-- zero allowed")

m("a top-up of no amount at all is sold",
  "platform_topup_credit",
  "  if p_amount is null or p_amount <= 0 then",
  "  if p_amount <= 0 then  -- null allowed",
  "-- null allowed")

m("a company that does not exist is not said so",
  "platform_topup_credit",
  "  if v_org.id is null then\n    raise exception 'No such organization'",
  "  if false then  -- no such company\n    raise exception 'No such organization'",
  "-- no such company")

m("SST is charged whether or not the issuer is registered",
  "platform_topup_credit",
  "  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then",
  "  if true then  -- always taxed",
  "-- always taxed")

m("SST is never charged",
  "platform_topup_credit",
  "  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then",
  "  if false then  -- never taxed",
  "-- never taxed")

m("the tax is the rate, not a percentage of the amount",
  "platform_topup_credit",
  "    v_tax  := round(p_amount * v_rate / 100, 2);",
  "    v_tax  := round(p_amount * v_rate, 2);  -- rate not percent",
  "-- rate not percent")

m("the number does not move on",
  "platform_topup_credit",
  "  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0) + 1",
  "  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0)  -- same number",
  "-- same number")

m("last year's numbers carry on into this one",
  "platform_topup_credit",
  "   where i.invoice_no like v_prefix || '-' || to_char(app.today(), 'YYYY') || '-%';",
  "   where i.invoice_no like v_prefix || '-%';  -- every year",
  "-- every year")

m("the number is not padded to four",
  "platform_topup_credit",
  "                 lpad(v_seq::text, 4, '0'));",
  "                 v_seq::text);  -- unpadded",
  "-- unpadded")

m("the default prefix is not KH",
  "platform_topup_credit",
  "  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'KH');",
  "  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'INV');  -- other prefix",
  "-- other prefix")

m("the invoice total leaves out the tax",
  "platform_topup_credit",
  "    'Document scanning credit', p_amount, v_rate, v_tax, p_amount + v_tax,",
  "    'Document scanning credit', p_amount, v_rate, v_tax, p_amount,  -- untaxed total",
  "-- untaxed total")

m("the company is credited the tax as well",
  "platform_topup_credit",
  "    p_org_id, 'topup', p_amount,",
  "    p_org_id, 'topup', p_amount + v_tax,  -- tax credited",
  "-- tax credited")

m("the note is not kept",
  "platform_topup_credit",
  "    p_note, auth.uid())",
  "    null, auth.uid())  -- no note",
  "-- no note")

m("the answer's total leaves out the tax",
  "platform_topup_credit",
  "    'total',      p_amount + v_tax,",
  "    'total',      p_amount,  -- answer untaxed",
  "-- answer untaxed")

m("CONTROL: a comment inside the block",
  "platform_topup_credit",
  "  if not app.is_platform_admin() then",
  "  if not app.is_platform_admin() then  -- (control)",
  "(control)")
