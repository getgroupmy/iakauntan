# Mutants for public.revalue_foreign_balances -- the month-end
# retranslation of every foreign receivable and payable at the closing
# rate, with the standing adjustment reversed first and the gain and
# loss stated separately.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/fx_shapes.sql \
#       supabase/tests/mutants/fx_revaluation.py
#
# then again against `fx_revaluation.sql`, `exchange_rate_feed.sql` and
# `reversal.sql`.
#
# RESULT, 5 October: 34 mutants (33 plus a control). 22 killed on
# `fx_shapes.sql` and 12 survived; 32 of 33 across all four files, with
# one proven EQUIVALENT. The control lived.
#
# AMENDED THE SAME EVENING. The harness's new pre-flight found that the
# mutant "ANOTHER COMPANY's invoices are retranslated" matched its
# anchor TWICE -- this function's sales and purchase blocks have
# character-for-character identical `where` clauses -- so it dropped the
# org scope from BOTH, and a double mutant's kill proves neither half on
# its own. Its anchor now carries `from public.sales_documents d`, which
# only the sales block has.
#
# THE PURCHASE SIDE ALREADY HAD ITS OWN MUTANT, further down: "ANOTHER
# COMPANY's bills are retranslated", whose anchor runs on through
# `and d.status <> 'void'` and so matches the purchase block alone. A
# first attempt at this amendment added a second purchase mutant
# alongside it, having asserted in a commit message that the purchase
# side had none -- which was simply untrue, and the duplicate has been
# removed. So the double anchor left the SALES scope resting on evidence
# the purchase block could have supplied; it did not leave the purchase
# scope unmeasured.
#
# RE-MEASURED against `fx_shapes.sql` with the anchors separated: both
# die on their own, so each side's org scope really is asserted. That
# file alone kills 28 of 33, and the six that survive it are the ones
# the other three files take -- the empty run and the netting in
# `fx_revaluation.sql`, and three about WHICH prior entry is undone in
# `reversal.sql`. THE UNION HAS NOT BEEN RE-RUN across all four; the
# figure at the top of this header predates the split and should be
# replaced by whoever next sweeps the whole set.
#
#   fx_shapes.sql         kills 22, then 32
#   fx_revaluation.sql    kills the empty run and the netting
#   reversal.sql          kills three about WHICH prior entry is undone
#   exchange_rate_feed.sql kills nothing new
#
# THE FINDING WORTH MORE THAN THE REST: a VOID SALES INVOICE is excluded
# and asserted; a VOID BILL is excluded and NOT. The two halves of the
# union have six conjuncts each and `fx_shapes.sql` had built the full
# set of negatives for the sales side only -- a ringgit invoice, a
# settled one, an unposted one, a voided one -- so the purchase side's
# `d.status <> 'void'` had nothing on the other side of it. Six rules
# asserted on one half of a symmetric query and one of them unasserted
# on the other is the commonest shape there is for a union, and the only
# way to see it is to mutate each half separately. A 9,000-dollar void
# bill is now in the fixture.
#
# The rest were the date boundary (every invoice in the file is dated
# the 15th and valued on the 31st, so nothing landed ON the valuation
# day -- and an invoice raised on the last day of the month is the
# ordinary close), a deleted invoice, the contact on each of the two
# revaluation legs, and the org scope on the lookup that picks which
# prior revaluation to reverse -- made observable by another company
# whose standing adjustment is dated LATER, so it sorts first the
# moment the scope is gone.
#
# Two things make this the densest function swept so far. The SELECTION
# is a union of two queries with six conjuncts each, and the sign of the
# payable half is inverted inside the select so that one rule downstream
# ("a positive difference is a gain") serves both -- which the function's
# own comment says in those words. A mutation to that inversion keeps
# the journal balanced and turns every payable gain into a loss.
#
# And it REVERSES ITS OWN PREVIOUS RUN before measuring, so there are
# two journals in play on every run after the first. A fixture that
# revalues once cannot see any of the five conjuncts that pick which
# prior entry to undo.

