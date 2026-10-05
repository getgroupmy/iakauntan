# Mutants for public.record_group_payment -- one payment across several
# companies, which is the widest single money mover in the schema: it
# writes a receipt or a purchase payment per (company, contact,
# currency), allocates every document, and posts each one.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0462_one_payment_across_several_companies.sql \
#       supabase/tests/group_payment.sql \
#       supabase/tests/mutants/record_group_payment.py
#
# Run it against each of the three files that call it in turn -- a
# per-file score understates the suite, and that nearly produced three
# false alarms earlier in this session:
#
#   supabase/tests/group_payment.sql           61 assertions, 27 calls
#   supabase/tests/group_payment_shapes.sql    62 assertions, 30 calls
#   supabase/tests/money_names_the_account.sql 40 assertions,  1 call
#
# Those counts are the `ok` lines the run prints, not a grep. The first
# draft of this header said 69 for group_payment.sql, from counting
# occurrences of `check_eq|check_true|check_refused` -- which also counts
# the helper definitions. Ask the run, not the text.
#
# Seventeen mutants, the last a control. They are chosen to attack three
# different kinds of claim, because a function this size fails in three
# different ways:
#
#   * the REFUSALS -- eight guards, each with its own sqlstate and its
#     own sentence, every one of which a test could be passing by
#     accident if it only checks that something was raised;
#   * the GROUPING -- one receipt per company/contact/currency, and the
#     single bank account per company's share;
#   * the FIGURES -- what the receipt is for, what the rate is, what the
#     discount does, and which account the money lands in.
#
# The figure mutants matter most and are the easiest to get wrong in a
# test. A mutation that moves money SYMMETRICALLY balances perfectly, so
# a journal-balance assertion cannot see it; only an assertion naming an
# account and a figure can.
#
# RESULT, 5 October: 17 mutants, 15 KILLED, 2 proven equivalent,
# NO GAPS. The strongest result of any function mutated this session --
# the others averaged better than one real gap each.
#
#   group_payment.sql         kills 13 of 17
#   group_payment_shapes.sql  kills 10, four of them the ones the first
#                             file missed
#   money_names_the_account.sql kills NONE -- its single call sits in a
#                             section asserting where the money lands,
#                             which none of these mutations move
#
# The per-file scores were 4 survivors and 7 survivors. The UNION is 2.
# That is the whole argument for running every file that calls the
# function, in one line of evidence: either file on its own would have
# reported five or six gaps that the other file closes.
#
# THE TWO EQUIVALENTS, both proven rather than argued:
#
#  1. "two currencies are merged into one receipt" -- widening the loop's
#     `group by org_id, contact_id, currency` to drop `currency` cannot
#     change the groups, because an earlier guard already refuses a
#     payment where one (org, contact) appears in more than one currency
#     ("One company's share of this payment is in two currencies"). That
#     guard is itself killed by group_payment.sql, which is what proves
#     it fires. So the `currency` in the GROUP BY is defensive and
#     unreachable -- the same shape as the canary check that made its own
#     floor test dead earlier in this session. Left in place: removing
#     dead defence from a money function is not worth the edit.
#
#  2. "a zero discount is passed as zero rather than as nothing" --
#     `nullif(l.discount, 0)` -> `l.discount`. Both 5-arg allocators
#     (`0385` sales, `0386` purchase) use `p_discount` in exactly ONE
#     place, `v_discount := round(coalesce(p_discount, 0), 2)`, and
#     nowhere else in either body -- checked by listing every line
#     mentioning it, not by reading the top of the function. `coalesce`
#     absorbs the difference, so there is nothing for a test to see.
#     Note the 6-arg idempotent overloads in `0734` DO put p_discount
#     into the idempotency fingerprint, where 0 and null differ -- but
#     record_group_payment calls the 5-arg form, so that path is not
#     reached from here.
#
# One mutant had to be rewritten before its survival meant anything: the
# first version of the grouping one was `group by org_id, contact_id,
# currency, currency`, a DUPLICATE column, which changes nothing at all.
# It "survived" 69 assertions because there was nothing to survive, and
# was very nearly written up as a gap.

m("a line may settle both an invoice and a bill, or neither",
  "record_group_payment",
  "              where (x.invoice_id is null) = (x.bill_id is null)) then",
  "              where (x.invoice_id is null) <> (x.bill_id is null)) then"
  "  -- exactly-one inverted",
  "-- exactly-one inverted")

m("a payment may mix invoices and bills, which is a contra",
  "record_group_payment",
  "  if v_inv > 0 and v_bill > 0 then",
  "  if v_inv > 0 and v_bill > 0 and false then  -- contra guard dropped",
  "-- contra guard dropped")

m("sales and purchase are the wrong way round",
  "record_group_payment",
  "  v_sales := v_inv > 0;",
  "  v_sales := v_bill > 0;  -- direction flipped",
  "-- direction flipped")

