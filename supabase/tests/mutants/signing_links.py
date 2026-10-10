# Mutants for public.corp_create_signing_link, corp_open_signing_link
# and corp_sign_with_link (0070) -- signing without an account: a link
# is issued only for a pending line by somebody who may write, one live
# per line, for one to ninety days; opening it names every state it can
# be in, records the first opening, and hands the text over only when
# it can be signed; signing with it makes every check signing at the
# desk makes, records the evidence with no login, and spends the link.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0070_signing_links.sql \
#       supabase/tests/secretarial.sql \
#       supabase/tests/mutants/signing_links.py
#
# RESULT: 31 mutants and a control, all killed by `secretarial.sql`;
# before its assertions, 10 -- the retirement on reissue, four of the
# states a link reads as, the first opening recorded, the text withheld,
# an expired link, a changed text, a spent link. Nothing had asked how
# long a link lives (a fortnight, never under a day or over ninety),
# who issued it and to what address, a missing line, a stranger, an
# answered line, the withdrawn and already-answered states, the FIRST
# opening kept, a name, an unknown or retired link, the browser and the
# time of a link signature, or that it names no login even when one is
# present. "A link signs once" caught any 22023; it reads the message
# now, which is what tells a spent link from an answered line.

C = "corp_create_signing_link"
O = "corp_open_signing_link"
S = "corp_sign_with_link"

m("issue: a line that does not exist is not refused in words", C,
  "  if s.id is null then\n    raise exception 'Signature not found'",
  "  if false then  -- not found\n    raise exception 'Signature not found'",
  "-- not found")
m("issue: anybody may issue a link", C,
  "  if not app.can_write(s.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")
m("issue: an answered line gets a link", C,
  "  if s.status <> 'pending' then\n    raise exception 'That line is already %'",
  "  if false then  -- any status\n    raise exception 'That line is already %'",
  "-- any status")
m("issue: the old link stays live", C,
  "     set revoked_at = now()\n   where signature_id = p_signature_id",
  "     set revoked_at = revoked_at  -- old stays\n   where signature_id = p_signature_id",
  "-- old stays")
m("issue: no ninety-day cap", C,
  "          now() + make_interval(days => greatest(least(coalesce(p_valid_days, 14), 90), 1)),",
  "          now() + make_interval(days => greatest(coalesce(p_valid_days, 14), 1)),  -- no cap",
  "-- no cap")
m("issue: no one-day floor", C,
  "          now() + make_interval(days => greatest(least(coalesce(p_valid_days, 14), 90), 1)),",
  "          now() + make_interval(days => least(coalesce(p_valid_days, 14), 90)),  -- no floor",
  "-- no floor")
m("issue: the default life is not a fortnight", C,
  "          now() + make_interval(days => greatest(least(coalesce(p_valid_days, 14), 90), 1)),",
  "          now() + make_interval(days => greatest(least(coalesce(p_valid_days, 1), 90), 1)),  -- one day",
  "-- one day")
m("issue: the address is not kept", C,
  "          p_email, auth.uid());",
  "          null, auth.uid());  -- no address",
  "-- no address")
m("issue: nobody is recorded as issuing it", C,
  "          p_email, auth.uid());",
  "          p_email, null);  -- nobody issued",
  "-- nobody issued")

m("open: a retired link reads as open", O,
  "    when l.revoked_at is not null then 'revoked'",
  "    when false then 'revoked'  -- revoked open",
  "-- revoked open")
m("open: a used link reads as open", O,
  "    when l.used_at is not null then 'used'",
  "    when false then 'used'  -- used open",
  "-- used open")
m("open: an expired link reads as open", O,
  "    when l.expires_at < now() then 'expired'",
  "    when false then 'expired'  -- expired open",
  "-- expired open")
m("open: a withdrawn request reads as open", O,
  "    when r.is_withdrawn then 'withdrawn'",
  "    when false then 'withdrawn'  -- withdrawn open",
  "-- withdrawn open")
m("open: an answered line reads as open", O,
  "    when s.status <> 'pending' then 'already_signed'",
  "    when false then 'already_signed'  -- answered open",
  "-- answered open")
m("open: a changed text reads as open", O,
  "    when app.corp_body_hash(d.body) <> r.body_sha256 then 'changed'",
  "    when false then 'changed'  -- changed open",
  "-- changed open")
m("open: the opening is not recorded", O,
  "     set opened_at = coalesce(opened_at, now()),",
  "     set opened_at = opened_at,  -- not recorded",
  "-- not recorded")
m("open: the first opening is overwritten", O,
  "     set opened_at = coalesce(opened_at, now()),",
  "     set opened_at = now(),  -- last opening",
  "-- last opening")
m("open: the text is handed over whatever the state", O,
  "    case when v_state = 'open' then d.body else null end,",
  "    d.body,  -- always the text",
  "-- always the text")

m("sign: no name is a signature", S,
  "  if coalesce(btrim(p_signed_name), '') = '' then",
  "  if false then  -- no name",
  "-- no name")
m("sign: an unknown link is not refused in words", S,
  "  if l.id is null then\n    raise exception 'This link is not valid'",
  "  if false then  -- unknown\n    raise exception 'This link is not valid'",
  "-- unknown")
m("sign: a retired link signs", S,
  "  if l.revoked_at is not null or l.used_at is not null then",
  "  if l.used_at is not null then  -- retired signs",
  "-- retired signs")
m("sign: a used link signs", S,
  "  if l.revoked_at is not null or l.used_at is not null then",
  "  if l.revoked_at is not null then  -- used signs",
  "-- used signs")
m("sign: an expired link signs", S,
  "  if l.expires_at < now() then",
  "  if false then  -- expired signs",
  "-- expired signs")
m("sign: an answered line is signed", S,
  "  if s.status <> 'pending' then\n    raise exception 'That line is already %'",
  "  if false then  -- any status\n    raise exception 'That line is already %'",
  "-- any status")
m("sign: a withdrawn request is signed", S,
  "  if r.is_withdrawn then",
  "  if false then  -- withdrawn signs",
  "-- withdrawn signs")
m("sign: a changed text is signed", S,
  "  if v_hash <> r.body_sha256 then",
  "  if false then  -- changed signs",
  "-- changed signs")
m("sign: the name is kept with its spaces", S,
  "         signed_name = btrim(p_signed_name),",
  "         signed_name = p_signed_name,  -- untrimmed",
  "-- untrimmed")
m("sign: no time is recorded", S,
  "         signed_at = now(),",
  "         signed_at = null,  -- no time",
  "-- no time")
m("sign: the browser is not kept", S,
  "         user_agent = app.request_header('user-agent'),\n         -- Deliberately null: nobody was signed in. The link is the\n",
  "         user_agent = null,  -- no browser\n         -- Deliberately null: nobody was signed in. The link is the\n",
  "-- no browser")
m("sign: a login is recorded where nobody was signed in", S,
  "         signed_by = null\n   where id = l.signature_id;",
  "         signed_by = auth.uid()  -- a login\n   where id = l.signature_id;",
  "-- a login")
m("sign: the link survives", S,
  "  update public.corp_signing_links set used_at = now() where id = l.id;",
  "  -- link survives",
  "-- link survives")

m("CONTROL", S,
  "  v_hash text;\nbegin\n  if coalesce(btrim(p_signed_name), '') = '' then",
  "  v_hash text;  -- control\nbegin\n  if coalesce(btrim(p_signed_name), '') = '' then",
  "-- control")
