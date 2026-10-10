# Mutants for public.open_shared_document (0642, from 0094) -- what a
# customer holding an invoice's share link sees, with no login: the
# link's state; every opening recorded, the first kept; and for an open
# link, the document, its lines, who it is from and to, and the ways to
# pay it while it owes anything.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0642_the_other_number_a_hotel_has_to_print.sql \
#       supabase/tests/document_share.sql \
#       supabase/tests/mutants/open_shared_document.py
#
# RESULT: 17 mutants and a control. 16 killed by `document_share.sql`,
# from 5 -- and from 0 by the seven other files that call it, each
# swept against this list too. Eleven only after its rule-by-rule
# block: an expired link, a deleted or rejected document, the first
# opening's time, address and browser kept and the last's moved on, the
# company's TIN, the balance, and its own lines in order.
#
# EQUIVALENT: "a paid invoice is offered a way to pay". `pay_with`
# reads `shared_payment_options`, which returns nothing on a balance of
# nothing (killed in its own sweep), so the `balance > 0` here is the
# same rule a second time. The file asserts the rule.

F = "open_shared_document"

# The door.
m("a revoked link opens", F,
  "    when l.revoked_at is not null then 'revoked'",
  "    when false then 'revoked'  -- revoked opens",
  "-- revoked opens")
m("an expired link opens", F,
  "    when l.expires_at < now() then 'expired'",
  "    when false then 'expired'  -- expired opens",
  "-- expired opens")
m("a deleted document opens", F,
  "    when d.id is null or d.deleted_at is not null then 'withdrawn'",
  "    when d.id is null then 'withdrawn'  -- deleted opens",
  "-- deleted opens")
m("a void document opens", F,
  "    when d.status in ('void', 'rejected') then 'withdrawn'",
  "    when d.status in ('rejected') then 'withdrawn'  -- void opens",
  "-- void opens")
m("a rejected document opens", F,
  "    when d.status in ('void', 'rejected') then 'withdrawn'",
  "    when d.status in ('void') then 'withdrawn'  -- rejected opens",
  "-- rejected opens")
m("a closed link says only 'closed'", F,
  "    return jsonb_build_object('state', v_state);",
  "    return jsonb_build_object('state', 'closed');  -- unsaid",
  "-- unsaid")

# Every opening.
m("the first opening is overwritten", F,
  "     set opened_at = coalesce(opened_at, now()),",
  "     set opened_at = now(),  -- first overwritten",
  "-- first overwritten")
m("the last opening is not kept", F,
  "         last_opened_at = now(),",
  "         last_opened_at = last_opened_at,  -- last unkept",
  "-- last unkept")
m("openings are not counted", F,
  "         open_count = open_count + 1,",
  "         open_count = open_count,  -- uncounted",
  "-- uncounted")
m("the browser that first opened it is overwritten", F,
  "         user_agent = coalesce(user_agent, app.request_header('user-agent'))",
  "         user_agent = app.request_header('user-agent')  -- browser overwritten",
  "-- browser overwritten")
m("the address that first opened it is overwritten", F,
  "         ip_address = coalesce(ip_address, nullif(split_part(coalesce(",
  "         ip_address = coalesce(nullif(split_part(coalesce(  -- address overwritten",
  "-- address overwritten")

# What it shows.
m("a paid invoice is offered a way to pay", F,
  "    'pay_with', case when coalesce(d.balance_amount, 0) > 0",
  "    'pay_with', case when true  -- always payable",
  "-- always payable")
m("the company's tourism tax number is not shown", F,
  "      'tourism_tax_reg_no', o.tourism_tax_reg_no,",
  "      'tourism_tax_reg_no', null,  -- no tourism tax",
  "-- no tourism tax")
m("the company's TIN is not shown", F,
  "      'tin', o.tin,",
  "      'tin', null,  -- no tin",
  "-- no tin")
m("the balance is the total", F,
  "      'balance_amount', d.balance_amount,",
  "      'balance_amount', d.total_amount,  -- balance is total",
  "-- balance is total")
m("the lines are out of order", F,
  "             order by li.line_no)",
  "             order by li.line_no desc)  -- reversed",
  "-- reversed")
m("another document's lines are shown", F,
  "       where li.document_id = d.id), '[]'::jsonb));",
  "       where li.org_id = d.org_id), '[]'::jsonb));  -- any document",
  "-- any document")

m("CONTROL", F,
  "  v_pay jsonb;\nbegin",
  "  v_pay jsonb;  -- control\nbegin",
  "-- control")
