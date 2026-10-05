# Mutants for public.import_open_invoices and public.import_open_bills
# -- the two halves of bringing a predecessor's open items onto the
# ledger on changeover day.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0150_import_open_items.sql \
#       supabase/tests/open_item_import.sql \
#       supabase/tests/mutants/open_item_import.py
#
# then again against `opening_trial_balance.sql`,
# `migration_progress.sql`, `cash_is_not_credit.sql` and
# `opening_balance_credit.sql`.
#
# RESULT, 5 October: 55 mutants (53 plus two controls, one per
# function). 39 killed on `open_item_import.sql` and 16 survived; 49 of
# 53 across all five files, with FOUR proven EQUIVALENT -- two pairs,
# both pairs equivalent on both sides. Both controls lived.
#
#   open_item_import.sql       kills 39, then 45
#   opening_trial_balance.sql  kills the contact org scope, both halves
#   cash_is_not_credit.sql     kills "invoice reads as already paid"
#   migration_progress.sql     kills "bill filed as this year's trading"
#
# THE PER-FILE RESULT WAS ASYMMETRIC IN BOTH DIRECTIONS AT ONCE, which
# is the measurement this file was written to take. On
# `open_item_import.sql`:
#
#   "the opening document reads as already paid"   invoice LIVED, bill DIED
#   "the journal is filed as this year's trading"  bill LIVED, invoice DIED
#
# Each half had an assertion the other lacked, and they were DIFFERENT
# assertions -- so neither half was the thorough one, and a reader
# comparing the two would have concluded both were covered. The union
# closed both, from two different files.
#
# AND THE EIGHT THAT SURVIVED EVERYWHERE CAME IN FOUR PERFECT PAIRS.
# The halves end up with the same holes once every file is counted; it
# is only the route to each hole that differs. Four of the eight were
# real -- the contact code's case, the currency's case, both on both
# sides -- and four were the two equivalent pairs below.
#
# The real four are what a predecessor's export actually looks like: the
# contact code spelled however the old system spelled it, and the
# currency in lower case. Every row in the suite until now was 'C-001'
# exactly and 'USD' or nothing, so `lower()` and `upper()` each had
# nothing on the other side of them.
#
# WRITTEN AS ONE FILE ON PURPOSE. The two functions are near
# line-for-line symmetric -- same guards, same coalesces, same contact
# lookup, same two-leg journal with the sides mirrored -- so the TWENTY
# shared rules below are generated from one table and applied to both.
# Any difference in the kill sheet is a difference in COVERAGE, not in
# the code, and that is exactly the finding `revalue_foreign_balances`
# and `receive_stock_transfer` both produced today: the two halves of a
# symmetric thing do not get symmetric coverage.
#
# The asymmetric ones are written out at the end: a sales document
# carries an `einvoice_status` and a bill carries the supplier's own
# document number, and each has a rule the other does not.

m('invoice: the run is not checked before it is allowed to write',
  'import_open_invoices',
  '  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);',
  '  -- run check dropped: perform app.check_open_item_run(p_org_id, p_rows, p_as_at);',
  '-- run check dropped')

m('bill: the run is not checked before it is allowed to write',
  'import_open_bills',
  '  perform app.check_open_item_run(p_org_id, p_rows, p_as_at);',
  '  -- run check dropped: perform app.check_open_item_run(p_org_id, p_rows, p_as_at);',
  '-- run check dropped')

m('invoice: a file with errors in it is imported anyway',
  'import_open_invoices',
  '  if p_commit and v_bad > 0 then',
  '  if false then  -- bad rows no longer stop the run',
  '-- bad rows no longer stop the run')

m('bill: a file with errors in it is imported anyway',
  'import_open_bills',
  '  if p_commit and v_bad > 0 then',
  '  if false then  -- bad rows no longer stop the run',
  '-- bad rows no longer stop the run')

m('invoice: a DRY RUN writes the documents',
  'import_open_invoices',
  '  if p_commit then\n    select base_currency into v_base',
  '  if true then  -- dry run writes\n    select base_currency into v_base',
  '-- dry run writes')

