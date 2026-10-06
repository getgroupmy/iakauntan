# Mutants for app.create_gl_entry_internal -- the one function every
# journal in the system is written by: invoices, bills, receipts,
# payroll, depreciation, POS, manual journals.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0688_the_matter_on_every_posting_path.sql \
#       supabase/tests/ledger.sql \
#       supabase/tests/mutants/create_gl_entry_internal.py
#
# RESULT, 6 October: 23 mutants, ALL KILLED, control alive. 19 died
# against the files that already existed (ledger, manual_journal,
# multicurrency, fx_revaluation, fx_shapes, reversal, matter_on_a_
# document, pricing_and_dimensions, posting_a_bill). Four needed new
# assertions:
#
#   - THE BASE CURRENCY ASSUMED TO BE RINGGIT (`p_currency <> 'MYR'` for
#     `<> v_base`). Every entry in the suite was for a ringgit company,
#     where the two are the same test. The app lets a company keep its
#     books in another currency; for an SGD company the mutant books its
#     own currency as foreign and ringgit as home. multicurrency.sql now
#     has an SGD company posting both ways.
#   - A SUPPLIED fc_credit IGNORED AND DERIVED. post_receipt_internal
#     states the realised-loss line's foreign amount as ZERO, and says
#     why in a comment ("deriving one would invent dollars that were
#     never invoiced"). Nothing asserted it: under the mutant a customer
#     who paid in full shows USD 444.44 paid. multicurrency.sql now
#     asserts the customer's foreign balance clears too.
#   - THE ZERO-RATE GUARD. Equivalent in OUTCOME -- gl_entries has its
#     own `exchange_rate > 0` check with the same SQLSTATE, 23514, which
#     is all multicurrency.sql caught -- but not in what the caller is
#     told. The test now asserts the function's sentence.
#   - THE TAX CODE on every line. Read back only by reverse_gl_entry,
#     and served by the API. posting_a_bill.sql asserts it.

m("a date no fiscal period covers is posted anyway",
  "create_gl_entry_internal",
  "  if v_period_id is null then\n    raise exception\n",
  "  if false then  -- no period is fine\n    raise exception\n",
  "-- no period is fine")

m("a closed period accepts a posting",
  "create_gl_entry_internal",
  "  if v_status <> 'open' then",
  "  if false then  -- closed is fine",
  "-- closed is fine")

m("a foreign entry with a zero rate posts zeroes and balances",
  "create_gl_entry_internal",
  "  if v_foreign and v_rate <= 0 then",
  "  if false then  -- any rate will do",
  "-- any rate will do")

m("'foreign' means not ringgit, rather than not the company's base",
  "create_gl_entry_internal",
  "  v_foreign := p_currency is not null and p_currency <> v_base;",
  "  v_foreign := p_currency is not null and p_currency <> 'MYR';  -- base assumed",
  "-- base assumed")

m("a foreign line's own currency amount is the ringgit amount",
  "create_gl_entry_internal",
  "                                   v_ln_debit / v_rate), 2);",
  "                                   v_ln_debit), 2);  -- fc not divided",
  "-- fc not divided")

m("a foreign amount the caller supplied is ignored and recomputed",
  "create_gl_entry_internal",
  "      v_fc_credit := round(coalesce((v_line ->> 'fc_credit')::numeric,\n",
  "      v_fc_credit := round(coalesce(null::numeric,  -- supplied fc ignored\n",
  "-- supplied fc ignored")

m("a base-currency line repeats its amount as a foreign one",
  "create_gl_entry_internal",
  "      v_fc_debit := 0;\n      v_fc_credit := 0;",
  "      v_fc_debit := v_ln_debit;  -- fc repeated\n      v_fc_credit := 0;",
  "-- fc repeated")

m("a journal that does not balance is accepted",
  "create_gl_entry_internal",
  "  if v_debit <> v_credit then",
  "  if false then  -- balance unchecked",
  "-- balance unchecked")

m("the contact is dropped from every line",
  "create_gl_entry_internal",
  "      nullif(v_line ->> 'contact_id', '')::uuid,",
  "      null::uuid,  -- contact dropped",
  "-- contact dropped")

m("the item is dropped from every line",
  "create_gl_entry_internal",
  "      nullif(v_line ->> 'item_id', '')::uuid,",
  "      null::uuid,  -- item dropped",
  "-- item dropped")

m("the tax code is dropped from every line",
  "create_gl_entry_internal",
  "      nullif(v_line ->> 'tax_code_id', '')::uuid,",
  "      null::uuid,  -- tax code dropped",
  "-- tax code dropped")

m("the tax amount is dropped from every line",
  "create_gl_entry_internal",
  "      round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2),",
  "      0,  -- tax amount dropped",
  "-- tax amount dropped")

m("the project is dropped from every line",
  "create_gl_entry_internal",
  "      nullif(v_line ->> 'project_code', ''),",
  "      null,  -- project dropped",
  "-- project dropped")

m("the department is dropped from every line",
  "create_gl_entry_internal",
  "      nullif(v_line ->> 'department_code', ''),",
  "      null,  -- department dropped",
  "-- department dropped")

m("the matter is dropped from every line",
  "create_gl_entry_internal",
  "      nullif(v_line ->> 'matter_id', '')::uuid);",
  "      null::uuid);  -- matter dropped",
  "-- matter dropped")

m("the line's description is dropped",
  "create_gl_entry_internal",
  "      (v_line ->> 'account_id')::uuid, v_line ->> 'description',",
  "      (v_line ->> 'account_id')::uuid, null,  -- description dropped",
  "-- description dropped")

m("the entry is stamped in the base currency whatever it was in",
  "create_gl_entry_internal",
  "    p_description, p_reference, p_currency, v_rate,",
  "    p_description, p_reference, v_base, v_rate,  -- entry currency lost",
  "-- entry currency lost")

m("every line carries a rate of one",
  "create_gl_entry_internal",
  "      p_currency, v_rate,\n",
  "      p_currency, 1,  -- line rate lost\n",
  "-- line rate lost")

m("the entry is left as a draft",
  "create_gl_entry_internal",
  "    'posted', now(), auth.uid(), auth.uid()",
  "    'draft', now(), auth.uid(), auth.uid()  -- left draft",
  "-- left draft")

m("the entry forgets the document it came from",
  "create_gl_entry_internal",
  "    p_entry_date, v_period_id, p_source, p_source_table, p_source_id,",
  "    p_entry_date, v_period_id, p_source, p_source_table, null,  -- source lost",
  "-- source lost")

m("the entry forgets its reference",
  "create_gl_entry_internal",
  "    p_description, p_reference, p_currency, v_rate,",
  "    p_description, null, p_currency, v_rate,  -- reference lost",
  "-- reference lost")

m("the entry is dated today rather than the day asked for",
  "create_gl_entry_internal",
  "    p_entry_date, v_period_id, p_source, p_source_table, p_source_id,",
  "    current_date, v_period_id, p_source, p_source_table, p_source_id,  -- dated today",
  "-- dated today")

m("every line is line one",
  "create_gl_entry_internal",
  "    v_no := v_no + 1;",
  "    v_no := 1;  -- all line one",
  "-- all line one")

m("CONTROL -- a comment inside the function block",
  "create_gl_entry_internal",
  "  v_rate numeric(18,8) := coalesce(p_exchange_rate, 1);",
  "  v_rate numeric(18,8) := coalesce(p_exchange_rate, 1);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
