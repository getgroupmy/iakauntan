-- =====================================================================
-- iAkauntan :: saying no, and who lodged it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/decline_and_lodge.sql
--
-- Two things the corporate secretarial file could not record.
--
-- `app.signature_status` has had `declined` since `0069` and
-- `corp_signatures.decline_reason` with it, and nothing could produce
-- either. So a director who would not sign looked exactly like one who
-- had not opened the email — and the difference is whether to send a
-- reminder or to redo the resolution.
--
-- And `corp_filings.lodged_by` and `fee_paid` were never written: the
-- app marked a lodgement with a bare update, and its only check — that
-- the date is not in the future — lived in Dart, which is to say
-- nowhere.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_e     uuid;
  v_a     uuid;
  v_b     uuid;
  v_doc   uuid;
  v_req   uuid;
  v_sig_a uuid;
  v_sig_b uuid;
  v_said  text;
  r       record;
begin
  v_org := pg_temp.test_org('Enggan Tandatangan Sdn Bhd', array['secretarial']);

  insert into public.corp_entities
    (org_id, name, registration_no, entity_type, incorporated_on,
     financial_year_end_day, financial_year_end_month, registered_office)
  values (v_org, 'Tandatangan Sdn Bhd', '202401011111', 'sdn_bhd',
          date '2024-03-12', 31, 12, 'Level 8, Menara ABC, KL')
  returning id into v_e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director One', '900101011111')
  returning id into v_a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (v_org, 'individual', 'Director Two', '900202022222')
  returning id into v_b;
  insert into public.corp_officers
    (org_id, entity_id, person_id, role, appointed_on)
  values (v_org, v_e, v_a, 'director', date '2024-03-12'),
         (v_org, v_e, v_b, 'director', date '2024-03-12');

  v_doc := public.corp_generate_document(v_e, 'sec_particulars');
  v_req := public.corp_request_signatures(v_doc, array[v_a, v_b],
             array['Director', 'Director'], current_date + 7, null);
  select id into v_sig_a from public.corp_signatures
   where request_id = v_req and person_id = v_a;
  select id into v_sig_b from public.corp_signatures
   where request_id = v_req and person_id = v_b;

  -- ------------------------------------------------------------------
  -- A refusal has to say why
  -- ------------------------------------------------------------------
  begin
    perform public.corp_decline_signature(v_sig_a, '   ');
    raise exception 'FAIL: a signature was declined with no reason';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a refusal with no reason is refused',
    v_said like '%Say why%');
  perform pg_temp.check_eq('and the line is still pending',
    (select status::text from public.corp_signatures where id = v_sig_a),
    'pending');

  perform public.corp_decline_signature(
    v_sig_a, 'The third resolution misstates the consideration.');
  perform pg_temp.check_eq('declined is reachable at last',
    (select status::text from public.corp_signatures where id = v_sig_a),
    'declined');
  perform pg_temp.check_eq('with the reason kept',
    (select decline_reason from public.corp_signatures where id = v_sig_a),
    'The third resolution misstates the consideration.');
  -- A refusal is a fact about the document too, and worth the same
  -- evidence a signature carries.
  perform pg_temp.check_true('and attributed to whoever did it',
    (select signed_by is not null from public.corp_signatures
      where id = v_sig_a));
  -- It is not a signature. Nothing downstream should read it as one.
  perform pg_temp.check_true('a declined line has signed nothing',
    (select signed_at is null and signed_name is null
       from public.corp_signatures where id = v_sig_a));

  -- Once said, it is said.
  begin
    perform public.corp_decline_signature(v_sig_a, 'Changed my mind');
    raise exception 'FAIL: a declined line was declined twice';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a declined line cannot be declined again',
    v_said like '%already declined%');

  -- And a refusal is not a signature waiting to happen.
  begin
    perform public.corp_sign_document(v_sig_a, 'Director One');
    raise exception 'FAIL: a declined line was then signed';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor signed afterwards',
    v_said like '%already declined%');

  -- The other director is untouched by the first one's refusal. A
  -- dissent is one person's.
  perform pg_temp.check_eq('the other line is still pending',
    (select status::text from public.corp_signatures where id = v_sig_b),
    'pending');
  perform public.corp_sign_document(v_sig_b, 'Director Two');
  perform pg_temp.check_eq('and can still be signed',
    (select status::text from public.corp_signatures where id = v_sig_b),
    'signed');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The lodgement, and the two things it never recorded
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_e    uuid;
  v_f     uuid;
  v_said  text;
  r       record;
  -- The company's own day, not the server's. Postgres runs in UTC here
  -- and the business is in UTC+8, so for eight hours of every day
  -- `current_date` is yesterday as far as the guard is concerned — and a
  -- test written against `current_date + 1` passes all morning and fails
  -- all evening. The function measures Malaysia's day, so this does too.
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Failkan Sdn Bhd', array['secretarial']);
  insert into public.corp_entities
    (org_id, name, entity_type, incorporated_on, registered_office)
  values (v_org, 'Failkan Sdn Bhd', 'sdn_bhd', date '2020-01-15',
          'No 1, Jalan Lama, 50000 Kuala Lumpur')
  returning id into v_e;

  -- An event a fortnight ago, and its filing.
  v_f := public.corp_open_filing(v_e, 'change_registered_office',
                                 v_today - 5);

  -- A lodgement is something that has happened.
  begin
    perform public.corp_mark_lodged(v_f, v_today + 1);
    raise exception 'FAIL: a filing was lodged tomorrow';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a future lodgement is refused',
    v_said like '%in the future%');

  -- Nor before the thing it notifies.
  begin
    perform public.corp_mark_lodged(v_f, v_today - 30);
    raise exception 'FAIL: a filing was lodged before the event';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor one lodged before the event it notifies',
    v_said like '%before the event it notifies%');

  begin
    perform public.corp_mark_lodged(v_f, v_today, 'SSM-1', -5);
    raise exception 'FAIL: a negative fee was accepted';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a negative fee is not a fee',
    v_said like '%not negative%');

  perform public.corp_mark_lodged(v_f, v_today - 1, ' SSM-2026-0099 ',
                                  60.00);
  select * into r from public.corp_filings f where f.id = v_f;
  perform pg_temp.check_eq('the filing is lodged', r.status::text, 'lodged');
  perform pg_temp.check_eq('on the day given', r.lodged_on::text,
    (v_today - 1)::text);
  perform pg_temp.check_eq('with the reference, trimmed',
    r.ssm_reference, 'SSM-2026-0099');
  -- The two the file could never say. Whose filing it was, and what SSM
  -- charged for it — a fee nobody wrote down is a fee nobody bills.
  perform pg_temp.check_true('and a name against it',
    r.lodged_by is not null);
  perform pg_temp.check_eq('and the fee to recharge', r.fee_paid, 60.00);

  -- Lodging twice would write over the reference SSM gave it.
  begin
    perform public.corp_mark_lodged(v_f, v_today, 'SSM-DIFFERENT');
    raise exception 'FAIL: a lodged filing was lodged again';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and it cannot be lodged twice',
    v_said like '%write over the reference%');
  perform pg_temp.check_eq('the first reference stands',
    (select ssm_reference from public.corp_filings where id = v_f),
    'SSM-2026-0099');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('declining is closed to anon',
    not has_function_privilege('anon',
      'public.corp_decline_signature(uuid, text)', 'execute'));
  -- Except through a link, exactly as signing is: the token is the
  -- credential, and somebody refusing to sign has no account here.
  perform pg_temp.check_true('but open to anon through a scoped link',
    has_function_privilege('anon',
      'public.corp_decline_with_link(text, text)', 'execute'));
  perform pg_temp.check_true('and recording a lodgement is closed to anon',
    not has_function_privilege('anon',
      'public.corp_mark_lodged(uuid, date, text, numeric)', 'execute'));
end $$;

rollback;
