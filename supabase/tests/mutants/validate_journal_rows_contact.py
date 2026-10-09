# Mutants for app.validate_journal_rows (0774, restated from 0633) -- the
# contact check 0774 adds, and only that: a contact code that is GIVEN
# must be a contact of THIS company, not deleted, matched in any case;
# an empty column is fine. The rest of the validator is 0633's and is
# reached through `mutants/import_journals.py`'s fixture.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0774_a_contact_code_in_a_journal_file_is_somebody.sql \
#       supabase/tests/import_journals.sql \
#       supabase/tests/mutants/validate_journal_rows_contact.py

m("an unknown contact code passes",
  "validate_journal_rows",
  "    elsif v_contact is not null and not exists (",
  "    elsif false and not exists (  -- any code",
  "-- any code")

m("an empty contact column is refused",
  "validate_journal_rows",
  "    elsif v_contact is not null and not exists (",
  "    elsif not exists (  -- column required",
  "-- column required")

m("another company's contact passes",
  "validate_journal_rows",
  "       where c.org_id = p_org_id and lower(c.code) = lower(v_contact)\n         and c.deleted_at is null)\n    then\n      v_problem := format(\n        'There is no customer or supplier",
  "       where lower(c.code) = lower(v_contact)  -- any company\n         and c.deleted_at is null)\n    then\n      v_problem := format(\n        'There is no customer or supplier",
  "-- any company")

m("a deleted contact passes",
  "validate_journal_rows",
  "         and c.deleted_at is null)\n    then\n      v_problem := format(\n        'There is no customer or supplier",
  "         and true)  -- deleted too\n    then\n      v_problem := format(\n        'There is no customer or supplier",
  "-- deleted too")

m("a contact code in another case is refused",
  "validate_journal_rows",
  "       where c.org_id = p_org_id and lower(c.code) = lower(v_contact)\n         and c.deleted_at is null)\n    then\n      v_problem := format(\n        'There is no customer or supplier",
  "       where c.org_id = p_org_id and c.code = v_contact  -- exact case\n         and c.deleted_at is null)\n    then\n      v_problem := format(\n        'There is no customer or supplier",
  "-- exact case")

m("CONTROL: a comment inside the block",
  "validate_journal_rows",
  "    elsif v_contact is not null and not exists (",
  "    elsif v_contact is not null and not exists (  -- (control)",
  "(control)")
