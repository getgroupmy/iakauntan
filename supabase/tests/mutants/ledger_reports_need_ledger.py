# Mutants for 0855 -- the reports built from the ledger ask
# app.can_read_ledger, as the journals themselves do (0019).
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0855_ledger_reports_need_ledger_access.sql \
#       supabase/tests/ledger_reports_need_ledger.sql \
#       supabase/tests/mutants/ledger_reports_need_ledger.py
#
# One mutant per guard: a SQL report's `can_read_ledger` put back to
# `is_org_member`, a PL/pgSQL report's added refusal switched off.
#
# RESULT: 24 of 30 killed, the control surviving. The six survivors are
# equivalent, and the test says so beside the assertions they belong to:
#
#   * `group_orgs`, guard 1 -- the company the report is asked from.
#     Every report that calls it has refused such a reader already.
#   * `report_group_consolidated_trial_balance` -- `group_orgs` lists
#     nothing for the reader and `report_group_trial_balance` refuses in
#     the same words.
#   * `tax_computation`, `tax_computation_individual`,
#     `tax_partnership_allocation`, `tax_partnership_summary` -- every
#     path reaches `tax_computation_lines` through
#     `app.tax_business_income`, and it refuses in the same words.
#
# Three were survivors of the first run and are killed now: a project
# code on a line (`ledger_dimensions` reads projects and departments
# apart), a frozen filing (`fs_export` answers one from `fs_figures`
# without `fs_prepare`), and the sister company's line against this one
# (the intercompany report reads `gl_lines` for every company
# `group_orgs` lists; the trial balance alone could not tell).

m('report_trial_balance: any member again',
  'report_trial_balance',
  '     and not a.is_group\n     and app.can_read_ledger(p_org_id)\n',
  '     and not a.is_group\n     and app.is_org_member(p_org_id)  -- m01\n',
  '-- m01')

m('report_profit_loss: any member again',
  'report_profit_loss',
  "     and a.account_type in ('revenue', 'expense')\n     and app.can_read_ledger(p_org_id)\n",
  "     and a.account_type in ('revenue', 'expense')\n     and app.is_org_member(p_org_id)  -- m02\n",
  '-- m02')

m('report_balance_sheet: any member again',
  'report_balance_sheet',
  "     and a.account_type in ('asset', 'liability', 'equity')\n     and app.can_read_ledger(p_org_id)\n",
  "     and a.account_type in ('asset', 'liability', 'equity')\n     and app.is_org_member(p_org_id)  -- m03\n",
  '-- m03')

m('report_general_ledger: any member again (guard 1 of 2)',
  'report_general_ledger',
  '    join opening o on o.account_id = w.id\n   where app.can_read_ledger(p_org_id)\n',
  '    join opening o on o.account_id = w.id\n   where app.is_org_member(p_org_id)  -- m04\n',
  '-- m04')

m('report_general_ledger: any member again (guard 2 of 2)',
  'report_general_ledger',
  '    from running r\n   where app.can_read_ledger(p_org_id)\n',
  '    from running r\n   where app.is_org_member(p_org_id)  -- m05\n',
  '-- m05')

m('report_cash_flow: any member again',
  'report_cash_flow',
  '    from lines l\n   where app.can_read_ledger(p_org_id)\n',
  '    from lines l\n   where app.is_org_member(p_org_id)  -- m06\n',
  '-- m06')

m('report_changes_in_equity: any member again (guard 1 of 2)',
  'report_changes_in_equity',
  '    from equity e\n   where app.can_read_ledger(p_org_id)\n',
  '    from equity e\n   where app.is_org_member(p_org_id)  -- m07\n',
  '-- m07')

m('report_changes_in_equity: any member again (guard 2 of 2)',
  'report_changes_in_equity',
  '    from result_for_period r\n   where app.can_read_ledger(p_org_id)\n',
  '    from result_for_period r\n   where app.is_org_member(p_org_id)  -- m08\n',
  '-- m08')

m('report_profit_loss_by_dimension: any member again',
  'report_profit_loss_by_dimension',
  '     and (p_department_code is null or l.department_code = p_department_code)\n     and app.can_read_ledger(p_org_id)\n',
  '     and (p_department_code is null or l.department_code = p_department_code)\n     and app.is_org_member(p_org_id)  -- m09\n',
  '-- m09')

