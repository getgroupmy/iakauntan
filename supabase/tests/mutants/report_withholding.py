# Mutants for public.report_withholding (0419) -- the withholding tax
# register: each s.107A / s.109 certificate, its tax in ringgit, when it
# was due, how late it went in, and the 10% penalty s.109(2) adds to
# anything not remitted on time.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0419_the_rest_of_the_app_never_followed_the_registrar.sql \
#       supabase/tests/withholding.sql \
#       supabase/tests/mutants/report_withholding.py

m("the tax is reported in the foreign currency, not ringgit",
  "report_withholding",
  "         round(c.tax_amount * coalesce(c.exchange_rate, 1), 2),\n         c.due_date,",
  "         round(c.tax_amount, 2),  -- rate dropped\n         c.due_date,",
  "-- rate dropped")

m("days late counts from the certificate date, not the due date",
  "report_withholding",
  "         greatest(0, coalesce(c.remitted_on, app.today()) - c.due_date)::integer,",
  "         greatest(0, coalesce(c.remitted_on, app.today()) - c.cert_date)::integer,  -- from cert date",
  "-- from cert date")

m("a remittance made early shows as NEGATIVE days late",
  "report_withholding",
  "         greatest(0, coalesce(c.remitted_on, app.today()) - c.due_date)::integer,",
  "         (coalesce(c.remitted_on, app.today()) - c.due_date)::integer,  -- floor dropped",
  "-- floor dropped")

m("an unremitted certificate is never late",
  "report_withholding",
  "         greatest(0, coalesce(c.remitted_on, app.today()) - c.due_date)::integer,",
  "         greatest(0, coalesce(c.remitted_on, c.due_date) - c.due_date)::integer,  -- unpaid never late",
  "-- unpaid never late")

m("a penalty is shown on tax that WAS remitted, late",
  "report_withholding",
  "           when c.remitted_on is null and app.today() > c.due_date",
  "           when app.today() > c.due_date  -- remitted ignored",
  "-- remitted ignored")

m("a penalty is shown before the tax is due",
  "report_withholding",
  "           when c.remitted_on is null and app.today() > c.due_date",
  "           when c.remitted_on is null  -- due date ignored",
  "-- due date ignored")

m("a penalty is shown ON the due date",
  "report_withholding",
  "           when c.remitted_on is null and app.today() > c.due_date",
  "           when c.remitted_on is null and app.today() >= c.due_date  -- due day penalised",
  "-- due day penalised")

m("the penalty is 1% rather than 10%",
  "report_withholding",
  "           then round(c.tax_amount * coalesce(c.exchange_rate, 1) * 0.10, 2)",
  "           then round(c.tax_amount * coalesce(c.exchange_rate, 1) * 0.01, 2)  -- one percent",
  "-- one percent")

m("the penalty is on the foreign amount",
  "report_withholding",
  "           then round(c.tax_amount * coalesce(c.exchange_rate, 1) * 0.10, 2)",
  "           then round(c.tax_amount * 0.10, 2)  -- penalty rate dropped",
  "-- penalty rate dropped")

m("a deleted certificate is reported",
  "report_withholding",
  "     and c.deleted_at is null\n",
  "     -- deleted included\n",
  "-- deleted included")

m("a void certificate is reported",
  "report_withholding",
  "     and c.status <> 'void'\n",
  "     -- void included\n",
  "-- void included")

m("certificates before the start date are reported",
  "report_withholding",
  "     and (p_from is null or c.cert_date >= p_from)\n",
  "     -- start ignored\n",
  "-- start ignored")

m("certificates after the end date are reported",
  "report_withholding",
  "     and c.cert_date <= p_to\n",
  "     -- end ignored\n",
  "-- end ignored")

m("a non-member reads the register",
  "report_withholding",
  "     and app.is_org_member(p_org_id)\n",
  "     -- membership ignored\n",
  "-- membership ignored")

m("another company's certificates are reported",
  "report_withholding",
  "   where c.org_id = p_org_id\n",
  "   where true  -- any company\n",
  "-- any company")

m("CONTROL -- a comment inside the function block",
  "report_withholding",
  "   order by c.form_code, c.cert_date, c.certificate_no;",
  "   order by c.form_code, c.cert_date, c.certificate_no;  -- CONTROL: this cannot change a row.",
  "-- CONTROL: this cannot change a row.")
