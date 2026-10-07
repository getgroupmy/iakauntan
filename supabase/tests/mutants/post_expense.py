# Mutants for public.post_expense (0727) -- an expense paid: the cost
# (split across lines when it has them, the largest taking the rounding),
# the input tax, and the account the money left, which it must name.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0727_an_expense_says_where_the_money_left.sql \
#       supabase/tests/expense_split.sql \
#       supabase/tests/mutants/post_expense.py
#
# RESULT: 23 mutants and a control. 22 killed between `expense_split.sql`
# and `expenses.sql` (run against each; neither kills them all alone).
# Two only after additions. The refusal of an expense naming NO account
# -- 0727's own fix -- was asserted by "names the expense" and "says
# paid from", and the next guard down says both of those too, so 0727's
# guard could be deleted and the refusal would come from the wrong
# sentence ("not one of this company's"). And no split had two equal
# largest lines, so the tie-break was never asked.
#
# One EQUIVALENT: "another company's bank account is paid from". `0160`'s
# foreign key makes such an expense impossible to insert; noted beside
# that block in `expenses.sql`.

m("an expense that does not exist posts nothing in silence",
  "post_expense",
  "  if not found then raise exception 'Expense % not found', p_id; end if;",
  "  if false then raise exception 'Expense % not found', p_id; end if;  -- no such",
  "-- no such")

m("a deleted expense is posted",
  "post_expense",
  "  if v_exp.deleted_at is not null then",
  "  if false then  -- deleted",
  "-- deleted")

m("anybody posts an expense",
  "post_expense",
  "  if not app.can_post(v_exp.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an expense is posted twice",
  "post_expense",
  "  if v_exp.gl_entry_id is not null then",
  "  if false then  -- double post",
  "-- double post")

m("a total that is not cost plus tax is posted",
  "post_expense",
  "  if v_exp.total_amount is distinct from v_exp.amount + v_exp.tax_amount then",
  "  if false then  -- mistotalled",
  "-- mistotalled")

m("a foreign expense is posted in its own currency's units",
  "post_expense",
  "  v_rate := coalesce(v_exp.exchange_rate, 1);",
  "  v_rate := 1;  -- unconverted",
  "-- unconverted")

m("an expense that names no account is posted (0286's shape)",
  "post_expense",
  "  if v_exp.bank_account_id is null then",
  "  if false then  -- no account",
  "-- no account")

m("another company's bank account is paid from",
  "post_expense",
  "   where b.id = v_exp.bank_account_id and b.org_id = v_exp.org_id;",
  "   where b.id = v_exp.bank_account_id;  -- any company",
  "-- any company")

m("the cost leg takes the cost converted alone",
  "post_expense",
  "  v_net := v_total - v_tax;",
  "  v_net := v_total - v_tax + 0.01;  -- off by a sen",
  "-- off by a sen")

m("the first line takes the rounding, not the largest",
  "post_expense",
  "   order by amount desc, line_no\n",
  "   order by line_no  -- first line\n",
  "-- first line")

m("of two equal lines the later takes the rounding",
  "post_expense",
  "   order by amount desc, line_no\n",
  "   order by amount desc, line_no desc  -- later line\n",
  "-- later line")

m("a line's own account is ignored",
  "post_expense",
  "      v_entries := v_entries || jsonb_build_object(\n        'account_id', r.account_id,",
  "      v_entries := v_entries || jsonb_build_object(\n        'account_id', v_exp.account_id,  -- header account",
  "-- header account")

m("a line's own project is ignored",
  "post_expense",
  "        'project_code', coalesce(r.project_code, v_exp.project_code),",
  "        'project_code', v_exp.project_code,  -- header project",
  "-- header project")

m("a line's own department is ignored",
  "post_expense",
  "        'department_code', coalesce(r.department_code,\n                                    v_exp.department_code),",
  "        'department_code', v_exp.department_code,  -- header department",
  "-- header department")

m("a line's own matter is ignored",
  "post_expense",
  "        'matter_id', coalesce(r.matter_id, v_exp.matter_id));\n    end loop;",
  "        'matter_id', v_exp.matter_id);  -- header matter\n    end loop;",
  "-- header matter")

m("a line with no project of its own loses the expense's",
  "post_expense",
  "        'project_code', coalesce(r.project_code, v_exp.project_code),",
  "        'project_code', r.project_code,  -- line only",
  "-- line only")

m("a line's description is ignored",
  "post_expense",
  "        'description', coalesce(r.description, v_exp.description,",
  "        'description', coalesce(v_exp.description,  -- header words",
  "-- header words")

m("an unsplit expense loses its department",
  "post_expense",
  "      'department_code', v_exp.department_code,\n      'matter_id', v_exp.matter_id);",
  "      'department_code', null,\n      'matter_id', v_exp.matter_id);  -- no department",
  "-- no department")

m("an unsplit expense loses its matter",
  "post_expense",
  "      'department_code', v_exp.department_code,\n      'matter_id', v_exp.matter_id);",
  "      'department_code', v_exp.department_code,\n      'matter_id', null);  -- no matter",
  "-- no matter")

m("the input tax is not claimed",
  "post_expense",
  "  if coalesce(v_exp.tax_amount, 0) > 0 then",
  "  if false then  -- no claim",
  "-- no claim")

m("the input tax is not tagged with its code",
  "post_expense",
  "      'tax_code_id', v_exp.tax_code_id,",
  "      'tax_code_id', null,  -- untagged",
  "-- untagged")

m("a posted expense does not say so",
  "post_expense",
  "     set gl_entry_id = v_entry_id, status = 'posted', posted_at = now()",
  "     set gl_entry_id = v_entry_id, status = status, posted_at = now()  -- draft",
  "-- draft")

m("the bank balance does not move",
  "post_expense",
  "     set current_balance = current_balance - v_total\n",
  "     set current_balance = current_balance  -- unmoved\n",
  "-- unmoved")

m("CONTROL: a comment inside the block",
  "post_expense",
  "  v_net := v_total - v_tax;",
  "  v_net := v_total - v_tax;  -- (control)",
  "(control)")
