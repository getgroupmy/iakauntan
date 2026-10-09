# Mutants for public.import_journals (0633) -- general journals from a
# file, one row per line, grouped by entry number: only somebody who
# may POST (this importer writes the ledger, the others make drafts);
# a preview writes nothing; a commit with any bad row writes nothing;
# rows of one entry are grouped whatever case the number is in; the
# account and the contact found by code whatever its case, and never a
# deleted contact; pence rounded to the sen; the old number kept as the
# entry's reference and as its import key, so the same file twice is
# refused rather than posted twice; the count of entries made returned.
#
# Not mutated: the entry's date as `min` rather than `max` --
# `app.validate_journal_rows` refuses an entry whose rows disagree on
# the date, so the two are the same date on anything that reaches here.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0633_the_journals_that_came_before.sql \
#       supabase/tests/import_journals.sql \
#       supabase/tests/mutants/import_journals.py
#
# RESULT: 16 mutants and a control. 14 killed by `import_journals.sql`,
# eight before its rule-by-rule block: every file named accounts by
# number (no case to get wrong), named no contact, gave each line its
# entry's description, described every entry and stayed above the sen,
# and nothing read the `committed` flag.
#
# Two are EQUIVALENT: "debits/credits are not rounded to the sen".
# `app.create_gl_entry_internal` rounds every line to two places before
# it balances the entry, so the importer's own `round` changes nothing
# that reaches the ledger.
#
# Found and raised rather than fixed: `app.validate_journal_rows` never
# looks at `contact_code`. A code that matches no live contact -- a typo,
# or a contact since deleted -- is dropped without a word, and the line
# posts without its customer or supplier. The block asserts only what
# holds either way: a deleted contact is never put on a line.

m("somebody who may not post imports journals",
  "import_journals",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a commit with bad rows goes ahead",
  "import_journals",
  "  if p_commit and v_bad > 0 then",
  "  if false then  -- bad rows too",
  "-- bad rows too")

m("a preview writes the ledger",
  "import_journals",
  "  if p_commit then\n    for v_key, v_no, v_date, v_desc in",
  "  if true then  -- preview writes\n    for v_key, v_no, v_date, v_desc in",
  "-- preview writes")

m("an entry number in two cases is two entries",
  "import_journals",
  "      select lower(app.import_text(r, 'entry_no')),",
  "      select app.import_text(r, 'entry_no'),  -- case kept",
  "-- case kept")

m("the lines of an entry are found case-sensitively",
  "import_journals",
  "       where lower(app.import_text(r, 'entry_no')) = v_key;",
  "       where app.import_text(r, 'entry_no') = v_key;  -- lines by exact case",
  "-- lines by exact case")

m("an account code in another case is not found",
  "import_journals",
  "                                 and lower(a.code)\n                                     = lower(app.import_text(r, 'account_code'))),",
  "                                 and a.code\n                                     = app.import_text(r, 'account_code')),  -- account by exact case",
  "-- account by exact case")

m("a contact code in another case is not found",
  "import_journals",
  "                                 and lower(c.code)\n                                     = lower(app.import_text(r, 'contact_code'))",
  "                                 and c.code\n                                     = app.import_text(r, 'contact_code')  -- contact by exact case",
  "-- contact by exact case")

m("a deleted contact is named on the line",
  "import_journals",
  "                                 and c.deleted_at is null))))",
  "                                 and true))))  -- deleted too",
  "-- deleted too")

m("debits are not rounded to the sen",
  "import_journals",
  "               'debit', round(app.import_number(\n                 app.import_text(r, 'debit'), 0), 2),",
  "               'debit', app.import_number(\n                 app.import_text(r, 'debit'), 0),  -- debit unrounded",
  "-- debit unrounded")

m("credits are not rounded to the sen",
  "import_journals",
  "               'credit', round(app.import_number(\n                 app.import_text(r, 'credit'), 0), 2),",
  "               'credit', app.import_number(\n                 app.import_text(r, 'credit'), 0),  -- credit unrounded",
  "-- credit unrounded")

m("a line's own description is dropped",
  "import_journals",
  "               'description', app.import_text(r, 'description'),",
  "               'description', null,  -- line description dropped",
  "-- line description dropped")

m("an entry with no description is left blank",
  "import_journals",
  "        coalesce(v_desc, 'Imported journal ' || v_no),",
  "        v_desc,  -- blank",
  "-- blank")

m("the old number is not kept as the reference",
  "import_journals",
  "        v_no, app.base_currency(p_org_id), 1);",
  "        null, app.base_currency(p_org_id), 1);  -- no reference",
  "-- no reference")

m("the same file twice is posted twice",
  "import_journals",
  "         set import_source = 'journals', import_ref = v_no,",
  "         set import_source = null, import_ref = null,  -- no key",
  "-- no key")

m("the count of entries is not kept",
  "import_journals",
  "      v_made := v_made + 1;",
  "      v_made := 1;  -- count one",
  "-- count one")

m("the result says it was not committed",
  "import_journals",
  "    'committed', p_commit);",
  "    'committed', false);  -- never committed",
  "-- never committed")

m("CONTROL: a comment inside the block",
  "import_journals",
  "  if p_commit and v_bad > 0 then",
  "  if p_commit and v_bad > 0 then  -- (control)",
  "(control)")
