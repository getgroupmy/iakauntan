# Mutants for public.clear_einvoice_signing_certificate (0777, restated
# from 0615) -- a signing certificate removed: administrators only;
# NOT the certificate a version 1.1 company signs with in the
# environment it submits to (0777); all five fields cleared, for the
# named environment only.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0777_the_certificate_a_signed_einvoice_needs_stays.sql \
#       supabase/tests/einvoice_signing_certificate.sql \
#       supabase/tests/mutants/clear_einvoice_signing_certificate.py
#
# RESULT: 6 mutants and a control, all killed by
# `einvoice_signing_certificate.sql`. The first three were in
# `mutants/einvoice_signing.py` against `0615` and were killed there.

m("anybody clears the certificate",
  "clear_einvoice_signing_certificate",
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a 1.1 company's certificate is taken from under it",
  "clear_einvoice_signing_certificate",
  "  if exists (\n       select 1 from public.organizations o",
  "  if false and exists (  -- 1.1 unguarded\n       select 1 from public.organizations o",
  "-- 1.1 unguarded")

m("a 1.0 company's certificate cannot be cleared",
  "clear_einvoice_signing_certificate",
  "          and coalesce(o.settings ->> 'einvoice_version', '1.0') = '1.1'",
  "          and true  -- any version",
  "-- any version")

m("the other environment's certificate cannot be cleared either",
  "clear_einvoice_signing_certificate",
  "          and o.einvoice_environment = p_environment) then",
  "          ) then  -- any environment",
  "-- any environment")

m("clearing leaves the private key behind",
  "clear_einvoice_signing_certificate",
  "    cert_private_key_pem = null,",
  "    cert_private_key_pem = cert_private_key_pem,  -- key left",
  "-- key left")

m("clearing one environment clears both",
  "clear_einvoice_signing_certificate",
  "   where org_id = p_org_id and environment = p_environment;",
  "   where org_id = p_org_id;  -- both environments",
  "-- both environments")

m("CONTROL: a comment inside the block",
  "clear_einvoice_signing_certificate",
  "  if not app.can_admin(p_org_id) then",
  "  if not app.can_admin(p_org_id) then  -- (control)",
  "(control)")
