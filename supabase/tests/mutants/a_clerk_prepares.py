# Mutants for 0883 -- deposits, contras and post-dated cheques post a
# journal, so each asks app.can_post as well as the module.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0883_a_clerk_prepares_somebody_else_posts.sql \
#       supabase/tests/a_clerk_prepares.sql \
#       supabase/tests/mutants/a_clerk_prepares.py

m('create contra does not ask whether the caller may post',
  'create_contra',
  "  if not app.can_post(p_org) then\n",
  "  if false then  -- create_contra unasked\n",
  '-- create_contra unasked')

m('create deposit does not ask whether the caller may post',
  'create_deposit',
  "  if not app.can_post(p_org) then\n",
  "  if false then  -- create_deposit unasked\n",
  '-- create_deposit unasked')

m('apply deposit does not ask whether the caller may post',
  'apply_deposit',
  "  if not app.can_post(v_note.org_id) then\n",
  "  if false then  -- apply_deposit unasked\n",
  '-- apply_deposit unasked')

m('settle deposit does not ask whether the caller may post',
  'settle_deposit',
  "  if not app.can_post(v_note.org_id) then\n",
  "  if false then  -- settle_deposit unasked\n",
  '-- settle_deposit unasked')

m('record pdc does not ask whether the caller may post',
  'record_pdc',
  "  if not app.can_post(p_org) then\n",
  "  if false then  -- record_pdc unasked\n",
  '-- record_pdc unasked')

m('clear pdc does not ask whether the caller may post',
  'clear_pdc',
  "  if not app.can_post(v_c.org_id) then\n",
  "  if false then  -- clear_pdc unasked\n",
  '-- clear_pdc unasked')

m('bounce pdc does not ask whether the caller may post',
  'bounce_pdc',
  "  if not app.can_post(v_c.org_id) then\n",
  "  if false then  -- bounce_pdc unasked\n",
  '-- bounce_pdc unasked')

m('CONTROL: a comment inside create_deposit',
  'create_deposit',
  "  if not app.can_post(p_org) then\n",
  "  if not app.can_post(p_org) then  -- control\n",
  '-- control')
