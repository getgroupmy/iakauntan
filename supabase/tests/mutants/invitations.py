# Mutants for public.invite_member and public.accept_invitation (0353)
# -- an owner or administrator invites an address (trimmed, any case)
# into one company in any role but owner; an address already a member
# has its role changed instead, unless it is the owner's; the token is
# stored as a digest and lives fourteen days; it is taken only by a
# signed-in person whose address it names, once, into a company they
# are not already in.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0353_an_invitation_only_its_addressee_can_take.sql \
#       supabase/tests/invitations.sql \
#       supabase/tests/mutants/invitations.py
#
# RESULT: 20 mutants and a control. 19 killed by `invitations.sql`,
# three of them by the rule-by-rule block: every address was nobody's
# until invited, and every accepting caller was signed in with an
# address, so a re-role reaching into another company, a token taken
# by nobody and one taken by an account with no address were unasked.
#
# One is EQUIVALENT: "a used invitation is taken again". Accepting
# nulls `invite_token`, so a used token matches no row whatever its
# status; and no road writes a token onto a row that is not 'invited'.

m("anybody invites",
  "invite_member",
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an owner is invited",
  "invite_member",
  "  if p_role = 'owner' then\n    raise exception 'Ownership is transferred, not invited';",
  "  if false then  -- owners too\n    raise exception 'Ownership is transferred, not invited';",
  "-- owners too")

m("no address is needed",
  "invite_member",
  "  if v_email is null or v_email = '' then",
  "  if false then  -- no address",
  "-- no address")

m("the address keeps its spaces and capitals",
  "invite_member",
  "  v_email citext := lower(trim(p_email))::citext;",
  "  v_email citext := p_email::citext;  -- as typed",
  "-- as typed")

m("a member of another company has their role changed",
  "invite_member",
  "   where m.org_id = p_org_id and pr.email = v_email;",
  "   where pr.email = v_email;  -- any company",
  "-- any company")

m("an existing member is invited again",
  "invite_member",
  "  if v_existing is not null then\n    if v_existing_role = 'owner' then",
  "  if false then  -- invited again\n    if v_existing_role = 'owner' then",
  "-- invited again")

m("the owner is demoted by an invitation",
  "invite_member",
  "    if v_existing_role = 'owner' then",
  "    if false then  -- owner demoted",
  "-- owner demoted")

m("a member's role change hands back a link",
  "invite_member",
  "    update public.org_members set role = p_role where id = v_existing;\n    -- Nothing to accept. Returning a token here would be offering a\n    -- link that leads to \"you are already a member\".\n    return null;",
  "    update public.org_members set role = p_role where id = v_existing;\n    return 'link';  -- a link anyway",
  "-- a link anyway")

m("the token is stored as it was handed out",
  "invite_member",
  "    app.corp_token_hash(v_token), now() + interval '14 days')",
  "    v_token, now() + interval '14 days')  -- raw token",
  "-- raw token")

m("an invitation lives a year",
  "invite_member",
  "    app.corp_token_hash(v_token), now() + interval '14 days')",
  "    app.corp_token_hash(v_token), now() + interval '365 days')  -- a year",
  "-- a year")

m("nobody is recorded as inviting",
  "invite_member",
  "    p_org_id, v_email, p_role, 'invited', auth.uid(),",
  "    p_org_id, v_email, p_role, 'invited', null,  -- nobody",
  "-- nobody")

m("an anonymous caller is asked for an address",
  "accept_invitation",
  "  if auth.uid() is null then",
  "  if false then  -- anonymous",
  "-- anonymous")

m("a used invitation is taken again",
  "accept_invitation",
  "   where invite_token = app.corp_token_hash(p_token) and status = 'invited';",
  "   where invite_token = app.corp_token_hash(p_token);  -- any status",
  "-- any status")

m("the token is matched as handed out",
  "accept_invitation",
  "   where invite_token = app.corp_token_hash(p_token) and status = 'invited';",
  "   where invite_token = p_token and status = 'invited';  -- raw",
  "-- raw")

m("an expired invitation is taken",
  "accept_invitation",
  "  if v_member.invite_expires_at < now() then",
  "  if false then  -- never expires",
  "-- never expires")

m("anybody holding the link takes it",
  "accept_invitation",
  "  if v_email is null or v_email <> v_member.invited_email then",
  "  if false then  -- the token is enough",
  "-- the token is enough")

m("a caller with no address takes it",
  "accept_invitation",
  "  if v_email is null or v_email <> v_member.invited_email then",
  "  if v_email <> v_member.invited_email then  -- null passes",
  "-- null passes")

m("a member joins twice",
  "accept_invitation",
  "  if exists (select 1 from public.org_members m\n              where m.org_id = v_member.org_id and m.user_id = auth.uid()) then",
  "  if false then  -- twice",
  "-- twice")

m("the token survives being used",
  "accept_invitation",
  "     set user_id = auth.uid(), status = 'active', joined_at = now(),\n         invite_token = null",
  "     set user_id = auth.uid(), status = 'active', joined_at = now()  -- token kept\n",
  "-- token kept")

m("joining is not dated",
  "accept_invitation",
  "     set user_id = auth.uid(), status = 'active', joined_at = now(),",
  "     set user_id = auth.uid(), status = 'active', joined_at = null,  -- undated",
  "-- undated")

m("CONTROL: a comment inside the block",
  "accept_invitation",
  "  if v_member.invite_expires_at < now() then",
  "  if v_member.invite_expires_at < now() then  -- (control)",
  "(control)")
