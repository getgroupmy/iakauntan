# Mutants for public.audit_view_payslip (0048) -- one payslip opened by
# somebody holding a grant, and the read logged against that grant.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0048_hrms_audited_payslip_reads.sql \
#       supabase/tests/payslip_access.sql \
#       supabase/tests/mutants/audit_view_payslip.py
#
# RESULT: 10 mutants and a control. 10 killed by `payslip_access.sql`,
# three only after a rule-by-rule block there: a missing payslip, a
# stranger and payroll were each refused, but asserted by SQLSTATE alone
# with a later guard raising the same code.

m("a payslip that does not exist is opened in silence",
  "audit_view_payslip",
  "  if v_slip.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("a stranger opens a payslip",
  "audit_view_payslip",
  "  if not app.is_org_member(v_slip.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("payroll reads through the audited route",
  "audit_view_payslip",
  "  if app.can_run_payroll(v_slip.org_id) then",
  "  if false then  -- payroll too",
  "-- payroll too")

m("no grant is needed",
  "audit_view_payslip",
  "  if v_grant is null then",
  "  if false then  -- ungranted",
  "-- ungranted")

m("the grant is looked up for another employee",
  "audit_view_payslip",
  "    v_slip.org_id, v_slip.run_id, v_slip.employee_id, v_slip.pay_date);",
  "    v_slip.org_id, v_slip.run_id, null, v_slip.pay_date);  -- nobody in particular",
  "-- nobody in particular")

m("the grant is looked up for no date",
  "audit_view_payslip",
  "    v_slip.org_id, v_slip.run_id, v_slip.employee_id, v_slip.pay_date);",
  "    v_slip.org_id, v_slip.run_id, v_slip.employee_id, null);  -- undated",
  "-- undated")

m("the tenant column goes out with the payslip",
  "audit_view_payslip",
  "  select to_jsonb(v_slip) - 'org_id'\n",
  "  select to_jsonb(v_slip)  -- all of it\n",
  "-- all of it")

m("the read is logged against no grant",
  "audit_view_payslip",
  "  values (v_slip.org_id, v_grant, auth.uid(), 'view', v_slip.id,",
  "  values (v_slip.org_id, null, auth.uid(), 'view', v_slip.id,  -- unattributed",
  "-- unattributed")

m("the read is logged against nobody",
  "audit_view_payslip",
  "  values (v_slip.org_id, v_grant, auth.uid(), 'view', v_slip.id,",
  "  values (v_slip.org_id, v_grant, null, 'view', v_slip.id,  -- anonymous",
  "-- anonymous")

m("the log does not say whose payslip",
  "audit_view_payslip",
  "          v_slip.employee_name,\n",
  "          null,  -- whose?\n",
  "-- whose?")

m("CONTROL: a comment inside the block",
  "audit_view_payslip",
  "  if v_grant is null then",
  "  if v_grant is null then  -- (control)",
  "(control)")
