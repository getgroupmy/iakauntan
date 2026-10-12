# Mutants for public.tax_computation_lines (0665) -- the lines of a
# Form B or C computation: each tagged profit-and-loss account at its
# treatment's fraction, then the typed adjustments.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0665_the_gap_between_the_accounts_and_the_return.sql \
#       supabase/tests/tax_computation.sql \
#       supabase/tests/mutants/tax_computation_lines.py
#
# RESULT: 9 of 10 killed, the control surviving -- after one section
# was added to the test. The first run left both ends of the basis
# period free: every journal in the file was dated 30 June, so starting
# the period a day late or ending it a day early went unseen. "The
# basis period, to the day" books a penalty on each end of the year and
# one on each day outside it. The survivor, "a line of nothing is
# listed", is equivalent: `report_profit_loss` leaves out an account
# with nothing on it, and every treatment's fraction is a whole or a
# half, so no sen rounds to nothing -- said in the test beside the
# add-back assertions.

m("anybody reads any company's computation",
  'tax_computation_lines',
  '  if not app.is_org_member(c.org_id) then',
  '  if false then  -- nobody asked',
  '-- nobody asked')

m('the basis period starts a day late',
  'tax_computation_lines',
  '  v_from := c.start_date;',
  '  v_from := c.start_date + 1;  -- a day late',
  '-- a day late')

m('the basis period ends a day early',
  'tax_computation_lines',
  '  v_to   := c.end_date;',
  '  v_to   := c.end_date - 1;  -- a day early',
  '-- a day early')

m('the basis period starts a day early',
  'tax_computation_lines',
  '  v_from := c.start_date;',
  '  v_from := c.start_date - 1;  -- a day early start',
  '-- a day early start')

m('the basis period ends a day late',
  'tax_computation_lines',
  '  v_to   := c.end_date;',
  '  v_to   := c.end_date + 1;  -- a day late end',
  '-- a day late end')

m('the fraction is not applied',
  'tax_computation_lines',
  '         round(pl.amount * t.fraction, 2),',
  '         round(pl.amount, 2),  -- whole',
  '-- whole')

m('a treatment applies to any kind of account',
  'tax_computation_lines',
  '   where t.applies_to = pl.account_type::text',
  '   where true  -- any account',
  '-- any account')

m('a line of nothing is listed',
  'tax_computation_lines',
  '     and round(pl.amount * t.fraction, 2) <> 0',
  '     and true  -- zeros too',
  '-- zeros too')

m("another computation's adjustments come too",
  'tax_computation_lines',
  '   where adj.computation_id = p_computation_id',
  '   where true  -- every adjustment',
  '-- every adjustment')

m('an adjustment counts for nothing',
  'tax_computation_lines',
  '         adj.amount, 1::numeric, adj.amount, null',
  '         adj.amount, 1::numeric, 0::numeric, null  -- adjusted away',
  '-- adjusted away')

m('CONTROL: a comment inside tax_computation_lines',
  'tax_computation_lines',
  '  v_to   := c.end_date;',
  '  v_to   := c.end_date;  -- (control)',
  '(control)')
