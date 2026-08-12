-- =====================================================================
-- iAkauntan :: corporate secretarial tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/secretarial.sql
--
-- The dates are the product. A secretarial firm's whole risk is a
-- missed deadline, so the arithmetic that produces them is asserted
-- rather than eyeballed. Runs inside a transaction that is rolled back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.sec_org()
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org('Sec Firm');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'secretarial', true) on conflict do nothing;
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- The Annual Return runs from the incorporation anniversary
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_sep uuid; v_leap uuid;
  v_due date;
begin
  v_org := pg_temp.sec_org();

  -- Incorporated on the 30th: clamping the anniversary day to dodge
  -- 29 February would move this two days early, and a statutory date
  -- that is wrong in the safe direction is still wrong.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Akhir Bulan Sdn Bhd', 'sdn_bhd', date '2019-09-30', 31, 12)
  returning id into v_sep;

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Lompat Sdn Bhd', 'sdn_bhd', date '2020-02-29', 31, 3)
  returning id into v_leap;

  select f.due_date into v_due
    from public.corp_upcoming_filings(v_org, 400) f
   where f.entity_id = v_sep and f.filing_type = 'annual_return'
   order by f.due_date limit 1;
  perform pg_temp.check_true(
    'the Annual Return is thirty days after the anniversary, not the 28th',
    extract(day from v_due) = 30);

  -- A leap-day company has its anniversary on 28 February in a common
  -- year, which is what Postgres interval arithmetic already does.
  select f.trigger_date into v_due
    from public.corp_upcoming_filings(v_org, 400) f
   where f.entity_id = v_leap and f.filing_type = 'annual_return'
   order by f.trigger_date limit 1;
  perform pg_temp.check_true('a leap-day anniversary does not drift',
    extract(month from v_due) = 2 and extract(day from v_due) in (28, 29));
end $$;

-- ---------------------------------------------------------------------
-- Only public companies hold an AGM
--
-- The 2016 Act removed the requirement for a private company entirely.
-- Telling a Sdn Bhd it has an AGM due is teaching the wrong law.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_sdn uuid; v_bhd uuid;
begin
  v_org := pg_temp.sec_org();

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Persendirian Sdn Bhd', 'sdn_bhd', date '2020-01-15', 31, 12)
  returning id into v_sdn;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Awam Berhad', 'berhad', date '2020-01-15', 31, 12)
  returning id into v_bhd;

  perform pg_temp.check_eq('no AGM is due of a private company',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_sdn and f.filing_type = 'agm'), 0);
  perform pg_temp.check_true('but a public company has one',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_bhd and f.filing_type = 'agm') > 0);

  -- And the guard holds when a filing is opened by hand.
  begin
    perform public.corp_open_filing(v_sdn, 'agm', date '2025-12-31');
    raise exception 'FAIL: a private company was given an AGM filing';
  exception when sqlstate '22023' then
    raise notice 'ok   an AGM filing is refused for a private company';
  end;

  -- Financial statements: six months to circulate, thirty to lodge.
  perform pg_temp.check_true('financial statements allow 180 + 30 days',
    (select f.due_date - f.trigger_date = 210
       from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_sdn and f.filing_type = 'financial_statements'
      limit 1));
end $$;

