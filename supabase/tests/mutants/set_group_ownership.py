# Mutants for public.set_group_ownership (0148) -- who owns a group
# company: said by an administrator of the company OWNED; no parent
# clears it; a company cannot own itself, must be in a group, and its
# parent must be in the same group and one the caller belongs to; the
# share is more than 0 and at most 100; and a parent that is itself
# owned is refused (one level).
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0148_group_consolidation.sql \
#       supabase/tests/group_consolidation.sql \
#       supabase/tests/mutants/set_group_ownership.py
#
# RESULT: 11 mutants and a control, all 11 killed by
# `group_consolidation.sql`; before its assertions, 5. Its refusals
# caught any error, and the table refuses nought percent itself, so the
# function's own bound could go. They read their words now, and a
# stranger, a company in no group, a parent of another group, more than
# 100 percent and no share at all are asked.
#
# Noted, not raised: the one-level rule is asked of the PARENT only. A
# company that already owns another can be given a parent, which builds
# the same three-level chain from below. No figure goes wrong for it --
# the consolidation takes the whole group, every member wholly owned or
# refused -- so it is an asymmetry in the rule, not a wrong number.

F = "set_group_ownership"

m("anybody may record ownership", F,
  "  if not app.can_admin(p_org_id) then\n    raise exception 'You cannot change this company''s ownership'",
  "  if false then  -- anybody\n    raise exception 'You cannot change this company''s ownership'",
  "-- anybody")
m("no parent does not clear it", F,
  "  if p_parent_org_id is null then\n    update public.organizations\n       set parent_org_id = null, owned_percent = null\n     where id = p_org_id;\n    return;\n  end if;",
  "  -- no clearing",
  "-- no clearing")
m("a company may own itself", F,
  "  if p_parent_org_id = p_org_id then",
  "  if false then  -- self owned",
  "-- self owned")
m("a company in no group may be owned", F,
  "  if v_group is null then\n    raise exception 'This company is not in a group'",
  "  if false then  -- no group\n    raise exception 'This company is not in a group'",
  "-- no group")
m("the parent may be in another group", F,
  "     where o.id = p_parent_org_id and o.group_id = v_group\n       and app.is_org_member(o.id))",
  "     where o.id = p_parent_org_id  -- any group\n       and app.is_org_member(o.id))",
  "-- any group")
m("the parent may be one the caller is not in", F,
  "       and app.is_org_member(o.id))",
  "       and true)  -- not a member",
  "-- not a member")
m("nought percent is ownership", F,
  "  if p_percent is null or p_percent <= 0 or p_percent > 100 then",
  "  if p_percent is null or p_percent < 0 or p_percent > 100 then  -- zero ok",
  "-- zero ok")
m("more than all of it is ownership", F,
  "  if p_percent is null or p_percent <= 0 or p_percent > 100 then",
  "  if p_percent is null or p_percent <= 0 then  -- over 100",
  "-- over 100")
m("no share is ownership", F,
  "  if p_percent is null or p_percent <= 0 or p_percent > 100 then",
  "  if p_percent <= 0 or p_percent > 100 then  -- null share",
  "-- null share")
m("a chain from above is taken", F,
  "  if exists (select 1 from public.organizations\n              where id = p_parent_org_id and parent_org_id is not null) then",
  "  if false then  -- chain taken",
  "-- chain taken")
m("the share is not recorded", F,
  "     set parent_org_id = p_parent_org_id, owned_percent = p_percent",
  "     set parent_org_id = p_parent_org_id, owned_percent = 100  -- always whole",
  "-- always whole")
m("CONTROL", F,
  "declare\n  v_group uuid;\nbegin",
  "declare\n  v_group uuid;  -- control\nbegin",
  "-- control")
