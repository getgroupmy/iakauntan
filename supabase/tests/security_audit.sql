-- =====================================================================
-- iAkauntan :: who got in, what they took, and what they changed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_audit.sql
--
-- The three things asserted here are the three that are easy to build
-- wrong in a way that looks right:
--
-- **A log that is not written.** The first version of the denial
-- recorder wrote the row and then raised the refusal, and the raise
-- unwound the transaction the row was in. It refused correctly, it
-- logged nothing, and only a count proved it. So every assertion below
-- counts rows after the fact rather than trusting that a function which
-- returned without error did something.
--
-- **A log that is written but nobody may read.** `access_type_modules`
-- carries neither `org_id` nor `id`, so the generic audit path would
-- file every permission change under no organization -- readable by
-- nobody, which is the same as not recording it.
--
-- **A log that records the secret.** `einvoice_credentials` holds a
-- client secret and a private key, and the trail is readable by every
-- admin. Asserted the only way worth asserting: put a known string in,
-- then search the whole trail for it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Signing in is recorded, per company, without the app being asked
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_owner uuid;
  v_sess  uuid := gen_random_uuid();
begin
  v_org := pg_temp.test_org('Kilang Selamat Sdn Bhd');

  -- A colleague rather than `test_user()`, and that is not cosmetic.
  -- Eight files in this suite -- the POS family and
  -- `inventory_forecast.sql` -- carry no `begin`/`rollback` at all, so
  -- their fixtures commit and `fixture@iakauntan.test` reaches this file
  -- already owning nine companies. A sign-in writes one row per company,
  -- so anything counted over that account counts nine other files'
  -- leftovers: the assertion that found this reported `expected 1, got
  -- 10`. `another_user` is fresh on every call, which makes the
  -- membership set exactly what this block puts in it.
  v_owner := pg_temp.another_user('signin-probe@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_owner, 'viewer', 'active');

  perform pg_temp.check_eq('this person keeps one set of books',
    (select count(*)::int from public.org_members where user_id = v_owner), 1);

  -- Exactly what GoTrue does on a successful password sign-in. Nothing
  -- in the application is involved, which is the point.
  insert into auth.sessions (id, user_id, created_at, updated_at, ip, user_agent)
  values (v_sess, v_owner, now(), now(), '203.0.113.7'::inet, 'Probe/1.0');

  perform pg_temp.check_eq('a sign-in is recorded for the company',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'sign_in' and session_id = v_sess), 1);

  -- Every one of these is scoped by organization as well as session,
  -- because (session, org) is the grain and session alone is not: one
  -- sign-in writes one row per company the person belongs to. The block
  -- below proves that rather than leaving it as a claim.
  perform pg_temp.check_eq('with the address it came from',
    (select host(ip_address) from public.security_events
      where org_id = v_org and session_id = v_sess and kind = 'sign_in'),
    '203.0.113.7');

  perform pg_temp.check_eq('and what it came from',
    (select user_agent from public.security_events
      where org_id = v_org and session_id = v_sess and kind = 'sign_in'),
    'Probe/1.0');

  -- The email is stored beside the id so the row still names somebody
  -- after the account is gone.
  perform pg_temp.check_eq('and who',
    (select email from public.security_events
      where org_id = v_org and session_id = v_sess and kind = 'sign_in'),
    'signin-probe@iakauntan.test');

  delete from auth.sessions where id = v_sess;

  perform pg_temp.check_eq('and the session ending is recorded too',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'session_ended' and session_id = v_sess), 1);
end;
$$;

-- ---------------------------------------------------------------------
-- One sign-in, every company the person keeps books for
-- ---------------------------------------------------------------------
--
-- A bookkeeper who keeps four sets of books signing in at midnight from
-- an unfamiliar address is a fact all four auditors are entitled to, and
-- an event filed under one of them is an event the other three cannot
-- see. So the fan-out is the design, and it is the reason `session_id`
-- is not a key on its own -- which the first version of the block above
-- assumed, and CI caught.
do $$
declare
  v_one   uuid;
  v_two   uuid;
  v_owner uuid;
  v_sess  uuid := gen_random_uuid();
