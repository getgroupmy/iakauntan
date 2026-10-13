# Mutants for 0857 -- the budget against actual, the budget built from
# actuals and the project budget each refuse a reader the ledger's
# `app.can_read_ledger` does not admit, after the check each had.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0857_a_budgets_actuals_are_the_ledgers.sql \
#       supabase/tests/budget_actuals_need_ledger.sql \
#       supabase/tests/mutants/budget_actuals.py
#
# RESULT: 8 of 8 killed, the control surviving.


m('the budget against actual asks the module only',
  'report_budget_vs_actual',
  '  if not app.can_read_ledger(v_b.org_id) then\n',
  '  if false then  -- module only\n',
  '-- module only')
m('the budget built from actuals asks the module only',
  'build_budget_from_actual',
  '  if not app.can_read_ledger(v_b.org_id) then\n',
  '  if false then  -- module only\n',
  '-- module only')
m("every member reads the ledger's figures on a project",
  'report_project_budget',
  '  v_ledger constant boolean := app.can_read_ledger(p_org_id);\n',
  '  v_ledger constant boolean := app.is_org_member(p_org_id);  -- any member\n',
  '-- any member')
m('the cost to date is not blanked',
  'report_project_budget',
  '           case when v_ledger then round(coalesce(g.cost, 0), 2) end,\n',
  '           round(coalesce(g.cost, 0), 2),  -- cost shown\n',
  '-- cost shown')
m('nor the revenue to date',
  'report_project_budget',
  '           case when v_ledger then round(coalesce(g.revenue, 0), 2) end,\n',
  '           round(coalesce(g.revenue, 0), 2),  -- revenue shown\n',
  '-- revenue shown')
m('nor what is left',
  'report_project_budget',
  '           case when not v_ledger or p.budget_amount is null then null\n',
  '           case when p.budget_amount is null then null  -- variance shown\n',
  '-- variance shown')
m('nor how much is spent',
  'report_project_budget',
  '           case when not v_ledger or coalesce(p.budget_amount, 0) = 0 then null\n',
  '           case when coalesce(p.budget_amount, 0) = 0 then null  -- percent shown\n',
  '-- percent shown')
m("nobody reads the ledger's figures on a project",
  'report_project_budget',
  '  v_ledger constant boolean := app.can_read_ledger(p_org_id);\n',
  '  v_ledger constant boolean := false;  -- nobody\n',
  '-- nobody')
m('CONTROL: a comment inside report_project_budget',
  'report_project_budget',
  '  v_ledger constant boolean := app.can_read_ledger(p_org_id);\n',
  '  v_ledger constant boolean := app.can_read_ledger(p_org_id);  -- (control)\n',
  '(control)')
