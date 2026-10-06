# Mutants for public.tax_upcoming_filings (0671) -- every LHDN
# obligation a company has coming due or recently missed, with its date,
# its e-filing extension and whether it has been dealt with.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0671_the_first_year_has_its_own_rules.sql \
#       supabase/tests/tax_filing_calendar.sql \
#       supabase/tests/mutants/tax_upcoming_filings.py
#
# then again against `tax_filings_recorded.sql`,
# `tax_estimate_first_period.sql`, `tax_dashboard_tile.sql` and
# `tax_stack_end_to_end.sql`.
#
# RESULT: (pending)

m("a stranger reads the company's obligations",
  "tax_upcoming_filings",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an employer's forms are asked of a company with no staff",
  "tax_upcoming_filings",
  "     and (not t.needs_employees or v_has_staff)",
  "     and true  -- staff or not",
  "-- staff or not")

m("a company's forms are asked of every kind of business",
  "tax_upcoming_filings",
  "      on coalesce(v_entity, 'other') = any (t.applies_to)",
  "      on true  -- every entity",
  "-- every entity")

m("Form E is labelled with the financial year",
  "tax_upcoming_filings",
  "         case when t.basis = 'month_day_after_year'\n              then make_date(extract(year from fy.end_date)::integer, 1, 1)\n              else fy.start_date end,",
  "         fy.start_date,  -- fy label",
  "-- fy label")

m("the e-filing extension is ignored",
  "tax_upcoming_filings",
  "                    + make_interval(months => coalesce(t.efiling_grace_months, 0))",
  "                    + make_interval(months => 0)  -- no grace months",
  "-- no grace months")

m("days left run the other way",
  "tax_upcoming_filings",
  "         (d.due - v_today)::integer,",
  "         (v_today - d.due)::integer,  -- backwards",
  "-- backwards")

m("the due day itself is overdue",
  "tax_upcoming_filings",
  "         d.due < v_today,",
  "         d.due <= v_today,  -- today late",
  "-- today late")

m("a revised estimate is shown, not its revision",
  "tax_upcoming_filings",
  "     and not exists (select 1 from public.tax_estimates r\n                      where r.revises_id = te.id)",
  "     and true  -- any estimate",
  "-- any estimate")

m("a first period's CP204 is due like any other year's",
  "tax_upcoming_filings",
  "        case when t.code = 'cp204'\n                  and te.first_period",
  "        case when false  -- no first period\n                  and te.first_period",
  "-- no first period")

m("the first period's CP204 is a day late",
  "tax_upcoming_filings",
  "                           - interval '1 day')::date",
  "                           )::date  -- day late",
  "-- day late")

m("a filed obligation stays on the list",
  "tax_upcoming_filings",
  "     and coalesce(tf.status, 'not_started') not in\n           ('filed', 'not_applicable')",
  "     and coalesce(tf.status, 'not_started') not in\n           ('not_applicable')  -- filed stays",
  "-- filed stays")

m("one marked not applicable stays on the list",
  "tax_upcoming_filings",
  "     and coalesce(tf.status, 'not_started') not in\n           ('filed', 'not_applicable')",
  "     and coalesce(tf.status, 'not_started') not in\n           ('filed')  -- n/a stays",
  "-- n/a stays")

m("one in preparation drops off",
  "tax_upcoming_filings",
  "     and coalesce(tf.status, 'not_started') not in\n           ('filed', 'not_applicable')",
  "     and coalesce(tf.status, 'not_started') = 'not_started'  -- prepared drops",
  "-- prepared drops")

m("Form E's filing is looked for against the financial year",
  "tax_upcoming_filings",
  "     and tf.period_to = case when t.basis = 'month_day_after_year'\n              then make_date(extract(year from fy.end_date)::integer, 12, 31)\n              else fy.end_date end",
  "     and tf.period_to = fy.end_date  -- fy",
  "-- fy")

m("a late obligation drops off the next day",
  "tax_upcoming_filings",
  "     and d.due between v_today - 365",
  "     and d.due between v_today  -- future only",
  "-- future only")

m("the window is ignored",
  "tax_upcoming_filings",
  "                   and v_today + greatest(coalesce(p_within_days, 240), 1)",
  "                   and v_today + 100000  -- forever",
  "-- forever")

m("another company's years are listed",
  "tax_upcoming_filings",
  "   where fy.org_id = p_org_id\n",
  "   where true  -- any org\n",
  "-- any org")

m("CONTROL: a comment inside the block",
  "tax_upcoming_filings",
  "  -- An employer for this purpose is anybody who has ever had somebody",
  "  -- CONTROL\n  -- An employer for this purpose is anybody who has ever had somebody",
  "-- CONTROL")