-- ---------------------------------------------------------------------
-- The register of members is computed, and cannot go negative
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_e uuid; v_ord uuid; v_a uuid; v_b uuid; v_c uuid;
begin
  v_org := pg_temp.sec_org();

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Saham Sdn Bhd', 'sdn_bhd', date '2024-03-12', 31, 12)
  returning id into v_e;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (v_org, v_e, 'ORD', 'Ordinary') returning id into v_ord;

  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Member A', '920415085566') returning id into v_a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Member B', '850922105533') returning id into v_b;
  insert into public.corp_persons (org_id, kind, full_name, registration_no)
  values (v_org, 'corporate', 'Holdings Bhd', '199501001234') returning id into v_c;

  insert into public.corp_share_events (org_id, entity_id, share_class_id,
    event_type, event_date, to_person_id, quantity, consideration_per_share,
    total_consideration)
  values (v_org, v_e, v_ord, 'allotment', date '2024-03-12', v_a, 100, 1, 100),
         (v_org, v_e, v_ord, 'allotment', date '2024-03-12', v_b, 100, 1, 100),
         (v_org, v_e, v_ord, 'allotment', date '2025-06-01', v_c, 300, 2.50, 750);
  insert into public.corp_share_events (org_id, entity_id, share_class_id,
    event_type, event_date, from_person_id, to_person_id, quantity)
  values (v_org, v_e, v_ord, 'transfer', date '2026-02-14', v_b, v_c, 40);

  perform pg_temp.check_eq('the transferee gains the shares',
    (select r.shares from public.corp_register_of_members(v_e) r
      where r.person_id = v_c), 340);
  perform pg_temp.check_eq('and the transferor loses them',
    (select r.shares from public.corp_register_of_members(v_e) r
      where r.person_id = v_b), 60);
  perform pg_temp.check_eq('percentages are of the class in issue',
    (select round(r.percent) from public.corp_register_of_members(v_e) r
      where r.person_id = v_c), 68);
  perform pg_temp.check_eq('issued capital counts only allotments',
    (select c.shares from public.corp_issued_capital(v_e) c), 500);

  -- A register that can go negative has already lied to the Registrar.
  begin
    insert into public.corp_share_events (org_id, entity_id, share_class_id,
      event_type, event_date, from_person_id, to_person_id, quantity)
    values (v_org, v_e, v_ord, 'transfer', date '2026-03-01', v_b, v_a, 1000);
    raise exception 'FAIL: transferred more shares than the holder held';
  exception when sqlstate '23514' then
    raise notice 'ok   nobody can transfer shares they do not hold';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Documents are built from the registers
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_e uuid; v_ord uuid; v_p uuid; v_doc uuid; v_body text;
  v_gaps integer;
begin
  v_org := pg_temp.sec_org();

  insert into public.corp_entities (org_id, name, registration_no, entity_type,
    incorporated_on, financial_year_end_day, financial_year_end_month,
    registered_office)
  values (v_org, 'Dokumen Sdn Bhd', '202401012345', 'sdn_bhd', date '2024-03-12',
          31, 12, 'Level 8, Menara ABC, Kuala Lumpur')
  returning id into v_e;
  insert into public.corp_share_classes (org_id, entity_id, code, name)
  values (v_org, v_e, 'ORD', 'Ordinary') returning id into v_ord;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Nurul Aisyah binti Rahman', '920415085566')
  returning id into v_p;
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_e, v_p, 'director', date '2024-03-12');
  insert into public.corp_share_events (org_id, entity_id, share_class_id,
    event_type, event_date, to_person_id, quantity, consideration_per_share,
    total_consideration)
  values (v_org, v_e, v_ord, 'allotment', date '2024-03-12', v_p, 100, 1, 100);

  v_doc := public.corp_generate_document(v_e, 'sec_particulars');
  select body into v_body from public.corp_documents where id = v_doc;

  perform pg_temp.check_true('the company name is merged',
    v_body like '%Dokumen Sdn Bhd%');
  perform pg_temp.check_true('the director comes from the register',
    v_body like '%Nurul Aisyah binti Rahman%');
  perform pg_temp.check_true('and so does the shareholding',
    v_body like '%100 Ordinary shares (100.00%%)%');
  perform pg_temp.check_true('no placeholder survives into the output',
    v_body not like '%{{%');
  -- to_char pads month names to nine characters without FM, which would
  -- put "12 March     2024" in the middle of a resolution.
  perform pg_temp.check_true('dates are not padded',
    v_body like '%12 March 2024%');

  -- What the register cannot answer is reported before anything is
  -- signed, rather than left as visible braces in a resolution.
  select count(*) into v_gaps
    from public.corp_template_placeholders(v_e, 'board_res_appoint_director')
   where not is_filled;
  perform pg_temp.check_true(
    'a template needing a new director''s details reports the gaps',
    v_gaps >= 3);
