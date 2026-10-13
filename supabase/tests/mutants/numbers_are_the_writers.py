# Mutants for 0877 -- a writer takes any number; payroll and HR the
# employee's and the payroll run's; anybody in the company a claim's and
# a leave's.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0877_only_a_writer_takes_a_number.sql \
#       supabase/tests/numbers_are_the_writers.sql \
#       supabase/tests/mutants/numbers_are_the_writers.py

m('staff take any number',
  'next_document_number',
  "  if not (app.can_write(p_org_id)\n",
  "  if not (app.is_staff_member(p_org_id)  -- staff\n",
  '-- staff')

m('a writer takes none',
  'next_document_number',
  "  if not (app.can_write(p_org_id)\n",
  "  if not (false  -- no writers\n",
  '-- no writers')

m('HR takes no employee number',
  'next_document_number',
  "          or (p_doc_type in ('employee', 'payroll_run')\n",
  "          or (p_doc_type in ('payroll_run')  -- runs only\n",
  '-- runs only')

m('HR takes no payroll run number',
  'next_document_number',
  "          or (p_doc_type in ('employee', 'payroll_run')\n",
  "          or (p_doc_type in ('employee')  -- employees only\n",
  '-- employees only')

m('HR takes any number',
  'next_document_number',
  "          or (p_doc_type in ('employee', 'payroll_run')\n",
  "          or (true  -- any type\n",
  '-- any type')

m('anybody takes the HR numbers',
  'next_document_number',
  "              and app.can_run_payroll(p_org_id))\n",
  "              and app.is_org_member(p_org_id))  -- members\n",
  '-- members')

m('nobody takes a leave number',
  'next_document_number',
  "          or (p_doc_type in ('expense_claim', 'leave_request')\n",
  "          or (p_doc_type in ('expense_claim')  -- claims only\n",
  '-- claims only')

m('a stranger takes a claim number',
  'next_document_number',
  "              and app.is_org_member(p_org_id))) then\n",
  "              and true)) then  -- strangers\n",
  '-- strangers')

m('CONTROL',
  'next_document_number',
  "  return app.next_document_number_internal(p_org_id, p_doc_type);\n",
  "  return app.next_document_number_internal(p_org_id, p_doc_type);  -- control\n",
  '-- control')