m('bill: a DRY RUN writes the documents',
  'import_open_bills',
  '  if p_commit then\n    select base_currency into v_base',
  '  if true then  -- dry run writes\n    select base_currency into v_base',
  '-- dry run writes')

m('invoice: a currency given in lower case is not recognised',
  'import_open_invoices',
  "      v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));",
  "      v_currency := coalesce(app.import_text(r, 'currency'), v_base);  -- currency case no longer folded",
  '-- currency case no longer folded')

m('bill: a currency given in lower case is not recognised',
  'import_open_bills',
  "      v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));",
  "      v_currency := coalesce(app.import_text(r, 'currency'), v_base);  -- currency case no longer folded",
  '-- currency case no longer folded')

m('invoice: a row with no currency is imported with none',
  'import_open_invoices',
  "      v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));",
  "      v_currency := upper(app.import_text(r, 'currency'));  -- base currency fallback dropped",
  '-- base currency fallback dropped')

m('bill: a row with no currency is imported with none',
  'import_open_bills',
  "      v_currency := upper(coalesce(app.import_text(r, 'currency'), v_base));",
  "      v_currency := upper(app.import_text(r, 'currency'));  -- base currency fallback dropped",
  '-- base currency fallback dropped')

m('invoice: a row with no rate is converted at nothing',
  'import_open_invoices',
  "      v_rate     := coalesce(app.import_number(\n                      app.import_text(r, 'exchange_rate'), null), 1);",
  "      v_rate     := app.import_number(\n                      app.import_text(r, 'exchange_rate'), null);  -- rate fallback dropped",
  '-- rate fallback dropped')

m('bill: a row with no rate is converted at nothing',
  'import_open_bills',
  "      v_rate     := coalesce(app.import_number(\n                      app.import_text(r, 'exchange_rate'), null), 1);",
  "      v_rate     := app.import_number(\n                      app.import_text(r, 'exchange_rate'), null);  -- rate fallback dropped",
  '-- rate fallback dropped')

m('invoice: a row with no due date gets none',
  'import_open_invoices',
  "      v_due      := coalesce(app.import_date(app.import_text(r, 'due_date')),\n                             v_date);",
  "      v_due      := app.import_date(app.import_text(r, 'due_date'));  -- due date fallback dropped",
  '-- due date fallback dropped')

m('bill: a row with no due date gets none',
  'import_open_bills',
  "      v_due      := coalesce(app.import_date(app.import_text(r, 'due_date')),\n                             v_date);",
  "      v_due      := app.import_date(app.import_text(r, 'due_date'));  -- due date fallback dropped",
  '-- due date fallback dropped')

m('invoice: a contact code in the wrong case is not found',
  'import_open_invoices',
  "         and lower(c.code) = lower(app.import_text(r, 'contact_code'))",
  "         and c.code = app.import_text(r, 'contact_code')  -- contact code case no longer folded",
  '-- contact code case no longer folded')

m('bill: a contact code in the wrong case is not found',
  'import_open_bills',
  "         and lower(c.code) = lower(app.import_text(r, 'contact_code'))",
  "         and c.code = app.import_text(r, 'contact_code')  -- contact code case no longer folded",
  '-- contact code case no longer folded')

m("invoice: ANOTHER COMPANY's contact is matched",
  'import_open_invoices',
  "       where c.org_id = p_org_id\n         and lower(c.code) = lower(app.import_text(r, 'contact_code'))",
  "       where lower(c.code) = lower(app.import_text(r, 'contact_code'))  -- contact org scope dropped",
  '-- contact org scope dropped')

m("bill: ANOTHER COMPANY's contact is matched",
  'import_open_bills',
  "       where c.org_id = p_org_id\n         and lower(c.code) = lower(app.import_text(r, 'contact_code'))",
  "       where lower(c.code) = lower(app.import_text(r, 'contact_code'))  -- contact org scope dropped",
  '-- contact org scope dropped')