end $$;

-- ---------------------------------------------------------------------
-- Signatures
--
-- Not a digital signature under the DSA 1997 — an electronic one under
-- the ECA 2006. What makes it worth anything is that the text is
-- fingerprinted when signing opens and again as each person signs.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_e uuid; v_a uuid; v_b uuid; v_doc uuid; v_req uuid;
  v_sig_a uuid; v_sig_b uuid;
begin
  v_org := pg_temp.sec_org();

  insert into public.corp_entities (org_id, name, registration_no, entity_type,
    incorporated_on, financial_year_end_day, financial_year_end_month,
    registered_office)
  values (v_org, 'Tandatangan Sdn Bhd', '202401011111', 'sdn_bhd',
          date '2024-03-12', 31, 12, 'Level 8, Menara ABC, KL')
  returning id into v_e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director One', '900101011111') returning id into v_a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director Two', '900202022222') returning id into v_b;
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_e, v_a, 'director', date '2024-03-12'),
         (v_org, v_e, v_b, 'director', date '2024-03-12');

  v_doc := public.corp_generate_document(v_e, 'sec_particulars');
  v_req := public.corp_request_signatures(v_doc, array[v_a, v_b],
             array['Director', 'Director'], current_date + 7, null);

  select id into v_sig_a from public.corp_signatures
   where request_id = v_req and person_id = v_a;
  select id into v_sig_b from public.corp_signatures
   where request_id = v_req and person_id = v_b;

  perform public.corp_sign_document(v_sig_a, 'Director One');
  perform pg_temp.check_true('a signature vouches for the text it was given',
    (select s.document_unchanged
       from public.corp_signature_state(v_doc) s
      where s.signature_id = v_sig_a));

  begin
    perform public.corp_sign_document(v_sig_a, 'Director One');
    raise exception 'FAIL: the same line was signed twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a line cannot be signed twice';
  end;

  begin
    perform public.corp_sign_document(v_sig_b, '   ');
    raise exception 'FAIL: an empty name was accepted as a signature';
  exception when sqlstate '22023' then
    raise notice 'ok   an empty name is not a signature';
  end;

  -- Since 0072 this cannot happen by the ordinary route at all: once a
  -- signature exists the words are what somebody attested to.
  begin
    update public.corp_documents set body = body || E'\n\nAnd one more thing.'
     where id = v_doc;
    raise exception 'FAIL: a signed document was edited';
  exception when sqlstate '23514' then
    raise notice 'ok   a signed document cannot be edited';
  end;

  -- The hash is the backstop for what the trigger cannot see — a change
  -- made by something other than an update to this table. Prevention and
  -- detection guard against different failures and both are worth having,
  -- so the guard is deliberately lifted here to reach the state the hash
  -- exists to catch. This is the one place in the suite that reaches past
  -- a rule on purpose, which is why it says so.
  alter table public.corp_documents disable trigger corp_document_locked;
  update public.corp_documents set body = body || E'\n\nAnd one more thing.'
   where id = v_doc;
  alter table public.corp_documents enable trigger corp_document_locked;

  perform pg_temp.check_true(
    'once the text changes, the signature stops vouching for it',
    (select s.document_unchanged = false
       from public.corp_signature_state(v_doc) s
      where s.signature_id = v_sig_a));

  begin
    perform public.corp_sign_document(v_sig_b, 'Director Two');
    raise exception 'FAIL: signed a document that had changed since circulation';
  exception when sqlstate '23514' then
    raise notice 'ok   nobody can sign a text that changed since it was circulated';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Amending a generated document
