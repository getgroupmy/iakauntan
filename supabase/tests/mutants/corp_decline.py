# Mutants for public.corp_decline_signature and public.corp_decline_with_link
# (0378) -- saying no, at the desk or on a link: the line exists and is
# still pending, the caller may write (or the link is live), a reason is
# given and kept trimmed, the request is not withdrawn; the refusal
# carries the address, the browser and the login (none, on a link); and
# a link is spent by a refusal.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0378_saying_no_and_who_lodged_it.sql \
#       supabase/tests/decline_and_lodge.sql \
#       supabase/tests/mutants/corp_decline.py
#
# RESULT: 21 mutants and a control, all 21 killed by
# `decline_and_lodge.sql`; before its assertions, 6, all at the desk.
# `corp_decline_with_link` had never been called by any file: every
# one of its ten mutants survived the first run. Its refusals, the
# evidence it keeps, the absent login and the spent link are asserted
# now, with the desk's missing line, stranger, address, browser and
# withdrawn request.
#
# Noted, not raised: a refusal records no time. `signed_at` stays empty
# (rightly -- nothing was signed) and the table has no column for when
# somebody said no; only `updated_at` and the audit trail know.

D = "corp_decline_signature"
L = "corp_decline_with_link"

m("desk: a line that does not exist is not refused in words", D,
  "  if s.id is null then\n    raise exception 'Signature not found'",
  "  if false then  -- not found\n    raise exception 'Signature not found'",
  "-- not found")

m("desk: anybody may decline for a director", D,
  "  if not app.can_write(s.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("desk: an answered line is declined", D,
  "  if s.status <> 'pending' then\n    raise exception 'This signature is already %'",
  "  if false then  -- any status\n    raise exception 'This signature is already %'",
  "-- any status")

m("desk: no reason is a reason", D,
  "  if v_reason is null then\n    raise exception\n      'Say why.",
  "  if false then  -- no reason\n    raise exception\n      'Say why.",
  "-- no reason")

m("desk: the reason is kept with its spaces", D,
  "  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');",
  "  v_reason text := nullif(coalesce(p_reason, ''), '');  -- untrimmed",
  "-- untrimmed")

m("desk: a withdrawn request is declined", D,
  "  if r.is_withdrawn then",
  "  if false then  -- withdrawn declined",
  "-- withdrawn declined")

m("desk: the line is not marked declined", D,
  "     set status         = 'declined',",
  "     set status         = status,  -- still pending",
  "-- still pending")

m("desk: no reason is kept", D,
  "         decline_reason = v_reason,",
  "         decline_reason = null,  -- no reason kept",
  "-- no reason kept")

m("desk: no address is kept", D,
  "         ip_address     = nullif(split_part(coalesce(\n           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,\n         user_agent     = app.request_header('user-agent'),\n         signed_by      = auth.uid()",
  "         ip_address     = null,  -- no address\n         user_agent     = app.request_header('user-agent'),\n         signed_by      = auth.uid()",
  "-- no address")

m("desk: no browser is kept", D,
  "         user_agent     = app.request_header('user-agent'),\n         signed_by      = auth.uid()",
  "         user_agent     = null,  -- no browser\n         signed_by      = auth.uid()",
  "-- no browser")

m("desk: no login is kept", D,
  "         signed_by      = auth.uid()",
  "         signed_by      = null  -- no login",
  "-- no login")

m("link: no reason is a reason", L,
  "  if v_reason is null then\n    raise exception 'Say why you are not signing.'",
  "  if false then  -- no reason\n    raise exception 'Say why you are not signing.'",
  "-- no reason")

m("link: an unknown link is not refused in words", L,
  "  if l.id is null then\n    raise exception 'This link is not valid'",
  "  if false then  -- unknown link\n    raise exception 'This link is not valid'",
  "-- unknown link")

m("link: a retired link declines", L,
  "  if l.revoked_at is not null or l.used_at is not null then",
  "  if l.used_at is not null then  -- retired works",
  "-- retired works")

m("link: a used link declines", L,
  "  if l.revoked_at is not null or l.used_at is not null then",
  "  if l.revoked_at is not null then  -- used works",
  "-- used works")

m("link: an expired link declines", L,
  "  if l.expires_at < now() then",
  "  if false then  -- expired works",
  "-- expired works")

m("link: an answered line is declined", L,
  "  if s.status <> 'pending' then\n    raise exception 'That line is already %'",
  "  if false then  -- any status\n    raise exception 'That line is already %'",
  "-- any status")

m("link: a withdrawn request is declined", L,
  "  if r.is_withdrawn then",
  "  if false then  -- withdrawn declined",
  "-- withdrawn declined")

m("link: no address is kept", L,
  "         ip_address     = nullif(split_part(coalesce(\n           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,\n         user_agent     = app.request_header('user-agent'),\n         -- Null, as it is for signing through a link: nobody was signed\n",
  "         ip_address     = null,  -- no address\n         user_agent     = app.request_header('user-agent'),\n         -- Null, as it is for signing through a link: nobody was signed\n",
  "-- no address")

m("link: a login is recorded where nobody was signed in", L,
  "         signed_by      = null\n   where id = s.id;",
  "         signed_by      = auth.uid()  -- a login\n   where id = s.id;",
  "-- a login")

m("link: the link survives the refusal", L,
  "  update public.corp_signing_links\n     set used_at = now() where id = l.id;",
  "  -- link kept",
  "-- link kept")

m("CONTROL", D,
  "  r        public.corp_signature_requests;\n  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');\nbegin\n  select * into s from public.corp_signatures where id = p_signature_id;",
  "  r        public.corp_signature_requests;  -- control\n  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');\nbegin\n  select * into s from public.corp_signatures where id = p_signature_id;",
  "-- control")
