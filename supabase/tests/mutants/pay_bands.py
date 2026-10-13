# Mutants for 0863 -- a position's salary band goes only to a member
# app.can_manage_hr admits, through position_salary_bands.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0863_a_pay_band_is_hrs.sql \
#       supabase/tests/pay_bands_withheld.sql \
#       supabase/tests/mutants/pay_bands.py
#
# The column grant is not a function. Swept by hand: the table-wide
# select put back, "but not what it pays" fails.

m('any member is given the bands',
  'position_salary_bands',
  '     and app.can_manage_hr(p_org_id)\n',
  '     and app.is_org_member(p_org_id)  -- any member\n',
  '-- any member')

m("every company's bands",
  'position_salary_bands',
  '   where p.org_id = p_org_id\n',
  '   where true  -- every company\n',
  '-- every company')

m('CONTROL: a comment inside position_salary_bands',
  'position_salary_bands',
  '   order by p.title;\n',
  '   order by p.title;  -- (control)\n',
  '(control)')