# EQUIVALENT on BOTH sides, proven by the VALIDATOR. Both import loops
# look the contact up with `and c.deleted_at is null`, and so does
# app.validate_open_items -- which runs FIRST on the same rows, marks a
# row whose contact it cannot find as an error, and then
# `if p_commit and v_bad > 0` raises before the loop runs at all. A row
# naming a deleted contact can never reach the import's own lookup.
# Right to keep: the two lookups are meant to agree, and this is the one
# that would matter the day the validator's filter changed.
m('invoice: a DELETED contact is matched',
  'import_open_invoices',
  '         and c.deleted_at is null;',
  '         and true;  -- deleted contacts matched',
  '-- deleted contacts matched')

m('bill: a DELETED contact is matched',
  'import_open_bills',
  '         and c.deleted_at is null;',
  '         and true;  -- deleted contacts matched',
  '-- deleted contacts matched')

# EQUIVALENT on BOTH sides, and proven by a TRIGGER -- a third kind of
# proof, after "the code's own shape" and "the table's constraints".
# `recalc_sales_totals_header` (and its purchase twin) fires on the LINE
# insert two statements later and sets
# `base_total_amount = round(<rounded total> * coalesce(exchange_rate, 1), 2)`
# on the header, so whatever the document insert put there is
# overwritten before anybody can read it. `open_item_import.sql` asserts
# the figure that SURVIVES (4,250.00 on USD 1,000 at 4.25), which is
# worth having and is not what kills this mutant -- nothing can.
m("invoice: the document's base total is not converted",
  'import_open_invoices',
  '        v_amount, 0, v_amount, round(v_amount * v_rate, 2),',
  '        v_amount, 0, v_amount, v_amount,  -- base total not converted',
  '-- base total not converted')

m("bill: the document's base total is not converted",
  'import_open_bills',
  '        v_amount, 0, v_amount, round(v_amount * v_rate, 2),',
  '        v_amount, 0, v_amount, v_amount,  -- base total not converted',
  '-- base total not converted')

m('invoice: the opening document reads as already paid',
  'import_open_invoices',
  "        0, v_amount, 'posted',",
  "        v_amount, 0, 'posted',  -- opening document reads as paid",
  '-- opening document reads as paid')

m('bill: the opening document reads as already paid',
  'import_open_bills',
  "        0, v_amount, 'posted',",
  "        v_amount, 0, 'posted',  -- opening document reads as paid",
  '-- opening document reads as paid')

m('invoice: the line has no description of its own and gets none',
  'import_open_invoices',
  "        coalesce(app.import_text(r, 'description'),\n                 'Balance brought forward'),",
  "        app.import_text(r, 'description'),  -- line description fallback dropped",
  '-- line description fallback dropped')

m('bill: the line has no description of its own and gets none',
  'import_open_bills',
  "        coalesce(app.import_text(r, 'description'),\n                 'Balance brought forward'),",
  "        app.import_text(r, 'description'),  -- line description fallback dropped",
  '-- line description fallback dropped')

m('invoice: the line is coded to nothing instead of to opening balances',
  'import_open_invoices',
  '        1, v_amount, 0, 0, v_amount, v_amount, v_equity);',
  '        1, v_amount, 0, 0, v_amount, v_amount, null);  -- line account dropped',
  '-- line account dropped')

m('bill: the line is coded to nothing instead of to opening balances',
  'import_open_bills',
  '        1, v_amount, 0, 0, v_amount, v_amount, v_equity);',
  '        1, v_amount, 0, 0, v_amount, v_amount, null);  -- line account dropped',
  '-- line account dropped')

m("invoice: the journal takes the DOCUMENT's date rather than the import date",
  'import_open_invoices',
  "        p_org_id, p_as_at, 'opening_balance'::app.journal_source,",
  "        p_org_id, v_date, 'opening_balance'::app.journal_source,  -- journal takes the document date",
  '-- journal takes the document date')

m("bill: the journal takes the DOCUMENT's date rather than the import date",
  'import_open_bills',
  "        p_org_id, p_as_at, 'opening_balance'::app.journal_source,",
  "        p_org_id, v_date, 'opening_balance'::app.journal_source,  -- journal takes the document date",
  '-- journal takes the document date')

m("invoice: the journal is filed as this year's trading",
  'import_open_invoices',
  "        p_org_id, p_as_at, 'opening_balance'::app.journal_source,",
  "        p_org_id, p_as_at, 'manual'::app.journal_source,  -- journal source changed",
  '-- journal source changed')

