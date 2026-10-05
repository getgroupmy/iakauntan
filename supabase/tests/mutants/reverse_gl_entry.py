# Mutants for public.reverse_gl_entry -- the contra entry that cancels a
# posted journal: a new header pointing back at the original, and every
# line copied with debit and credit swapped.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/reversal.sql \
#       supabase/tests/mutants/reverse_gl_entry.py
#
# then again against the other fifteen files that reach it.
#
# SIXTEEN test files call this function, which by the lesson
# `run_recurring_journals` taught is not a coverage figure -- it is a
# list of files to read. Most of them reverse something incidentally, on
# the way to asserting that a bank balance or an aged list came back to
# where it started, and a balance is one number whichever way the two
# halves of the contra are written.
#
# `0421` is called "what day the money moved", and the date is the thing
# it exists to fix: a reversal takes the date it is GIVEN, posts into
# that date's period, and refuses if that period is shut. Three of the
# mutants below are about nothing else.
#
# NOT A MUTANT -- A DEFECT, reported in `docs/handoff.md` and NOT fixed
# here: the line copy names twelve columns and `gl_lines` has six more
# that carry meaning. `fc_debit`, `fc_credit`, `tax_amount`,
# `project_code`, `department_code` and `matter_id` are all dropped, so
# the ringgit side of a reversal nets to zero and the foreign-currency
# side, the tax, the dimensions and the matter do not. Reproduced on a
# USD bill; see the handoff. A mutation sweep cannot find an omission --
# it breaks what is there -- which is why this one was found by reading
# the insert against the table and is recorded here rather than below.
#
# RESULT, 5 October: 34 mutants (33 plus a control), against ALL
# SIXTEEN callers.
#
#   ledger.sql                 16      deposits.sql                5
#   reversal.sql               13      post_dated_cheques.sql      5
#   fx_shapes.sql              11      property.sql                5
#   fx_revaluation.sql         10      ledger_append_only.sql      4
#   bank_reconciliation.sql     9      statement_of_account.sql    3
#   bank_transfers.sql          9      exchange_rate_feed.sql      0
#   bank_balance_resync.sql     9
#   void_an_invoice.sql         8
#   opening_trial_balance.sql   8
#   contra.sql                  5
#
# 19 of 33 before the work. 33 of 33 on `reversal.sql` ALONE after it,
# nothing equivalent, control alive on every file.
#
# THE FILE NAMED AFTER THE FUNCTION IS NOT ITS BEST COVERAGE.
# `ledger.sql` kills 16 and `reversal.sql` 13, and `reversal.sql`'s own
# header says why, accurately and modestly: "one assertion, made three
# times against the three callers: a reversal has to come to nothing."
# This sweep is what that modesty cost -- 20 of 33 -- and the honest
# reading is not that the comment was wrong. It was right. A file can
# state its own limit plainly and still leave two thirds of a function
# unasserted, and only a measurement says which two thirds.
#
# EVERY ONE OF THE 14 SURVIVORS WAS SOMETHING THAT DOES NOT MOVE A
# BALANCE. Sixteen files reverse something, every one of them nets to
# zero, and a balance is one number whichever way the contra is written:
#
#   * all four guards -- a journal that is not there, a stranger, a
#     draft, and a reversal that was itself voided;
#   * `0059`'s period machinery: a locked period, taken by
#     `fx_revaluation.sql` for the closed one and nothing else;
#   * `0421`'s DATE machinery. This migration is called "what day the
#     money moved" and two of its three date mutants lived -- including
#     `coalesce(p_date, app.today())` collapsing to `p_date`, which
#     leaves a reversal called with no date refusing instead of landing
#     today;
#   * the provenance: the contra could call itself a manual journal,
#     forget which document it reverses, drop the reference, post a USD
#     journal in ringgit at a rate of one, lose the word "Reversal" from
#     every line, and forget who and what each line was for.
#
# NOT A MUTANT -- A DEFECT, reported in `docs/handoff.md` and NOT fixed
# here: the line copy names twelve columns and `gl_lines` has six more
# that carry meaning. See the note below the header.

# ------------------------------------------------------------ the guards

m("a journal that does not exist is reversed anyway",
  "reverse_gl_entry",
  "  if not found then raise exception 'Journal % not found', p_entry_id; end if;",
  "  if false then raise exception 'Journal % not found', p_entry_id; end if;"
  "  -- missing journal refusal dropped",
  "-- missing journal refusal dropped")

m("anybody can reverse a posted journal",
  "reverse_gl_entry",
  "  if not app.can_post(v_entry.org_id) then",
  "  if false then  -- reversal post guard dropped",
  "-- reversal post guard dropped")

