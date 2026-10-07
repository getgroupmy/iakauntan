# Mutants for public.chat_request_link, chat_decide_link,
# chat_revoke_link and chat_set_access (0135) -- two companies agreeing
# to talk, and who in one of them may.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0135_chat.sql \
#       supabase/tests/chat.sql \
#       supabase/tests/mutants/chat_links.py
#
# RESULT: 23 mutants and a control, all killed by `chat.sql`. Fifteen
# only after the "Linking two companies, rule by rule" block there:
# every request had been an owner asking a real, other, unlinked company
# and every answer a yes. Who may ask, a company asking itself or a
# company that is not there, the kind a group's companies get, a
# refusal, a second answer, the other side asking back, revocation by
# the company filed second, and both of `chat_set_access`'s guards were
# all unasserted.

m("anybody links their company",
  "chat_request_link",
  "  if not (app.can_admin(p_my_org) or app.is_platform_admin()) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a company links to itself",
  "chat_request_link",
  "  if p_my_org = p_target_org then",
  "  if false then  -- itself",
  "-- itself")

m("a company that does not exist is asked",
  "chat_request_link",
  "  if not exists (select 1 from public.organizations where id = p_target_org) then",
  "  if false then  -- nowhere",
  "-- nowhere")

m("two companies in one group link as strangers",
  "chat_request_link",
  "              and a.group_id is not null and a.group_id = b.group_id)",
  "              and false)  -- strangers",
  "-- strangers")

m("two companies in no group link as a group",
  "chat_request_link",
  "              and a.group_id is not null and a.group_id = b.group_id)",
  "              and a.group_id is not distinct from b.group_id)  -- null group",
  "-- null group")

m("an approved link is asked for again",
  "chat_request_link",
  "    if v_existing.status = 'approved' then",
  "    if false then  -- again",
  "-- again")

m("asking again leaves the old answer standing",
  "chat_request_link",
  "       set status = 'pending', requested_by_org = p_my_org,",
  "       set status = status, requested_by_org = p_my_org,  -- old answer",
  "-- old answer")

m("asking again keeps the old asker",
  "chat_request_link",
  "       set status = 'pending', requested_by_org = p_my_org,",
  "       set status = 'pending', requested_by_org = requested_by_org,  -- old asker",
  "-- old asker")

m("asking again keeps who decided last time",
  "chat_request_link",
  "           decided_by = null, decided_at = null, created_at = now()",
  "           decided_at = null, created_at = now()  -- still decided",
  "-- still decided")

m("a link is filed the wrong way round",
  "chat_request_link",
  "  values (least(p_my_org, p_target_org), greatest(p_my_org, p_target_org),",
  "  values (p_my_org, p_target_org,  -- unordered",
  "-- unordered")

m("a link that does not exist is answered in silence",
  "chat_decide_link",
  "  if v_link.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("an answered link is answered again",
  "chat_decide_link",
  "  if v_link.status <> 'pending' then",
  "  if false then  -- twice",
  "-- twice")

m("the asking side answers its own request",
  "chat_decide_link",
  "  v_other := case when v_link.requested_by_org = v_link.org_a\n                  then v_link.org_b else v_link.org_a end;",
  "  v_other := v_link.requested_by_org;  -- self-approved",
  "-- self-approved")

m("anybody answers for the company asked",
  "chat_decide_link",
  "  if not (app.can_admin(v_other) or app.is_platform_admin()) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a refusal is an approval",
  "chat_decide_link",
  "     set status = (case when p_approve then 'approved' else 'rejected' end)",
  "     set status = ('approved')  -- always yes",
  "-- always yes")

m("an answer is not signed",
  "chat_decide_link",
  "         decided_by = auth.uid(), decided_at = now()",
  "         decided_by = null, decided_at = now()  -- unsigned",
  "-- unsigned")

m("a link that does not exist is ended in silence",
  "chat_revoke_link",
  "  if v_link.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody ends a link",
  "chat_revoke_link",
  "  if not (app.can_admin(v_link.org_a) or app.can_admin(v_link.org_b)\n          or app.is_platform_admin()) then",
  "  if false then  -- anybody",
  "-- anybody")

m("only the first company may end it",
  "chat_revoke_link",
  "  if not (app.can_admin(v_link.org_a) or app.can_admin(v_link.org_b)\n",
  "  if not (app.can_admin(v_link.org_a)  -- one side\n",
  "-- one side")

m("ending a link does not end it",
  "chat_revoke_link",
  "     set status = 'revoked', decided_by = auth.uid(), decided_at = now()",
  "     set status = status, decided_by = auth.uid(), decided_at = now()  -- still linked",
  "-- still linked")

m("anybody switches chat on",
  "chat_set_access",
  "  if not (app.can_admin(p_org_id) or app.is_platform_admin()) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a stranger is switched on",
  "chat_set_access",
  "  if not exists (select 1 from public.org_members\n                  where org_id = p_org_id and user_id = p_user_id) then",
  "  if false then  -- stranger",
  "-- stranger")

m("switching off does not",
  "chat_set_access",
  "    set is_enabled = excluded.is_enabled,",
  "    set is_enabled = chat_access.is_enabled,  -- stays on",
  "-- stays on")

m("CONTROL: a comment inside the block",
  "chat_set_access",
  "    set is_enabled = excluded.is_enabled,",
  "    set is_enabled = excluded.is_enabled,  -- (control)",
  "(control)")
