# Mutants for public.close_project and public.reopen_project (0389) -- a
# job closed only when its billable time has been billed, or written
# off on purpose: the project must exist, the caller must be able to
# post, not twice; billable, unbilled time on THIS project refuses the
# close unless written off, and a write-off makes exactly that time
# non-billable (the hours stay, nobody is charged); reopening needs the
# same and an open project is refused.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0389_the_project_budget_nobody_could_overrun.sql \
#       supabase/tests/project_budget.sql \
#       supabase/tests/mutants/close_project.py
#
# RESULT: 14 mutants and a control, all killed by `project_budget.sql`;
# twelve before two assertions were added: a write-off that reached
# every project's unbilled time (the file had one company with one
# job carrying hours), and reopening a project that does not exist.
#
# Noted, not yet raised: the refusal is the function's alone. The
# `projects_update` policy lets any member who can write set
# `is_active = false` directly, closing a job over unbilled hours --
# the same shape as `0775` for matters, though here the money left
# unwatched is the firm's own, not a client's. The app's project form
# does not write `is_active`, so it is the API's road, not the button's.

m("a project that does not exist is not said so",
  "close_project",
  "  if v_p.id is null then\n    raise exception 'No such project.' using errcode = 'P0002';\n  end if;\n  if not app.can_post(v_p.org_id) then\n    raise exception 'not permitted to close a project'",
  "  if false then  -- no such project\n    raise exception 'No such project.' using errcode = 'P0002';\n  end if;\n  if not app.can_post(v_p.org_id) then\n    raise exception 'not permitted to close a project'",
  "-- no such project")

m("anybody closes a project",
  "close_project",
  "  if not app.can_post(v_p.org_id) then\n    raise exception 'not permitted to close a project'",
  "  if false then  -- whoever asks\n    raise exception 'not permitted to close a project'",
  "-- whoever asks")

m("a closed project is closed again",
  "close_project",
  "  if not v_p.is_active then",
  "  if false then  -- twice",
  "-- twice")

m("unbilled time does not stop a close",
  "close_project",
  "  if v_n > 0 and not p_write_off then",
  "  if false then  -- hours left",
  "-- hours left")

m("billed time counts as unbilled",
  "close_project",
  "   where t.project_id = p_project\n     and t.is_billable\n     and not t.is_billed;",
  "   where t.project_id = p_project\n     and t.is_billable;  -- billed too\n",
  "-- billed too")

m("unbillable time counts as unbilled",
  "close_project",
  "   where t.project_id = p_project\n     and t.is_billable\n     and not t.is_billed;",
  "   where t.project_id = p_project\n     and not t.is_billed;  -- unbillable too\n",
  "-- unbillable too")

m("a write-off writes nothing off",
  "close_project",
  "  if p_write_off and v_n > 0 then",
  "  if false then  -- nothing written off",
  "-- nothing written off")

m("a write-off reaches billed time too",
  "close_project",
  "     where project_id = p_project\n       and is_billable\n       and not is_billed;",
  "     where project_id = p_project\n       and is_billable;  -- billed written off\n",
  "-- billed written off")

m("a write-off reaches other projects",
  "close_project",
  "     where project_id = p_project\n       and is_billable\n       and not is_billed;",
  "     where project_id is not null\n       and is_billable\n       and not is_billed;  -- every project",
  "-- every project")

m("the project stays open",
  "close_project",
  "     set is_active = false, updated_at = now()",
  "     set updated_at = now()  -- still open",
  "-- still open")

m("a project that does not exist is not said so, reopening",
  "reopen_project",
  "  if v_p.id is null then\n    raise exception 'No such project.' using errcode = 'P0002';\n  end if;\n  if not app.can_post(v_p.org_id) then\n    raise exception 'not permitted to reopen a project'",
  "  if false then  -- no such project\n    raise exception 'No such project.' using errcode = 'P0002';\n  end if;\n  if not app.can_post(v_p.org_id) then\n    raise exception 'not permitted to reopen a project'",
  "-- no such project")

m("anybody reopens a project",
  "reopen_project",
  "  if not app.can_post(v_p.org_id) then\n    raise exception 'not permitted to reopen a project'",
  "  if false then  -- whoever asks\n    raise exception 'not permitted to reopen a project'",
  "-- whoever asks")

m("an open project is reopened",
  "reopen_project",
  "  if v_p.is_active then",
  "  if false then  -- already open",
  "-- already open")

m("the project stays closed",
  "reopen_project",
  "     set is_active = true, updated_at = now()",
  "     set updated_at = now()  -- still closed",
  "-- still closed")

m("CONTROL: a comment inside the block",
  "close_project",
  "  if not v_p.is_active then",
  "  if not v_p.is_active then  -- (control)",
  "(control)")
