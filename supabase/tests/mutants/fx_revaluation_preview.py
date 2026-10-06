# Mutants for public.fx_revaluation_preview (0739) -- what month-end
# retranslation WOULD do, per currency, before anybody presses the button.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/fx_revaluation.sql \
#       supabase/tests/mutants/fx_revaluation_preview.py
#
# then again against `fx_shapes.sql`.
#
# The sales and purchase blocks of the open-items CTE are word for word
# alike, so each anchor here carries its `from` line to say which.
#
# RESULT: 15 mutants and a control. 15 killed.
#
#   The first sweep killed 8 across fx_revaluation.sql and fx_shapes.sql.
#   No fixture had a settled, draft or void foreign invoice, a ringgit
#   BILL, an April bill, or a rate dated after the as-at day -- so any
#   day from March on read 4.20. "fx_revaluation_preview, rule by rule"
#   in fx_revaluation.sql kills the other six; the stranger dies in
#   fx_shapes.sql.

m("a stranger previews the revaluation",
  "fx_revaluation_preview",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a ringgit invoice is retranslated",
  "fx_revaluation_preview",
  "      from public.sales_documents d\n     where d.org_id = p_org_id and d.currency <> v_base",
  "      from public.sales_documents d\n     where d.org_id = p_org_id  -- base too",
  "-- base too")

m("another company's invoices are previewed",
  "fx_revaluation_preview",
  "      from public.sales_documents d\n     where d.org_id = p_org_id and d.currency <> v_base",
  "      from public.sales_documents d\n     where d.currency <> v_base  -- any org",
  "-- any org")

m("a ringgit bill is retranslated",
  "fx_revaluation_preview",
  "      from public.purchase_documents d\n     where d.org_id = p_org_id and d.currency <> v_base",
  "      from public.purchase_documents d\n     where d.org_id = p_org_id  -- base too",
  "-- base too")

m("a settled invoice is counted",
  "fx_revaluation_preview",
  "      from public.sales_documents d\n     where d.org_id = p_org_id and d.currency <> v_base\n       and d.balance_amount <> 0 and d.doc_date <= p_as_at",
  "      from public.sales_documents d\n     where d.org_id = p_org_id and d.currency <> v_base\n       and d.doc_date <= p_as_at  -- settled too",
  "-- settled too")

m("an invoice after the date is counted",
  "fx_revaluation_preview",
  "      from public.sales_documents d\n     where d.org_id = p_org_id and d.currency <> v_base\n       and d.balance_amount <> 0 and d.doc_date <= p_as_at",
  "      from public.sales_documents d\n     where d.org_id = p_org_id and d.currency <> v_base\n       and d.balance_amount <> 0  -- future too",
  "-- future too")

m("a bill after the date is counted",
  "fx_revaluation_preview",
  "      from public.purchase_documents d\n     where d.org_id = p_org_id and d.currency <> v_base\n       and d.balance_amount <> 0 and d.doc_date <= p_as_at",
  "      from public.purchase_documents d\n     where d.org_id = p_org_id and d.currency <> v_base\n       and d.balance_amount <> 0  -- future too",
  "-- future too")

m("an unposted invoice is counted",
  "fx_revaluation_preview",
  "       and d.deleted_at is null and d.gl_entry_id is not null\n       and d.status <> 'void'\n    union all",
  "       and d.deleted_at is null  -- unposted too\n       and d.status <> 'void'\n    union all",
  "-- unposted too")

m("a void invoice is counted",
  "fx_revaluation_preview",
  "       and d.status <> 'void'\n    union all",
  "       and true  -- void too\n    union all",
  "-- void too")

m("a bill is counted as owed TO us",
  "fx_revaluation_preview",
  "    select d.currency, -d.balance_amount, coalesce(d.exchange_rate, 1)",
  "    select d.currency, d.balance_amount, coalesce(d.exchange_rate, 1)  -- sign",
  "-- sign")

m("the bills are left out",
  "fx_revaluation_preview",
  "      from public.purchase_documents d\n     where d.org_id = p_org_id and d.currency <> v_base",
  "      from public.purchase_documents d\n     where false  -- no bills",
  "-- no bills")

m("booked at the closing rate, so there is never a difference",
  "fx_revaluation_preview",
  "         round(sum(o.amount * o.rate), 2),",
  "         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at)), 2),  -- booked",
  "-- booked")

m("restated at the booked rate",
  "fx_revaluation_preview",
  "         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at)), 2),\n         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at))\n",
  "         round(sum(o.amount * o.rate), 2),  -- restated\n         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at))\n",
  "-- restated")

m("the difference has the wrong sign",
  "fx_revaluation_preview",
  "             - sum(o.amount * o.rate), 2)",
  "             - sum(o.amount * o.rate), 2) * -1  -- sign",
  "-- sign")

m("the closing rate is today's, not the date's",
  "fx_revaluation_preview",
  "  select o.currency,\n         app.exchange_rate_for(p_org_id, o.currency, p_as_at),",
  "  select o.currency,\n         app.exchange_rate_for(p_org_id, o.currency, app.today()),  -- today",
  "-- today")

m("CONTROL: a comment inside the block",
  "fx_revaluation_preview",
  "  v_base := app.base_currency(p_org_id);\n\n  return query\n  with open_items as (",
  "  v_base := app.base_currency(p_org_id);\n  -- CONTROL\n  return query\n  with open_items as (",
  "-- CONTROL")
