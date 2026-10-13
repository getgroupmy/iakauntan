# Mutants for 0875's two functions that needed more than the
# substitution: `attachments_of` asks the record's own question, and
# `next_document_number` numbers a claim or leave for anybody in the
# company.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0875_the_rest_of_the_company_is_the_staffs.sql \
#       supabase/tests/employee_definers.sql \
#       supabase/tests/mutants/employee_definers_0875.py

m('attachments are anybody\'s in the company',
  'attachments_of',
  "   where app.can_read_attachment(p_org_id, p_table, p_record_id)\n",
  "   where app.is_org_member(p_org_id)  -- members\n",
  '-- members')

m('attachments are the staff\'s',
  'attachments_of',
  "   where app.can_read_attachment(p_org_id, p_table, p_record_id)\n",
  "   where app.is_staff_member(p_org_id)  -- staff\n",
  '-- staff')

m('her claim takes no number',
  'next_document_number',
  "  if not (app.is_staff_member(p_org_id)\n          or (p_doc_type in ('expense_claim', 'leave_request')\n              and app.is_org_member(p_org_id))) then\n",
  "  if not app.is_staff_member(p_org_id) then  -- staff only\n",
  '-- staff only')

m('she takes any number',
  'next_document_number',
  "          or (p_doc_type in ('expense_claim', 'leave_request')\n              and app.is_org_member(p_org_id))) then\n",
  "          or app.is_org_member(p_org_id)) then  -- any number\n",
  '-- any number')

m('a stranger numbers a claim',
  'next_document_number',
  "              and app.is_org_member(p_org_id))) then\n",
  "              and true)) then  -- strangers\n",
  '-- strangers')

m('her leave takes no number',
  'next_document_number',
  "          or (p_doc_type in ('expense_claim', 'leave_request')\n",
  "          or (p_doc_type in ('expense_claim')  -- claims only\n",
  '-- claims only')

m('CONTROL',
  'next_document_number',
  "  return app.next_document_number_internal(p_org_id, p_doc_type);\n",
  "  return app.next_document_number_internal(p_org_id, p_doc_type);  -- control\n",
  '-- control')
