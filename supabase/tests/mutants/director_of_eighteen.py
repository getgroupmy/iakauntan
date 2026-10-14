# Mutants for 0899 -- a director (or alternate) is an individual who has
# attained eighteen on the day of appointment, where a date of birth is
# recorded.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0899_a_director_is_a_person_of_eighteen.sql \
#       supabase/tests/director_of_eighteen.sql \
#       supabase/tests/mutants/director_of_eighteen.py

m('a company is appointed director again',
  'corp_director_is_eligible',
  "  if v_p.kind <> 'individual' then\n",
  "  if false and v_p.kind <> 'individual' then  -- any kind\n",
  '-- any kind')

m('a minor is appointed again',
  'corp_director_is_eligible',
  "  if v_p.date_of_birth + interval '18 years' > new.appointed_on then\n",
  "  if false and v_p.date_of_birth + interval '18 years' > new.appointed_on then  -- any age\n",
  '-- any age')

m('not on the eighteenth birthday either',
  'corp_director_is_eligible',
  "  if v_p.date_of_birth + interval '18 years' > new.appointed_on then\n",
  "  if v_p.date_of_birth + interval '18 years' >= new.appointed_on then  -- not the birthday\n",
  '-- not the birthday')

m('seventeen will do',
  'corp_director_is_eligible',
  "  if v_p.date_of_birth + interval '18 years' > new.appointed_on then\n",
  "  if v_p.date_of_birth + interval '17 years' > new.appointed_on then  -- seventeen\n",
  '-- seventeen')

m('alternates are not asked',
  'corp_director_is_eligible',
  "  if new.role not in ('director', 'alternate_director') then\n",
  "  if new.role not in ('director') then  -- directors only\n",
  '-- directors only')

m('every office is asked',
  'corp_director_is_eligible',
  "  if new.role not in ('director', 'alternate_director') then\n",
  "  if false then  -- every office\n",
  '-- every office')

m('CONTROL: a comment inside the function',
  'corp_director_is_eligible',
  "  select * into v_p from public.corp_persons where id = new.person_id;\n",
  "  -- control\n  select * into v_p from public.corp_persons where id = new.person_id;\n",
  '-- control')
