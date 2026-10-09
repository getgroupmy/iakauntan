# Mutants for public.clear_einvoice_credentials (0107) -- a company's
# MyInvois login for one environment removed: administrators only; THIS
# company's, THIS environment's.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0107_einvoice_credentials_per_org.sql \
#       supabase/tests/einvoice_credentials.sql \
#       supabase/tests/mutants/clear_einvoice_credentials.py
#
# RESULT: 3 mutants and a control, all killed by
# `einvoice_credentials.sql`; none before its block. Its one clear was
# of a company holding only the environment cleared, by its owner, so
# "just that environment" was asserted where there was nothing else to
# take.

m("anybody removes the login",
  "clear_einvoice_credentials",
  "  if not app.can_admin(p_org_id) then\n    raise exception 'Only an administrator can remove e-Invoice credentials'",
  "  if false then  -- whoever asks\n    raise exception 'Only an administrator can remove e-Invoice credentials'",
  "-- whoever asks")

m("both environments go",
  "clear_einvoice_credentials",
  "   where org_id = p_org_id and environment = p_environment;",
  "   where org_id = p_org_id;  -- both environments",
  "-- both environments")

m("every company's login goes",
  "clear_einvoice_credentials",
  "   where org_id = p_org_id and environment = p_environment;",
  "   where environment = p_environment;  -- every company",
  "-- every company")

m("CONTROL: a comment inside the block",
  "clear_einvoice_credentials",
  "   where org_id = p_org_id and environment = p_environment;",
  "   where org_id = p_org_id and environment = p_environment;  -- (control)",
  "(control)")
