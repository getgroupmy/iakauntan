# Mutants for 0854 -- app.audit_redact masks a gateway's signature key
# and its kin as it masks an API key.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0854_the_key_a_confirmation_is_signed_with.sql \
#       supabase/tests/export_masks_gateway_keys.sql \
#       supabase/tests/mutants/the_key_a_confirmation_is_signed_with.py
#
# RESULT: 7 of 7 killed, the control surviving.

m('a signature key is not a secret',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signing_key|signing_keys|hmac|webhook_key|webhook_keys'  -- no signature_key",
  '-- no signature_key')

m('only the singular signature key is',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signature_key|signing_key|signing_keys|hmac|webhook_key|webhook_keys'  -- singular only",
  '-- singular only')

m('a signing key is not a secret',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signature_key|signature_keys|hmac|webhook_key|webhook_keys'  -- no signing_key",
  '-- no signing_key')

m('an HMAC is not a secret',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|webhook_key|webhook_keys'  -- no hmac",
  '-- no hmac')

m('a webhook key is not a secret',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac'  -- no webhook_key",
  '-- no webhook_key')

m("a document's signature is a secret too",
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signature|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'  -- bare signature",
  '-- bare signature')

m('none of the new words',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || ''  -- none new",
  '-- none new')

m('CONTROL: a comment inside audit_redact',
  'audit_redact',
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'",
  "                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'  -- (control)",
  '(control)')
