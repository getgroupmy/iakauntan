-- =====================================================================
-- iAkauntan :: a signature is the database's (0791)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/signature_evidence.sql
--
-- `0069` writes the evidence of a signature itself -- the status, the
-- time, the hash of the text, the address, the browser, the login --
-- because "a signature record the signer can write is not evidence of
-- anything". The tables' own policies let any member who may write set
-- every one of those columns directly, and on 10 October that was
-- enough to sign for a director who had not, and to rewrite a signed
-- resolution under a real signature with the state still saying
-- "unchanged". `0791` refuses a client's own statement that does so.
--
-- Everything that matters runs under `set local role authenticated`,
-- signed in as a member with the accountant's role: a member who may
-- write, which is all the tables' policies ask. `pg_temp.sign_in_as`
-- sets `request.jwt.claims` and does not change the role, so without
-- the `set local role` every statement here would run as the owner and
-- pass the guard for the wrong reason -- the first assertion checks it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_sig (
  org uuid, clerk uuid, doc uuid, req uuid,
  person_a uuid, person_b uuid, person_c uuid,
  sig_a uuid, sig_b uuid, doc2 uuid, req2 uuid, sig2 uuid);
grant select on t_sig to authenticated;

do $$
declare
  v_org uuid; v_e uuid; v_a uuid; v_b uuid; v_c uuid;
  v_doc uuid; v_req uuid; v_sa uuid; v_sb uuid; v_clerk uuid;
  v_doc2 uuid; v_req2 uuid; v_s2 uuid;
begin
  v_org := pg_temp.test_org('Tandatangan Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'secretarial', true) on conflict do nothing;

  insert into public.corp_entities (org_id, name, registration_no,
    entity_type, incorporated_on, financial_year_end_day,
    financial_year_end_month, registered_office)
  values (v_org, 'Resolusi Sdn Bhd', '202401017777', 'sdn_bhd',
          date '2024-03-12', 31, 12, 'Level 2, Menara Bukti, KL')
  returning id into v_e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director One', '900101011111')
  returning id into v_a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director Two', '900202022222')
  returning id into v_b;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director Three', '900303033333')
  returning id into v_c;
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_e, v_a, 'director', date '2024-03-12'),
         (v_org, v_e, v_b, 'director', date '2024-03-12'),
         (v_org, v_e, v_c, 'director', date '2024-03-12');

  -- One resolution, two directors asked, the first of whom has signed.
  v_doc := public.corp_generate_document(v_e, 'sec_particulars');
  v_req := public.corp_request_signatures(v_doc, array[v_a, v_b],
             array['Director', 'Director'], null, null);
  select id into v_sa from public.corp_signatures
   where request_id = v_req and person_id = v_a;
  select id into v_sb from public.corp_signatures
   where request_id = v_req and person_id = v_b;
  perform public.corp_sign_document(v_sa, 'Director One');

  -- A second, with nobody signed yet: what may still be tidied away.
  v_doc2 := public.corp_generate_document(v_e, 'sec_particulars');
  v_req2 := public.corp_request_signatures(v_doc2, array[v_c],
              array['Director'], null, null);
  select id into v_s2 from public.corp_signatures where request_id = v_req2;

  v_clerk := pg_temp.another_user('kerani-tandatangan@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accountant', 'active');

  insert into t_sig values (v_org, v_clerk, v_doc, v_req, v_a, v_b, v_c,
    v_sa, v_sb, v_doc2, v_req2, v_s2);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_sig),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_new text := 'These particulars now say something else.';
