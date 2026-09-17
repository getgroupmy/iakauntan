-- =====================================================================
-- iAkauntan :: the number only the customer has
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tax_details.sql
--
-- `0626`. A customer fills in their own TIN on a public form, and the
-- form writes into the columns an e-Invoice is built from. Four things
-- have to hold or it is a way for a stranger to edit master data:
--
--   * **a blank is filled and a value is never overwritten.** This is
--     the whole design. A submission that replaced a verified TIN would
--     take a working contact and break it, and nothing in the product
--     would say when.
--   * **a changed TIN is an unverified TIN.** `is_tin_verified` means
--     LHDN matched that TIN to that identification number. Move any of
--     the three and the tick is a claim about numbers that are no
--     longer there -- and a stale tick is worse than none, because the
--     e-Invoice screen shows it beside a number nobody checked.
--   * **accepting a disagreement takes the company's permission.** The
--     public path fills blanks; going over the top of something we hold
--     is `can_write`, the same permission that issued the link.
--   * **the page is not the portal.** A tax-details token opens a form
--     with no money on it, and it opens on its own route -- which is
--     the bug 0494 was written to undo, on the third path.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A contact and a live link to it, in one call.
create or replace function pg_temp.a_contact(
  p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, contact_type, code, name, email)
  values (p_org, 'customer', p_code, p_name, lower(p_code) || '@buyer.test')
  returning id into v_id;
  return v_id;
end;
$$;

-- The token, not the URL. `request_tax_details` hands back a link and
-- the functions take a token, so every test here needs the tail --
-- extracted on the LAST slash, which is what the path change in 0494
-- turned out to need.
create or replace function pg_temp.a_link(p_contact uuid)
returns text language plpgsql as $$
declare v_url text;
begin
  v_url := public.request_tax_details(p_contact) ->> 'url';
  return regexp_replace(v_url, '^.*/', '');
end;
$$;

-- ---------------------------------------------------------------------
-- 1. A blank is filled. A value is not overwritten.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Nombor Cukai Sdn Bhd');
  v_buyer uuid;
  v_token text;
  v_res   jsonb;
  c       public.contacts;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B001', 'Pembeli Sdn Bhd');
  -- We hold an SST number and a city already, and no TIN. That is the
  -- ordinary state of a contact this link is sent to.
  update public.contacts
     set sst_registration_no = 'W10-1808-31000001', city = 'Shah Alam'
   where id = v_buyer;

  v_token := pg_temp.a_link(v_buyer);

  v_res := public.submit_tax_details(v_token, jsonb_build_object(
    'tin', 'C1234567890',
    'id_type', 'BRN',
    'id_value', '201901000001',
    -- Both of these disagree with what we hold.
    'sst_registration_no', 'W10-9999-31000009',
    'city', 'Petaling Jaya',
    'submitted_by_name', 'Siti the accounts clerk'));

  select * into c from public.contacts where id = v_buyer;

  perform pg_temp.check_eq('a blank TIN is filled from the form',
    c.tin, 'C1234567890');
  perform pg_temp.check_eq('and the identification it was issued against',
    c.id_value, '201901000001');
  perform pg_temp.check_eq(
    'an SST number we already hold is NOT overwritten',
    c.sst_registration_no, 'W10-1808-31000001');
  perform pg_temp.check_eq('nor a city', c.city, 'Shah Alam');

  perform pg_temp.check_true('the form says something is awaiting review',
    (v_res ->> 'awaiting_review')::boolean);
  perform pg_temp.check_eq('and names what it did take',
    v_res ->> 'applied_list', 'id_type, id_value, tin');

  -- And the disagreement is on the review list with BOTH sides, because
  -- "the customer says W10-9999" is not answerable without "you hold
  -- W10-1808".
  perform pg_temp.check_eq('the disagreement is waiting, with both sides',
    (select jsonb_agg(x order by x ->> 'field')
       from public.pending_tax_submissions(v_org) p,
            jsonb_array_elements(p.conflicts) x)::text,
    jsonb_build_array(
      jsonb_build_object('field', 'city',
        'theirs', 'Petaling Jaya', 'ours', 'Shah Alam'),
      jsonb_build_object('field', 'sst_registration_no',
        'theirs', 'W10-9999-31000009', 'ours', 'W10-1808-31000001')
    )::text);