m('ledger_dimensions: any member again (guard 1 of 2)',
  'ledger_dimensions',
  '   where l.org_id = p_org_id and l.project_code is not null\n     and app.can_read_ledger(p_org_id)\n',
  '   where l.org_id = p_org_id and l.project_code is not null\n     and app.is_org_member(p_org_id)  -- m10\n',
  '-- m10')

m('ledger_dimensions: any member again (guard 2 of 2)',
  'ledger_dimensions',
  '   where l.org_id = p_org_id and l.department_code is not null\n     and app.can_read_ledger(p_org_id)\n',
  '   where l.org_id = p_org_id and l.department_code is not null\n     and app.is_org_member(p_org_id)  -- m11\n',
  '-- m11')

m('group_orgs: any member again (guard 1 of 2)',
  'group_orgs',
  '    from public.organizations o\n   where app.can_read_ledger(p_org_id)\n',
  '    from public.organizations o\n   where app.is_org_member(p_org_id)  -- m12\n',
  '-- m12')

m('group_orgs: any member again (guard 2 of 2)',
  'group_orgs',
  '   where app.can_read_ledger(p_org_id)\n     and app.can_read_ledger(o.id)\n',
  '   where app.can_read_ledger(p_org_id)\n     and app.is_org_member(o.id)  -- m13\n',
  '-- m13')

m('report_with_layout: the ledger refusal is gone',
  'report_with_layout',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- m14\n',
  '-- m14')

m('report_group_trial_balance: the ledger refusal is gone',
  'report_group_trial_balance',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- m15\n',
  '-- m15')

m('report_group_intercompany: the ledger refusal is gone',
  'report_group_intercompany',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- m16\n',
  '-- m16')

m('report_group_consolidated_trial_balance: the ledger refusal is gone',
  'report_group_consolidated_trial_balance',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- m17\n',
  '-- m17')

m('report_group_elimination_check: the ledger refusal is gone',
  'report_group_elimination_check',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- m18\n',
  '-- m18')

m('report_deferred_revenue: the ledger refusal is gone',
  'report_deferred_revenue',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- m19\n',
  '-- m19')

m('suggest_bank_matches: the ledger refusal is gone',
  'suggest_bank_matches',
  '  if not app.can_read_ledger(t.org_id) then\n',
  '  if false then  -- m20\n',
  '-- m20')

m('bank_reconciliation_status: the ledger refusal is gone',
  'bank_reconciliation_status',
  '  if not app.can_read_ledger(v_org) then\n',
  '  if false then  -- m21\n',
  '-- m21')

m('tax_computation_lines: the ledger refusal is gone',
  'tax_computation_lines',
  '  if not app.can_read_ledger(c.org_id) then\n',
  '  if false then  -- m22\n',
  '-- m22')

m('tax_computation: the ledger refusal is gone',
  'tax_computation',
  '  if not app.can_read_ledger(c.org_id) then\n',
  '  if false then  -- m23\n',
  '-- m23')

m('tax_computation_individual: the ledger refusal is gone',
  'tax_computation_individual',
  '  if not app.can_read_ledger(c.org_id) then\n',
  '  if false then  -- m24\n',
  '-- m24')

m('tax_partnership_allocation: the ledger refusal is gone',
  'tax_partnership_allocation',
  '  if not app.can_read_ledger(c.org_id) then\n',
  '  if false then  -- m25\n',
  '-- m25')

m('tax_partnership_summary: the ledger refusal is gone',
  'tax_partnership_summary',
  '  if not app.can_read_ledger(c.org_id) then\n',
  '  if false then  -- m26\n',
  '-- m26')

m('tax_estimate_exposure: the ledger refusal is gone',
  'tax_estimate_exposure',
  '  if not app.can_read_ledger(e.org_id) then\n',
  '  if false then  -- m27\n',
  '-- m27')

m('fs_prepare: the ledger refusal is gone',
  'fs_prepare',
  '  if not app.can_read_ledger(f.org_id) then\n',
  '  if false then  -- m28\n',
  '-- m28')

m('fs_export: the ledger refusal is gone',
  'fs_export',
  '  if not app.can_read_ledger(f.org_id) then\n',
  '  if false then  -- m29\n',
  '-- m29')

m('fs_audit_exemption: the ledger refusal is gone',
  'fs_audit_exemption',
  '  if not app.can_read_ledger(f.org_id) then\n',
  '  if false then  -- m30\n',
  '-- m30')

m('CONTROL: a comment inside report_trial_balance',
  'report_trial_balance',
  '   order by a.code;\n',
  '   order by a.code;  -- (control)\n',
  '(control)')
