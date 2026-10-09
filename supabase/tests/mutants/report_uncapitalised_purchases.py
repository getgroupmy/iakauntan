# Mutants for public.report_uncapitalised_purchases (0382, restated in
# 0780) -- this company's posted bill lines (paid in part or in full
# included since 0780) coded to a fixed asset account, dated by the
# as-at date, with no live asset against them, at the line's net in the
# company's own money, oldest first; to those who may read the module.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0780_a_paid_bill_is_still_a_posted_one.sql \
#       supabase/tests/capitalisation.sql \
#       supabase/tests/mutants/report_uncapitalised_purchases.py
#
# RESULT: 12 mutants and a control, all killed by `capitalisation.sql`,
# three of them (the paid and part-paid bills, and the dollar bill's
# amount) by blocks written with `0780`.

ST = "     and d.status in ('posted', 'partial', 'completed')"

m("any status is listed",
  "report_uncapitalised_purchases",
  ST,
  "     and true  -- any status",
  "-- any status")

m("a paid bill drops off the list (as before 0780)",
  "report_uncapitalised_purchases",
  ST,
  "     and d.status = 'posted'  -- posted only",
  "-- posted only")

m("a part-paid bill drops off",
  "report_uncapitalised_purchases",
  ST,
  "     and d.status in ('posted', 'completed')  -- no partial",
  "-- no partial")

m("a bill paid in full drops off",
  "report_uncapitalised_purchases",
  ST,
  "     and d.status in ('posted', 'partial')  -- no completed",
  "-- no completed")

m("a void bill is listed",
  "report_uncapitalised_purchases",
  ST,
  "     and d.status in ('posted', 'partial', 'completed', 'void')  -- void listed",
  "-- void listed")

m("anybody reads it",
  "report_uncapitalised_purchases",
  "     and app.can_read_module(p_org, 'fixed_assets')",
  "     and true  -- anybody",
  "-- anybody")

m("an expense line is listed",
  "report_uncapitalised_purchases",
  "     and a.account_subtype = 'fixed_asset'",
  "     and true  -- any account",
  "-- any account")

m("the as-at date is ignored",
  "report_uncapitalised_purchases",
  "     and (p_as_at is null or d.doc_date <= p_as_at)",
  "     and true  -- any date",
  "-- any date")

m("a capitalised line stays on the list",
  "report_uncapitalised_purchases",
  "                      where f.purchase_line_id = l.id\n",
  "                      where false and f.purchase_line_id = l.id  -- never capitalised\n",
  "-- never capitalised")

m("a deleted asset still takes its line off",
  "report_uncapitalised_purchases",
  "                        and f.deleted_at is null)",
  "                        and true)  -- deleted counted",
  "-- deleted counted")

m("the amount is in the bill's currency",
  "report_uncapitalised_purchases",
  "         round(l.line_subtotal * d.exchange_rate, 2)",
  "         round(l.line_subtotal, 2)  -- bill currency",
  "-- bill currency")

m("newest first",
  "report_uncapitalised_purchases",
  "   order by d.doc_date, d.doc_no, l.line_no;",
  "   order by d.doc_date desc, d.doc_no desc, l.line_no;  -- newest",
  "-- newest")

m("CONTROL: a comment inside the block",
  "report_uncapitalised_purchases",
  "     and a.account_subtype = 'fixed_asset'",
  "     and a.account_subtype = 'fixed_asset'  -- (control)",
  "(control)")