end $$;

-- ---------------------------------------------------------------------
-- 2. A changed TIN is an unverified TIN
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tanda Sah Sdn Bhd');
  v_buyer uuid;
  v_token text;
  v_sub   uuid;
  c       public.contacts;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B002', 'Pengesah Sdn Bhd');
  update public.contacts
     set tin = 'C1111111111', id_type = 'BRN', id_value = '201901000002',
         is_tin_verified = true, tin_verified_at = now()
   where id = v_buyer;

  v_token := pg_temp.a_link(v_buyer);
  perform public.submit_tax_details(v_token,
    jsonb_build_object('tin', 'C2222222222'));

  select * into c from public.contacts where id = v_buyer;
  perform pg_temp.check_eq(
    'a TIN we hold survives the public form untouched',
    c.tin, 'C1111111111');
  perform pg_temp.check_true('and stays verified',
    c.is_tin_verified);

  -- Now somebody in the company accepts it.
  select id into v_sub from public.tax_detail_submissions
   where contact_id = v_buyer;
  perform public.apply_tax_submission(v_sub);

  select * into c from public.contacts where id = v_buyer;
  perform pg_temp.check_eq('an accepted submission does overwrite it',
    c.tin, 'C2222222222');
  perform pg_temp.check_true('and the verified tick falls with it',
    not c.is_tin_verified);
  perform pg_temp.check_true('and the date it was verified goes too',
    c.tin_verified_at is null);
end $$;

-- The identification number is the other half of what LHDN matched, so
-- moving it alone has to clear the tick as well.
do $$
declare
  v_org   uuid := pg_temp.test_org('Nombor Pengenalan Sdn Bhd');
  v_buyer uuid;
  v_sub   uuid;
  c       public.contacts;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B003', 'Tukar Nombor Sdn Bhd');
  update public.contacts
     set tin = 'C3333333333', id_type = 'BRN', id_value = '201901000003',
         is_tin_verified = true, tin_verified_at = now()
   where id = v_buyer;

  perform public.submit_tax_details(pg_temp.a_link(v_buyer),
    jsonb_build_object('id_value', '201901000099'));
  select id into v_sub from public.tax_detail_submissions
   where contact_id = v_buyer;
  perform public.apply_tax_submission(v_sub);

  select * into c from public.contacts where id = v_buyer;
  perform pg_temp.check_eq('the identification number moved',
    c.id_value, '201901000099');
  perform pg_temp.check_true(
    'and the TIN is unverified although the TIN did not move',
    not c.is_tin_verified);
end $$;

-- A field that has nothing to do with the TIN must NOT clear the tick.
-- Without this, every accepted address change would quietly untick a
-- number LHDN really did match, and somebody would re-verify four
-- hundred contacts for nothing.
do $$
declare
  v_org   uuid := pg_temp.test_org('Alamat Sahaja Sdn Bhd');
  v_buyer uuid;
  v_sub   uuid;
  c       public.contacts;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B004', 'Pindah Alamat Sdn Bhd');
  update public.contacts
     set tin = 'C4444444444', id_type = 'BRN', id_value = '201901000004',
         address_line1 = 'Lot 1, Jalan Lama',
         is_tin_verified = true, tin_verified_at = now()
   where id = v_buyer;

  perform public.submit_tax_details(pg_temp.a_link(v_buyer),
    jsonb_build_object('address_line1', 'Lot 2, Jalan Baru'));
  select id into v_sub from public.tax_detail_submissions
   where contact_id = v_buyer;
  perform public.apply_tax_submission(v_sub);

  select * into c from public.contacts where id = v_buyer;
  perform pg_temp.check_eq('the address moved',
    c.address_line1, 'Lot 2, Jalan Baru');
  perform pg_temp.check_true('and the verified TIN is left alone',
    c.is_tin_verified);
