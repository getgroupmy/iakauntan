# Mutants for public.audit_list_payslips (0281) -- the payslips a grant
# covers, listed and logged once, against the grant that permitted it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0281_the_log_that_forgot_which_grant_let_them_in.sql \
#       supabase/tests/payslip_access.sql \
#       supabase/tests/mutants/audit_list_payslips.py
#
# RESULT: 10 mutants and a control. 10 killed by `payslip_access.sql`,
# four only after a rule-by-rule block there. The fixture's list was
# only ever one payslip long, in one company, from one run: so the run
# filter, the count it logs, the tenant column it strips and the company
# it reads were all unasserted. The block lists four payslips over two
# runs, next to a company whose payslips the same auditor may also read.

m("a stranger lists a company's payslips",
  "audit_list_payslips",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("payroll lists through the audited route",
  "audit_list_payslips",
  "  if app.can_run_payroll(p_org_id) then",
  "  if false then  -- payroll too",
  "-- payroll too")

m("the tenant column goes out with the list",
  "audit_list_payslips",
  "  select coalesce(jsonb_agg(to_jsonb(p) - 'org_id' order by p.employee_no), '[]'::jsonb),",
  "  select coalesce(jsonb_agg(to_jsonb(p) order by p.employee_no), '[]'::jsonb),  -- all of it",
  "-- all of it")

m("another company's payslips are listed",
  "audit_list_payslips",
  "    from public.payslips p\n   where p.org_id = p_org_id\n     and (p_run_id is null or p.run_id = p_run_id)\n     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)\n         is not null;",
  "    from public.payslips p\n   where true  -- any company\n     and (p_run_id is null or p.run_id = p_run_id)\n     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)\n         is not null;",
  "-- any company")

m("the run asked for is ignored",
  "audit_list_payslips",
  "     and (p_run_id is null or p.run_id = p_run_id)\n     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)\n         is not null;",
  "     and true  -- every run\n     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)\n         is not null;",
  "-- every run")

m("everything is listed, covered or not",
  "audit_list_payslips",
  "     and app.covering_grant(p.org_id, p.run_id, p.employee_id, p.pay_date)\n         is not null;\n\n  if v_count",
  "     and true;  -- uncovered too\n\n  if v_count",
  "-- uncovered too")

m("an empty list is logged",
  "audit_list_payslips",
  "  if v_count = 0 then",
  "  if false then  -- log nothing too",
  "-- log nothing too")

m("the grant is looked up across the whole company",
  "audit_list_payslips",
  "         is not null\n   order by p.employee_no",
  "         is not null or true  -- any payslip\n   order by p.employee_no",
  "-- any payslip")

m("the list is logged against no grant",
  "audit_list_payslips",
  "  values (p_org_id, v_grant, auth.uid(), 'list', v_count,",
  "  values (p_org_id, null, auth.uid(), 'list', v_count,  -- unattributed",
  "-- unattributed")

m("the list is logged as one payslip",
  "audit_list_payslips",
  "  values (p_org_id, v_grant, auth.uid(), 'list', v_count,",
  "  values (p_org_id, v_grant, auth.uid(), 'list', 1,  -- one",
  "-- one")

m("CONTROL: a comment inside the block",
  "audit_list_payslips",
  "  if v_count = 0 then",
  "  if v_count = 0 then  -- (control)",
  "(control)")
