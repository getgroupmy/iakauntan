-- =====================================================================
-- iAkauntan :: the conflict check, and the two figures on a matter
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/matter_conflicts.sql
--
-- `matters.opposing_party` has been a column since `0021` and nothing
-- wrote it, so "do we act for the people this new file is against" had
-- no answer in the data. Rule 3 of the Legal Profession (Practice and
-- Etiquette) Rules 1978 is what makes that the question a firm has to
-- be able to ask.
--
-- The check runs in both directions, and the assertions here are
-- separate for each, because a check that only looks one way is a check
-- that finds half the conflicts and reads like one that finds them all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.mc_client(p_org uuid, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, 'C-' || substr(gen_random_uuid()::text, 1, 6), p_name,
          'customer')
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Folding a name somebody typed
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the suffixes people vary are dropped',
    app.conflict_key('ABC Sdn. Bhd.'), app.conflict_key('ABC Sdn Bhd'));
  perform pg_temp.check_eq('and Berhad with them',
    app.conflict_key('Pinang Holdings Berhad'),
    app.conflict_key('Pinang Holdings Bhd'));
  perform pg_temp.check_eq('case and punctuation likewise',
    app.conflict_key('Lim, Tan & Partners'),
    app.conflict_key('LIM TAN AND PARTNERS'));
  -- Generous on purpose: a firm that writes the full style on one file
  -- and the short one on another has not recorded two companies, and a
  -- check that misses one is worth nothing.
  perform pg_temp.check_eq('the long style and the short one are one name',
    app.conflict_key('Pinang Holdings Berhad'), app.conflict_key('Pinang'));
  perform pg_temp.check_eq('and the spaces left behind are collapsed',
    app.conflict_key('Lim  Sdn  Bhd  Tan'), 'lim tan');
  perform pg_temp.check_true('but two different companies stay different',
    app.conflict_key('ABC Sdn Bhd') <> app.conflict_key('ABD Sdn Bhd'));
  perform pg_temp.check_true('and nothing folds to nothing',
    app.conflict_key('   ') is null);
  perform pg_temp.check_true('as does a name that was never given',
    app.conflict_key(null) is null);
end $$;

-- ---------------------------------------------------------------------
-- Both directions of a conflict
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Guaman Bersih Sdn Bhd');
  v_abc   uuid;
  v_xyz   uuid;
  v_new   uuid;
  v_first uuid;
  v_m     uuid;
  v_said  text;
  r       record;
begin
  v_abc := pg_temp.mc_client(v_org, 'ABC Sdn Bhd');
  v_xyz := pg_temp.mc_client(v_org, 'XYZ Enterprise');
  v_new := pg_temp.mc_client(v_org, 'Delta Trading Sdn Bhd');

  -- The firm acts for ABC, against Delta.
  v_first := public.open_matter(v_org, 'M-1', 'ABC v Delta', v_abc,
    'Delta Trading Sdn. Bhd.', 'litigation');
  perform pg_temp.check_eq('the file records who is on the other side',
    (select opposing_party from public.matters where id = v_first),
    'Delta Trading Sdn. Bhd.');
  perform pg_temp.check_true('and whose file it is',
    (select fee_earner is not null from public.matters where id = v_first));

  -- Direction one: a new file *against* somebody the firm acts for.
  begin
    perform public.open_matter(v_org, 'M-2', 'XYZ v ABC', v_xyz,
      'ABC Sdn. Bhd.', 'litigation');
    raise exception 'FAIL: a file was opened against the firm''s own client';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('acting against a client is caught',
    v_said like '%both sides%');
  perform pg_temp.check_true('and the first file is named',
    v_said like '%M-1%');
  perform pg_temp.check_true('with the rule that makes it matter',
    v_said like '%Rule 3%');

  select * into r from public.check_matter_conflict(v_org, v_xyz,
    'ABC Sdn. Bhd.');
  perform pg_temp.check_eq('the check says which way round it is',
    r.direction, 'we act for the other side');
  perform pg_temp.check_eq('and names the file', r.matter_no, 'M-1');

  -- Direction two: a new file *for* somebody the firm has acted
  -- against. Only checking the first direction finds half the
  -- conflicts and reads like finding them all.
  select * into r from public.check_matter_conflict(v_org, v_new, null);
  perform pg_temp.check_eq('acting for a former opponent is caught too',
    r.direction, 'we have acted against this client');
  perform pg_temp.check_eq('and names the same file', r.matter_no, 'M-1');

  begin
    perform public.open_matter(v_org, 'M-3', 'Delta advice', v_new, null,
      'corporate');
    raise exception 'FAIL: a file was opened for a former opponent';
  exception when sqlstate '23514' then null;
  end;

  -- The way through, which is what keeps the refusal honest: a
  -- conflict can be waived by informed consent in some circumstances,
  -- and the judgement is a solicitor's. It has to be written down.
  v_m := public.open_matter(v_org, 'M-3', 'Delta advice', v_new, null,
    'corporate', null, null, null, 0,
    'Unrelated retainer; both clients consented in writing on 3 March.');
  perform pg_temp.check_true('saying why lets the file open',
    v_m is not null);
  perform pg_temp.check_true('and the reason is on the file',
    (select notes from public.matters where id = v_m) like
      'Unrelated retainer%');

  -- Whitespace is not a reason. A box somebody pressed space in to get
  -- past the screen is the failure the note exists to prevent.
  begin
    perform public.open_matter(v_org, 'M-5', 'XYZ v ABC', v_xyz,
      'ABC Sdn. Bhd.', 'litigation', null, null, null, 0, '    ');
    raise exception 'FAIL: a blank note cleared a conflict';
  exception when sqlstate '23514' then null;
  end;

  -- No other side, no conflict, no note asked for.
  perform pg_temp.check_true('an unrelated file opens without a word',
    public.open_matter(v_org, 'M-4', 'Conveyancing',
      pg_temp.mc_client(v_org, 'Encik Rahman'), 'Bank Perumahan Bhd',
      'conveyancing') is not null);

  -- Re-asking M-1's own question does not report M-1: a file's client
  -- and its opponent are the two things being asked about, so it can
  -- never be its own answer. By now it does report M-3, because the
  -- firm has since taken Delta on — which is the conflict that arrived
  -- after the file was opened, and the reason to re-check at all.
  perform pg_temp.check_eq('a file is not its own conflict',
    (select count(*) from public.check_matter_conflict(
       v_org, v_abc, 'Delta Trading Sdn. Bhd.')
      where matter_no = 'M-1'), 0);
  perform pg_temp.check_eq('and the one that arrived afterwards is found',
    (select count(*) from public.check_matter_conflict(
       v_org, v_abc, 'Delta Trading Sdn. Bhd.')
      where matter_no = 'M-3'), 1);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Whose file it is
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Fail Siapa Sdn Bhd');
  v_cl   uuid;
  v_m    uuid;
  v_old  uuid;
  v_said text;