--
-- Generated text is a starting point, not a finished deed — until
-- somebody signs it, at which point the words are what they attested to.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_e uuid; v_p uuid; v_doc uuid; v_req uuid; v_sig uuid;
begin
  v_org := pg_temp.sec_org();

  insert into public.corp_entities (org_id, name, registration_no, entity_type,
    incorporated_on, financial_year_end_day, financial_year_end_month,
    registered_office)
  values (v_org, 'Pindaan Sdn Bhd', '202401013333', 'sdn_bhd',
          date '2024-04-04', 31, 12, 'Level 3, Menara PQR, KL')
  returning id into v_e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director Amend', '900505055555')
  returning id into v_p;
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_e, v_p, 'director', date '2024-04-04');

  v_doc := public.corp_generate_document(v_e, 'sec_particulars');

  perform public.corp_update_document(v_doc, 'Amended particulars',
            'Rewritten by the secretary.');
  perform pg_temp.check_true('an unsigned document can be amended',
    (select body = 'Rewritten by the secretary.' and title = 'Amended particulars'
       from public.corp_documents where id = v_doc));

  begin
    perform public.corp_update_document(v_doc, '   ', 'Still needs a title.');
    raise exception 'FAIL: a document was left with no title';
  exception when sqlstate '22023' then
    raise notice 'ok   a document still needs a title';
  end;

  v_req := public.corp_request_signatures(v_doc, array[v_p], array['Director'],
             null, null);
  select id into v_sig from public.corp_signatures where request_id = v_req;
  perform public.corp_sign_document(v_sig, 'Director Amend');

  begin
    perform public.corp_update_document(v_doc, 'Amended again', 'Different text.');
    raise exception 'FAIL: a signed document was edited';
  exception when sqlstate '23514' then
    raise notice 'ok   a signed document cannot be edited';
  end;

  -- The rule is a trigger rather than a check inside the function,
  -- because RLS grants can_write full ALL on this table: without it,
  -- anyone with a session could PATCH the row straight past the RPC.
  begin
    update public.corp_documents set body = 'Straight past the function.'
     where id = v_doc;
    raise exception 'FAIL: a signed document was edited by direct update';
  exception when sqlstate '23514' then
    raise notice 'ok   and not by going around the function either';
  end;

  -- Bookkeeping about the document is not the document.
  update public.corp_documents set filing_id = null where id = v_doc;
  raise notice 'ok   a signed document still accepts non-text changes';
end $$;

-- ---------------------------------------------------------------------
-- Signing links
--
-- The only part of the database a stranger can reach. Everything here is
-- asserted from the anon role rather than as the owner, because the
-- question is not "does the SQL work" but "what can somebody with a URL
-- and no account actually do".
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_e uuid; v_a uuid; v_b uuid; v_doc uuid; v_req uuid;
  v_sig_a uuid; v_sig_b uuid;
  v_owner uuid := pg_temp.test_user();
  v_first text; v_live text; v_late text; v_stale text;
  v_state text; v_body text; v_who text;