m("bill: the journal is filed as this year's trading",
  'import_open_bills',
  "        p_org_id, p_as_at, 'opening_balance'::app.journal_source,",
  "        p_org_id, p_as_at, 'manual'::app.journal_source,  -- journal source changed",
  '-- journal source changed')

m("invoice: the journal is not converted at the row's rate",
  'import_open_invoices',
  "            'debit', round(v_amount * v_rate, 2), 'credit', 0,",
  "            'debit', v_amount, 'credit', 0,  -- first leg not converted",
  '-- first leg not converted')

# The ONE line where the two bodies genuinely differ in SHAPE rather
# than in meaning: the invoice's first leg is the receivable and carries
# a contact after it, so it ends in a comma; the bill's first leg is
# equity and closes the object. The harness REFUSED the shared anchor on
# the bill side rather than silently matching nothing, which is exactly
# what its landed check exists for -- a mutation that does not apply is
# reported as a harness error, never as a survivor.
m("bill: the journal is not converted at the row's rate",
  "import_open_bills",
  "            'debit', round(v_amount * v_rate, 2), 'credit', 0),",
  "            'debit', v_amount, 'credit', 0),  -- first leg not converted",
  "-- first leg not converted")

m('invoice: the document is left unposted',
  'import_open_invoices',
  '         set gl_entry_id = v_entry_id, posted_at = now(), posted_by = auth.uid()',
  '         set posted_at = now(), posted_by = auth.uid()  -- document not linked to its journal',
  '-- document not linked to its journal')

m('bill: the document is left unposted',
  'import_open_bills',
  '         set gl_entry_id = v_entry_id, posted_at = now(), posted_by = auth.uid()',
  '         set posted_at = now(), posted_by = auth.uid()  -- document not linked to its journal',
  '-- document not linked to its journal')

m('invoice: nothing records WHEN the opening balance was brought in',
  'import_open_invoices',
  '         set gl_entry_id = v_entry_id, posted_at = now(), posted_by = auth.uid()',
  '         set gl_entry_id = v_entry_id, posted_by = auth.uid()  -- posted_at not recorded',
  '-- posted_at not recorded')

m('bill: nothing records WHEN the opening balance was brought in',
  'import_open_bills',
  '         set gl_entry_id = v_entry_id, posted_at = now(), posted_by = auth.uid()',
  '         set gl_entry_id = v_entry_id, posted_by = auth.uid()  -- posted_at not recorded',
  '-- posted_at not recorded')

m('invoice: a committed run still reports every row as merely valid',
  'import_open_invoices',
  '      select jsonb_agg(jsonb_set(x, \'{status}\', \'"imported"\'))',
  '      select jsonb_agg(x)  -- rows not relabelled as imported',
  '-- rows not relabelled as imported')

m('bill: a committed run still reports every row as merely valid',
  'import_open_bills',
  '      select jsonb_agg(jsonb_set(x, \'{status}\', \'"imported"\'))',
  '      select jsonb_agg(x)  -- rows not relabelled as imported',
  '-- rows not relabelled as imported')

# ---------------------------------------------------------------------
# The asymmetric ones, and the control
# ---------------------------------------------------------------------

m("invoice: the control account and the contact's own are swapped",
  "import_open_invoices",
  "      select c.id, coalesce(c.receivable_account_id,",
  "      select c.id, coalesce(null::uuid,"
  "  -- own receivable account ignored",
  "-- own receivable account ignored")

m("bill: the control account and the contact's own are swapped",
  "import_open_bills",
  "      select c.id, coalesce(c.payable_account_id,",
  "      select c.id, coalesce(null::uuid,  -- own payable account ignored",
  "-- own payable account ignored")

m("invoice: an opening invoice is offered to LHDN as a new one",
  "import_open_invoices",
  "        'not_applicable',",
  "        'pending',  -- opening invoice queued for LHDN",
  "-- opening invoice queued for LHDN")

