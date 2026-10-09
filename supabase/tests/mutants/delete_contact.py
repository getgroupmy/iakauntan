# Mutants for public.delete_contact (0654) -- a contact removed only when
# nothing points at it: one already gone is said to be gone (P0002,
# not a permission refusal); the caller must be able to write, AND the
# contacts module must be on -- both, because a definer function skips
# both policies otherwise; anything pointing at it refuses with the
# counts, largest first, naming the contact (or "That contact" when it
# has no name), as 23503; deleted; its name handed back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0654_deleting_a_contact_nothing_points_at.sql \
#       supabase/tests/contact_delete.sql \
#       supabase/tests/mutants/delete_contact.py
#
# RESULT: 9 mutants and a control, all killed by `contact_delete.sql`;
# six before its rule-by-rule block. Every refusal had named a contact
# with a name and listed one kind of thing, so listing the smallest
# count first or dropping the "That contact" fallback passed; and the
# module guard could not be reached by switching the module off --
# `contacts` is core -- only by a member whose access type reads
# contacts and does not write them.
#
# Noted, not raised: that member is told "The contacts module is not
# switched on for this company", which is not true of the company and
# not what stopped them.

m("a contact already deleted is not said to be gone",
  "delete_contact",
  "  if v_org is null then\n    raise exception 'That contact has already been deleted'",
  "  if false then  -- gone unsaid\n    raise exception 'That contact has already been deleted'",
  "-- gone unsaid")

m("somebody who may not write deletes a contact",
  "delete_contact",
  "  if not app.can_write(v_org) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a company without the contacts module deletes one",
  "delete_contact",
  "  if not app.can_write_module(v_org, 'contacts') then",
  "  if false then  -- no module needed",
  "-- no module needed")

m("a contact something points at is deleted anyway",
  "delete_contact",
  "  if v_blockers <> '{}'::jsonb then",
  "  if false then  -- blockers ignored",
  "-- blockers ignored")

m("the blockers are listed smallest first",
  "delete_contact",
  "              order by value::text::bigint desc, key",
  "              order by value::text::bigint, key  -- smallest first",
  "-- smallest first")

m("a nameless contact is named as nothing",
  "delete_contact",
  "                    coalesce(nullif(btrim(v_name), ''), 'That contact'),",
  "                    v_name,  -- no fallback",
  "-- no fallback")

m("a blocker refusal looks like a permission one",
  "delete_contact",
  "                    array_to_string(v_parts, ', ')\n      using errcode = '23503';",
  "                    array_to_string(v_parts, ', ')\n      using errcode = '42501';  -- as a permission",
  "-- as a permission")

m("the contact is not deleted",
  "delete_contact",
  "  delete from public.contacts where id = p_id;",
  "  perform 1;  -- kept",
  "-- kept")

m("the name is not handed back",
  "delete_contact",
  "  return jsonb_build_object('deleted', true, 'name', v_name);",
  "  return jsonb_build_object('deleted', true, 'name', null);  -- no name",
  "-- no name")

m("CONTROL: a comment inside the block",
  "delete_contact",
  "  if v_blockers <> '{}'::jsonb then",
  "  if v_blockers <> '{}'::jsonb then  -- (control)",
  "(control)")
