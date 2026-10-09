# Mutants for public.reopen_matter (0372) -- a closed or archived file
# opened again: it must exist and not be deleted, the legal module must
# be on, the caller must be able to post; an open one is refused; open
# again with its closing date cleared.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0372_a_matter_that_could_never_be_closed.sql \
#       supabase/tests/matter_closing.sql \
#       supabase/tests/mutants/reopen_matter.py
#
# RESULT: 8 mutants and a control, all killed by `matter_closing.sql`;
# three before its rule-by-rule block. Only an open matter had ever
# been refused, and no archived matter had ever been reopened.

m("a matter that does not exist is not said so",
  "reopen_matter",
  "  if v_m.id is null then\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "  if false then  -- no such matter\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "-- no such matter")

m("a deleted matter is reopened",
  "reopen_matter",
  "   where id = p_matter and deleted_at is null;\n  if v_m.id is null then\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "   where id = p_matter;  -- deleted too\n  if v_m.id is null then\n    raise exception 'No such matter.' using errcode = 'P0002';\n  end if;\n  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "-- deleted too")

m("a company without the legal module reopens a matter",
  "reopen_matter",
  "  if not app.has_module(v_m.org_id, 'legal') then\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "  if false then  -- no module needed\n    raise exception 'The legal module is not enabled for this organization.'\n      using errcode = '42501';\n  end if;\n  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "-- no module needed")

m("anybody reopens a matter",
  "reopen_matter",
  "  if not app.can_post(v_m.org_id) then\n    raise exception 'not permitted to reopen a matter'",
  "  if false then  -- whoever asks\n    raise exception 'not permitted to reopen a matter'",
  "-- whoever asks")

m("an open matter is reopened",
  "reopen_matter",
  "  if v_m.status not in ('closed', 'archived') then",
  "  if false then  -- any status",
  "-- any status")

m("an archived matter cannot be reopened",
  "reopen_matter",
  "  if v_m.status not in ('closed', 'archived') then",
  "  if v_m.status <> 'closed' then  -- closed only",
  "-- closed only")

m("a reopened matter keeps its closing date",
  "reopen_matter",
  "     set status = 'open', closed_date = null, updated_at = now()",
  "     set status = 'open', updated_at = now()  -- date kept",
  "-- date kept")

m("the matter stays closed",
  "reopen_matter",
  "     set status = 'open', closed_date = null, updated_at = now()",
  "     set closed_date = null, updated_at = now()  -- still closed",
  "-- still closed")

m("CONTROL: a comment inside the block",
  "reopen_matter",
  "  if v_m.status not in ('closed', 'archived') then",
  "  if v_m.status not in ('closed', 'archived') then  -- (control)",
  "(control)")
