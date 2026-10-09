-- =====================================================================
-- iAkauntan :: the address on the record is the caller's
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/client_address.sql
--
-- `0785`. Fifteen functions record where a request came from by asking
-- `app.request_header('x-forwarded-for')` and casting the first hop to
-- an address. Before `0785` that hop was whatever the client sent --
-- Cloudflare appends the address it saw AFTER it -- and a hop that was
-- not an address, as 'unknown' from some corporate proxies, made the
-- write it was recorded on fail. Now the function answers with the
-- caller's address: `cf-connecting-ip`, which the edge sets, else the
-- first hop that is an address, else nothing; never an error.
--
-- `request.headers` is what PostgREST sets for a request, so setting it
-- here is setting what a request would carry.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.with_headers(p_headers text)
returns void language sql as $$
  select set_config('request.headers', p_headers, true);
$$;

-- ---------------------------------------------------------------------
-- What the function answers
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.with_headers(
    '{"x-forwarded-for": "6.6.6.6, 203.0.113.9", "cf-connecting-ip": "203.0.113.9"}');
  perform pg_temp.check_eq('the address the edge saw, not the one the client wrote first',
    app.request_header('x-forwarded-for'), '203.0.113.9');

  perform pg_temp.with_headers('{"x-forwarded-for": "unknown, 203.0.113.9"}');
  perform pg_temp.check_eq('without it, the first hop that is an address',
    app.request_header('x-forwarded-for'), '203.0.113.9');

  perform pg_temp.with_headers(
    '{"x-forwarded-for": "198.51.100.4", "cf-connecting-ip": "not an address"}');
  perform pg_temp.check_eq('and an edge value that is not one is passed over too',
    app.request_header('x-forwarded-for'), '198.51.100.4');

  perform pg_temp.with_headers('{"cf-connecting-ip": " 2001:db8::7 "}');
  perform pg_temp.check_eq('an IPv6 address, trimmed and bare',
    app.request_header('x-forwarded-for'), '2001:db8::7');

  perform pg_temp.with_headers('{"x-forwarded-for": "unknown, proxy.local"}');
  perform pg_temp.check_true('nothing that is an address is no address',
    app.request_header('x-forwarded-for') is null);

  perform pg_temp.with_headers('{"user-agent": "Ujian/1.0", "x-forwarded-for": "unknown"}');
  perform pg_temp.check_eq('every other header is answered as it was',
    app.request_header('user-agent'), 'Ujian/1.0');
  perform pg_temp.check_true('and an absent one is null',
    app.request_header('accept-language') is null);
  perform pg_temp.with_headers('{"user-agent": ""}');
  perform pg_temp.check_true('and an empty one is null too, as it always was',
    app.request_header('user-agent') is null);

  perform pg_temp.with_headers('not json');
  perform pg_temp.check_true('a setting that is not JSON answers null, not an error',
    app.request_header('x-forwarded-for') is null);

  perform pg_temp.with_headers('{}');
end $$;

-- ---------------------------------------------------------------------
-- What it is recorded on
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Alamat Pemanggil Sdn Bhd');
  v_c   uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- The write that used to fail.
  perform pg_temp.with_headers('{"x-forwarded-for": "unknown, 203.0.113.9"}');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Di Belakang Proksi', 'customer') returning id into v_c;
  perform pg_temp.check_eq('a proxy that says "unknown" no longer stops a save, and the trail has the address',
    (select host(ip_address) from public.audit_logs
      where record_id = v_c and action = 'insert'), '203.0.113.9');

  perform pg_temp.with_headers(
    '{"x-forwarded-for": "6.6.6.6, 203.0.113.10", "cf-connecting-ip": "203.0.113.10"}');
  update public.contacts set name = 'Di Belakang Proksi Bhd' where id = v_c;
  perform pg_temp.check_eq('and the address on the trail is the edge''s, not the client''s',
    (select host(ip_address) from public.audit_logs
      where record_id = v_c and action = 'update'), '203.0.113.10');

  perform pg_temp.with_headers('{}');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may call it
--
-- `0165`'s event trigger strips PUBLIC from every function a migration
-- creates, `0785`'s replacement included, so only the owner may call
-- it. That is fine only while everything that does is a definer owned
-- by the same role. Asked of the catalogue, so a new caller that runs
-- as the client fails here rather than in production.
-- ---------------------------------------------------------------------
do $$
declare v_who text;
begin
  select string_agg(n.nspname || '.' || p.proname, ', ') into v_who
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.prosrc ~ 'request_header\('
     and p.oid <> 'app.request_header(text)'::regprocedure
     and n.nspname not in ('pg_catalog', 'information_schema')
     and (not p.prosecdef
          or p.proowner <> (select proowner from pg_proc
                             where oid = 'app.request_header(text)'::regprocedure));
  perform pg_temp.check_true('every caller runs as the function''s owner'
    || coalesce(' (not: ' || v_who || ')', ''), v_who is null);
  perform pg_temp.check_true('no policy reads a header',
    not exists (select 1 from pg_policies
                 where coalesce(qual, '') || coalesce(with_check, '') ~ 'request_header'));
  perform pg_temp.check_true('and it has fifteen callers or more, so the walk is looking',
    (select count(*) from pg_proc p where p.prosrc ~ 'request_header\(''x-forwarded-for''\)') >= 15);
end $$;

rollback;
