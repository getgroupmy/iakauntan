# Mutants for public.create_bank_transfer (0739) -- money moved between
# two of a company's own bank accounts: the refusals, the rates either
# side, what arrived, and the exchange difference -- plus the two small
# functions 0739 redefined beside it: the member-checking wrapper over
# app.exchange_rate_for, and depreciation_preview.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/bank_transfers.sql \
#       supabase/tests/mutants/create_bank_transfer.py
#
# RESULT: (pending)

m("a stranger moves a company's money",
  "create_bank_transfer",
  "  if not app.can_post(f.org_id) then",
  "  if false then  -- anybody posts",
  "-- anybody posts")

m("money moves between two companies' accounts",
  "create_bank_transfer",
  "  if f.org_id <> t.org_id then",
  "  if false then  -- two companies",
  "-- two companies")

m("an account transfers to itself",
  "create_bank_transfer",
  "  if f.id = t.id then",
  "  if false then  -- to itself",
  "-- to itself")

m("a transfer of nothing is accepted",
  "create_bank_transfer",
  "  if v_sent <= 0 then",
  "  if v_sent < 0 then  -- nothing sent",
  "-- nothing sent")

m("a foreign account is taken at rate one",
  "create_bank_transfer",
  "  v_from_rate := case when f.currency = coalesce(v_base, 'MYR') then 1\n    else app.exchange_rate_for(f.org_id, f.currency, p_transfer_date) end;",
  "  v_from_rate := 1;  -- from at par",
  "-- from at par")

m("the receiving account's rate is the sending account's",
  "create_bank_transfer",
  "    else app.exchange_rate_for(f.org_id, t.currency, p_transfer_date) end;",
  "    else app.exchange_rate_for(f.org_id, f.currency, p_transfer_date) end;  -- to at from",
  "-- to at from")

m("a missing rate is not refused",
  "create_bank_transfer",
  "  if v_from_rate is null or v_to_rate is null then",
  "  if false then  -- no rate fine",
  "-- no rate fine")

m("in one currency the charges are not taken off what arrived",
  "create_bank_transfer",
  "    case when f.currency = t.currency then v_sent - v_charges else null end), 2);",
  "    case when f.currency = t.currency then v_sent else null end), 2);  -- charges kept",
  "-- charges kept")

m("across currencies what arrived is guessed",
  "create_bank_transfer",
  "    case when f.currency = t.currency then v_sent - v_charges else null end), 2);",
  "    v_sent - v_charges), 2);  -- guessed",
  "-- guessed")

m("nothing arriving is accepted",
  "create_bank_transfer",
  "  if v_received <= 0 then",
  "  if v_received < 0 then  -- nothing arrived",
  "-- nothing arrived")

m("the exchange difference forgets the charges",
  "create_bank_transfer",
  "          - round(v_received * v_to_rate, 2)\n          - round(v_charges * v_from_rate, 2);",
  "          - round(v_received * v_to_rate, 2);  -- no charges",
  "-- no charges")

m("the exchange difference reads what arrived at the sending rate",
  "create_bank_transfer",
  "          - round(v_received * v_to_rate, 2)",
  "          - round(v_received * v_from_rate, 2)  -- wrong rate",
  "-- wrong rate")

m("figures that do not add up in one currency are accepted",
  "create_bank_transfer",
  "  if f.currency = t.currency and v_diff <> 0 then",
  "  if false then  -- typo accepted",
  "-- typo accepted")

m("a cross-currency difference is refused as a typo",
  "create_bank_transfer",
  "  if f.currency = t.currency and v_diff <> 0 then",
  "  if v_diff <> 0 then  -- fx refused",
  "-- fx refused")

m("the difference is not recorded",
  "create_bank_transfer",
  "    v_sent, v_received, v_charges, v_from_rate, v_to_rate, v_diff,",
  "    v_sent, v_received, v_charges, v_from_rate, v_to_rate, 0,  -- no diff",
  "-- no diff")

# -- public.exchange_rate_for (the wrapper) ---------------------------------

m("a stranger reads a company's rates",
  "exchange_rate_for",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- stranger",
  "-- stranger")

# -- public.depreciation_preview ----------------------------------------------

m("a stranger previews the depreciation",
  "depreciation_preview",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- stranger",
  "-- stranger")

m("the preview charges what has already been charged",
  "depreciation_preview",
  "         greatest(app.accumulated_depreciation_at(a, p_as_at)\n                  - a.accumulated_depreciation, 0),",
  "         app.accumulated_depreciation_at(a, p_as_at),  -- whole",
  "-- whole")

m("a disposed asset is previewed",
  "depreciation_preview",
  "     and a.status = 'active'",
  "     and true  -- any status",
  "-- any status")

m("an asset bought after the date is previewed",
  "depreciation_preview",
  "     and a.acquisition_date <= p_as_at",
  "     and true  -- future",
  "-- future")

m("CONTROL: a comment inside the block",
  "create_bank_transfer",
  "  -- In one currency the three figures are arithmetic, not judgement, so",
  "  -- CONTROL\n  -- In one currency the three figures are arithmetic, not judgement, so",
  "-- CONTROL")
