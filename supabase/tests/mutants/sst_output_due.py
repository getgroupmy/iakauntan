# Mutants for app.sst_output_due (0456) -- what the SST-02 return says
# is owed for a taxable period: sales tax and non-invoice service tax on
# the document date, service tax on an invoice when the money arrives
# (or twelve months after the invoice, whichever is first), with credit
# notes reducing it. `public.sst_return_lines` is a wrapper over this.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0456_service_tax_is_due_when_the_money_arrives.sql \
#       supabase/tests/service_tax_on_payment.sql \
#       supabase/tests/mutants/sst_output_due.py

#
# RESULT, 6 October: 18 mutants, ALL 18 KILLED, control alive, across
# eight files -- with NO new assertion. The first function swept that
# needed none. service_tax_on_payment.sql kills 10 on its own (the
# payment basis, the anniversary, the apportionment, the credit-note
# sign) and sst_shapes.sql the rest (refund notes, drafts, the service
# charge's own tax, the period edges, the anniversary to the day, a
# zero period left out, the rounding to the sen). The statutory return
# was written test-first, and it shows.

m("a credit note adds to the tax instead of reducing it",
  "sst_output_due",
  "           case when d.doc_type in ('credit_note', 'refund_note')\n"
  "                then -1 else 1 end as sign,",
  "           1 as sign,  -- credit sign dropped",
  "-- credit sign dropped")

m("a refund note is declared like an invoice",
  "sst_output_due",
  "           case when d.doc_type in ('credit_note', 'refund_note')\n"
  "                then -1 else 1 end as sign,",
  "           case when d.doc_type in ('credit_note')  -- refund dropped\n"
  "                then -1 else 1 end as sign,",
  "-- refund dropped")

m("a draft invoice is declared",
  "sst_output_due",
  "                          'refund_note')\n"
  "       and d.status not in ('draft', 'void')\n"
  "    union all",
  "                          'refund_note')\n"
  "       and d.status not in ('void')  -- drafts declared\n"
  "    union all",
  "-- drafts declared")

m("the service charge's own tax is never declared",
  "sst_output_due",
  "       and coalesce(d.service_charge_amount, 0) <> 0\n  ),",
  "       and false  -- service charge dropped\n  ),",
  "-- service charge dropped")

m("service tax on an invoice is declared on the invoice date after all",
  "sst_output_due",
  "     where not (l.code = '02' and l.doc_type = 'invoice')\n"
  "       and l.doc_date between p_from and p_to",
  "     where l.doc_date between p_from and p_to  -- payment basis dropped",
  "-- payment basis dropped")

m("a credit note for service tax waits for a payment that never comes",
  "sst_output_due",
  "     where not (l.code = '02' and l.doc_type = 'invoice')",
  "     where not (l.code = '02')  -- service credits held back",
  "-- service credits held back")

m("tax on the document is read from outside the period",
  "sst_output_due",
  "     where not (l.code = '02' and l.doc_type = 'invoice')\n"
  "       and l.doc_date between p_from and p_to",
  "     where not (l.code = '02' and l.doc_type = 'invoice')\n"
  "       and l.doc_date <= p_to  -- period start dropped",
  "-- period start dropped")

m("a draft receipt counts as money received",
  "sst_output_due",
  "       and r.status not in ('draft', 'void')\n  ),",
  "       and r.status not in ('void')  -- draft receipts count\n  ),",
  "-- draft receipts count")

m("the money is dated the day it was keyed, not received",
  "sst_output_due",
  "    select s.doc_id, r.receipt_date as paid_on, a.amount",
  "    select s.doc_id, r.created_at::date as paid_on, a.amount  -- keyed date",
  "-- keyed date")

m("the anniversary is a day early",
  "sst_output_due",
  "           (s.doc_date + interval '12 months' + interval '1 day')::date\n"
  "             as falls_due,",
  "           (s.doc_date + interval '12 months')::date  -- a day early\n"
  "             as falls_due,",
  "-- a day early")

m("a payment ON the anniversary is not counted as paid by then",
  "sst_output_due",
  "                        and p.paid_on\n"
  "                            <= (s.doc_date + interval '12 months')::date),",
  "                        and p.paid_on\n"
  "                            < (s.doc_date + interval '12 months')::date),  -- strict",
  "-- strict")

m("the payment share is not apportioned -- the whole tax on any payment",
  "sst_output_due",
  "           sum(s.tax * p.amount / s.total) as tax\n      from paid p",
  "           sum(s.tax) as tax  -- not apportioned\n      from paid p",
  "-- not apportioned")

m("payments after the anniversary are declared a second time",
  "sst_output_due",
  "       and p.paid_on < an.falls_due\n  ),",
  "  ),  -- post-anniversary payments counted",
  "-- post-anniversary payments counted")

m("payments outside the period are declared in it",
  "sst_output_due",
  "     where p.paid_on between p_from and p_to\n       and p.paid_on < an.falls_due",
  "     where p.paid_on <= p_to  -- payment period start dropped\n"
  "       and p.paid_on < an.falls_due",
  "-- payment period start dropped")

m("what is still owing at the anniversary is never declared",
  "sst_output_due",
  "     where an.falls_due between p_from and p_to\n"
  "       and an.total > an.paid_by_then",
  "     where false  -- the twelve-month rule dropped\n"
  "       and an.total > an.paid_by_then",
  "-- the twelve-month rule dropped")

m("at the anniversary the WHOLE tax falls due, paid or not",
  "sst_output_due",
  "           sum(an.tax * (an.total - an.paid_by_then) / an.total) as tax",
  "           sum(an.tax) as tax  -- paid part declared again",
  "-- paid part declared again")

m("a period with nothing in it returns a row of zeroes",
  "sst_output_due",
  "     and (x.net <> 0 or x.tax <> 0);",
  "     ;  -- zero rows kept",
  "-- zero rows kept")

m("the figures are not rounded to the sen",
  "sst_output_due",
  "  select x.code, x.basis, round(x.net, 2), round(x.tax, 2)",
  "  select x.code, x.basis, x.net, x.tax  -- unrounded",
  "-- unrounded")

m("CONTROL -- a comment inside the function block",
  "sst_output_due",
  "  -- Money actually received against them, on the day it was received",
  "  -- CONTROL: this cannot change a number.\n"
  "  -- Money actually received against them, on the day it was received",
  "-- CONTROL: this cannot change a number.")