begin
  v_org := pg_temp.sec_org();

  insert into public.corp_entities (org_id, name, registration_no, entity_type,
    incorporated_on, financial_year_end_day, financial_year_end_month,
    registered_office)
  values (v_org, 'Pautan Sdn Bhd', '202401012222', 'sdn_bhd',
          date '2024-05-20', 31, 12, 'Level 9, Menara XYZ, KL')
  returning id into v_e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director One', '900303033333') returning id into v_a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director Two', '900404044444') returning id into v_b;
  insert into public.corp_officers (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_e, v_a, 'director', date '2024-05-20'),
         (v_org, v_e, v_b, 'director', date '2024-05-20');

  v_doc := public.corp_generate_document(v_e, 'sec_particulars');
  v_req := public.corp_request_signatures(v_doc, array[v_a, v_b],
             array['Director', 'Director'], current_date + 7, null);
  select id into v_sig_a from public.corp_signatures
   where request_id = v_req and person_id = v_a;
  select id into v_sig_b from public.corp_signatures
   where request_id = v_req and person_id = v_b;

  v_first := public.corp_create_signing_link(v_sig_a, 14, 'one@example.test');

  perform pg_temp.check_true('a token carries 256 bits of randomness',
    length(v_first) = 64);
  perform pg_temp.check_true('the token itself is never stored',
    not exists (select 1 from public.corp_signing_links
                 where token_hash = v_first));
  perform pg_temp.check_true('only its hash is',
    exists (select 1 from public.corp_signing_links
             where token_hash = app.corp_token_hash(v_first)));

  -- Issuing a replacement has to kill the one already in somebody's
  -- inbox, or "I sent a new link" would mean two working links.
  v_live := public.corp_create_signing_link(v_sig_a, 14, 'one@example.test');
  perform pg_temp.check_true('issuing a new link retires the old one',
    (select revoked_at is not null from public.corp_signing_links
      where token_hash = app.corp_token_hash(v_first)));

  -- A link for the second director that will be aged out, and one that
  -- will be left behind by an edit.
  v_late := public.corp_create_signing_link(v_sig_b, 14, null);
  update public.corp_signing_links set expires_at = now() - interval '1 day'
   where token_hash = app.corp_token_hash(v_late);

  -- ---- from here on, nobody is signed in and the role is anon --------
  perform pg_temp.sign_out();
  execute 'set local role anon';

  begin
    perform 1 from public.corp_signing_links;
    raise exception 'FAIL: anon read the signing link table';
  exception when insufficient_privilege then
    raise notice 'ok   the link table itself is shut to anon';
  end;

  select l.state, l.document_body into v_state, v_body
    from public.corp_open_signing_link(v_first) l;
  perform pg_temp.check_true('a retired link says it was withdrawn',
    v_state = 'revoked');
  perform pg_temp.check_true('and withholds the text', v_body is null);

  select l.state, l.document_body into v_state, v_body
    from public.corp_open_signing_link(v_late) l;
  perform pg_temp.check_true('an aged link says expired rather than invalid',
    v_state = 'expired');
  perform pg_temp.check_true('and withholds the text too', v_body is null);

  select l.state, l.document_body, l.signatory_name into v_state, v_body, v_who
    from public.corp_open_signing_link(gen_random_uuid()::text) l;
  perform pg_temp.check_true('a token nobody issued is simply invalid',
    v_state = 'invalid');
  perform pg_temp.check_true('and tells a guesser nothing at all',
    v_body is null and v_who is null);

  select l.state, l.document_body, l.signatory_name into v_state, v_body, v_who
    from public.corp_open_signing_link(v_live) l;
  perform pg_temp.check_true('the live link opens', v_state = 'open');
  perform pg_temp.check_true('hands over the text to be signed',
    v_body is not null);
  perform pg_temp.check_true('and names the person it was meant for',
    v_who = 'Director One');

  begin
    perform public.corp_sign_with_link(v_late, 'Director Two');
    raise exception 'FAIL: an expired link still signed';
  exception when sqlstate '22023' then
    raise notice 'ok   an expired link cannot sign';
  end;

  perform public.corp_sign_with_link(v_live, 'Director One');

  begin
    perform public.corp_sign_with_link(v_live, 'Director One');
    raise exception 'FAIL: a link signed twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a link signs once and is then spent';
  end;

  select l.state into v_state from public.corp_open_signing_link(v_live) l;
  perform pg_temp.check_true('and reopening it says used', v_state = 'used');

  execute 'reset role';
  perform pg_temp.sign_in_as(v_owner);

  perform pg_temp.check_true('the signature stands as an ordinary signature',
    (select s.document_unchanged
       from public.corp_signature_state(v_doc) s
      where s.signature_id = v_sig_a));
  perform pg_temp.check_true(
    'but signed_by stays null: nobody was signed in',
    (select signed_by is null and signed_name = 'Director One'
       and ip_address is not distinct from null
       from public.corp_signatures where id = v_sig_a));

  -- Now move the text underneath a link that is already out.
  v_stale := public.corp_create_signing_link(v_sig_b, 14, null);
  update public.corp_documents set body = body || E'\n\nAdded after the fact.'
   where id = v_doc;

  perform pg_temp.sign_out();
  execute 'set local role anon';

  select l.state, l.document_body into v_state, v_body
    from public.corp_open_signing_link(v_stale) l;
  perform pg_temp.check_true('a link outlived by an edit says so',
    v_state = 'changed');
  perform pg_temp.check_true('and will not show the text it no longer covers',
    v_body is null);

  begin
    perform public.corp_sign_with_link(v_stale, 'Director Two');
    raise exception 'FAIL: signed a document that had changed since the link went out';
  exception when sqlstate '23514' then
    raise notice 'ok   a changed document cannot be signed by link either';
  end;

  execute 'reset role';
  perform pg_temp.sign_in_as(v_owner);

  -- The secretary can see the link was opened; that is the only evidence
  -- there is that it reached anybody.
  perform pg_temp.check_true('opening a link is recorded',
    (select opened_at is not null from public.corp_signing_links
      where token_hash = app.corp_token_hash(v_live)));
