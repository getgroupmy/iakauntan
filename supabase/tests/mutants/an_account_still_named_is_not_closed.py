# Mutants for 0921 -- retire_account refuses an account that a setting
# still names for postings to come.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0921_an_account_still_named_is_not_closed.sql \
#       supabase/tests/an_account_still_named_is_not_closed.sql \
#       supabase/tests/mutants/an_account_still_named_is_not_closed.py

F = 'retire_account'

m('a named account is closed all the same',
  F,
  "  if v_named_n > 0 then\n",
  "  if false /* never */ then\n",
  '/* never */')

# --- each thing that names an account --------------------------------
m('payroll settings are not asked',
  F,
  "           where s.org_id = v_a.org_id and k.account_id = p_id\n",
  "           where s.org_id = v_a.org_id and k.account_id = p_id and false /* no payroll */\n",
  '/* no payroll */')

m("a contact's receivable account is not asked",
  F,
  "           where c.receivable_account_id = p_id and c.deleted_at is null\n",
  "           where c.receivable_account_id = p_id and c.deleted_at is null and false /* no recv */\n",
  '/* no recv */')

m("a contact's payable account is not asked",
  F,
  "           where c.payable_account_id = p_id and c.deleted_at is null\n",
  "           where c.payable_account_id = p_id and c.deleted_at is null and false /* no pay */\n",
  '/* no pay */')

m("an item's sales account is not asked",
  F,
  "           where i.sales_account_id = p_id and i.deleted_at is null\n",
  "           where i.sales_account_id = p_id and i.deleted_at is null and false /* no sales */\n",
  '/* no sales */')

m("an item's purchase account is not asked",
  F,
  "           where i.purchase_account_id = p_id and i.deleted_at is null\n",
  "           where i.purchase_account_id = p_id and i.deleted_at is null and false /* no purch */\n",
  '/* no purch */')

m('a claim type is not asked',
  F,
  "           where t.expense_account_id = p_id\n",
  "           where t.expense_account_id = p_id and false /* no claim */\n",
  '/* no claim */')

for col, line in [('asset_account_id,      ', 'asset account'),
                  ('accumulated_account_id,', 'accumulated depreciation'),
                  ('expense_account_id,    ', 'depreciation expense')]:
    m("a fixed asset's %s is not asked" % line,
      F,
      "              (f.%s '%s')" % (col, line),
      "              (null::uuid /* fa %s */, '%s')" % (line, line),
      '/* fa %s */' % line)

# --- each line of the payroll settings -------------------------------
for col, pad, line in [
    ('salary_expense_account_id', ' ', "salary expense"),
    ('epf_expense_account_id', '    ', "employer''s EPF expense"),
    ('socso_expense_account_id', '  ', "employer''s SOCSO expense"),
    ('eis_expense_account_id', '    ', "employer''s EIS expense"),
    ('hrdf_expense_account_id', '   ', "HRD Corp levy expense"),
    ('salary_payable_account_id', ' ', "net salary payable"),
    ('epf_payable_account_id', '    ', "EPF payable"),
    ('socso_payable_account_id', '  ', "SOCSO payable"),
    ('eis_payable_account_id', '    ', "EIS payable"),
    ('pcb_payable_account_id', '    ', "PCB payable"),
    ('zakat_payable_account_id', '  ', "zakat payable"),
]:
    m('the payroll line %s is not asked' % col,
      F,
      "              (s.%s,%s'%s')" % (col, pad, line),
      "              (null::uuid /* %s */,%s'%s')" % (col, pad, line),
      '/* %s */' % col)

m('the EPF payable is called the SOCSO payable',
  F,
  "              (s.epf_payable_account_id,    'EPF payable'),\n",
  "              (s.epf_payable_account_id,    'SOCSO payable' /* misnamed */),\n",
  '/* misnamed */')

# --- rows no longer in use -------------------------------------------
m('a removed contact still holds its receivable account open',
  F,
  "           where c.receivable_account_id = p_id and c.deleted_at is null\n",
  "           where c.receivable_account_id = p_id  -- removed too\n",
  '-- removed too')

m('a removed contact still holds its payable account open',
  F,
  "           where c.payable_account_id = p_id and c.deleted_at is null\n",
  "           where c.payable_account_id = p_id  -- removed too\n",
  '-- removed too')

m('a removed item still holds its sales account open',
  F,
  "           where i.sales_account_id = p_id and i.deleted_at is null\n",
  "           where i.sales_account_id = p_id  -- removed too\n",
  '-- removed too')