m("anybody can revalue the foreign balances",
  "revalue_foreign_balances",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- revalue post guard dropped",
  "-- revalue post guard dropped")

m("the previous revaluation is not reversed, so the estimates compound",
  "revalue_foreign_balances",
  "  if v_prior is not null then\n    perform public.reverse_gl_entry(v_prior, p_as_at);",
  "  if false then\n    perform public.reverse_gl_entry(v_prior, p_as_at);"
  "  -- prior revaluation not reversed",
  "-- prior revaluation not reversed")

m("the reversal is dated the day it was typed, not the valuation date",
  "revalue_foreign_balances",
  "    perform public.reverse_gl_entry(v_prior, p_as_at);",
  "    perform public.reverse_gl_entry(v_prior, app.today());"
  "  -- reversal date forced to today",
  "-- reversal date forced to today")

m("ANOTHER COMPANY's revaluation is the one reversed",
  "revalue_foreign_balances",
  "   where e.org_id = p_org_id and e.source = 'fx_revaluation'",
  "   where e.source = 'fx_revaluation'  -- prior lookup org scope dropped",
  "-- prior lookup org scope dropped")

m("any journal at all is taken for the previous revaluation",
  "revalue_foreign_balances",
  "   where e.org_id = p_org_id and e.source = 'fx_revaluation'",
  "   where e.org_id = p_org_id  -- prior lookup source dropped",
  "-- prior lookup source dropped")

m("a REVERSAL of a revaluation is itself reversed",
  "revalue_foreign_balances",
  "     and e.status = 'posted' and e.is_reversal = false",
  "     and e.status = 'posted'  -- is_reversal no longer checked",
  "-- is_reversal no longer checked")

m("a revaluation already reversed by hand is reversed a second time",
  "revalue_foreign_balances",
  "     and not exists (select 1 from public.gl_entries x\n"
  "                      where x.reversed_entry_id = e.id and x.status = 'posted')",
  "     and true  -- already-reversed check dropped",
  "-- already-reversed check dropped")

# EQUIVALENT, proven by the function's own invariant plus the absence of
# any unpost path. There can never be two rows for the ORDER BY to
# choose between: each run reverses the single candidate it finds before
# posting at most one new one, a reversal carries `is_reversal = true`
# and is excluded by the conjunct above, and a reversed entry is
# excluded by the `not exists`. The only state with two candidates needs
# a reversal that is no longer `posted`, and this schema has no function
# that unposts or voids a gl_entry -- checked, not assumed; the undo
# everywhere is another reversal. So the ORDER BY is right, would be
# load-bearing the day that invariant broke, and is unobservable today.
m("the OLDEST revaluation is reversed rather than the latest",
  "revalue_foreign_balances",
  "   order by e.entry_date desc, e.created_at desc",
  "   order by e.entry_date, e.created_at  -- prior order reversed",
  "-- prior order reversed")

m("the contact's OWN receivable account is ignored for the chart's 1210",
  "revalue_foreign_balances",
  "      select coalesce(c.receivable_account_id,",
  "      select coalesce(null::uuid,  -- own receivable account ignored",
  "-- own receivable account ignored")

m("the contact's OWN payable account is ignored for the chart's 2110",
  "revalue_foreign_balances",
  "      select coalesce(c.payable_account_id,",
  "      select coalesce(null::uuid,  -- own payable account ignored",
  "-- own payable account ignored")

m("RINGGIT invoices are retranslated too",
  "revalue_foreign_balances",
  "       where d.org_id = p_org_id and d.currency <> v_base\n"
  "         and d.balance_amount <> 0 and d.doc_date <= p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n"
  "      union all",
  "       where d.org_id = p_org_id\n"
  "         and d.balance_amount <> 0 and d.doc_date <= p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'  -- base currency no longer excluded\n"
  "      union all",
  "-- base currency no longer excluded")