begin
  select * into c from t_sig;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this member really may write for the company',
    app.can_write(c.org));
  perform pg_temp.check_eq('Director One really has signed',
    (select status::text from public.corp_signatures where id = c.sig_a),
    'signed');

  -- ------------------------------------------------------------------
  -- A signature nobody gave
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a line cannot be marked signed directly',
    format('update public.corp_signatures set status = %L where id = %L',
           'signed', c.sig_b),
    'The status on a signature is written by the database%', '42501');
  perform pg_temp.check_refused('nor its name typed in',
    format('update public.corp_signatures set signed_name = %L where id = %L',
           'Director Two', c.sig_b),
    'The name on a signature%', '42501');
  perform pg_temp.check_refused('nor declined for them',
    format('update public.corp_signatures set decline_reason = %L where id = %L',
           'Abroad', c.sig_b),
    'The reason for declining on a signature%', '42501');
  perform pg_temp.check_refused('nor a signed line inserted for them',
    format($q$insert into public.corp_signatures
                (org_id, request_id, person_id, status, signed_name, signed_at)
              values (%L, %L, %L, 'signed', 'Director Three', now())$q$,
           c.org, c.req, c.person_c),
    'A signature line starts pending and empty%', '42501');
  -- Asked of the status alone, too: a line inserted 'signed' with every
  -- other column empty still says somebody signed.
  perform pg_temp.check_refused('even with nothing else filled in',
    format($q$insert into public.corp_signatures
                (org_id, request_id, person_id, status)
              values (%L, %L, %L, 'signed')$q$,
           c.org, c.req, c.person_c),
    'A signature line starts pending and empty%', '42501');

  -- ------------------------------------------------------------------
  -- A real signature's record, rewritten
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a signing time cannot be moved',
    format('update public.corp_signatures set signed_at = %L where id = %L',
           '2024-01-02 10:00+08', c.sig_a),
    'The time on a signature%', '42501');
  perform pg_temp.check_refused('nor the address it came from',
    format('update public.corp_signatures set ip_address = %L where id = %L',
           '203.0.113.99', c.sig_a),
    'The address on a signature%', '42501');
  perform pg_temp.check_refused('nor the browser',
    format('update public.corp_signatures set user_agent = %L where id = %L',
           'typed by the clerk', c.sig_a),
    'The browser on a signature%', '42501');
  perform pg_temp.check_refused('nor whose login it was',
    format('update public.corp_signatures set signed_by = null where id = %L',
           c.sig_a),
    'The login on a signature%', '42501');
  perform pg_temp.check_refused('nor the text it vouches for',
    format('update public.corp_signatures set body_sha256_at_signing = %L where id = %L',
           encode(sha256(convert_to(v_new, 'UTF8')), 'hex'), c.sig_a),
    'The hash of the text signed on a signature%', '42501');
  perform pg_temp.check_refused('nor who signed it',
    format('update public.corp_signatures set person_id = %L where id = %L',
           c.person_c, c.sig_a),
    'The person on a signature%', '42501');
  perform pg_temp.check_refused('nor which request it answers',
    format('update public.corp_signatures set request_id = %L where id = %L',
           c.req2, c.sig_a),
    'The request on a signature%', '42501');
  perform pg_temp.check_refused('nor the capacity they signed in',
    format('update public.corp_signatures set capacity = %L where id = %L',
           'Secretary', c.sig_a),
    'The capacity a person signed in is part of what they signed.', '42501');
  perform pg_temp.check_refused('and a signed line is not deleted',
    format('delete from public.corp_signatures where id = %L', c.sig_a),
    'A line that has been signed is the record that it was%', '42501');

  -- ------------------------------------------------------------------
  -- The request: the lock `0072` reads, and the text it fixes
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('a request cannot be withdrawn directly',
    format('update public.corp_signature_requests set is_withdrawn = true where id = %L',
           c.req),
    'The withdrawal on a signature request%', '42501');
  perform pg_temp.check_refused('nor its withdrawal dated',
    format('update public.corp_signature_requests set withdrawn_at = now() where id = %L',
           c.req),
    'The time of withdrawal on a signature request%', '42501');
  perform pg_temp.check_refused('nor the text it circulated re-hashed',
    format('update public.corp_signature_requests set body_sha256 = %L where id = %L',
           encode(sha256(convert_to(v_new, 'UTF8')), 'hex'), c.req),
    'The hash of the text circulated on a signature request%', '42501');
  perform pg_temp.check_refused('nor pointed at another document',
    format('update public.corp_signature_requests set document_id = %L where id = %L',
           c.doc2, c.req),
    'The document on a signature request%', '42501');
  perform pg_temp.check_refused('nor its author changed',
    format('update public.corp_signature_requests set requested_by = null where id = %L',
           c.req),
    'The author on a signature request%', '42501');
  perform pg_temp.check_refused('nor its date',
    format('update public.corp_signature_requests set requested_at = %L where id = %L',
           '2024-01-01', c.req),
    'The time on a signature request%', '42501');
  perform pg_temp.check_refused('a request is not raised by hand',
    format($q$insert into public.corp_signature_requests
                (org_id, document_id, body_sha256) values (%L, %L, 'x')$q$,
           c.org, c.doc2),
    'Signatures are requested with corp_request_signatures%', '42501');
  perform pg_temp.check_refused('and one somebody has signed is not deleted',
    format('delete from public.corp_signature_requests where id = %L', c.req),
    'Somebody has already signed or declined this request%', '42501');

  -- So the text under Director One's signature is still the text, and
  -- the state says so.
  perform pg_temp.check_refused('the signed text itself stays locked',
    format('update public.corp_documents set body = %L where id = %L',
           v_new, c.doc),
    'This document has been signed by 1 person%', '23514');
  perform pg_temp.check_eq('the state reports what was signed, and only that',
    (select string_agg(s.person_name || '=' || s.status
                       || coalesce('/' || s.document_unchanged::text, ''),
                       '; ' order by s.person_name)
       from public.corp_signature_state(c.doc) s),
    'Director One=signed/true; Director Two=pending');

  -- ------------------------------------------------------------------
  -- What is still the company's to tidy
  -- ------------------------------------------------------------------
  update public.corp_signature_requests
     set due_on = pg_temp.today() + 14, note = 'Chase on Monday'
   where id = c.req;
  perform pg_temp.check_eq('a request''s due date and note are still the company''s',
    (select note from public.corp_signature_requests where id = c.req),
    'Chase on Monday');
  update public.corp_signatures set capacity = 'Alternate director'
   where id = c.sig_b;
  perform pg_temp.check_eq('as is the capacity of a line nobody has answered',
    (select capacity from public.corp_signatures where id = c.sig_b),
    'Alternate director');
  insert into public.corp_signatures (org_id, request_id, person_id, capacity)
  values (c.org, c.req, c.person_c, 'Director');
  perform pg_temp.check_eq('a plain pending line can still be added',
    (select count(*)::integer from public.corp_signatures
      where request_id = c.req and person_id = c.person_c and status = 'pending'), 1);
  delete from public.corp_signatures
   where request_id = c.req and person_id = c.person_c;
  perform pg_temp.check_eq('and taken off again while nobody has answered it',
    (select count(*)::integer from public.corp_signatures
      where request_id = c.req and person_id = c.person_c), 0);
  delete from public.corp_signature_requests where id = c.req2;
  perform pg_temp.check_eq('and a request nobody has answered can be deleted',
    (select count(*)::integer from public.corp_signature_requests
      where id = c.req2), 0);

  -- ------------------------------------------------------------------
  -- And the functions, run by this same client, still do their work
  -- ------------------------------------------------------------------
  perform public.corp_sign_document(c.sig_b, '  Director Two  ');
  perform pg_temp.check_true('signing through the function still writes the record',
    (select status = 'signed' and signed_name = 'Director Two'
            and signed_at is not null and signed_by = c.clerk
            and body_sha256_at_signing is not null
       from public.corp_signatures where id = c.sig_b));
  perform public.corp_request_signatures(c.doc, array[c.person_c],
    array['Director'], null, null);
  perform pg_temp.check_eq('raising the request again still adds a signer',
    (select count(*)::integer from public.corp_signatures
      where request_id = c.req and person_id = c.person_c), 1);
  perform public.corp_decline_signature(
    (select id from public.corp_signatures
      where request_id = c.req and person_id = c.person_c),
    'Not appointed when the meeting was held');
  perform pg_temp.check_eq('and declining through the function still writes it',
    (select status::text from public.corp_signatures
      where request_id = c.req and person_id = c.person_c), 'declined');
end $$;

reset role;

do $$
declare v_n integer;
begin
  select count(*) into v_n
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and t.tgname = 'signature_is_the_databases'
     and c.relname in ('corp_signatures', 'corp_signature_requests');
  perform pg_temp.check_eq('the rule is on both tables', v_n, 2);
end $$;

rollback;
