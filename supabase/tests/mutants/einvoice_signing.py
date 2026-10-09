# Mutants for set_einvoice_version, set_einvoice_signing_certificate and
# clear_einvoice_signing_certificate (0615) -- signing a tax document:
# administrators only, all three; the version is 1.0 or 1.1 (trimmed),
# and 1.1 only with a certificate AND key on file for the environment
# the company submits to (sandbox when unset); the version kept in the
# company's settings; a certificate needs both halves, is stored
# trimmed, its optional details blank to null, against the named
# environment's credentials -- which must already exist; clearing
# removes all five fields, for the named environment only.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0615_the_signature_on_a_tax_document.sql \
#       supabase/tests/einvoice_signing_certificate.sql \
#       supabase/tests/mutants/einvoice_signing.py
#
# RESULT: 20 mutants and a control. 19 killed by
# `einvoice_signing_certificate.sql`, ten before its rule-by-rule block.
# Since `0777` restated `clear_einvoice_signing_certificate`, its three
# mutants live in `mutants/clear_einvoice_signing_certificate.py`, run
# against `0777`; the 17 here are the two functions `0615` still owns.
#
# One is EQUIVALENT: "a company with no environment set is taken to
# submit to production". `organizations.einvoice_environment` is NOT
# NULL with default 'sandbox', so the coalesce never reaches its second
# argument.
#
# A certificate with no key IS reachable, and is why "a certificate
# without its key will do for 1.1" was worth killing:
# `set_einvoice_credentials` stores one (measured).
#
# Raised and answered (`0777`, refuse while on 1.1):
# `clear_einvoice_signing_certificate` did not
# ask whether the company is on version 1.1 for that environment, so it
# leaves exactly the state `set_einvoice_version` refuses to create -- a
# 1.1 company with nothing to sign with, whose e-Invoice button then
# fails at LHDN instead of on the screen that caused it.

m("anybody changes the e-Invoice version",
  "set_einvoice_version",
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("any version is taken",
  "set_einvoice_version",
  "  if v_version not in ('1.0', '1.1') then",
  "  if false then  -- any version",
  "-- any version")

m("a padded version is refused",
  "set_einvoice_version",
  "  v_version text := btrim(coalesce(p_version, ''));",
  "  v_version text := coalesce(p_version, '');  -- untrimmed",
  "-- untrimmed")

m("1.1 is taken with nothing to sign with",
  "set_einvoice_version",
  "  if v_version = '1.1' and not exists (",
  "  if false and not exists (  -- unsigned 1.1",
  "-- unsigned 1.1")

m("a certificate without its key will do for 1.1",
  "set_einvoice_version",
  "         and c.cert_pem is not null\n         and c.cert_private_key_pem is not null) then",
  "         and c.cert_pem is not null) then  -- key not needed\n",
  "-- key not needed")

m("a certificate for the other environment will do for 1.1",
  "set_einvoice_version",
  "         and c.environment = coalesce(o.einvoice_environment, 'sandbox')",
  "         and true  -- any environment",
  "-- any environment")

m("a company with no environment set is taken to submit to production",
  "set_einvoice_version",
  "         and c.environment = coalesce(o.einvoice_environment, 'sandbox')",
  "         and c.environment = coalesce(o.einvoice_environment, 'production')  -- production by default",
  "-- production by default")

m("the version is not kept",
  "set_einvoice_version",
  "           to_jsonb(v_version),",
  "           to_jsonb('1.0'::text),  -- always 1.0",
  "-- always 1.0")

m("anybody sets the certificate",
  "set_einvoice_signing_certificate",
  "  if not app.can_admin(p_org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a certificate for a third environment is taken",
  "set_einvoice_signing_certificate",
  "  if p_environment not in ('sandbox', 'production') then",
  "  if false then  -- any environment",
  "-- any environment")

m("a certificate without its key is taken",
  "set_einvoice_signing_certificate",
  "  if coalesce(btrim(p_cert_pem), '') = ''\n     or coalesce(btrim(p_cert_private_key_pem), '') = '' then",
  "  if coalesce(btrim(p_cert_pem), '') = '' then  -- key optional\n",
  "-- key optional")

m("a key without its certificate is taken",
  "set_einvoice_signing_certificate",
  "  if coalesce(btrim(p_cert_pem), '') = ''\n     or coalesce(btrim(p_cert_private_key_pem), '') = '' then",
  "  if coalesce(btrim(p_cert_private_key_pem), '') = '' then  -- cert optional\n",
  "-- cert optional")

m("the certificate is stored untrimmed",
  "set_einvoice_signing_certificate",
  "    cert_pem             = btrim(p_cert_pem),",
  "    cert_pem             = p_cert_pem,  -- untrimmed",
  "-- untrimmed")

m("a blank serial number is stored as blank",
  "set_einvoice_signing_certificate",
  "    cert_serial_number   = nullif(btrim(coalesce(p_cert_serial_number, '')), ''),",
  "    cert_serial_number   = p_cert_serial_number,  -- blank kept",
  "-- blank kept")

m("the expiry is not kept",
  "set_einvoice_signing_certificate",
  "    cert_expires_at      = p_cert_expires_at,",
  "    cert_expires_at      = null,  -- no expiry",
  "-- no expiry")

m("a certificate is set on the other environment's credentials",
  "set_einvoice_signing_certificate",
  "   where org_id = p_org_id and environment = p_environment;\n\n  if not found then",
  "   where org_id = p_org_id;  -- every environment\n\n  if not found then",
  "-- every environment")

m("a certificate with no credentials to sit beside is lost without a word",
  "set_einvoice_signing_certificate",
  "  if not found then\n    raise exception 'Add the MyInvois client id and secret for % first",
  "  if false then  -- silently lost\n    raise exception 'Add the MyInvois client id and secret for % first",
  "-- silently lost")

m("CONTROL: a comment inside the block",
  "set_einvoice_version",
  "  if v_version not in ('1.0', '1.1') then",
  "  if v_version not in ('1.0', '1.1') then  -- (control)",
  "(control)")