# TWO MUTANTS, and until 5 October there was one. This function has
# symmetric SALES and PURCHASE blocks whose `where` clauses are
# character-for-character identical, so the single anchor matched TWICE
# and `source.replace` dropped the org scope from BOTH. That is not the
# mutant the label named: it is a double mutant, and killing a double
# mutant proves neither half on its own -- the purchase side alone could
# have done it, leaving the sales scope unasserted and reported as
# covered. The purchase side meanwhile had no mutant at all.
#
# Found by the harness's own pre-flight once it learned to count
# matches, which is the whole argument for having one: the old run
# reported a kill and said nothing.
#
# The anchors now carry the line that distinguishes them -- the table
# each block reads.
m("ANOTHER COMPANY's INVOICES are retranslated",
  "revalue_foreign_balances",
  "        from public.sales_documents d\n"
  "        join public.contacts c on c.id = d.contact_id\n"
  "       where d.org_id = p_org_id and d.currency <> v_base",
  "        from public.sales_documents d\n"
  "        join public.contacts c on c.id = d.contact_id\n"
  "       where d.currency <> v_base  -- sales org scope dropped",
  "-- sales org scope dropped")


m("an invoice dated the valuation day ITSELF is left out",
  "revalue_foreign_balances",
  "         and d.balance_amount <> 0 and d.doc_date <= p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n"
  "      union all",
  "         and d.balance_amount <> 0 and d.doc_date < p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'  -- sales date boundary narrowed\n"
  "      union all",
  "-- sales date boundary narrowed")

m("an invoice dated AFTER the valuation day is retranslated",
  "revalue_foreign_balances",
  "         and d.balance_amount <> 0 and d.doc_date <= p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n"
  "      union all",
  "         and d.balance_amount <> 0\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'  -- sales date no longer checked\n"
  "      union all",
  "-- sales date no longer checked")

m("a DELETED invoice is retranslated",
  "revalue_foreign_balances",
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n"
  "      union all",
  "         and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'  -- sales deleted_at dropped\n"
  "      union all",
  "-- sales deleted_at dropped")

m("an UNPOSTED invoice is retranslated, against a ledger it never reached",
  "revalue_foreign_balances",
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n"
  "      union all",
  "         and d.deleted_at is null\n"
  "         and d.status <> 'void'  -- sales posted check dropped\n"
  "      union all",
  "-- sales posted check dropped")

m("a VOID invoice is retranslated",
  "revalue_foreign_balances",
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n"
  "      union all",
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "      union all  -- sales void check dropped",
  "-- sales void check dropped")

m("a PAYABLE is signed like a receivable, so its gain reads as a loss",
  "revalue_foreign_balances",
  "             -d.balance_amount, coalesce(d.exchange_rate, 1)",
  "             d.balance_amount, coalesce(d.exchange_rate, 1)"
  "  -- payable sign dropped",
  "-- payable sign dropped")

m("a VOID bill is retranslated",
  "revalue_foreign_balances",
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n    )",
  "         and d.deleted_at is null and d.gl_entry_id is not null\n    )"
  "  -- purchase void check dropped",
  "-- purchase void check dropped")

m("ANOTHER COMPANY's bills are retranslated",
  "revalue_foreign_balances",
  "       where d.org_id = p_org_id and d.currency <> v_base\n"
  "         and d.balance_amount <> 0 and d.doc_date <= p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'\n    )",
  "       where d.currency <> v_base\n"
  "         and d.balance_amount <> 0 and d.doc_date <= p_as_at\n"
  "         and d.deleted_at is null and d.gl_entry_id is not null\n"
  "         and d.status <> 'void'  -- purchase org scope dropped\n    )",
  "-- purchase org scope dropped")

m("the rate the document was BOOKED at is taken as one",
  "revalue_foreign_balances",
  "             d.balance_amount as amount, coalesce(d.exchange_rate, 1) as rate",
  "             d.balance_amount as amount, 1 as rate  -- booked rate ignored",
  "-- booked rate ignored")

m("the balance is retranslated at the rate it was booked at",
  "revalue_foreign_balances",
  "           round(sum(i.amount * app.exchange_rate_for(p_org_id, i.currency, p_as_at))\n"
  "               - sum(i.amount * i.rate), 2) as diff",
  "           round(sum(i.amount * i.rate)\n"
  "               - sum(i.amount * i.rate), 2) as diff  -- closing rate ignored",
  "-- closing rate ignored")

