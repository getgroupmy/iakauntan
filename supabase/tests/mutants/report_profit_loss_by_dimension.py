# Mutants for public.report_profit_loss_by_dimension (0739) -- the
# profit and loss for one project or one department.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/pricing_and_dimensions.sql \
#       supabase/tests/mutants/report_profit_loss_by_dimension.py
#
# then again against `manual_journal.sql` and `report_layouts.sql`.
#
# RESULT: 11 mutants and a control. 11 killed, all in
# pricing_and_dimensions.sql.
#
#   The first sweep killed 4 there. The fixture was revenue only, one
#   company, all posted, all inside the year, no department and no nil
#   line. "report_profit_loss_by_dimension, rule by rule" kills the
#   other seven.

m("revenue is shown as a debit",
  "report_profit_loss_by_dimension",
  "                        then l.credit - l.debit",
  "                        then l.debit - l.credit  -- sign",
  "-- sign")

m("expenses are shown as credits",
  "report_profit_loss_by_dimension",
  "                        else l.debit - l.credit end), 2) as amount",
  "                        else l.credit - l.debit end), 2) as amount  -- sign",
  "-- sign")

m("another company's lines are counted",
  "report_profit_loss_by_dimension",
  "   where l.org_id = p_org_id",
  "   where true  -- any org",
  "-- any org")

m("a draft or void journal is counted",
  "report_profit_loss_by_dimension",
  "     and e.status = 'posted'",
  "     and true  -- any status",
  "-- any status")

m("a journal before the period is counted",
  "report_profit_loss_by_dimension",
  "     and e.entry_date between p_from and p_to",
  "     and e.entry_date <= p_to  -- no start",
  "-- no start")

m("a journal after the period is counted",
  "report_profit_loss_by_dimension",
  "     and e.entry_date between p_from and p_to",
  "     and e.entry_date >= p_from  -- no end",
  "-- no end")

m("the balance sheet is in the profit and loss",
  "report_profit_loss_by_dimension",
  "     and a.account_type in ('revenue', 'expense')",
  "     and true  -- every type",
  "-- every type")

m("the project is ignored",
  "report_profit_loss_by_dimension",
  "     and (p_project_code is null or l.project_code = p_project_code)",
  "     and true  -- any project",
  "-- any project")

m("the department is ignored",
  "report_profit_loss_by_dimension",
  "     and (p_department_code is null or l.department_code = p_department_code)",
  "     and true  -- any department",
  "-- any department")

m("a stranger reads the profit",
  "report_profit_loss_by_dimension",
  "     and app.is_org_member(p_org_id)",
  "     and true  -- anybody",
  "-- anybody")

m("an account that nets to nothing is shown",
  "report_profit_loss_by_dimension",
  "  having sum(l.debit - l.credit) <> 0",
  "  having true  -- zeroes",
  "-- zeroes")

m("CONTROL: a comment inside the block",
  "report_profit_loss_by_dimension",
  "   group by a.id, a.code, a.name, a.account_type, a.account_subtype",
  "   -- CONTROL\n   group by a.id, a.code, a.name, a.account_type, a.account_subtype",
  "-- CONTROL")
