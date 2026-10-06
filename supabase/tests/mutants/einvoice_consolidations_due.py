# Mutants for public.einvoice_consolidations_due (0616) -- every
# consolidation coming due within LHDN's seven days, or already late,
# with whether the company can submit it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0616_the_consolidation_nobody_could_file.sql \
#       supabase/tests/pos_einvoice_consolidation.sql \
#       supabase/tests/mutants/einvoice_consolidations_due.py
#
# RESULT: (pending)

m("a submitted consolidation is still due",
  "einvoice_consolidations_due",
  "   where c.status in ('draft', 'generated')",
  "   where true  -- any status",
  "-- any status")

m("an empty consolidation is due",
  "einvoice_consolidations_due",
  "     and c.document_count > 0",
  "     and true  -- empty",
  "-- empty")

m("a company not on e-Invoice is chased",
  "einvoice_consolidations_due",
  "     and o.einvoice_enabled",
  "     and true  -- not enabled",
  "-- not enabled")

m("a late one drops off the list",
  "einvoice_consolidations_due",
  "     and c.due_date <= app.today() + p_within_days",
  "     and c.due_date between app.today() and app.today() + p_within_days  -- future only",
  "-- future only")

m("the window is ignored",
  "einvoice_consolidations_due",
  "     and c.due_date <= app.today() + p_within_days",
  "     and true  -- any distance",
  "-- any distance")

m("days left counts from the period end",
  "einvoice_consolidations_due",
  "         (c.due_date - app.today())::integer,",
  "         (c.period_end - app.today())::integer,  -- from the end",
  "-- from the end")

m("the credentials are the other environment's",
  "einvoice_consolidations_due",
  "     and cr.environment = coalesce(o.einvoice_environment, 'sandbox')",
  "     and cr.environment <> coalesce(o.einvoice_environment, 'sandbox')  -- other",
  "-- other")

m("half the credentials is enough",
  "einvoice_consolidations_due",
  "         cr.client_id is not null and cr.client_secret is not null,",
  "         cr.client_id is not null,  -- id only",
  "-- id only")

m("a certificate with no key is enough",
  "einvoice_consolidations_due",
  "         cr.cert_pem is not null and cr.cert_private_key_pem is not null",
  "         cr.cert_pem is not null  -- no key",
  "-- no key")

m("CONTROL: a comment inside the block",
  "einvoice_consolidations_due",
  "     -- Overdue ones are included however late, because a deadline that",
  "     -- CONTROL\n     -- Overdue ones are included however late, because a deadline that",
  "-- CONTROL")
