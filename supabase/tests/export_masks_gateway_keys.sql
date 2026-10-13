-- =====================================================================
-- iAkauntan :: the key a confirmation is signed with (0854)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/export_masks_gateway_keys.sql
--
-- A company's payment gateway keys are write-only: no client role may
-- read `org_payment_gateways`. Before `0854` the company export, which
-- masks secrets by column name through `app.audit_redact`, wrote the
-- X-Signature key out in clear. Asked as the owner with the role
-- `authenticated`, as the export screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_xk (org uuid);
grant select on t_xk to authenticated;

do $$
declare v_org uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Eksport Kunci Sdn Bhd');
  insert into t_xk values (v_org);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_xk; v_row jsonb;
begin
  select * into d from t_xk;
  perform public.set_org_payment_gateway(d.org, 'billplz', 'sandbox',
    'API-KEY-1234', 'COLL-1', 'XSIG-SECRET-9876');

  perform pg_temp.check_refused('the premise: the owner may not read the keys',
    'select * from public.org_payment_gateways',
    'permission denied for table org_payment_gateways', '42501');

  -- What was measured.
  v_row := public.company_export_page(d.org, 'org_payment_gateways', null, 10) -> 'rows' -> 0;
  perform pg_temp.check_eq('the export does not carry the key confirmations are signed with',
    v_row ->> 'signature_key', '***');
  perform pg_temp.check_eq('nor the API key, as before',
    v_row ->> 'api_key', '***');
  perform pg_temp.check_eq('while what is not a secret is still exported',
    (v_row ->> 'collection_ref') || ' / ' || (v_row ->> 'mode') || ' / ' || (v_row ->> 'gateway_code'),
    'COLL-1 / sandbox / billplz');
end $$;

reset role;

-- The words, one at a time, and the two that must stay readable: a
-- document's own signature is what was filed, and the secretary is a
-- person (`0289`).
do $$
declare v jsonb;
begin
  v := app.audit_redact(jsonb_build_object(
         'signature_key', 'a', 'x_signature_key', 'b', 'signing_key', 'c',
         'hmac', 'd', 'webhook_key', 'e', 'signature_keys', 'f',
         'signature', 'g', 'responsible_secretary', 'h'));
  perform pg_temp.check_eq('a signature or signing key is masked, under any prefix',
    concat_ws(' ', v ->> 'signature_key', v ->> 'x_signature_key', v ->> 'signing_key',
                   v ->> 'signature_keys'),
    '*** *** *** ***');
  perform pg_temp.check_eq('and an HMAC or webhook key',
    concat_ws(' ', v ->> 'hmac', v ->> 'webhook_key'), '*** ***');
  perform pg_temp.check_eq('but a document''s signature and the secretary are not',
    concat_ws(' ', v ->> 'signature', v ->> 'responsible_secretary'), 'g h');
end $$;

rollback;