m('a removed item still holds its purchase account open',
  F,
  "           where i.purchase_account_id = p_id and i.deleted_at is null\n",
  "           where i.purchase_account_id = p_id  -- removed too\n",
  '-- removed too')

m('an asset removed from the register still holds its accounts open',
  F,
  "             and f.deleted_at is null\n",
  "             -- removed too\n",
  '-- removed too')

m('a disposed asset still holds its accounts open',
  F,
  "             and f.status in ('active', 'fully_depreciated')\n",
  "             -- any status\n",
  '-- any status')

m('a fully depreciated asset no longer holds its accounts open',
  F,
  "             and f.status in ('active', 'fully_depreciated')\n",
  "             and f.status in ('active')  -- active only\n",
  '-- active only')

# --- the four found by measuring ---------------------------------------
m("a payment method's charge account is not asked",
  F,
  "           where m.charge_account_id = p_id and m.deleted_at is null\n",
  "           where m.charge_account_id = p_id and m.deleted_at is null and false /* no pm */\n",
  '/* no pm */')

m('a removed payment method still holds its charge account open',
  F,
  "           where m.charge_account_id = p_id and m.deleted_at is null\n",
  "           where m.charge_account_id = p_id  -- removed too\n",
  '-- removed too')

m('a recurring journal is not asked',
  F,
  "           where j.org_id = v_a.org_id\n",
  "           where j.org_id = v_a.org_id and false /* no rj */\n",
  '/* no rj */')

m('a recurring journal switched off still holds its accounts open',
  F,
  "             and j.is_active\n",
  "             -- off too\n",
  '-- off too')

m('a recurring journal past its end still holds its accounts open',
  F,
  "             and (j.end_date is null or j.next_run_date <= j.end_date)\n",
  "             -- ended too\n",
  '-- ended too')

m('a recurring document is not asked',
  F,
  "           where r.org_id = v_a.org_id\n",
  "           where r.org_id = v_a.org_id and false /* no rd */\n",
  '/* no rd */')

m('a recurring document switched off still holds its accounts open',
  F,
  "             and r.is_active\n",
  "             -- off too\n",
  '-- off too')

m('revenue still to recognise is not asked',
  F,
  "           where d.org_id = v_a.org_id\n",
  "           where d.org_id = v_a.org_id and false /* no rev */\n",
  '/* no rev */')

m('revenue already recognised still holds its account open',
  F,
  "                  and s.gl_entry_id is null\n",
  "                  -- recognised too\n",
  '-- recognised too')

m('revenue taken back in full still holds its account open',
  F,
  "                  and s.amount > s.cancelled_amount)\n",
  "                  /* cancelled too */)\n",
  '/* cancelled too */')

# --- how the refusal reads -------------------------------------------
m('four are named, not five',
  F,
  "filter (where x.rn <= 5)\n",
  "filter (where x.rn <= 4 /* four */)\n",
  '/* four */')

m('the rest are counted from the wrong number',
  F,
  "                      then ' and ' || (v_named_n - 5) || ' more' else '' end\n",
  "                      then ' and ' || (v_named_n - 4 /* off by one */) || ' more' else '' end\n",
  '/* off by one */')

m('"and N more" is said only past six',
  F,
  "      v_named || case when v_named_n > 5\n",
  "      v_named || case when v_named_n > 7 /* late */\n",
  '/* late */')

m('what names it is listed by name alone, not by kind first',
  F,
  "         string_agg(x.what, ', ' order by x.ord, x.what) filter (where x.rn <= 5)\n",
  "         string_agg(x.what, ', ' order by x.what /* by name */) filter (where x.rn <= 5)\n",
  '/* by name */')

m('the five named are the last five, not the first',
  F,
  "      select y.ord, y.what, row_number() over (order by y.ord, y.what) as rn\n",
  "      select y.ord, y.what, row_number() over (order by y.ord, y.what desc /* last */) as rn\n",
  '/* last */')

m('the refusal is a permission error, not a rule',
  F,
  "                      then ' and ' || (v_named_n - 5) || ' more' else '' end\n"
  "      using errcode = '23514';\n",
  "                      then ' and ' || (v_named_n - 5) || ' more' else '' end\n"
  "      using errcode = '42501';  -- permission\n",
  '-- permission')

m('CONTROL: a comment inside the function',
  F,
  "  -- And what still names it for postings to come (0921). A setting\n",
  "  -- And what still names it for postings to come (0921). A setting (control)\n",
  '(control)')
