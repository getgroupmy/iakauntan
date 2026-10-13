# Mutants for 0878 -- a salesperson writes no purchase document and a
# purchaser no sales document, unless an access type says otherwise.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0878_each_side_writes_its_own.sql \
#       supabase/tests/each_side_writes_its_own.sql \
#       supabase/tests/mutants/each_side_writes_its_own.py

m('everybody writes both sides',
  'writes_side',
  "  select not exists (\n",
  "  select true or exists (  -- everybody\n",
  '-- everybody')

m('an access type does not widen',
  'writes_side',
  "       and m.access_type_id is null\n",
  "       and true  -- type ignored\n",
  '-- type ignored')

m('the sides are the wrong way round',
  'writes_side',
  "                      when 'sales'     then 'purchaser'::app.member_role\n                      when 'purchases' then 'sales'::app.member_role\n",
  "                      when 'sales'     then 'sales'::app.member_role  -- swapped\n                      when 'purchases' then 'purchaser'::app.member_role\n",
  '-- swapped')

m('a purchaser writes sales',
  'writes_side',
  "                      when 'sales'     then 'purchaser'::app.member_role\n",
  "                      when 'sales'     then null  -- purchasers free\n",
  '-- purchasers free')

m('somebody else\'s role is asked',
  'writes_side',
  "       and m.user_id = auth.uid()\n",
  "       and true  -- anybody\n",
  '-- anybody')

m('a delete is not asked',
  'each_side_writes_its_own',
  "  if tg_op = 'DELETE' then\n    v_org := old.org_id;\n",
  "  if tg_op = 'DELETE' then\n    return old;  -- deletes free\n    v_org := old.org_id;\n",
  '-- deletes free')

m('CONTROL',
  'writes_side',
  "       and m.access_type_id is null\n",
  "       and m.access_type_id is null  -- control\n",
  '-- control')