m("an allocation of nothing is allowed",
  "record_group_payment",
  "              where coalesce(x.amount, 0) <= 0) then",
  "              where coalesce(x.amount, 0) < 0) then  -- zero allowed",
  "-- zero allowed")

m("the same document may appear on the payment twice",
  "record_group_payment",
  "             having count(*) > 1) then",
  "             having count(*) > 2) then  -- duplicate guard loosened",
  "-- duplicate guard loosened")

m("a DRAFT document can be paid",
  "record_group_payment",
  "    from pg_temp._gp where status not in ('posted', 'partial');",
  "    from pg_temp._gp where status not in ('posted', 'partial', 'draft');"
  "  -- draft allowed",
  "-- draft allowed")

m("a deleted document is still payable",
  "record_group_payment",
  "     where d.deleted_at is null;\n  else",
  "     where d.deleted_at is not null or true;  -- deleted allowed\n  else",
  "-- deleted allowed")

m("more than is outstanding may be paid, if the excess is called discount",
  "record_group_payment",
  "    from pg_temp._gp where round(amount + discount, 2) >"
  " round(balance, 2);",
  "    from pg_temp._gp where round(amount, 2) > round(balance, 2);"
  "  -- discount excluded from the ceiling",
  "-- discount excluded from the ceiling")

m("paying exactly the balance is refused",
  "record_group_payment",
  "    from pg_temp._gp where round(amount + discount, 2) >"
  " round(balance, 2);",
  "    from pg_temp._gp where round(amount + discount, 2) >="
  " round(balance, 2);  -- exact settlement refused",
  "-- exact settlement refused")

m("another company's bank account is accepted",
  "record_group_payment",
  "     and (a.id is null or a.org_id <> b.org_id);",
  "     and (a.id is null or a.org_id = b.org_id);  -- cross-company inverted",
  "-- cross-company inverted")

m("the right to post in every company is not required",
  "record_group_payment",
  "    if not app.can_post(v_org) then",
  "    if not app.can_post(v_org) and false then  -- can_post dropped",
  "-- can_post dropped")

m("one company's share may be in two currencies",
  "record_group_payment",
  "           where c.org_id = b.org_id and c.contact_id = b.contact_id) > 1;",
  "           where c.org_id = b.org_id and c.contact_id = b.contact_id) > 2;"
  "  -- two currencies allowed",
  "-- two currencies allowed")

m("two bank accounts in one company's share are accepted",
  "record_group_payment",
  "    if g.bank is distinct from g.bank_hi then",
  "    if g.bank is not distinct from g.bank_hi then  -- one-bank inverted",
  "-- one-bank inverted")

m("the receipt is written for the cash PLUS the discount",
  "record_group_payment",
  "           sum(amount) as cash,",
  "           sum(amount + coalesce(discount, 0)) as cash,"
  "  -- discount banked",
  "-- discount banked")

# The first version of this mutant was `group by org_id, contact_id,
# currency, currency` -- a DUPLICATE column, which changes nothing. It
# "survived" 69 assertions because there was nothing to survive, and was
# very nearly written up as a gap in the suite. A mutant has to be
# checked for being a no-op before its survival means anything.
# Currency cannot simply be dropped from the GROUP BY while the select
# still names it, so the select aggregates it instead.
m("two currencies are merged into one receipt",
  "record_group_payment",
  "    select org_id, contact_id, currency,\n"
  "           sum(amount) as cash,\n"
  "           min(bank_account_id::text)::uuid as bank,\n"
  "           max(bank_account_id::text)::uuid as bank_hi,\n"
  "           min(payment_mode_code) as mode\n"
  "      from pg_temp._gp\n"
  "     group by org_id, contact_id, currency\n",
  "    select org_id, contact_id, min(currency) as currency,\n"
  "           sum(amount) as cash,\n"
  "           min(bank_account_id::text)::uuid as bank,\n"
  "           max(bank_account_id::text)::uuid as bank_hi,\n"
  "           min(payment_mode_code) as mode\n"
  "      from pg_temp._gp\n"
  "     group by org_id, contact_id  -- grouping widened\n",
  "-- grouping widened")

m("the exchange rate is ignored, so a foreign payment posts at 1",
  "record_group_payment",
  "    v_rate := case when g.currency = app.base_currency(g.org_id) then 1",
  "    v_rate := case when true then 1  -- rate dropped",
  "-- rate dropped")

m("a zero discount is passed as zero rather than as nothing",
  "record_group_payment",
  "          v_id, l.doc_id, l.amount, nullif(l.discount, 0), p_paid_on);"
  "\n      end loop;\n\n      perform public.post_receipt(v_id);",
  "          v_id, l.doc_id, l.amount, l.discount, p_paid_on);"
  "  -- nullif dropped\n      end loop;\n\n"
  "      perform public.post_receipt(v_id);",
  "-- nullif dropped")

m("CONTROL -- a comment inside the function block",
  "record_group_payment",
  "  v_sales := v_inv > 0;",
  "  v_sales := v_inv > 0;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
