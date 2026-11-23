# Mutants for 0920 -- a client's own statement does not insert an
# account or change one's number, kind, subtype, heading flag or parent.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0920_the_chart_is_shaped_by_upsert_account.sql \
#       supabase/tests/the_chart_is_shaped_by_upsert_account.sql \
#       supabase/tests/mutants/the_chart_is_shaped_by_upsert_account.py

F = 'the_chart_is_shaped_by_upsert_account'

m('everybody is asked, the owner and the functions included',
  F,
  "  if current_user not in ('authenticated', 'anon') then\n    return new;\n  end if;\n",
  "  -- everybody is asked\n",
  '-- everybody is asked')

m('only anon is asked',
  F,
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if current_user not in ('anon') then  -- anon only\n",
  '-- anon only')

m('the trigger runs as its owner, so nobody is a client',
  F,
  "language plpgsql\nset search_path = public, app, pg_temp\nas $$\ndeclare\n",
  "language plpgsql\nsecurity definer\nset search_path = public, app, pg_temp\nas $$\n"
  "declare  -- as owner\n",
  '-- as owner')

m('a direct insert is not asked',
  F,
  "  if tg_op = 'INSERT' then\n    raise exception\n",
  "  if tg_op = 'INSERT' then return new; end if;  -- insert is free\n"
  "  if tg_op = 'INSERT' then\n    raise exception\n",
  '-- insert is free')

for col, what in [
    ('code', 'number'),
    ('account_type', 'kind'),
    ('account_subtype', 'subtype'),
    ('is_group', 'heading'),
    ('parent_id', 'parent'),
]:
    m('a change of %s is not asked' % what,
      F,
      "  if new.%s is distinct from old.%s then\n" % (col, col),
      "  if false /* %s is free */ then\n" % what,
      '/* %s is free */' % what)

m('every update is refused, whether or not the shape moved',
  F,
  "  if cardinality(v_what) > 0 then\n",
  "  if true /* always */ then\n",
  '/* always */')

m('what moved is listed with commas',
  F,
  "array_to_string(v_what, ' or ')",
  "array_to_string(v_what, ', ' /* commas */)",
  '/* commas */')

m('the number is called the code',
  F,
  "    v_what := v_what || 'its number'::text;\n",
  "    v_what := v_what || 'its code'::text;  -- renamed\n",
  '-- renamed')

m('the refusal of an update is a check violation, not a permission',
  F,
  "      old.code, array_to_string(v_what, ' or ')\n      using errcode = '42501';\n",
  "      old.code, array_to_string(v_what, ' or ')\n      using errcode = '23514';  -- check\n",
  '-- check')

m('the refusal of an insert is a check violation, not a permission',
  F,
  "      'its kind and where it is filed -- not by a direct write.'\n      using errcode = '42501';\n",
  "      'its kind and where it is filed -- not by a direct write.'\n      using errcode = '23514';  -- check\n",
  '-- check')

m('CONTROL: a comment inside the function',
  F,
  "  -- NOT security definer: a definer would always answer \"the owner\".\n",
  "  -- NOT security definer: a definer would always answer \"the owner\". (control)\n",
  '(control)')