end $$;

-- ---------------------------------------------------------------------
-- Attachments inherit what they hang off
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_clerk uuid; v_emp_user uuid; v_emp uuid; v_other uuid;
begin
  v_org := pg_temp.sec_org();

  insert into auth.users (id, email)
  values (gen_random_uuid(), 'clerk-' || gen_random_uuid() || '@iakauntan.test')
  returning id into v_clerk;
  insert into auth.users (id, email)
  values (gen_random_uuid(), 'emp-' || gen_random_uuid() || '@iakauntan.test')
  returning id into v_emp_user;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active'),
         (v_org, v_emp_user, 'employee', 'active');

  insert into public.employees (org_id, employee_no, full_name, hire_date,
    basic_salary, residency_status, user_id)
  values (v_org, 'A1', 'Self Service', date '2024-01-01', 5000, 'citizen',
          v_emp_user) returning id into v_emp;
  insert into public.employees (org_id, employee_no, full_name, hire_date,
    basic_salary, residency_status)
  values (v_org, 'A2', 'Somebody Else', date '2024-01-01', 5000, 'citizen')
  returning id into v_other;

  perform pg_temp.sign_in_as(v_emp_user);
  perform pg_temp.check_true('an employee sees their own attachments',
    app.can_read_attachment(v_org, 'employees', v_emp));
  perform pg_temp.check_true('and not a colleague''s',
    not app.can_read_attachment(v_org, 'employees', v_other));

  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('a clerk reads a bill attachment',
    app.can_read_attachment(v_org, 'purchase_documents', gen_random_uuid()));
  perform pg_temp.check_true('but not a personnel one',
    not app.can_read_attachment(v_org, 'employees', v_other));

  perform pg_temp.sign_out();
  perform pg_temp.check_true('and a non-member reads nothing',
    not app.can_read_attachment(v_org, 'purchase_documents', gen_random_uuid()));

  -- A malformed path denies rather than raising, so a bad upload is a
  -- refusal and not a 500.
  perform pg_temp.check_true('a malformed path is null, not an error',
    app.uuid_or_null('not-a-uuid') is null);

  perform pg_temp.sign_in_as(pg_temp.test_user());
  begin
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'employees', v_emp, 'x.pdf', 'somewhere/else.pdf');
    raise exception 'FAIL: an attachment path that lied about itself was accepted';
  exception when sqlstate '22023' then
    raise notice 'ok   the path must agree with the row';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_e uuid;
begin
  v_org := pg_temp.sec_org();
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Terlindung Sdn Bhd', 'sdn_bhd', date '2024-01-01')
  returning id into v_e;

  perform pg_temp.sign_out();

  begin
    perform * from public.corp_upcoming_filings(v_org, 120);
    raise exception 'FAIL: a non-member read the deadline list';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot read the deadlines';
  end;

  begin
    perform * from public.corp_register_of_members(v_e);
    raise exception 'FAIL: a non-member read the register of members';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot read the register of members';
  end;

  begin
    perform public.corp_generate_document(v_e, 'sec_particulars');
    raise exception 'FAIL: a non-member generated a document';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot generate a document';
  end;
end $$;

rollback;
