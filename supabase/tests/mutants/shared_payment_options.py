# Mutants for public.shared_payment_options (0413) -- the ways a
# customer holding an invoice's share link may pay it: none for a link
# revoked or expired, none for a document deleted, void, rejected or
# owing nothing; otherwise this company's acquirers that are switched on
# and have somewhere to bank, each once, by code.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0413_the_customer_can_pay_the_invoice_they_were_sent.sql \
#       supabase/tests/shared_invoice_payment.sql \
#       supabase/tests/mutants/shared_payment_options.py
#
# RESULT: 9 mutants and a control, all 9 killed by
# `shared_invoice_payment.sql`, from 4: a link revoked or expired and a
# document deleted, void or rejected only after its rule-by-rule block,
# which asks each with the acquirer set up and able to bank and a
# control link offered it first.

F = "shared_payment_options"

m("a revoked link is offered a way to pay", F,
  "  if l.id is null or l.revoked_at is not null or l.expires_at < now() then\n    return;",
  "  if l.id is null or l.expires_at < now() then  -- revoked pays\n    return;",
  "-- revoked pays")
m("an expired link is offered a way to pay", F,
  "  if l.id is null or l.revoked_at is not null or l.expires_at < now() then\n    return;",
  "  if l.id is null or l.revoked_at is not null then  -- expired pays\n    return;",
  "-- expired pays")
m("a deleted document is offered a way to pay", F,
  "  if d.id is null or d.deleted_at is not null\n     or d.status in ('void', 'rejected')\n     or coalesce(d.balance_amount, 0) <= 0 then\n    return;",
  "  if d.id is null  -- deleted pays\n     or d.status in ('void', 'rejected')\n     or coalesce(d.balance_amount, 0) <= 0 then\n    return;",
  "-- deleted pays")
m("a void document is offered a way to pay", F,
  "     or d.status in ('void', 'rejected')\n     or coalesce(d.balance_amount, 0) <= 0 then\n    return;",
  "     or d.status in ('rejected')  -- void pays\n     or coalesce(d.balance_amount, 0) <= 0 then\n    return;",
  "-- void pays")
m("a rejected document is offered a way to pay", F,
  "     or d.status in ('void', 'rejected')\n     or coalesce(d.balance_amount, 0) <= 0 then\n    return;",
  "     or d.status in ('void')  -- rejected pays\n     or coalesce(d.balance_amount, 0) <= 0 then\n    return;",
  "-- rejected pays")
m("an invoice owing nothing is offered a way to pay", F,
  "     or coalesce(d.balance_amount, 0) <= 0 then\n    return;\n  end if;\n\n  return query",
  "     or coalesce(d.balance_amount, 0) < 0 then  -- nothing owed pays\n    return;\n  end if;\n\n  return query",
  "-- nothing owed pays")
m("another company's acquirers are offered", F,
  "     where c.org_id = l.org_id\n       and c.is_active",
  "     where true  -- any company\n       and c.is_active",
  "-- any company")
m("an acquirer switched off is offered", F,
  "       and c.is_active\n       and c.settlement_bank_account_id is not null",
  "       and true  -- switched off\n       and c.settlement_bank_account_id is not null",
  "-- switched off")
m("an acquirer with nowhere to bank is offered", F,
  "       and c.settlement_bank_account_id is not null\n     order by c.gateway_code;",
  "       and true  -- nowhere to bank\n     order by c.gateway_code;",
  "-- nowhere to bank")

m("CONTROL", F,
  "  d public.sales_documents;\nbegin\n  select * into l from public.document_share_links\n   where token_hash = app.corp_token_hash(p_token);\n  if l.id is null or l.revoked_at is not null or l.expires_at < now() then\n    return;",
  "  d public.sales_documents;  -- control\nbegin\n  select * into l from public.document_share_links\n   where token_hash = app.corp_token_hash(p_token);\n  if l.id is null or l.revoked_at is not null or l.expires_at < now() then\n    return;",
  "-- control")