begin
  v_one := pg_temp.test_org('Dua Buku Satu Sdn Bhd');
  v_two := pg_temp.test_org('Dua Buku Dua Sdn Bhd');

  -- Fresh again, for the reason given above.
  v_owner := pg_temp.another_user('two-books@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_one, v_owner, 'viewer', 'active'),
         (v_two, v_owner, 'viewer', 'active');

  perform pg_temp.check_eq('the same person keeps two sets of books',
    (select count(*)::int from public.org_members where user_id = v_owner), 2);

  insert into auth.sessions (id, user_id, created_at, updated_at, ip, user_agent)
  values (v_sess, v_owner, now(), now(), '198.51.100.4'::inet, 'Two/1.0');

  perform pg_temp.check_eq('and one sign-in reaches both auditors',
    (select count(*)::int from public.security_events
      where session_id = v_sess and kind = 'sign_in'), 2);
  perform pg_temp.check_eq('one row each, not two under one company',
    (select count(distinct org_id)::int from public.security_events
      where session_id = v_sess and kind = 'sign_in'), 2);

  delete from auth.sessions where id = v_sess;
  perform pg_temp.check_eq('and the session ending reaches both as well',
    (select count(*)::int from public.security_events
      where session_id = v_sess and kind = 'session_ended'), 2);
end;
$$;

-- ---------------------------------------------------------------------
-- A sign-in that was refused, and the limits on believing it
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_them uuid;
begin
  v_org  := pg_temp.test_org('Kilang Selamat Dua Sdn Bhd');
  v_them := pg_temp.another_user('locked-out@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_them, 'viewer', 'active');

  perform public.report_failed_sign_in('locked-out@iakauntan.test');
  perform pg_temp.check_eq('a rejected password is recorded',
    (select count(*)::int from public.security_events
      where user_id = v_them and kind = 'sign_in' and outcome = 'refused'), 1);

  -- Within the minute, so it must not write a second. Counted over the
  -- person rather than the company, because the rate limit is per
  -- account -- counting per company would pass even if the limit had
  -- stopped working for somebody who keeps more than one set of books.
  perform public.report_failed_sign_in('locked-out@iakauntan.test');
  perform pg_temp.check_eq('and a second within the minute is dropped',
    (select count(*)::int from public.security_events
      where user_id = v_them and kind = 'sign_in' and outcome = 'refused'), 1);

  -- An address nobody has. Nothing is written and nothing is returned,
  -- so the function cannot be used to find out which addresses exist.
  perform public.report_failed_sign_in('nobody@nowhere.invalid');
  perform pg_temp.check_eq('and nothing at all for an address that is not a user',
    (select count(*)::int from public.security_events
      where email = 'nobody@nowhere.invalid'), 0);
end;
$$;

-- ---------------------------------------------------------------------
-- A copy leaving the building, and a refusal being reported
-- ---------------------------------------------------------------------
do $$
declare
  v_org      uuid;
  v_other    uuid;
  v_stranger uuid;
  v_failed   boolean;
begin
  v_org := pg_temp.test_org('Kilang Selamat Tiga Sdn Bhd');

  perform public.record_export(v_org, 'Trial balance', 'PDF, Jan to Aug 2026');
  perform pg_temp.check_eq('an export is recorded',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'export'), 1);
  perform pg_temp.check_eq('with what was taken',
    (select target from public.security_events
      where org_id = v_org and kind = 'export'), 'Trial balance');

  perform public.report_denied(v_org, 'post_payroll_run', 'Only an admin may post payroll');
  perform pg_temp.check_eq('a refusal reported by the app is recorded',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'denied'), 1);
  perform pg_temp.check_true('and says that is where it came from',
    (select detail like '%reported by the app%' from public.security_events
      where org_id = v_org and kind = 'denied'));

  -- One a minute, so a loop cannot push the rest of the log off the end.
  perform public.report_denied(v_org, 'post_payroll_run', 'again');
  perform pg_temp.check_eq('and a second within the minute is dropped',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'denied'), 1);

  -- Somebody else's company. Neither call may write anything: taking the
  -- caller's word for the org_id would let anybody write into anybody's
  -- log.
  v_other    := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  v_stranger := pg_temp.another_user('stranger-audit@iakauntan.test');
  perform pg_temp.sign_in_as(v_stranger);

  v_failed := false;
  begin
    perform public.record_export(v_org, 'Everything');
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('an outsider cannot record an export', v_failed);

  perform public.report_denied(v_org, 'anything', 'from outside');
  perform pg_temp.check_eq('and cannot write a refusal into it either',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'denied'), 1);
end;
$$;

-- ---------------------------------------------------------------------
-- Reading the log is an event, and not everybody may
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_owner  uuid;
  v_clerk  uuid;
  v_failed boolean;
begin
  v_org   := pg_temp.test_org('Kilang Selamat Empat Sdn Bhd');
  v_owner := pg_temp.test_user();

  perform public.record_export(v_org, 'Ledger');
  perform pg_temp.check_true('the log has something in it to read',
    (select count(*) from public.security_log(v_org)) > 0);

  perform pg_temp.check_eq('and reading it is itself recorded',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'sensitive_read'
        and target = 'security_log'), 1);

  perform public.audit_trail(v_org);
  perform pg_temp.check_eq('so is reading the change log',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'sensitive_read'
        and target = 'audit_trail'), 1);

  perform pg_temp.check_true('the summary counts what the log holds',
    (public.security_summary(v_org, 30) ->> 'exports')::int >= 1);

  -- A member who is not an admin. The log says where every colleague
  -- works from, so membership is not the bar.
  v_clerk := pg_temp.another_user('clerk-audit@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active');
  perform pg_temp.sign_in_as(v_clerk);

  v_failed := false;
  begin
    perform public.security_log(v_org);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('a clerk cannot read the security log', v_failed);

  v_failed := false;
  begin
    perform public.audit_trail(v_org);
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('nor the change log', v_failed);

  -- And nothing was recorded as read for the attempts that failed.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('a refused read is not a read',
    (select count(*)::int from public.security_events
      where org_id = v_org and kind = 'sensitive_read'
        and target = 'security_log'), 1);