m("the balances of two CONTACTS are netted into one line",
  "revalue_foreign_balances",
  "     group by i.account_id, i.contact_id, i.currency",
  "     group by i.account_id, i.currency  -- contact no longer grouped",
  "-- contact no longer grouped")

m("two CURRENCIES are netted into one line",
  "revalue_foreign_balances",
  "     group by i.account_id, i.contact_id, i.currency",
  "     group by i.account_id, i.contact_id  -- currency no longer grouped",
  "-- currency no longer grouped")

m("a balance whose rate has not moved gets a line of nothing",
  "revalue_foreign_balances",
  "    having round(sum(i.amount * app.exchange_rate_for(p_org_id, i.currency, p_as_at))\n"
  "              - sum(i.amount * i.rate), 2) <> 0",
  "    having true  -- nil difference lines kept",
  "-- nil difference lines kept")

m("a gain is CREDITED to the receivable, so the debtor shrinks",
  "revalue_foreign_balances",
  "        'debit', r.diff, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,",
  "        'debit', 0, 'credit', r.diff, 'fc_debit', 0, 'fc_credit', 0,"
  "  -- gain side swapped",
  "-- gain side swapped")

m("the revaluation is not recorded against the contact it belongs to",
  "revalue_foreign_balances",
  "        'debit', r.diff, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,\n"
  "        'contact_id', r.contact_id);",
  "        'debit', r.diff, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,\n"
  "        'contact_id', null);  -- gain leg contact dropped",
  "-- gain leg contact dropped")

m("a LOSS is not recorded against its contact either",
  "revalue_foreign_balances",
  "        'debit', 0, 'credit', -r.diff, 'fc_debit', 0, 'fc_credit', 0,\n"
  "        'contact_id', r.contact_id);",
  "        'debit', 0, 'credit', -r.diff, 'fc_debit', 0, 'fc_credit', 0,\n"
  "        'contact_id', null);  -- loss leg contact dropped",
  "-- loss leg contact dropped")

m("a run that found nothing to revalue posts an empty journal",
  "revalue_foreign_balances",
  "  if v_gain = 0 and v_loss = 0 then\n    return null;",
  "  if false then\n    return null;  -- empty run still posts",
  "-- empty run still posts")

m("the gain and the loss are NETTED instead of stated separately",
  "revalue_foreign_balances",
  "  if v_gain <> 0 then\n"
  "    v_entries := v_entries || jsonb_build_object(\n"
  "      'account_id', app.fx_account(p_org_id, true),",
  "  if v_gain - v_loss > 0 then\n"
  "    v_entries := v_entries || jsonb_build_object(\n"
  "      'account_id', app.fx_account(p_org_id, true),  -- gain netted",
  "-- gain netted")

m("the GAIN is posted to the LOSS account",
  "revalue_foreign_balances",
  "      'account_id', app.fx_account(p_org_id, true),",
  "      'account_id', app.fx_account(p_org_id, false),  -- gain account swapped",
  "-- gain account swapped")

m("the LOSS is posted to the GAIN account",
  "revalue_foreign_balances",
  "      'account_id', app.fx_account(p_org_id, false),",
  "      'account_id', app.fx_account(p_org_id, true),  -- loss account swapped",
  "-- loss account swapped")

m("the revaluation journal is dated the day it was typed",
  "revalue_foreign_balances",
  "    p_org_id, p_as_at, 'fx_revaluation'::app.journal_source, v_entries,",
  "    p_org_id, app.today(), 'fx_revaluation'::app.journal_source, v_entries,"
  "  -- revaluation date forced to today",
  "-- revaluation date forced to today")

m("CONTROL -- a comment beside the base currency",
  "revalue_foreign_balances",
  "  v_base := app.base_currency(p_org_id);",
  "  v_base := app.base_currency(p_org_id);"
  "  -- CONTROL: this cannot change a currency.",
  "-- CONTROL: this cannot change a currency.")
