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

  -- And that it still says it does not write. `0599` marked it STABLE,
  -- which it had always been in fact and never in the catalog --
  -- plpgsql defaults to VOLATILE, so for its whole life this read sat
  -- in `check_undocumented_writes.py`'s list of writes.
  --
  -- The declaration is worth an assertion because a later
  -- `create or replace` that forgets the word silently puts it back,
  -- and because the published description in `docs/api/` now counts it
  -- among the functions that only read. Nothing else would notice: a
  -- read declared VOLATILE works perfectly.
  perform pg_temp.check_eq('and is still declared a read, not a write',
    (select p.provolatile::text from pg_proc p
      where p.oid = 'public.org_payment_gateway_status(uuid)'::regprocedure),
    's');

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

-- ---------------------------------------------------------------------
-- One acquirer, one mode at a time  (`0773`)
--
-- Both modes are HELD at once, as above; before `0773` both could also
-- be SWITCHED ON at once, and then the pay link picked between them by
-- row order. A sandbox bill could settle a real invoice, or a live
-- payment fail its signature check and never settle. Switching a mode
-- on now switches the same acquirer's other mode off -- and nothing
-- else: not another acquirer, not another company, and switching a
-- mode OFF leaves the other where it was.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_them  uuid;
  v_owner uuid := pg_temp.test_user();
  v_admin uuid := pg_temp.another_user('pentadbir@satumod.test');
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Satu Mod Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_them := pg_temp.test_org('Syarikat Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', 'sk_test', 'col_t', 'xsig_t', true);
  perform public.set_org_payment_gateway(
    v_org, 'toyyibpay', 'sandbox', 'tp_test', 'cat_t', 'tsig_t', true);
  perform public.set_org_payment_gateway(
    v_them, 'billplz', 'sandbox', 'sk_theirs', 'col_x', 'xsig_x', true);

  -- Saved with the live switch OFF: the sandbox stays on.
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'production', 'sk_live', 'col_l', 'xsig_l', false);
  perform pg_temp.check_true('storing live keys switched off leaves the sandbox on',
    (select is_active from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'));

  -- Going live, by somebody else, so who switched the sandbox off is
  -- a person and not merely whoever set it up.
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_admin, 'admin', 'active', now());
  perform pg_temp.sign_in_as(v_admin);
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'production', null, null, null, true);
  perform pg_temp.sign_in_as(v_owner);

  perform pg_temp.check_true('going live switches the live keys on',
    (select is_active from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'production'));
  perform pg_temp.check_true('and the sandbox off',
    not (select is_active from public.org_payment_gateways
          where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'));
  perform pg_temp.check_true('saying who did it',
    (select updated_by from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox') = v_admin);
  perform pg_temp.check_eq('keeping its keys, so going back is a switch and not a re-keying',
    (select api_key from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'), 'sk_test');
  perform pg_temp.check_true('another acquirer''s sandbox is left on',
    (select is_active from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'toyyibpay' and mode = 'sandbox'));
  perform pg_temp.check_true('and so is another company''s',
    (select is_active from public.org_payment_gateways
      where org_id = v_them and gateway_code = 'billplz' and mode = 'sandbox'));

  -- Off is off, and nothing else.
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'production', null, null, null, false);
  perform pg_temp.check_eq('switching live off switches nothing on',
    (select count(*) from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and is_active), 0);

  -- And back to the sandbox, which takes the live keys off with it.
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'production', null, null, null, true);
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', null, null, null, true);
  perform pg_temp.check_eq('back in the sandbox, only the sandbox is on',
    (select string_agg(mode, ',') from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and is_active), 'sandbox');

  -- Saving keys without touching the switch leaves the switch where it
  -- was. A screen correcting a collection id is not a decision to stop
  -- taking payments.
  perform public.set_org_payment_gateway(v_org, 'billplz', 'sandbox', null, 'col_t2');
  perform pg_temp.check_true('saving keys alone leaves a mode switched on',
    (select is_active from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'));
  perform public.set_org_payment_gateway(v_org, 'billplz', 'sandbox', 'sk_test2');
  perform pg_temp.check_eq('and a new key alone keeps the collection it had',
    (select collection_ref from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'), 'col_t2');

  -- The two refusals above are caught by SQLSTATE alone, and the
  -- table's own check and foreign key raise the same two: with either
  -- guard gone, they passed. By the sentence, which is the guard's.
  perform pg_temp.check_refused('a third mode is refused by the function, in words',
    format('select public.set_org_payment_gateway(%L, %L, %L, %L)',
           v_org, 'billplz', 'live', 'sk_1'),
    'Mode must be sandbox or production, not live', '23514');
  perform pg_temp.check_refused('and an acquirer nobody knows, in words',
    format('select public.set_org_payment_gateway(%L, %L, %L, %L)',
           v_org, 'not_an_acquirer', 'sandbox', 'sk_1'),
    'not_an_acquirer is not an acquirer this platform knows about.', '23503');

  -- The same rule for anything that writes the table without the
  -- function: the index refuses the second switch outright.
  begin
    update public.org_payment_gateways set is_active = true
     where org_id = v_org and gateway_code = 'billplz' and mode = 'production';
    raise exception 'FAIL: one acquirer was switched on in two modes';
  exception when unique_violation then
    raise notice 'ok   and nothing can switch one acquirer on twice';
  end;
end $$;

rollback;
