# Mutants for public.set_expense_split (0692) -- splitting one claimed
# cost across accounts: the expense exists, is not deleted, the caller
# may write, it is not posted; the split replaces the old one, each line
# has an amount and one of this company's accounts, keeps its
# description, tax, project, department and matter; and the header
# follows the split -- the sums, and the account of the largest line.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0692_the_matter_a_claimed_cost_belongs_to.sql \
#       supabase/tests/expense_split.sql \
#       supabase/tests/mutants/set_expense_split.py
#
# RESULT: 20 mutants and a control. 18 killed by `expense_split.sql`;
# before its assertions, 8. Its refusals caught ANY error, and the
# table refuses most of them itself -- an amount of 0 by a check, an
# account of another company by a same-company key -- so every one of
# the function's own checks could go and the file still passed. They
# read their own words now, and a missing or deleted expense, a second
# split replacing the first, and a split's tax are asked.
#
# Two are EQUIVALENT:
#   * a line with no account at all: `not exists (... where id = null)`
#     is already true, so the next clause refuses in the same words;
#   * the header's total leaving out the tax: the `expense_total`
#     trigger sets total_amount from amount and tax_amount on the row.

F = "set_expense_split"

m("an expense that does not exist is not refused in words", F,
  "  if not found then\n    raise exception 'Expense % not found'",
  "  if false then  -- not found\n    raise exception 'Expense % not found'",
  "-- not found")
m("a deleted expense is split", F,
  "  if v_exp.deleted_at is not null then",
  "  if false then  -- deleted split",
  "-- deleted split")
m("anybody may split an expense", F,
  "  if not app.can_write(v_exp.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")
m("a posted expense is split", F,
  "  if v_exp.gl_entry_id is not null then",
  "  if false then  -- posted split",
  "-- posted split")
m("the old split is kept", F,
  "  delete from public.expense_lines where expense_id = p_expense_id;",
  "  -- old split kept",
  "-- old split kept")
m("an empty split is not an empty split", F,
  "  if p_lines is null or jsonb_array_length(p_lines) = 0 then\n    return 0;",
  "  if false then  -- empty goes on\n    return 0;",
  "-- empty goes on")
m("a line with no amount is not refused in words", F,
  "    if v_amount <= 0 then",
  "    if false then  -- no amount",
  "-- no amount")
m("another company's account is not refused in words", F,
  "          where id = v_acct and org_id = v_exp.org_id) then",
  "          where id = v_acct) then  -- any company",
  "-- any company")
m("a line with no account is not refused in words", F,
  "    if v_acct is null or not exists (",
  "    if not exists (  -- null passes",
  "-- null passes")
m("the description is not kept", F,
  "            nullif(v_line ->> 'description', ''), v_amount,",
  "            null, v_amount,  -- no description",
  "-- no description")
m("the tax is not kept", F,
  "            nullif(v_line ->> 'tax_code_id', '')::uuid, v_tax,",
  "            nullif(v_line ->> 'tax_code_id', '')::uuid, 0,  -- no tax",
  "-- no tax")
m("the project is not kept", F,
  "            nullif(v_line ->> 'project_code', ''),",
  "            null,  -- no project",
  "-- no project")
m("the department is not kept", F,
  "            nullif(v_line ->> 'department_code', ''),",
  "            null,  -- no department",
  "-- no department")
m("the matter is not kept", F,
  "            nullif(v_line ->> 'matter_id', '')::uuid);",
  "            null);  -- no matter",
  "-- no matter")
m("the header takes the smallest line's account", F,
  "   order by amount desc, line_no",
  "   order by amount, line_no  -- smallest",
  "-- smallest")
m("the header's amount does not follow", F,
  "     set amount = s.base,",
  "     set amount = e.amount,  -- header amount kept",
  "-- header amount kept")
m("the header's tax does not follow", F,
  "         tax_amount = s.tax,",
  "         tax_amount = e.tax_amount,  -- header tax kept",
  "-- header tax kept")
m("the header's total leaves out the tax", F,
  "         total_amount = s.base + s.tax,",
  "         total_amount = s.base,  -- no tax in total",
  "-- no tax in total")
m("the header's account does not follow", F,
  "         account_id = v_big,",
  "         account_id = e.account_id,  -- header account kept",
  "-- header account kept")
m("the count is not returned", F,
  "  return v_no;\nend;",
  "  return 0;  -- no count\nend;",
  "-- no count")
m("CONTROL", F,
  "  v_big    uuid;",
  "  v_big    uuid;  -- control",
  "-- control")
