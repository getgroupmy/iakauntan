-- =====================================================================
-- iAkauntan :: a tenant's own gateway credentials
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tenant_gateway_credentials.sql
--
-- `payment_gateways` is the platform's acquirer catalogue — keyed on
-- `code` alone, no `org_id`, settling `platform_invoices`. A tenant
-- collecting from its own customer needs credentials of its own, and an
-- acquirer API key can take money, so `0412` gave the table the shape
-- `0107` gave the LHDN credentials: RLS on with no policies, every
-- client grant revoked, writes through a SECURITY DEFINER function, and
-- a status function that never hands a secret back.
--
-- ---------------------------------------------------------------------
-- Everything about the client's reach runs under `set local role`
--
-- `pg_temp.sign_in_as` sets `request.jwt.claims` and does not change
-- the session role, so a test that only signs in runs as the table
-- owner — exempt from RLS and needing no grants. A file that asks "can
-- a client read the key" without the role change answers a question
-- about the owner and reports it as an answer about the client.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_gw_ctx (org uuid, other uuid, admin_user uuid, clerk uuid);
grant select on t_gw_ctx to authenticated;

do $$
declare
  v_org   uuid;
  v_other uuid;
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid;
  v_admin2 uuid;
  r       record;
  v_n     int;
begin
  v_org := pg_temp.test_org('Kedai Bayar Sdn Bhd');

  -- ------------------------------------------------------------------
  -- Setting them
  -- ------------------------------------------------------------------
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', 'sk_sandbox_abc', 'col_123', 'xsig_1', true);

  select * into r from public.org_payment_gateways
   where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox';
  perform pg_temp.check_eq('the key is stored', r.api_key, 'sk_sandbox_abc');
  perform pg_temp.check_eq('and the collection it points at',
    r.collection_ref, 'col_123');
  perform pg_temp.check_eq('and what a callback is verified against',
    r.signature_key, 'xsig_1');
  perform pg_temp.check_true('and it is switched on', r.is_active);

  -- ------------------------------------------------------------------
  -- Sandbox and production, both at once
  -- ------------------------------------------------------------------
  -- `0107`'s first lesson. With the mode as a column on a row an
  -- organization only has one of, going live destroys the sandbox
  -- credentials and "prove it, then go live" becomes a one-way door.
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'production', 'sk_live_xyz', 'col_999', 'xsig_2', false);

  perform pg_temp.check_eq('both modes are held at once',
    (select count(*) from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz'), 2);
  perform pg_temp.check_eq('and going live leaves the sandbox key alone',
    (select api_key from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'),
    'sk_sandbox_abc');

  -- ------------------------------------------------------------------
  -- A null secret leaves the stored one alone
  -- ------------------------------------------------------------------
  -- `0107`'s second lesson, and the one its test caught on the first
  -- run: the merge has to happen before the insert, because `api_key`
  -- is NOT NULL and the proposed row is validated before the conflict
  -- is looked for. Correcting a typo in a collection id must not blank
  -- the key.
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', null, 'col_456', null, true);

  select * into r from public.org_payment_gateways
   where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox';
  perform pg_temp.check_eq('correcting the collection keeps the key',
    r.api_key, 'sk_sandbox_abc');
  perform pg_temp.check_eq('and the collection is the new one',
    r.collection_ref, 'col_456');
  perform pg_temp.check_eq('and the signature key survives too',
    r.signature_key, 'xsig_1');

  begin
    perform public.set_org_payment_gateway(v_org, 'toyyibpay', 'sandbox', null);
    raise exception
      'FAIL: an acquirer was set up for the first time with no key';
  exception when sqlstate '23514' then
    raise notice 'ok   but the first time, a key is required';
  end;

  begin
    perform public.set_org_payment_gateway(
      v_org, 'not_an_acquirer', 'sandbox', 'sk_1');
    raise exception 'FAIL: an acquirer nobody has heard of was accepted';
  exception when sqlstate '23503' then
    raise notice 'ok   and the acquirer has to be one the platform knows';
  end;

  begin
    perform public.set_org_payment_gateway(v_org, 'billplz', 'live', 'sk_1');
    raise exception 'FAIL: a third mode was accepted';
  exception when sqlstate '23514' then
    raise notice 'ok   and the mode is sandbox or production';
  end;

  -- ------------------------------------------------------------------
  -- What a screen may see
  -- ------------------------------------------------------------------
  select count(*) into v_n from public.org_payment_gateway_status(v_org);
  perform pg_temp.check_eq('the status function lists both modes', v_n, 2);

  select * into r from public.org_payment_gateway_status(v_org)
   where mode = 'sandbox';
  perform pg_temp.check_true('and says a key is set', r.has_api_key);
  perform pg_temp.check_true('and that a callback can be verified',
    r.has_signature_key);
  perform pg_temp.check_eq('and shows which pot the money lands in',
    r.collection_ref, 'col_456');

  -- The assertion the function exists for. A function that hands a
  -- secret to a client role is the same exposure as a policy that does,
  -- through a different door — so the shape of the answer is asserted
  -- and not only its contents.
  perform pg_temp.check_eq(
    'and returns no column that could carry a secret',
    (select count(*) from information_schema.columns
      where table_name = 'org_payment_gateway_status'), 0);
  -- And the behavioural version, which is the one that matters: a
  -- mutant returning the key under an innocent column name would pass
  -- both of the shape checks above and fail this. Asserted on the whole
  -- row rather than on a named column for exactly that reason.
  perform pg_temp.check_true(
    'and no column of what it returns carries the key',
    not (row_to_json(r)::text like '%sk_sandbox_abc%'));
  perform pg_temp.check_true('nor the signature key',
    not (row_to_json(r)::text like '%xsig_1%'));

  perform pg_temp.check_eq(
    'nor names one in its signature',
    (select count(*) from pg_proc p
      cross join lateral unnest(coalesce(p.proargnames, '{}')) as a(name)
      where p.oid = 'public.org_payment_gateway_status(uuid)'::regprocedure
        and a.name in ('api_key', 'signature_key')), 0);

  -- ------------------------------------------------------------------
  -- Who may
  -- ------------------------------------------------------------------
  v_clerk := pg_temp.another_user('clerk@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accountant', 'active');

  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.set_org_payment_gateway(
      v_org, 'billplz', 'sandbox', 'sk_the_accountants');
    raise exception 'FAIL: an accountant set the company''s acquirer key';
  exception when sqlstate '42501' then
    raise notice 'ok   an accountant may post a journal and not take money';
  end;

  begin
    perform public.org_payment_gateway_status(v_org);
    raise exception 'FAIL: an accountant read the company''s payment set-up';
  exception when sqlstate '42501' then
    raise notice 'ok   nor see how it is set up';
  end;

  -- ------------------------------------------------------------------
  -- Another company's administrator
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  v_other := pg_temp.test_org('Syarikat Seberang Sdn Bhd');
  v_admin2 := pg_temp.another_user('admin2@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_other, v_admin2, 'owner', 'active');

  perform pg_temp.sign_in_as(v_admin2);
  begin
    perform public.set_org_payment_gateway(
      v_org, 'billplz', 'sandbox', 'sk_from_next_door');
    raise exception
      'FAIL: another company''s owner set this company''s acquirer key';
  exception when sqlstate '42501' then
    raise notice 'ok   and an administrator is an administrator of one company';
  end;

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('so the key is still the one that was set',
    (select api_key from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'),
    'sk_sandbox_abc');

  -- ------------------------------------------------------------------
  -- Clearing
  -- ------------------------------------------------------------------
  perform public.clear_org_payment_gateway(v_org, 'billplz', 'production');
  perform pg_temp.check_eq('going back to sandbox removes the live key',
    (select count(*) from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz'
        and mode = 'production'), 0);
  perform pg_temp.check_eq('and leaves the sandbox one',
    (select count(*) from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz'
        and mode = 'sandbox'), 1);

  insert into t_gw_ctx values (v_org, v_other, v_owner, v_clerk);
end $$;

-- ---------------------------------------------------------------------
-- And what a client role can reach, as a client role
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select admin_user from t_gw_ctx),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_ok boolean;
begin
  select * into c from t_gw_ctx;

  -- Without this the section below runs as the table's owner, which is
  -- exempt from RLS and needs no grants, and every refusal it claims
  -- would be a refusal that never happened.
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this person really is an administrator',
    app.can_admin(c.org));

  begin
    perform 1 from public.org_payment_gateways;
    raise exception
      'FAIL: a client role read the table acquirer keys are kept in';
  exception when sqlstate '42501' then
    raise notice 'ok   the table itself is out of a client role''s reach';
  end;

  begin
    insert into public.org_payment_gateways
      (org_id, gateway_code, mode, api_key)
    values (c.org, 'billplz', 'sandbox', 'sk_written_directly');
    raise exception 'FAIL: a client role wrote an acquirer key directly';
  exception when sqlstate '42501' then
    raise notice 'ok   and cannot be written to either';
  end;

  -- The positive control, and the half that has to survive: the whole
  -- point of the two barriers is that the front door still works.
  perform public.set_org_payment_gateway(
    c.org, 'toyyibpay', 'sandbox', 'sk_through_the_door', 'cat_1', 'sig_1', true);

  select has_api_key into v_ok
    from public.org_payment_gateway_status(c.org)
   where gateway_code = 'toyyibpay';
  perform pg_temp.check_true(
    'while an administrator still sets one up through the front door', v_ok);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The two barriers, asserted as barriers
-- ---------------------------------------------------------------------
do $$
declare v_privs text; v_policies int;
begin
  if not (select relrowsecurity from pg_class
           where oid = 'public.org_payment_gateways'::regclass) then
    raise exception 'FAIL: row-level security is off on the acquirer keys';
  end if;
  raise notice 'ok   row-level security is on';

  select count(*) into v_policies from pg_policy
   where polrelid = 'public.org_payment_gateways'::regclass;
  perform pg_temp.check_eq('with no policy admitting anyone', v_policies, 0);

  select string_agg(distinct privilege_type, ', ' order by privilege_type)
    into v_privs
    from information_schema.role_table_grants
   where grantee in ('anon', 'authenticated')
     and table_schema = 'public' and table_name = 'org_payment_gateways';
  if v_privs is not null then
    raise exception
      'FAIL: a client role holds % on the acquirer keys. RLS makes it '
      'inert, and one layer is not what this table was given.', v_privs;
  end if;
  raise notice 'ok   and no grant behind it, so both would have to fail';

  -- The comparison that says this is the established shape rather than
  -- a new opinion: the LHDN credentials are held the same way.
  perform pg_temp.check_eq(
    'the same way the LHDN credentials are held',
    (select count(*) from pg_policy
      where polrelid = 'public.einvoice_credentials'::regclass), 0);
end $$;

rollback;
