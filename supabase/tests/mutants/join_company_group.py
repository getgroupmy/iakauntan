# Mutants for public.join_company_group (0132) -- an administrator of
# the company moves it into a group (or out, with null); a group that
# does not exist is said so; a group with companies in it is joined only
# by somebody already a member of one of them; an empty one is the one
# somebody just made.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0132_company_groups.sql \
#       supabase/tests/branches_and_groups.sql \
#       supabase/tests/mutants/join_company_group.py
#
# RESULT: 5 mutants and a control, all killed by
# `branches_and_groups.sql`; two before the block was extended. Its
# comment said a stranger "cannot attach a company to it", but the one
# try used a company the stranger did not administer, so the ADMIN
# guard answered and the group's own -- membership of a company already
# in it -- was never reached: "a stranger joins a group with companies
# in it" survived. Nor was a missing group or leaving one asked.
#
# Noted, not raised: an EMPTY group may be joined by any administrator
# who has its id, because "a group with nothing in it yet is the one
# somebody just made" -- `created_by` is not consulted. Ids are random
# and an empty group is readable by nobody, its maker included, so
# squatting one needs an id nobody can list.

F = "join_company_group"

m("anybody moves a company", F,
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a group that does not exist is not said so", F,
  "     and not exists (select 1 from public.company_groups g where g.id = p_group_id)",
  "     and false  -- any group",
  "-- any group")

m("a stranger joins a group with companies in it", F,
  "     and not app.is_group_member(p_group_id) then",
  "     and false then  -- strangers too",
  "-- strangers too")

m("a group just made cannot be joined", F,
  "     and exists (select 1 from public.organizations o where o.group_id = p_group_id)",
  "     and true  -- empty asked too",
  "-- empty asked too")

m("a company cannot leave its group", F,
  "  update public.organizations set group_id = p_group_id where id = p_org_id;",
  "  update public.organizations set group_id = coalesce(p_group_id, group_id) where id = p_org_id;  -- stays",
  "-- stays")

m("CONTROL: a comment inside the block", F,
  "  if not app.can_admin(p_org_id) then",
  "  if not app.can_admin(p_org_id) then  -- (control)",
  "(control)")
