# Mutants for public.portal_document_token (0493, restated in 0798) --
# from an open portal link to a customer the company has not deleted, a
# link to one of this customer's own documents in this company,
# never a draft, void or rejected one, living no longer than the portal
# link or thirty days, addressed where the portal link was.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0798_a_withdrawn_account_mints_nothing.sql \
#       supabase/tests/customer_portal_shapes.sql \
#       supabase/tests/mutants/portal_document_token.py
#
# RESULT: 16 mutants and a control. 13 killed by
# `customer_portal_shapes.sql`, three of them (a rejected document, the
# thirty-day cap under a longer portal, the address a minted link
# inherits) only after the block added beside section 5, and one (a
# withdrawn account) by `0798`'s own assertion there.
#
# EQUIVALENT, three, all recorded in the file's section 6:
#   * "another company's document opens" and "another company's record
#     with our party id counts" mask each other -- the same rule written
#     twice, the document held to its contact's company by
#     `sales_documents_contact_same_org`. "neither company check", both
#     removed at once, is killed by the impostor.
#   * "a document with no customer opens": `contact_id` is NOT NULL, and
#     `c2.id = null` matches nothing in any case.

F = "portal_document_token"

m("a revoked portal mints links", F,
  "     and revoked_at is null and expires_at >= now();\n  if l.id is null then\n    raise exception 'This link is no longer open'",
  "     and expires_at >= now();  -- revoked mints\n  if l.id is null then\n    raise exception 'This link is no longer open'",
  "-- revoked mints")
m("an expired portal mints links", F,
  "     and revoked_at is null and expires_at >= now();\n  if l.id is null then\n    raise exception 'This link is no longer open'",
  "     and revoked_at is null;  -- expired mints\n  if l.id is null then\n    raise exception 'This link is no longer open'",
  "-- expired mints")
m("a withdrawn account mints links", F,
  "  if c.id is null or c.deleted_at is not null then\n    raise exception 'This link is no longer open' using errcode = '42501';",
  "  if c.id is null then  -- withdrawn mints\n    raise exception 'This link is no longer open' using errcode = '42501';",
  "-- withdrawn mints")
m("a deleted document opens", F,
  "     or d.deleted_at is not null\n",
  "     or false  -- deleted opens\n",
  "-- deleted opens")
m("another company's document opens", F,
  "     or d.org_id <> l.org_id\n",
  "     or false  -- any company\n",
  "-- any company")
m("a document with no customer opens", F,
  "     or d.contact_id is null\n",
  "     or false  -- no customer\n",
  "-- no customer")
m("the customer's other record does not count", F,
  "               or (c.party_id is not null and c2.party_id = c.party_id)))\n  then",
  "               or false))  -- one record\n  then",
  "-- one record")
m("another company's record with our party id counts", F,
  "        where c2.id = d.contact_id\n          and c2.org_id = l.org_id\n",
  "        where c2.id = d.contact_id  -- any company's record\n",
  "-- any company's record")
m("a draft opens", F,
  "  if d.status in ('draft', 'void', 'rejected') then",
  "  if d.status in ('void', 'rejected') then  -- draft opens",
  "-- draft opens")
m("a void document opens", F,
  "  if d.status in ('draft', 'void', 'rejected') then",
  "  if d.status in ('draft', 'rejected') then  -- void opens",
  "-- void opens")
m("a rejected document opens", F,
  "  if d.status in ('draft', 'void', 'rejected') then",
  "  if d.status in ('draft', 'void') then  -- rejected opens",
  "-- rejected opens")
m("a document link outlives the portal", F,
  "          least(l.expires_at, now() + interval '30 days'),",
  "          now() + interval '30 days',  -- outlives",
  "-- outlives")
m("a document link lives as long as the portal", F,
  "          least(l.expires_at, now() + interval '30 days'),",
  "          l.expires_at,  -- as long",
  "-- as long")
m("the link is addressed to nobody", F,
  "          l.sent_to_email);",
  "          null);  -- nobody",
  "-- nobody")
m("the token handed back opens nothing", F,
  "  values (l.org_id, d.id, app.corp_token_hash(v_token),",
  "  values (l.org_id, d.id, app.corp_token_hash(v_token || 'x'),  -- wrong hash",
  "-- wrong hash")

m("neither company check", F,
  "     or d.org_id <> l.org_id\n     or d.contact_id is null\n     or not exists (\n       select 1 from public.contacts c2\n        where c2.id = d.contact_id\n          and c2.org_id = l.org_id\n",
  "     or d.contact_id is null\n     or not exists (\n       select 1 from public.contacts c2\n        where c2.id = d.contact_id  -- no company asked\n",
  "-- no company asked")

m("CONTROL", F,
  "  v_token text;\nbegin\n  select * into l from public.customer_portal_links\n   where token_hash = app.corp_token_hash(p_token)\n     and revoked_at is null and expires_at >= now();\n  if l.id is null then\n    raise exception 'This link is no longer open'",
  "  v_token text;  -- control\nbegin\n  select * into l from public.customer_portal_links\n   where token_hash = app.corp_token_hash(p_token)\n     and revoked_at is null and expires_at >= now();\n  if l.id is null then\n    raise exception 'This link is no longer open'",
  "-- control")