m("a DRAFT journal can be reversed",
  "reverse_gl_entry",
  "  if v_entry.status <> 'posted' then",
  "  if false then  -- posted-only check dropped",
  "-- posted-only check dropped")

m("only UNPOSTED journals can be reversed",
  "reverse_gl_entry",
  "  if v_entry.status <> 'posted' then",
  "  if v_entry.status = 'posted' then  -- posted-only check inverted",
  "-- posted-only check inverted")

m("a journal can be reversed TWICE, which puts it back",
  "reverse_gl_entry",
  "  if exists (select 1 from public.gl_entries r\n"
  "              where r.reversed_entry_id = p_entry_id and r.status = 'posted') then",
  "  if false then  -- double-reversal check dropped",
  "-- double-reversal check dropped")

m("a VOIDED reversal still blocks a second attempt",
  "reverse_gl_entry",
  "              where r.reversed_entry_id = p_entry_id and r.status = 'posted') then",
  "              where r.reversed_entry_id = p_entry_id) then"
  "  -- voided reversals count as blocking",
  "-- voided reversals count as blocking")

m("the double-reversal check looks at the wrong journal",
  "reverse_gl_entry",
  "              where r.reversed_entry_id = p_entry_id and r.status = 'posted') then",
  "              where r.id = p_entry_id and r.status = 'posted') then"
  "  -- double-reversal check reads the original",
  "-- double-reversal check reads the original")

# -------------------------------------------------------- the period

m("the reversal is posted into the ORIGINAL's period",
  "reverse_gl_entry",
  "  v_period_id := app.period_for_date(v_entry.org_id, v_on);",
  "  v_period_id := app.period_for_date(v_entry.org_id, v_entry.entry_date);"
  "  -- period taken from the original",
  "-- period taken from the original")

m("a reversal dated outside every fiscal year is posted anyway",
  "reverse_gl_entry",
  "  if v_period_id is null then",
  "  if false then  -- missing period refusal dropped",
  "-- missing period refusal dropped")

m("a CLOSED period accepts a reversal",
  "reverse_gl_entry",
  "  if v_status <> 'open' then",
  "  if false then  -- closed period refusal dropped",
  "-- closed period refusal dropped")

m("a LOCKED period accepts a reversal, only a closed one does not",
  "reverse_gl_entry",
  "  if v_status <> 'open' then",
  "  if v_status = 'closed' then  -- only `closed` refused",
  "-- only `closed` refused")

# ---------------------------------------------------------- the date

m("the date the caller asked for is ignored",
  "reverse_gl_entry",
  "  v_on date := coalesce(p_date, app.today());",
  "  v_on date := app.today();  -- caller's date ignored",
  "-- caller's date ignored")

m("a reversal with no date given lands nowhere",
  "reverse_gl_entry",
  "  v_on date := coalesce(p_date, app.today());",
  "  v_on date := p_date;  -- today fallback dropped",
  "-- today fallback dropped")

m("the reversal is dated the day the original was",
  "reverse_gl_entry",
  "    v_on, v_period_id, v_entry.source,",
  "    v_entry.entry_date, v_period_id, v_entry.source,"
  "  -- reversal dated the original's day",
  "-- reversal dated the original's day")

# -------------------------------------------------------- the header

m("the reversal takes the original's document number",
  "reverse_gl_entry",
  "    v_entry.org_id, app.next_document_number_internal(v_entry.org_id, 'journal'),",
  "    v_entry.org_id, v_entry.entry_no,  -- document number reused",
  "-- document number reused")

m("a reversal of a bill calls itself a manual journal",
  "reverse_gl_entry",
  "    v_on, v_period_id, v_entry.source,",
  "    v_on, v_period_id, 'manual'::app.journal_source,"
  "  -- reversal source lied about",
  "-- reversal source lied about")

m("the reversal does not say what it reverses the posting OF",
  "reverse_gl_entry",
  "    v_entry.source_table, v_entry.source_id,",
  "    null, null,  -- source document forgotten",
  "-- source document forgotten")

m("the reversal copies the original's description instead of naming it",
  "reverse_gl_entry",
  "    'Reversal of ' || v_entry.entry_no, v_entry.reference,",
  "    v_entry.description, v_entry.reference,"
  "  -- reversal not named as one",
  "-- reversal not named as one")

m("the reversal drops the original's reference",
  "reverse_gl_entry",
  "    'Reversal of ' || v_entry.entry_no, v_entry.reference,",
  "    'Reversal of ' || v_entry.entry_no, null,"
  "  -- reference dropped from the header",
  "-- reference dropped from the header")

