# Mutants for public.detach_company_from_firm (0450) -- either side ends
# the appointment, the company's administrator or the firm's manager;
# exactly the memberships the firm brought are removed, in this company
# only, and the company keeps no firm; it says how many went. A company
# with no firm is nothing to detach.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0450_the_firm_that_keeps_other_peoples_books.sql \
#       supabase/tests/firm_portfolio.sql \
#       supabase/tests/mutants/detach_company_from_firm.py
#
# RESULT: 8 mutants and a control, all killed by `firm_portfolio.sql`;
# three before its rule-by-rule block. Every detach in the file was
# made by somebody who both owned the company and ran the firm, so the
# guard -- either side may end it, nobody else -- was never asked, a
# firm never had a second client for its staff to stay in, and the
# count it returns was never read. "Anybody ends it" survived: the
# guard on who may take a practice's access to a company's books had
# no assertion at all.

F = "detach_company_from_firm"

m("anybody ends it", F,
  "  if not (app.can_admin(p_org_id) or app.can_manage_firm(v_firm)) then",
  "  if false then  -- anybody",
  "-- anybody")

m("only the company may end it", F,
  "  if not (app.can_admin(p_org_id) or app.can_manage_firm(v_firm)) then",
  "  if not app.can_admin(p_org_id) then  -- company only",
  "-- company only")

m("only the firm may end it", F,
  "  if not (app.can_admin(p_org_id) or app.can_manage_firm(v_firm)) then",
  "  if not app.can_manage_firm(v_firm) then  -- firm only",
  "-- firm only")

m("the client's own people go too", F,
  "   where m.org_id = p_org_id and m.via_firm_id = v_firm;",
  "   where m.org_id = p_org_id and m.user_id <> auth.uid();  -- everybody",
  "-- everybody")

m("the firm's staff leave its other clients too", F,
  "   where m.org_id = p_org_id and m.via_firm_id = v_firm;",
  "   where m.via_firm_id = v_firm;  -- every client",
  "-- every client")

m("the firm's access stays", F,
  "   where m.org_id = p_org_id and m.via_firm_id = v_firm;",
  "   where false;  -- nobody leaves",
  "-- nobody leaves")

m("the company keeps its firm", F,
  "  update public.organizations set firm_id = null where id = p_org_id;",
  "  perform 1;  -- firm kept",
  "-- firm kept")

m("it says nobody went", F,
  "  return v_n;",
  "  return 0;  -- nobody",
  "-- nobody")

m("CONTROL: a comment inside the block", F,
  "  return v_n;",
  "  return v_n;  -- (control)",
  "(control)")