end;
$$;

-- ---------------------------------------------------------------------
-- The money, and the tables that were not being watched
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid;
  v_contact uuid;
  v_type    uuid;
begin
  v_org := pg_temp.test_org('Kilang Selamat Lima Sdn Bhd');

  -- A supplier's details changed. The oldest fraud there is, and until
  -- 0236 there was no record of it.
  insert into public.contacts (org_id, code, contact_type, name, phone)
  values (v_org, 'S-001', 'supplier', 'Pembekal Setia', '03-1111111')
  returning id into v_contact;
  update public.contacts set phone = '03-9999999' where id = v_contact;

  perform pg_temp.check_eq('a supplier change is recorded',
    (select count(*)::int from public.audit_logs
      where org_id = v_org and table_name = 'contacts' and action = 'update'), 1);
  perform pg_temp.check_eq('with the old number and the new one',
    (select (old_data ->> 'phone') || ' -> ' || (new_data ->> 'phone')
       from public.audit_logs
      where org_id = v_org and table_name = 'contacts' and action = 'update'),
    '03-1111111 -> 03-9999999');

  -- A permission change, which carries neither org_id nor id.
  insert into public.access_types (org_id, name)
  values (v_org, 'Probe type') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'read');

  perform pg_temp.check_eq('a permission change is filed under its company',
    (select count(*)::int from public.audit_logs
      where org_id = v_org and table_name = 'access_type_modules'), 1);
  perform pg_temp.check_eq('against the access type it changed',
    (select record_id from public.audit_logs
      where org_id = v_org and table_name = 'access_type_modules'), v_type);
end;
$$;

-- ---------------------------------------------------------------------
-- A secret never reaches the trail, by any of the three routes
-- ---------------------------------------------------------------------
do $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org('Kilang Selamat Enam Sdn Bhd');

  insert into public.einvoice_credentials
    (org_id, environment, client_id, client_secret, cert_private_key_pem)
  values (v_org, 'sandbox', 'cid-1', 'CANARY-SECRET-VALUE', 'CANARY-PRIVATE-KEY');
  update public.einvoice_credentials set client_secret = 'CANARY-SECRET-ROTATED'
   where org_id = v_org and environment = 'sandbox';
  delete from public.einvoice_credentials
   where org_id = v_org and environment = 'sandbox';

  -- The positive control first: without this, "the secret is nowhere"
  -- passes just as well against a trigger that never fired.
  perform pg_temp.check_eq('insert, update and delete are all recorded',
    (select count(*)::int from public.audit_logs
      where org_id = v_org and table_name = 'einvoice_credentials'), 3);

  perform pg_temp.check_eq('and the secret is in none of them',
    (select count(*)::int from public.audit_logs
      where org_id = v_org
        and (coalesce(old_data::text, '') || coalesce(new_data::text, ''))
            like '%CANARY%'), 0);

  perform pg_temp.check_eq('the client id, which is not a secret, is still legible',
    (select new_data ->> 'client_id' from public.audit_logs
      where org_id = v_org and table_name = 'einvoice_credentials'
        and action = 'insert'), 'cid-1');
  perform pg_temp.check_eq('and the secret reads as redacted, not as absent',
    (select new_data ->> 'client_secret' from public.audit_logs
      where org_id = v_org and table_name = 'einvoice_credentials'
        and action = 'insert'), '***');
end;
$$;

-- ---------------------------------------------------------------------
-- Seven years, and then gone
-- ---------------------------------------------------------------------
do $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org('Kilang Selamat Tujuh Sdn Bhd');

  insert into public.security_events (org_id, email, kind, created_at)
  values (v_org, 'old@example.test',    'export', now() - interval '8 years'),
         (v_org, 'recent@example.test', 'export', now() - interval '6 years 11 months');
  insert into public.audit_logs (org_id, table_name, action, created_at)
  values (v_org, 'accounts', 'update', now() - interval '8 years'),
         (v_org, 'accounts', 'update', now() - interval '6 years 11 months');

  perform app.purge_audit_history(7);

  perform pg_temp.check_eq('the eight-year-old event is gone',
    (select count(*)::int from public.security_events
      where email = 'old@example.test'), 0);
  perform pg_temp.check_eq('and the eight-year-old change with it',
    (select count(*)::int from public.audit_logs
      where org_id = v_org and created_at < now() - interval '7 years'), 0);

  -- The half that makes the other half mean something: a purge that
  -- deleted everything would satisfy both assertions above.
  perform pg_temp.check_eq('what is still inside seven years survives',
    (select count(*)::int from public.security_events
      where email = 'recent@example.test'), 1);
  perform pg_temp.check_eq('on both logs',
    (select count(*)::int from public.audit_logs
      where org_id = v_org and table_name = 'accounts'
        and created_at > now() - interval '7 years'), 1);
end;
$$;

rollback;
