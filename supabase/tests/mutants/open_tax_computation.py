# Mutants for public.open_tax_computation and public.tax_computation_misfiled
# (0665) -- opening a Form B or C computation on a financial year, and
# the list of accounts whose tax treatment is on the wrong side.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0665_the_gap_between_the_accounts_and_the_return.sql \
#       supabase/tests/tax_computation.sql \
#       supabase/tests/mutants/open_tax_computation.py
#
# RESULT: 9 of 9 killed, the control surviving -- after five
# assertions were added. The first run left five alive, none of them a
# defect in the code and every one a question the test never asked:
# another company's financial year opened; the year of assessment read
# off the start of the period, which every company in the file closing
# on 31 December could not tell apart; and the misfiled list's three
# filters -- an account taken off the chart, another company's
# accounts, and a reader who is not a member.

m('anybody opens a computation',
  'open_tax_computation',
  '  if not app.can_post(p_org_id) then',
  '  if false then  -- nobody asked',
  '-- nobody asked')

m("another company's year will do",
  'open_tax_computation',
  '   where fy.id = p_fiscal_year_id and fy.org_id = p_org_id;',
  '   where fy.id = p_fiscal_year_id;  -- any company',
  '-- any company')

m('the year of assessment is the year the period starts',
  'open_tax_computation',
  '  select fy.end_date into v_ends',
  '  select fy.start_date into v_ends  -- year it starts',
  '-- year it starts')

m('opening it twice makes a second one',
  'open_tax_computation',
  '  if v_id is not null then',
  '  if false then  -- always new',
  '-- always new')

m('the year of assessment is the year after',
  'open_tax_computation',
  '     extract(year from v_ends)::integer, auth.uid())',
  '     extract(year from v_ends)::integer + 1, auth.uid())  -- a year on',
  '-- a year on')

m('a treatment on the right side is reported as misfiled',
  'tax_computation_misfiled',
  '     and t.applies_to <> a.account_type::text',
  '     and t.applies_to = a.account_type::text  -- the right ones',
  '-- the right ones')

m('a deleted account is reported',
  'tax_computation_misfiled',
  '     and a.deleted_at is null',
  '     and true  -- deleted too',
  '-- deleted too')

m('anybody reads the list',
  'tax_computation_misfiled',
  '     and app.is_org_member(p_org_id)',
  '     and true  -- nobody asked either',
  '-- nobody asked either')

m("another company's accounts are reported",
  'tax_computation_misfiled',
  '   where a.org_id = p_org_id',
  '   where true  -- every company',
  '-- every company')

m('CONTROL: a comment inside open_tax_computation',
  'open_tax_computation',
  '  if v_id is not null then',
  '  if v_id is not null then  -- (control)',
  '(control)')