begin
  v_cl := pg_temp.mc_client(v_org, 'Sebuah Syarikat Sdn Bhd');

  begin
    insert into public.matters (org_id, matter_no, name, client_id, status)
    values (v_org, 'M-9', 'Nobody''s', v_cl, 'open');
    raise exception 'FAIL: an open file belonged to nobody';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an open file is somebody''s',
    v_said like '%whose matter it is%');

  -- Closed files are not. A matter archived years ago should not need
  -- a fee earner appointed to it before anything else can be corrected.
  insert into public.matters (org_id, matter_no, name, client_id, status)
  values (v_org, 'M-10', 'Long closed', v_cl, 'closed')
  returning id into v_old;
  perform pg_temp.check_true('a closed one need not be', v_old is not null);

  -- A row already in that state stays editable, because judging the
  -- row rather than the change would make a client's phone number
  -- uncorrectable until somebody decided whose file it was.
  alter table public.matters disable trigger matters_fee_earner_ck;
  insert into public.matters (org_id, matter_no, name, client_id, status)
  values (v_org, 'M-11', 'From before', v_cl, 'open') returning id into v_m;
  alter table public.matters enable trigger matters_fee_earner_ck;

  update public.matters set description = 'Corrected' where id = v_m;
  perform pg_temp.check_eq('a file from before the rule stays editable',
    (select description from public.matters where id = v_m), 'Corrected');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Billed past what was agreed
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Yuran Tetap Sdn Bhd');
  v_cl   uuid;
  v_m    uuid;
  v_free uuid;
  v_inv  uuid;
  r      record;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  v_cl := pg_temp.mc_client(v_org, 'Sebuah Syarikat Sdn Bhd');

  v_m := public.open_matter(v_org, 'M-1', 'Fixed fee advice', v_cl, null,
    'corporate', null, null, 5000, 300);
  -- A matter with no agreed fee is not over it; there is nothing to be
  -- over.
  v_free := public.open_matter(v_org, 'M-2', 'By the hour', v_cl, null,
    'litigation', null, null, null, 300);

  perform pg_temp.check_eq('nothing is over the fee to begin with',
    (select count(*) from public.report_matters_over_agreed_fee(v_org)), 0);

  -- Time recorded but not yet billed still counts: the question is what
  -- the client will be asked for, not what they have been asked for.
  insert into public.time_entries
    (org_id, matter_id, entry_date, description, minutes, hourly_rate)
  values (v_org, v_m, current_date, 'Drafting', 1200, 300);
  perform pg_temp.check_eq('unbilled time counts towards it',
    (select over_by from public.report_matters_over_agreed_fee(v_org)
      where matter_no = 'M-1'), 1000);

  -- And the matter with no agreed fee is not reported however much
  -- time goes on it.
  insert into public.time_entries
    (org_id, matter_id, entry_date, description, minutes, hourly_rate)
  values (v_org, v_free, current_date, 'Attendance', 6000, 300);
  perform pg_temp.check_eq('a matter with no agreed fee is not over it',
    (select count(*) from public.report_matters_over_agreed_fee(v_org)
      where matter_no = 'M-2'), 0);

  -- Once the time is billed it must not be counted twice: on the
  -- invoice and as unbilled time.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, matter_id)
  values (v_org, 'invoice', 'INV-1', current_date, v_cl, 'MYR', 1,
          'approved', v_m)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_inv, 1, 'Professional fees', 1, 6000);
  update public.time_entries set is_billed = true, invoice_id = v_inv
   where matter_id = v_m;

  select * into r from public.report_matters_over_agreed_fee(v_org)
   where matter_no = 'M-1';
  perform pg_temp.check_eq('billed time is counted once, not twice',
    r.over_by, 1000);
  perform pg_temp.check_eq('the invoice is what was billed', r.billed, 6000);
  perform pg_temp.check_eq('and nothing is waiting', r.unbilled, 0);
  perform pg_temp.check_eq('with the client named', r.client_name,
    'Sebuah Syarikat Sdn Bhd');

  -- A voided invoice was never billed.
  update public.sales_documents set status = 'void' where id = v_inv;
  perform pg_temp.check_eq('a voided invoice is not billing',
    (select count(*) from public.report_matters_over_agreed_fee(v_org)
      where matter_no = 'M-1'), 0);

  -- Agreed to act for nothing. Reporting that back as an overrun is
  -- reporting the firm's own decision to it.
  update public.matters set agreed_fee = 0 where id = v_free;
  perform pg_temp.check_eq('a pro bono file is not over its fee',
    (select count(*) from public.report_matters_over_agreed_fee(v_org)
      where matter_no = 'M-2'), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may ask
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Siapa Boleh Sdn Bhd');
  v_cl  uuid;
  v_m   uuid;
  v_out uuid := pg_temp.another_user('outsider@mc.test');
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  v_cl := pg_temp.mc_client(v_org, 'Sebuah Syarikat Sdn Bhd');
  v_m := public.open_matter(v_org, 'M-1', 'Advice', v_cl, 'Somebody Bhd',
    'corporate', null, null, 1000, 300);
  -- Enough time on it to be over the agreed fee, and a client whose
  -- name a conflict check will match. Both so that "closed to an
  -- outsider" is an assertion about who is asking rather than about a
  -- firm with nothing on its books.
  insert into public.time_entries
    (org_id, matter_id, entry_date, description, minutes, hourly_rate)
  values (v_org, v_m, current_date, 'Advice', 600, 300);

  perform pg_temp.check_eq('the firm sees its own conflict',
    (select count(*) from public.check_matter_conflict(
       v_org, null, 'Sebuah Syarikat Sdn Bhd')), 1);
  perform pg_temp.check_eq('and its own overrun',
    (select count(*) from public.report_matters_over_agreed_fee(v_org)), 1);

  -- The conflict list is the firm's client list read sideways.
  perform pg_temp.sign_in_as(v_out);
  perform pg_temp.check_eq('the conflict check is closed to an outsider',
    (select count(*) from public.check_matter_conflict(
       v_org, null, 'Sebuah Syarikat Sdn Bhd')), 0);
  perform pg_temp.check_eq('and the fee report',
    (select count(*) from public.report_matters_over_agreed_fee(v_org)), 0);
  begin
    perform public.open_matter(v_org, 'M-2', 'Advice', v_cl, null);
    raise exception 'FAIL: an outsider opened a matter';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A firm that did not buy the module
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Bukan Guaman Sdn Bhd',
                  array['accounting', 'sales']);
  v_cl  uuid;
begin
  v_cl := pg_temp.mc_client(v_org, 'Sebuah Syarikat Sdn Bhd');
  begin
    perform public.open_matter(v_org, 'M-1', 'Advice', v_cl, null);
    raise exception 'FAIL: a company without the module opened a matter';
  exception when sqlstate '42501' then null;
  end;
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the conflict check is closed to anon',
    not has_function_privilege('anon',
      'public.check_matter_conflict(uuid, uuid, text)', 'execute'));
  perform pg_temp.check_true('and opening a matter',
    not has_function_privilege('anon',
      'public.open_matter(uuid, text, text, uuid, text, text, uuid, uuid, '
      'numeric, numeric, text)', 'execute'));
  perform pg_temp.check_true('and the agreed fee report',
    not has_function_privilege('anon',
      'public.report_matters_over_agreed_fee(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may check',
    has_function_privilege('authenticated',
      'public.check_matter_conflict(uuid, uuid, text)', 'execute'));
end $$;

rollback;
