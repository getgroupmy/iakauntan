# Mutants for 0888 -- a reversal is never dated before the journal it
# undoes, revaluations excepted; the voids reverse on the later of today
# and the original's own day.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0888_a_reversal_never_comes_before_what_it_undoes.sql \
#       supabase/tests/reversal_after_what_it_undoes.sql \
#       supabase/tests/mutants/reversal_after_what_it_undoes.py

m('a journal is reversed before it was made again',
  'reverse_gl_entry',
  "  if v_on < v_entry.entry_date and v_entry.source <> 'fx_revaluation' then\n",
  "  if false then  -- early reversal\n",
  '-- early reversal')

m('a journal is not reversed on its own day either',
  'reverse_gl_entry',
  "  if v_on < v_entry.entry_date and v_entry.source <> 'fx_revaluation' then\n",
  "  if v_on <= v_entry.entry_date and v_entry.source <> 'fx_revaluation' then  -- not that day\n",
  '-- not that day')

m('a revaluation rerun for an earlier day is refused',
  'reverse_gl_entry',
  "  if v_on < v_entry.entry_date and v_entry.source <> 'fx_revaluation' then\n",
  "  if v_on < v_entry.entry_date then  -- no exception\n",
  '-- no exception')

m('an invoice dated ahead is voided today again',
  'void_sales_document',
  "      greatest(app.today(), (select e.entry_date from public.gl_entries e\n",
  "      least(app.today(), (select e.entry_date from public.gl_entries e  -- today again\n",
  '-- today again')

m('an invoice is always voided on its own day',
  'void_sales_document',
  "      greatest(app.today(), (select e.entry_date from public.gl_entries e\n",
  "      coalesce((select e.entry_date from public.gl_entries e  -- its own day\n",
  '-- its own day')

m('a deposit dated ahead is voided today again',
  'void_deposit',
  "      greatest(app.today(), (select e.entry_date from public.gl_entries e\n",
  "      least(app.today(), (select e.entry_date from public.gl_entries e  -- today again\n",
  '-- today again')

m('a contra dated ahead is voided today again',
  'void_contra',
  "      greatest(app.today(), (select e.entry_date from public.gl_entries e\n",
  "      least(app.today(), (select e.entry_date from public.gl_entries e  -- today again\n",
  '-- today again')

m('CONTROL: a comment inside the reversal check',
  'reverse_gl_entry',
  "  if v_on < v_entry.entry_date and v_entry.source <> 'fx_revaluation' then\n",
  "  if v_on < v_entry.entry_date and v_entry.source <> 'fx_revaluation' then  -- control\n",
  '-- control')