m("invoice: the receivable is CREDITED, so the debtor is a creditor",
  "import_open_invoices",
  "            'account_id', v_ar,\n"
  "            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),\n"
  "            'debit', round(v_amount * v_rate, 2), 'credit', 0,\n"
  "            'contact_id', v_contact_id),",
  "            'account_id', v_ar,\n"
  "            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),\n"
  "            'debit', 0, 'credit', round(v_amount * v_rate, 2),\n"
  "            'contact_id', v_contact_id),  -- receivable side swapped",
  "-- receivable side swapped")

m("invoice: the opening debt is owed by nobody",
  "import_open_invoices",
  "            'contact_id', v_contact_id),",
  "            'contact_id', null),  -- receivable leg contact dropped",
  "-- receivable leg contact dropped")

m("bill: the payable is DEBITED, so the creditor is a debtor",
  "import_open_bills",
  "            'account_id', v_ap,\n"
  "            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),\n"
  "            'debit', 0, 'credit', round(v_amount * v_rate, 2),\n"
  "            'contact_id', v_contact_id)),",
  "            'account_id', v_ap,\n"
  "            'description', 'Opening balance ' || app.import_text(r, 'doc_no'),\n"
  "            'debit', round(v_amount * v_rate, 2), 'credit', 0,\n"
  "            'contact_id', v_contact_id)),  -- payable side swapped",
  "-- payable side swapped")

m("bill: the opening debt is owed to nobody",
  "import_open_bills",
  "            'contact_id', v_contact_id)),",
  "            'contact_id', null)),  -- payable leg contact dropped",
  "-- payable leg contact dropped")

m("bill: the supplier's own document number is not kept",
  "import_open_bills",
  "        coalesce(app.import_text(r, 'supplier_doc_no'),\n"
  "                 app.import_text(r, 'doc_no')),",
  "        null,  -- supplier doc no dropped",
  "-- supplier doc no dropped")

m("bill: a row with no supplier number of its own gets none",
  "import_open_bills",
  "        coalesce(app.import_text(r, 'supplier_doc_no'),\n"
  "                 app.import_text(r, 'doc_no')),",
  "        app.import_text(r, 'supplier_doc_no'),"
  "  -- supplier doc no fallback dropped",
  "-- supplier doc no fallback dropped")

m("invoice: the journal does not point back at the document",
  "import_open_invoices",
  "        'sales_documents', v_doc_id, app.import_text(r, 'reference'),",
  "        'sales_documents', null, app.import_text(r, 'reference'),"
  "  -- sales source document forgotten",
  "-- sales source document forgotten")

m("bill: the journal does not point back at the document",
  "import_open_bills",
  "        'purchase_documents', v_doc_id, app.import_text(r, 'reference'),",
  "        'purchase_documents', null, app.import_text(r, 'reference'),"
  "  -- purchase source document forgotten",
  "-- purchase source document forgotten")

m("invoice: the rows are validated as BILLS",
  "import_open_invoices",
  "  v_results := app.validate_open_items(p_org_id, p_rows, p_as_at, 'invoice');",
  "  v_results := app.validate_open_items(p_org_id, p_rows, p_as_at, 'bill');"
  "  -- invoice rows validated as bills",
  "-- invoice rows validated as bills")

m("bill: the rows are validated as INVOICES",
  "import_open_bills",
  "  v_results := app.validate_open_items(p_org_id, p_rows, p_as_at, 'bill');",
  "  v_results := app.validate_open_items(p_org_id, p_rows, p_as_at, 'invoice');"
  "  -- bill rows validated as invoices",
  "-- bill rows validated as invoices")

m("CONTROL -- a comment beside the invoice loop",
  "import_open_invoices",
  "      v_date     := app.import_date(app.import_text(r, 'doc_date'));",
  "      v_date     := app.import_date(app.import_text(r, 'doc_date'));"
  "  -- CONTROL: this cannot change a date.",
  "-- CONTROL: this cannot change a date.")

m("CONTROL -- a comment beside the bill loop",
  "import_open_bills",
  "      v_date     := app.import_date(app.import_text(r, 'doc_date'));",
  "      v_date     := app.import_date(app.import_text(r, 'doc_date'));"
  "  -- CONTROL: this cannot change a date.",
  "-- CONTROL: this cannot change a date.")