m("a reversal of a USD journal is posted in ringgit",
  "reverse_gl_entry",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,",
  "    app.base_currency(v_entry.org_id), v_entry.exchange_rate, 'posted', true, v_entry.id,"
  "  -- header currency forced to base",
  "-- header currency forced to base")

m("the reversal is rated at one, whatever the original was",
  "reverse_gl_entry",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,",
  "    v_entry.currency, 1, 'posted', true, v_entry.id,"
  "  -- header rate forced to one",
  "-- header rate forced to one")

m("the reversal is left as a DRAFT, so nothing is actually reversed",
  "reverse_gl_entry",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,",
  "    v_entry.currency, v_entry.exchange_rate, 'draft', true, v_entry.id,"
  "  -- reversal left in draft",
  "-- reversal left in draft")

m("the reversal does not declare itself a reversal",
  "reverse_gl_entry",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', false, v_entry.id,"
  "  -- is_reversal flag dropped",
  "-- is_reversal flag dropped")

# `reversed_entry_id` is what the double-reversal check reads, so losing
# it does two things at once: the pair cannot be walked, and the journal
# can be reversed again and again.
m("the reversal does not point back at what it reversed",
  "reverse_gl_entry",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', true, v_entry.id,",
  "    v_entry.currency, v_entry.exchange_rate, 'posted', true, null,"
  "  -- back-pointer dropped",
  "-- back-pointer dropped")

# --------------------------------------------------------- the lines

# The one mutant this whole function is about. Both halves still
# BALANCE, so `assert_gl_balanced` passes and every total in the suite
# that reads a trial balance passes with it -- the pair simply doubles
# the original instead of cancelling it.
m("THE LINES ARE NOT SWAPPED, so the pair doubles instead of cancelling",
  "reverse_gl_entry",
  "         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id",
  "         debit, credit, currency, exchange_rate, contact_id, item_id, tax_code_id"
  "  -- debit and credit not swapped",
  "-- debit and credit not swapped")

m("every reversal line is line one",
  "reverse_gl_entry",
  "  select org_id, v_new_id, line_no, account_id,",
  "  select org_id, v_new_id, 1, account_id,  -- line numbers collapsed",
  "-- line numbers collapsed")

m("the reversal lines are not marked as reversals",
  "reverse_gl_entry",
  "         'Reversal: ' || coalesce(description, ''),",
  "         description,  -- line not named as a reversal",
  "-- line not named as a reversal")

# A line with no description of its own makes `'Reversal: ' || null` null
# WITHOUT the coalesce, so the whole description disappears rather than
# reading `Reversal: `.
m("a line with no description of its own loses the word Reversal too",
  "reverse_gl_entry",
  "         'Reversal: ' || coalesce(description, ''),",
  "         'Reversal: ' || description,  -- null description swallows the label",
  "-- null description swallows the label")

m("the reversal lines are posted in ringgit at one",
  "reverse_gl_entry",
  "         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id",
  "         credit, debit, app.base_currency(org_id), 1, contact_id, item_id, tax_code_id"
  "  -- line currency and rate forced to base",
  "-- line currency and rate forced to base")

m("the reversal forgets who and what each line was for",
  "reverse_gl_entry",
  "         credit, debit, currency, exchange_rate, contact_id, item_id, tax_code_id",
  "         credit, debit, currency, exchange_rate, null, null, null"
  "  -- line dimensions dropped",
  "-- line dimensions dropped")

# INVERTED rather than dropped: `where entry_id <> p_entry_id` copies
# every OTHER journal's lines, which is deterministic. Simply removing
# the predicate would do the same thing plus the original, and either
# way the point is that the copy is scoped to one journal.
m("every OTHER journal's lines are copied into the reversal",
  "reverse_gl_entry",
  "    from public.gl_lines where entry_id = p_entry_id;",
  "    from public.gl_lines where entry_id <> p_entry_id;"
  "  -- line copy no longer scoped to the journal",
  "-- line copy no longer scoped to the journal")

m("the reversal is given no lines at all",
  "reverse_gl_entry",
  "    from public.gl_lines where entry_id = p_entry_id;",
  "    from public.gl_lines where entry_id = v_new_id;"
  "  -- line copy reads the new journal",
  "-- line copy reads the new journal")

# -------------------------------------------------------- the return

m("the caller is handed back the journal it asked to reverse",
  "reverse_gl_entry",
  "  return v_new_id;\nend; $$;",
  "  return p_entry_id;  -- original returned instead of the reversal\nend; $$;",
  "-- original returned instead of the reversal")

m("CONTROL -- a comment beside the declaration",
  "reverse_gl_entry",
  "  v_new_id uuid;",
  "  v_new_id uuid;  -- CONTROL: this cannot change a balance.",
  "-- CONTROL: this cannot change a balance.")