end $$;

-- ---------------------------------------------------------------------
-- 3. Accepting a disagreement takes the company's permission
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Kebenaran Sdn Bhd');
  v_buyer  uuid;
  v_sub    uuid;
  v_reader uuid := pg_temp.another_user('viewer@iakauntan.test');
begin
  v_buyer := pg_temp.a_contact(v_org, 'B005', 'Hak Menulis Sdn Bhd');
  update public.contacts set tin = 'C5555555555' where id = v_buyer;
  perform public.submit_tax_details(pg_temp.a_link(v_buyer),
    jsonb_build_object('tin', 'C5555559999'));
  select id into v_sub from public.tax_detail_submissions
   where contact_id = v_buyer;

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_reader, 'viewer');
  perform pg_temp.sign_in_as(v_reader);

  perform pg_temp.check_refused(
    'somebody who may only read cannot accept a submission',
    format('select public.apply_tax_submission(%L)', v_sub),
    '%Not permitted%', '42501');
  perform pg_temp.check_refused(
    'nor dismiss one',
    format('select public.dismiss_tax_submission(%L)', v_sub),
    '%Not permitted%', '42501');
  perform pg_temp.check_refused(
    'nor ask a contact for their details in the first place',
    format('select public.request_tax_details(%L)', v_buyer),
    '%Not permitted%', '42501');

  perform pg_temp.check_eq('and the TIN we hold is untouched',
    (select tin from public.contacts where id = v_buyer), 'C5555555555');
end $$;

-- ---------------------------------------------------------------------
-- 4. The link is a link: it expires, it is revoked, and it says nothing
--    about money
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Pautan Sdn Bhd');
  v_buyer uuid;
  v_live  text;
  v_old   text;
  v_open  jsonb;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B006', 'Pautan Mati Sdn Bhd');

  v_old := pg_temp.a_link(v_buyer);
  -- Issuing a second kills the first, for `share_document`'s reason:
  -- the last link sent has to be the one that works.
  v_live := pg_temp.a_link(v_buyer);

  perform pg_temp.check_eq('the link the company just replaced is revoked',
    public.open_tax_detail_request(v_old) ->> 'state', 'revoked');
  perform pg_temp.check_refused(
    'and a revoked link submits nothing',
    format('select public.submit_tax_details(%L, %L::jsonb)',
           v_old, '{"tin": "C6666666666"}'),
    '%no longer open%', '42501');

  v_open := public.open_tax_detail_request(v_live);
  perform pg_temp.check_eq('the live one opens', v_open ->> 'state', 'open');

  -- What we hold, so the customer corrects rather than retypes.
  perform pg_temp.check_eq('and shows the customer their own name',
    v_open -> 'contact' ->> 'name', 'Pautan Mati Sdn Bhd');

  -- And nothing about money. The portal is for that; it is a different
  -- token and a different page.
  perform pg_temp.check_eq(
    'the form carries no invoices, no balance and no total',
    (select coalesce(string_agg(k, ', ' order by k), 'none')
       from jsonb_object_keys(v_open) k
      where k in ('invoices', 'total_outstanding', 'balance_amount',
                  'documents', 'currency')),
    'none');

  -- Expiry.
  update public.tax_detail_requests set expires_at = now() - interval '1 day'
   where contact_id = v_buyer and revoked_at is null;
  perform pg_temp.check_eq('an expired link opens nothing',
    public.open_tax_detail_request(v_live) ->> 'state', 'expired');
  perform pg_temp.check_refused(
    'and submits nothing',
    format('select public.submit_tax_details(%L, %L::jsonb)',
           v_live, '{"tin": "C6666666666"}'),
    '%no longer open%', '42501');

  perform pg_temp.check_eq('a token nobody issued is invalid',
    public.open_tax_detail_request('not-a-token') ->> 'state', 'invalid');
end $$;

