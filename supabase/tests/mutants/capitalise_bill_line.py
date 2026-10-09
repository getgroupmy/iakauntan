# Mutants for public.capitalise_bill_line (0382, restated in 0780) -- a
# posted bill line (since 0780, paid in part or in full counts),
# coded to a fixed asset account, becomes one asset in the register at
# the line's own net amount in the company's money, on the bill's date,
# from the bill's supplier; once; with the module and `can_write`.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0780_a_paid_bill_is_still_a_posted_one.sql \
#       supabase/tests/capitalisation.sql \
#       supabase/tests/mutants/capitalise_bill_line.py
#
# RESULT: 26 mutants and a control, all killed by `capitalisation.sql`.
# Swept first against 0382 on 9 October: 9 of 20. The fixtures
# collapsed what the asset takes from where -- every bill dated today,
# in ringgit, of one line, capitalised with no name, category,
# residual or method -- and no void or waiting bill was ever offered.
# The sweep also found the defect `0780` fixes: a bill paid in part or
# in full is no longer 'posted', and was refused as never posted.

m("a line that does not exist is not said so",
  "capitalise_bill_line",
  "  if v_line.id is null then",
  "  if false then  -- any line",
  "-- any line")

m("anybody may capitalise",
  "capitalise_bill_line",
  "  if not app.can_write(v_line.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("no module is needed",
  "capitalise_bill_line",
  "  if not app.has_module(v_line.org_id, 'fixed_assets') then",
  "  if false then  -- no module",
  "-- no module")

m("an unposted bill is capitalised",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if false then  -- unposted taken",
  "-- unposted taken")

m("only a draft is refused",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status = 'draft' then  -- only drafts",
  "-- only drafts")

m("a paid bill is not posted (as before 0780)",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted') then  -- posted only",
  "-- posted only")

m("a part-paid bill is not posted",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'completed') then  -- no partial",
  "-- no partial")

m("a bill paid in full is not posted",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial') then  -- no completed",
  "-- no completed")

m("a void bill is capitalised",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial', 'completed', 'void') then  -- void taken",
  "-- void taken")

m("a bill waiting for approval is capitalised",
  "capitalise_bill_line",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial', 'completed', 'pending') then  -- pending taken",
  "-- pending taken")

m("a line becomes two assets",
  "capitalise_bill_line",
  "  if exists (select 1 from public.fixed_assets\n              where purchase_line_id = p_line and deleted_at is null) then",
  "  if false then  -- twice",
  "-- twice")

m("a deleted asset still holds its line",
  "capitalise_bill_line",
  "              where purchase_line_id = p_line and deleted_at is null) then",
  "              where purchase_line_id = p_line) then  -- deleted counted",
  "-- deleted counted")

m("a line naming no account is not said so",
  "capitalise_bill_line",
  "  if v_acct.id is null then",
  "  if false then  -- no account",
  "-- no account")

m("an expense line goes in the register",
  "capitalise_bill_line",
  "  if v_acct.account_subtype <> 'fixed_asset' then",
  "  if false then  -- any account",
  "-- any account")

m("the cost ignores the exchange rate",
  "capitalise_bill_line",
  "  v_cost := round(v_line.line_subtotal * v_doc.exchange_rate, 2);",
  "  v_cost := round(v_line.line_subtotal, 2);  -- bill currency",
  "-- bill currency")

m("the cost is the gross, tax and all",
  "capitalise_bill_line",
  "  v_cost := round(v_line.line_subtotal * v_doc.exchange_rate, 2);",
  "  v_cost := round(v_line.line_total * v_doc.exchange_rate, 2);  -- gross",
  "-- gross")

m("a line worth nothing is an asset",
  "capitalise_bill_line",
  "  if v_cost <= 0 then",
  "  if v_cost < 0 then  -- zero taken",
  "-- zero taken")

m("a residual above cost is taken",
  "capitalise_bill_line",
  "  if coalesce(p_residual_value, 0) > v_cost then",
  "  if false then  -- any residual",
  "-- any residual")

m("a residual equal to cost is refused",
  "capitalise_bill_line",
  "  if coalesce(p_residual_value, 0) > v_cost then",
  "  if coalesce(p_residual_value, 0) >= v_cost then  -- equal refused",
  "-- equal refused")

m("the asset number keeps its spaces",
  "capitalise_bill_line",
  "  values (v_line.org_id, btrim(p_asset_no),",
  "  values (v_line.org_id, p_asset_no,  -- untrimmed",
  "-- untrimmed")

m("the name given is ignored",
  "capitalise_bill_line",
  "          coalesce(nullif(btrim(coalesce(p_name, '')), ''),",
  "          coalesce(null,  -- name ignored",
  "-- name ignored")

m("the acquisition date is today",
  "capitalise_bill_line",
  "          v_doc.doc_date, v_cost, coalesce(p_residual_value, 0),",
  "          app.today(), v_cost, coalesce(p_residual_value, 0),  -- today",
  "-- today")

m("the residual given is dropped",
  "capitalise_bill_line",
  "          v_doc.doc_date, v_cost, coalesce(p_residual_value, 0),",
  "          v_doc.doc_date, v_cost, 0,  -- no residual",
  "-- no residual")

m("the method given is dropped",
  "capitalise_bill_line",
  "          p_method, p_useful_life_months, p_rate_percent,",
  "          'straight_line', p_useful_life_months, p_rate_percent,  -- one method",
  "-- one method")

m("nobody is recorded as making it",
  "capitalise_bill_line",
  "          v_doc.contact_id, v_doc.id, v_line.id, auth.uid())",
  "          v_doc.contact_id, v_doc.id, v_line.id, null)  -- nobody",
  "-- nobody")

m("the category given is dropped",
  "capitalise_bill_line",
  "          p_category, v_acct.id,",
  "          null, v_acct.id,  -- no category",
  "-- no category")

m("CONTROL: a comment inside the block",
  "capitalise_bill_line",
  "  if v_cost <= 0 then",
  "  if v_cost <= 0 then  -- (control)",
  "(control)")
