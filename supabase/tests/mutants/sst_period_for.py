# Mutants for app.sst_period_for (0455) -- which SST taxable period a
# date falls in, and when its return is due: monthly for an approved
# filer, otherwise two-monthly with the first period ending on the last
# day of the month after registration (or on the Director General's
# chosen month), and the return due by the end of the month after.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0455_two_months_and_the_month_after.sql \
#       supabase/tests/sst_taxable_period.sql \
#       supabase/tests/mutants/sst_period_for.py

#
# RESULT, 6 October: 13 mutants, 12 KILLED, 1 EQUIVALENT, control
# alive. sst_taxable_period.sql kills 11, sst_shapes.sql the twelfth.
#
# EQUIVALENT: "an unregistered company is given a taxable period". The
# mutant drops the is_sst_registered test and leaves the next one,
# `sst_registered_from is null`. Those two columns change only through
# set_sst_registration() -- app.guard_sst_registration refuses any
# other write -- and deregistering there sets the date to null. So no
# company is unregistered with a date, and the next guard always
# catches it.  (The writer.)

m("an unregistered company is given a taxable period",
  "sst_period_for",
  "  if v_org.id is null or not coalesce(v_org.is_sst_registered, false)",
  "  if v_org.id is null  -- registration not checked",
  "-- registration not checked")

m("a date before registration is given a period",
  "sst_period_for",
  "     or p_on < v_org.sst_registered_from\n",
  "     -- pre-registration dates allowed\n",
  "-- pre-registration dates allowed")

m("a monthly filer is put on two-monthly periods",
  "sst_period_for",
  "  if v_org.sst_period_months = 1 then",
  "  if false then  -- monthly ignored",
  "-- monthly ignored")

m("a monthly filer's first period starts before registration",
  "sst_period_for",
  "    v_start := greatest(date_trunc('month', p_on)::date,\n"
  "                        v_org.sst_registered_from);",
  "    v_start := date_trunc('month', p_on)::date;  -- registration floor dropped",
  "-- registration floor dropped")

m("a monthly return is due a month late",
  "sst_period_for",
  "      (date_trunc('month', v_end) + interval '2 months - 1 day')::date,\n"
  "      v_start = v_org.sst_registered_from;",
  "      (date_trunc('month', v_end) + interval '3 months - 1 day')::date,  -- late\n"
  "      v_start = v_org.sst_registered_from;",
  "-- late")

m("the Director General's chosen month is ignored",
  "sst_period_for",
  "  if v_org.sst_period_ends_month is not null then",
  "  if false then  -- DG month ignored",
  "-- DG month ignored")

m("the first period ends in the month of registration, not the month after",
  "sst_period_for",
  "          + extract(month from v_org.sst_registered_from)::integer + 1;\n  end if;",
  "          + extract(month from v_org.sst_registered_from)::integer;  -- month after dropped\n  end if;",
  "-- month after dropped")

m("the first period is not flagged as the first",
  "sst_period_for",
  "      (date_trunc('month', v_anchor) + interval '2 months - 1 day')::date,\n      true;",
  "      (date_trunc('month', v_anchor) + interval '2 months - 1 day')::date,\n      false;  -- first not flagged",
  "-- first not flagged")

m("the first period starts on the first of the month, not the day of registration",
  "sst_period_for",
  "      v_org.sst_registered_from, v_anchor,",
  "      date_trunc('month', v_org.sst_registered_from)::date, v_anchor,  -- month start",
  "-- month start")

m("a date ON the first period's last day falls in the second",
  "sst_period_for",
  "  if p_on <= v_anchor then",
  "  if p_on < v_anchor then  -- last day excluded",
  "-- last day excluded")

m("later periods are a month off",
  "sst_period_for",
  "  v_endm := v_m0 + 2 * (v_k + 1);",
  "  v_endm := v_m0 + 2 * (v_k + 1) + 1;  -- a month off",
  "-- a month off")

m("a later period is one month long",
  "sst_period_for",
  "  v_start := make_date((v_endm - 2) / 12, ((v_endm - 2) % 12) + 1, 1);",
  "  v_start := make_date((v_endm - 1) / 12, ((v_endm - 1) % 12) + 1, 1);  -- one month",
  "-- one month")

m("a later return is due at the end of the period itself",
  "sst_period_for",
  "    (date_trunc('month', v_end) + interval '2 months - 1 day')::date,\n    false;",
  "    v_end,  -- due on the period end\n    false;",
  "-- due on the period end")

m("CONTROL -- a comment inside the function block",
  "sst_period_for",
  "  -- Whole two-month blocks between the first period and this date.",
  "  -- CONTROL: this cannot change a date.\n"
  "  -- Whole two-month blocks between the first period and this date.",
  "-- CONTROL: this cannot change a date.")
