# Mutants for 0835 -- app.a_share_class_stays_with_its_company refuses
# any change to the company a class of shares belongs to.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0835_a_class_of_shares_stays_with_its_company.sql \
#       supabase/tests/share_class_company_kept.sql \
#       supabase/tests/mutants/a_class_of_shares_stays_with_its_company.py
#
# RESULT, 12 October: 3 of 3 killed by share_class_company_kept.sql,
# the control surviving. No mutant for `org_id`: the same-tenant key
# (0519) refuses a tenant moved without its company, so the trigger
# asks only the company -- and the file moves both, as the owner.

m('the company is never asked',
  'a_share_class_stays_with_its_company',
  '  if NEW.entity_id is distinct from OLD.entity_id then',
  '  if false then  -- never asked',
  '-- never asked')

m('the code is asked instead of the company',
  'a_share_class_stays_with_its_company',
  '  if NEW.entity_id is distinct from OLD.entity_id then',
  '  if NEW.code is distinct from OLD.code then  -- the code',
  '-- the code')

m('every amendment is refused',
  'a_share_class_stays_with_its_company',
  '  if NEW.entity_id is distinct from OLD.entity_id then',
  '  if true then  -- nothing amended',
  '-- nothing amended')

m('CONTROL: a comment inside a_share_class_stays_with_its_company',
  'a_share_class_stays_with_its_company',
  '  return NEW;\nend $$;',
  '  return NEW;  -- (control)\nend $$;',
  '(control)')
