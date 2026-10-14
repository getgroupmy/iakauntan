# Mutants for 0900 -- a secretary is an individual of eighteen recorded as
# resident in Malaysia (s.235); a director's rule is unchanged.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0900_a_secretary_is_a_resident_of_eighteen.sql \
#       supabase/tests/secretary_resident_of_eighteen.sql \
#       supabase/tests/mutants/secretary_resident_of_eighteen.py

m('a secretary is not asked at all',
  'corp_officer_is_eligible',
  "  if new.role not in ('director', 'alternate_director', 'secretary') then\n",
  "  if new.role not in ('director', 'alternate_director') then  -- no secretary\n",
  '-- no secretary')

m('a company is appointed secretary again',
  'corp_officer_is_eligible',
  "    if v_p.kind <> 'individual' then\n      raise exception\n        '% is a company, and a secretary",
  "    if false then  -- any kind\n      raise exception\n        '% is a company, and a secretary",
  '-- any kind')

m('a minor is appointed secretary again',
  'corp_officer_is_eligible',
  "    if v_p.date_of_birth + interval '18 years' > new.appointed_on then\n      raise exception\n        '% was born on % and is not yet eighteen on %. A secretary",
  "    if false then  -- any age\n      raise exception\n        '% was born on % and is not yet eighteen on %. A secretary",
  '-- any age')

m('not on the eighteenth birthday either',
  'corp_officer_is_eligible',
  "    if v_p.date_of_birth + interval '18 years' > new.appointed_on then\n      raise exception\n        '% was born on % and is not yet eighteen on %. A secretary",
  "    if v_p.date_of_birth + interval '18 years' >= new.appointed_on then  -- not the birthday\n      raise exception\n        '% was born on % and is not yet eighteen on %. A secretary",
  '-- not the birthday')

m('somebody abroad is appointed secretary',
  'corp_officer_is_eligible',
  "    if not v_p.is_resident_in_malaysia then\n",
  "    if false then  -- anywhere\n",
  '-- anywhere')

m('a secretary falls through to the director rules',
  'corp_officer_is_eligible',
  "  if new.role = 'secretary' then\n",
  "  if false then  -- as a director\n",
  '-- as a director')

m('every director must live here too',
  'corp_officer_is_eligible',
  "  if new.role = 'secretary' then\n",
  "  if new.role in ('secretary', 'director') then  -- residence for all\n",
  '-- residence for all')

m('CONTROL: a comment inside the function',
  'corp_officer_is_eligible',
  "    -- 0900: s.235.\n",
  "    -- 0900: s.235.\n    -- control\n",
  '-- control')