-- ---------------------------------------------------------------------
-- 5. A form submitted empty is not an answer
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Borang Kosong Sdn Bhd');
  v_buyer uuid;
  v_token text;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B007', 'Tiada Jawapan Sdn Bhd');
  v_token := pg_temp.a_link(v_buyer);

  perform pg_temp.check_refused(
    'a form with nothing on it is refused',
    format('select public.submit_tax_details(%L, %L::jsonb)',
           v_token, '{"submitted_by_name": "Someone"}'),
    '%tax_detail_submissions_says_something%');

  -- Whitespace is nothing. Without the trim it would be an answer, and
  -- a contact would end up with a TIN of three spaces.
  perform pg_temp.check_refused(
    'and so is one filled in with spaces',
    format('select public.submit_tax_details(%L, %L::jsonb)',
           v_token, '{"tin": "   ", "city": " "}'),
    '%tax_detail_submissions_says_something%');

  perform pg_temp.check_eq('nothing was recorded either way',
    (select count(*) from public.tax_detail_submissions
      where contact_id = v_buyer), 0);
end $$;

-- ---------------------------------------------------------------------
-- 6. A correction supersedes, and waits
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Pembetulan Sdn Bhd');
  v_buyer uuid;
  v_token text;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B008', 'Salah Taip Sdn Bhd');
  -- A city we hold, so that the FIRST answer disagrees with something
  -- and therefore stays on the review list on its own account. Without
  -- it, the first answer would auto-apply in full, agree with the
  -- contact afterwards, and drop off the list whether or not anything
  -- superseded it -- which is a fixture that cannot tell the two apart,
  -- and the mutation sweep said so.
  update public.contacts set city = 'Ipoh' where id = v_buyer;
  v_token := pg_temp.a_link(v_buyer);

  -- The typo, into a blank, and a city that disagrees.
  perform public.submit_tax_details(v_token,
    jsonb_build_object('tin', 'C7777777770', 'city', 'Taiping'));
  perform pg_temp.check_eq('the first answer fills the blank',
    (select tin from public.contacts where id = v_buyer), 'C7777777770');
  perform pg_temp.check_eq('and its disagreement is waiting',
    (select count(*) from public.pending_tax_submissions(v_org)), 1);

  -- And the correction, on the same link.
  perform public.submit_tax_details(v_token,
    jsonb_build_object('tin', 'C7777777777', 'city', 'Kampar'));

  perform pg_temp.check_eq(
    'a correction does not overwrite what the first answer filled',
    (select tin from public.contacts where id = v_buyer), 'C7777777770');
  perform pg_temp.check_eq('the first answer stops waiting for review',
    (select count(*) from public.tax_detail_submissions
      where contact_id = v_buyer and superseded_at is not null), 1);
  -- One, not two. The superseded answer still disagrees with the
  -- contact -- 'Taiping' never landed -- so nothing but the supersede
  -- keeps it off this list, and a review list carrying both would show
  -- two rows contradicting each other with no way to tell which the
  -- customer meant.
  perform pg_temp.check_eq('and exactly one row is waiting',
    (select count(*) from public.pending_tax_submissions(v_org)), 1);
  perform pg_temp.check_eq('which is the corrected number',
    (select x ->> 'theirs'
       from public.pending_tax_submissions(v_org) p,
            jsonb_array_elements(p.conflicts) x
      where x ->> 'field' = 'tin'), 'C7777777777');
  perform pg_temp.check_eq('and the corrected city, not the first one',
    (select x ->> 'theirs'
       from public.pending_tax_submissions(v_org) p,
            jsonb_array_elements(p.conflicts) x
      where x ->> 'field' = 'city'), 'Kampar');

  -- Dismissed, it stops waiting and the contact keeps the typo -- which
  -- is the company's call to make and is recorded as such.
  perform public.dismiss_tax_submission(
    (select submission_id from public.pending_tax_submissions(v_org)));
  perform pg_temp.check_eq('a dismissed submission stops waiting',
    (select count(*) from public.pending_tax_submissions(v_org)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 7. A TIN is upper case, whoever typed it
-- ---------------------------------------------------------------------
-- `contact_editor.dart` upper-cases it on save and every other TIN in
-- the schema is upper. A customer typing theirs in lower case must not
-- create a second spelling of the same number, because `contact_lookalikes`
-- matches on it and two spellings are two companies.
do $$
declare
  v_org   uuid := pg_temp.test_org('Huruf Besar Sdn Bhd');
  v_buyer uuid;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B009', 'Huruf Kecil Sdn Bhd');
  perform public.submit_tax_details(pg_temp.a_link(v_buyer),
    jsonb_build_object('tin', 'c8888888888', 'id_value', 'jm0167410-v'));
  perform pg_temp.check_eq('a TIN typed in lower case is stored upper',
    (select tin from public.contacts where id = v_buyer), 'C8888888888');
  perform pg_temp.check_eq('and so is the identification number',
    (select id_value from public.contacts where id = v_buyer),
    'JM0167410-V');
end $$;

-- ---------------------------------------------------------------------
-- 8. One company's submissions are not another's
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_b     uuid;
  v_buyer uuid;
begin
  perform pg_temp.test_org('Syarikat A Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.test_org('Borang A Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_b := pg_temp.test_org('Borang B Sdn Bhd');

  v_buyer := pg_temp.a_contact(v_a, 'B010', 'Pelanggan A Sdn Bhd');
  update public.contacts set tin = 'C9999999990' where id = v_buyer;
  perform public.submit_tax_details(pg_temp.a_link(v_buyer),
    jsonb_build_object('tin', 'C9999999999'));

  perform pg_temp.check_eq('A sees the submission on its own contact',
    (select count(*) from public.pending_tax_submissions(v_a)), 1);
  perform pg_temp.check_eq('and B sees none of it',
    (select count(*) from public.pending_tax_submissions(v_b)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 9. The link goes to the form, not to the document page
-- ---------------------------------------------------------------------
-- 0494 exists because 0493 emailed every portal link on the document
-- route, and `open_shared_document` answered `invalid` to all of them.
-- This is the third path and the same mistake was available.
do $$
declare
  v_org   uuid := pg_temp.test_org('Laluan Sdn Bhd');
  v_buyer uuid;
  v_url   text;
begin
  insert into public.platform_settings (key, value)
  values ('site_url', '"https://books.example.my"'::jsonb)
  on conflict (key) do update set value = excluded.value;

  v_buyer := pg_temp.a_contact(v_org, 'B011', 'Laluan Betul Sdn Bhd');
  v_url := public.request_tax_details(v_buyer) ->> 'url';

  -- The whole string, not a suffix: written first as a `like '%tax-details%'`
  -- it passed for a builder that ignored the configured site, which is
  -- the hole 0494's own test had.
  perform pg_temp.check_eq(
    'the link goes to the form, on the site the platform is configured for',
    regexp_replace(v_url, '/[^/]+$', ''),
    'https://books.example.my/#/tax-details');
end $$;

-- ---------------------------------------------------------------------
-- 10. The invitation says what it is for
-- ---------------------------------------------------------------------
-- A request for a tax number arriving out of nowhere reads as the thing
-- people are warned about. It is queued, and it says why.
do $$
declare
  v_org   uuid := pg_temp.test_org('Jemputan Sdn Bhd');
  v_buyer uuid;
  v_body  text;
begin
  v_buyer := pg_temp.a_contact(v_org, 'B012', 'Terima Emel Sdn Bhd');
  perform pg_temp.a_link(v_buyer);

  select body into v_body from public.email_outbox
   where org_id = v_org and template_code = 'tax_details_request';

  perform pg_temp.check_true('the invitation is queued', v_body is not null);
  perform pg_temp.check_true('it names MyInvois as the reason',
    v_body like '%MyInvois%');
  perform pg_temp.check_true('and carries the link',
    v_body like '%/#/tax-details/%');
  perform pg_temp.check_true(
    'and says the page holds nothing about what they owe',
    v_body like '%amount owing%');
end $$;

rollback;
