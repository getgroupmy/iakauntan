# Mutants for 0925 -- 0912's rule reads only the row's own company's
# accounts. 0912's own mutants (an_account_fits_where_it_is_used.py)
# are re-run against this migration's text with 0912's test.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0925_an_account_is_described_only_to_its_own_company.sql \
#       supabase/tests/an_account_is_described_only_to_its_own_company.sql \
#       supabase/tests/mutants/an_account_is_described_only_to_its_own_company.py

F = 'an_account_fits_where_it_is_used'

m("another company's account is looked up and described",
  F,
  "     where a.id = v_id and a.org_id = new.org_id;\n",
  "     where a.id = v_id;  -- any company\n",
  '-- any company')

m('an account that is not found is described as nothing',
  F,
  "    continue when v_acct.id is null;\n",
  "    -- not found falls through\n",
  '-- not found falls through')

m('the company is asked, but an account not found is still described',
  F,
  "     where a.id = v_id and a.org_id = new.org_id;\n"
  "    continue when v_acct.id is null;\n",
  "     where a.id = v_id and a.org_id = new.org_id;\n"
  "    -- found or not\n",
  '-- found or not')

m('CONTROL: a comment inside the function',
  F,
  "  -- Each argument is `column:rule:what it is called`.\n",
  "  -- Each argument is `column:rule:what it is called`. (control)\n",
  '(control)')
