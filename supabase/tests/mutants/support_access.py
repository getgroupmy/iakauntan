# Mutants for public.grant_support_access and public.end_support_access
# (0719) -- a platform administrator opens a company's books read-only,
# for a stated reason, for between five minutes and eight hours (an
# hour unless asked), one open grant per administrator per company, in
# the customer's own audit trail; the holder, any platform
# administrator, or the company's own administrator ends it, once, on
# the record.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0719_support_access_and_a_company_made_for_somebody.sql \
#       supabase/tests/support_access.sql \
#       supabase/tests/mutants/support_access.py
#
# RESULT: 19 mutants and a control, all killed by `support_access.sql`;
# five before its rule-by-rule block. The reason refusal was asserted
# by SQLSTATE alone, which the table's own check raises too; nothing
# deleted, defaulted to null, a second administrator, a second company,
# a stranger, or a session ended twice was ever in a fixture. One worth
# knowing: the minutes' `coalesce(p_minutes, 60)` is reached only by an
# explicit null -- the parameter's own default answers an omitted one.

m("anybody grants",
  "grant_support_access",
  "  if not app.is_platform_admin() then",
  "  if false then  -- anybody",
  "-- anybody")

m("no reason is needed",
  "grant_support_access",
  "  if nullif(btrim(coalesce(p_reason, '')), '') is null then",
  "  if false then  -- no reason",
  "-- no reason")

m("a deleted company is opened",
  "grant_support_access",
  "   where o.id = p_org_id and o.deleted_at is null;",
  "   where o.id = p_org_id;  -- deleted too",
  "-- deleted too")

m("no such company is not said so",
  "grant_support_access",
  "  if v_name is null then",
  "  if false then  -- any company",
  "-- any company")

m("a week",
  "grant_support_access",
  "  v_minutes := least(greatest(coalesce(p_minutes, 60), 5), 480);",
  "  v_minutes := least(greatest(coalesce(p_minutes, 60), 5), 10080);  -- a week",
  "-- a week")

m("a minute",
  "grant_support_access",
  "  v_minutes := least(greatest(coalesce(p_minutes, 60), 5), 480);",
  "  v_minutes := least(greatest(coalesce(p_minutes, 60), 1), 480);  -- a minute",
  "-- a minute")

m("half an hour unless asked",
  "grant_support_access",
  "  v_minutes := least(greatest(coalesce(p_minutes, 60), 5), 480);",
  "  v_minutes := least(greatest(coalesce(p_minutes, 30), 5), 480);  -- half an hour",
  "-- half an hour")

m("grants stack",
  "grant_support_access",
  "  update public.support_access\n     set ended_at = now(), ended_by = auth.uid()\n   where org_id = p_org_id and admin_id = auth.uid() and ended_at is null;",
  "  perform 1;  -- stacks",
  "-- stacks")

m("another administrator's grant is ended",
  "grant_support_access",
  "   where org_id = p_org_id and admin_id = auth.uid() and ended_at is null;",
  "   where org_id = p_org_id and ended_at is null;  -- any admin",
  "-- any admin")

m("this administrator's grants elsewhere are ended",
  "grant_support_access",
  "   where org_id = p_org_id and admin_id = auth.uid() and ended_at is null;",
  "   where admin_id = auth.uid() and ended_at is null;  -- any company",
  "-- any company")

m("the reason is kept as typed",
  "grant_support_access",
  "  values (p_org_id, auth.uid(), btrim(p_reason),",
  "  values (p_org_id, auth.uid(), p_reason,  -- untrimmed",
  "-- untrimmed")

m("the minutes recorded are the ones asked for",
  "grant_support_access",
  "            'minutes', v_minutes,",
  "            'minutes', p_minutes,  -- asked",
  "-- asked")

m("no such session is not said so",
  "end_support_access",
  "  if not found then",
  "  if false then  -- any id",
  "-- any id")

m("anybody ends it",
  "end_support_access",
  "  if not (s.admin_id = auth.uid()\n          or app.is_platform_admin()\n          or app.can_admin(s.org_id)) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the customer cannot end it",
  "end_support_access",
  "          or app.is_platform_admin()\n          or app.can_admin(s.org_id)) then",
  "          or app.is_platform_admin()) then  -- not the customer",
  "-- not the customer")

m("another platform administrator cannot end it",
  "end_support_access",
  "          or app.is_platform_admin()\n          or app.can_admin(s.org_id)) then",
  "          or app.can_admin(s.org_id)) then  -- holder or customer",
  "-- holder or customer")

m("ending it twice records it twice",
  "end_support_access",
  "  if s.ended_at is not null then\n    return;\n  end if;",
  "  if false then  -- again\n    return;\n  end if;",
  "-- again")

m("nobody is recorded as ending it",
  "end_support_access",
  "     set ended_at = now(), ended_by = auth.uid()\n   where id = p_id;",
  "     set ended_at = now(), ended_by = null  -- nobody\n   where id = p_id;",
  "-- nobody")

m("the trail never says the customer ended it",
  "end_support_access",
  "                             'by_the_customer', app.can_admin(s.org_id)));",
  "                             'by_the_customer', false));  -- never",
  "-- never")

m("CONTROL: a comment inside the block",
  "grant_support_access",
  "  if v_name is null then",
  "  if v_name is null then  -- (control)",
  "(control)")
