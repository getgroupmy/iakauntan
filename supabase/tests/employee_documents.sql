-- =====================================================================
-- iAkauntan :: the documents that expire, and the list that reads them
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/employee_documents.sql
--
-- `0025` built an index on `(org_id, expires_date)` for a list that was
-- never written, so a lapsing work permit could only be found by
-- opening every employee record in turn. Employing somebody whose Pass
-- has expired is the employer's offence under s.55B of the Immigration
-- Act 1959/63, charged per person, so the list is not a convenience.
--
-- The assertions:
--
--   * the two rules the dialog carried alone are in the database;
--   * `uploaded_by` is written once, by the person who filed it;
--   * a renewal retires what it replaces, and the retired one leaves
--     the list — a list that is mostly noise is a list nobody reads;
--   * an expired permit on an expatriate is reported as an offence and
--     sorted above everything else, and a leaver's is not reported at
--     all.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ed_employee(
  p_org uuid, p_no text, p_name text, p_residency text default 'citizen',
  p_status text default 'active')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status,
     -- `0371` refuses a leaver with no last working day, because the
     -- payroll run goes by the date and not by the status. A fixture
     -- that wants a leaver has to make a real one.
     last_working_date)
  values (p_org, p_no, p_name, date '2020-01-01', 3000,
          date '1990-01-01', p_residency::app.residency_status,
          p_status::app.employment_status,
          case when p_status in ('resigned', 'terminated', 'retired')
               then current_date - 30 end)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- The rules the dialog was carrying alone
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Dokumen Pekerja Sdn Bhd');
  v_emp  uuid;
  v_doc  uuid;
  v_said text;
begin
  v_emp := pg_temp.ed_employee(v_org, 'E1', 'Encik Rahim');

  -- A kind the dialog does not offer is a kind no report can group.
  begin
    insert into public.employee_documents
      (org_id, employee_id, doc_type, title)
    values (v_org, v_emp, 'work_permit', 'Pass');
    raise exception 'FAIL: a document of an unknown kind was recorded';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the kinds are the five there are',
    v_said like '%employee_documents_kind_ck%');

  -- Expiring before it was issued.
  begin
    insert into public.employee_documents
      (org_id, employee_id, doc_type, title, issued_date, expires_date)
    values (v_org, v_emp, 'permit', 'Pass', date '2026-06-01',
            date '2026-01-01');
    raise exception 'FAIL: a document expired before it was issued';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a document does not expire before it '
    'was issued', v_said like '%employee_documents_dates_ck%');

  -- Either date alone is ordinary and neither is refused.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_emp, 'permit', 'Employment Pass', date '2026-12-31')
  returning id into v_doc;
  perform pg_temp.check_true('an expiry with no issue date is allowed',
    v_doc is not null);

  -- Filed by whoever filed it, and not by whoever edits it next.
  perform pg_temp.check_eq('the person who filed it is recorded',
    (select uploaded_by from public.employee_documents where id = v_doc),
    pg_temp.test_user());

  perform pg_temp.sign_in_as(pg_temp.another_user('other-hr@ed.test'));
  -- Made a member so the row policy lets the update through; the point
  -- under test is the column, not the policy.
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, auth.uid(), 'hr_manager', 'active')
  on conflict (org_id, user_id) do update set role = 'hr_manager';
  -- Writing the column directly, not merely editing the row. An update
  -- that never mentions `uploaded_by` leaves it alone by itself, so a
  -- fixture that only edits the title proves nothing about the rule.
  update public.employee_documents
     set title = 'Employment Pass (copy)', uploaded_by = auth.uid()
   where id = v_doc;
  perform pg_temp.check_eq('and is not replaced by whoever edits it next',
    (select uploaded_by from public.employee_documents where id = v_doc),
    pg_temp.test_user());
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A renewal retires what it replaces
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Pembaharuan Sdn Bhd');
  v_emp  uuid;
  v_old  uuid;
  v_new  uuid;
  v_said text;
  v_n    integer;
  v_row  record;
  v_today date := current_date;
begin
  v_emp := pg_temp.ed_employee(v_org, 'E1', 'Mr Chen', 'expatriate');

  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, issued_date, expires_date,
     notes)
  values (v_org, v_emp, 'permit', 'Employment Pass',
          v_today - 700, v_today + 20, 'Category II')
  returning id into v_old;

  select count(*)::integer into v_n
    from public.report_expiring_documents(v_org, 60);
  perform pg_temp.check_eq('the pass about to lapse is on the list', v_n, 1);

  -- A renewal that runs no further is not a renewal.
  begin
    perform public.renew_employee_document(v_old, v_today + 10);
    raise exception 'FAIL: a renewal expired before what it replaced';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a renewal runs past the one it replaces',
    v_said like '%runs past the document it replaces%');

  -- And one with no new expiry is nothing at all.
  begin
    perform public.renew_employee_document(v_old, null);
    raise exception 'FAIL: a renewal was recorded with no expiry';
  exception when sqlstate '23502' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and has a date to run to',
    v_said like '%A renewal has a new expiry date%');

  v_new := public.renew_employee_document(v_old, v_today + 400);

  -- Everything not given again is carried across: retyping the kind is
  -- how a renewed permit comes out as something else.
  select * into v_row from public.employee_documents where id = v_new;
  perform pg_temp.check_eq('the renewal is the same kind',
    v_row.doc_type, 'permit');
  perform pg_temp.check_eq('with the same title',
    v_row.title, 'Employment Pass');
  perform pg_temp.check_eq('the same notes', v_row.notes, 'Category II');
  perform pg_temp.check_eq('and runs from where the old one stopped',
    v_row.issued_date::text, (v_today + 20)::text);
  perform pg_temp.check_eq('and says what it replaced',
    v_row.supersedes_id, v_old);

  -- The retired one leaves the list, and the new one is not on it yet.
  select count(*)::integer into v_n
    from public.report_expiring_documents(v_org, 60);
  perform pg_temp.check_eq(
    'a replaced document is off the list, and the new one is not due',
    v_n, 0);
  select count(*)::integer into v_n
    from public.report_expiring_documents(v_org, 500);
  perform pg_temp.check_eq('the new one appears when the window reaches it',
    v_n, 1);

  -- Renewing the one that was already renewed is renewing the wrong one.
  begin
    perform public.renew_employee_document(v_old, v_today + 800);
    raise exception 'FAIL: a superseded document was renewed again';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('renew the one that replaced it',
    v_said like '%already been renewed%');

  -- And not around the function either. The function's refusal is the
  -- readable one; the index is the one that holds, because a row can
  -- be written straight through PostgREST without passing the function
  -- at all — and two successors means "which is current" has two
  -- answers and the list has to guess.
  begin
    insert into public.employee_documents
      (org_id, employee_id, doc_type, title, expires_date, supersedes_id)
    values (v_org, v_emp, 'permit', 'A second successor',
            v_today + 900, v_old);
    raise exception 'FAIL: one document was superseded twice';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('one successor, and the index says so',
    v_said like '%employee_documents_one_successor%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Whose offence it is
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Imigresen Sdn Bhd');
  v_expat uuid;
  v_local uuid;
  v_gone  uuid;
  v_out   uuid := pg_temp.another_user('outsider@ed.test');
  v_said  text;
  v_first record;
  v_n     integer;
  -- Today in Kuala Lumpur. `report_expiring_documents` counts from the
  -- Malaysian day since `0419`; on `current_date` the pass that expired
  -- three days ago was reported as four for the eight hours the two
  -- zones disagree.
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_expat := pg_temp.ed_employee(v_org, 'E1', 'Mr Tanaka', 'foreign_worker');
  v_local := pg_temp.ed_employee(v_org, 'E2', 'Cik Aminah', 'citizen');
  v_gone  := pg_temp.ed_employee(v_org, 'E3', 'Mr Silva', 'expatriate',
                                 'resigned');

  -- An expired pass on somebody still employed.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_expat, 'permit', 'Visit Pass (Temporary Employment)',
          v_today - 3);
  -- A certificate lapsing sooner, to prove the ordering is by
  -- consequence and not by date.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_local, 'certificate', 'Safety officer competency',
          v_today - 20);
  -- And a leaver's expired pass, which is not the company's offence.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_gone, 'permit', 'Employment Pass', v_today - 40);

  select count(*)::integer into v_n
    from public.report_expiring_documents(v_org, 60);
  perform pg_temp.check_eq('a leaver''s lapsed pass is not reported',
    v_n, 2);

  select * into v_first from public.report_expiring_documents(v_org, 60)
   limit 1;
  perform pg_temp.check_eq('the offence is first, whatever the dates say',
    v_first.consequence, 'offence');
  perform pg_temp.check_eq('and it is the expatriate''s',
    v_first.employee_no, 'E1');
  perform pg_temp.check_true('and it is flagged expired',
    v_first.is_expired);
  perform pg_temp.check_eq('and counted in days', v_first.days_until, -3);

  perform pg_temp.check_eq('the certificate is a renewal to chase',
    (select consequence from public.report_expiring_documents(v_org, 60)
      where employee_no = 'E2'), 'renewal');

  -- A citizen cannot hold a lapsed work permit as an offence: there is
  -- no pass to lapse.
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_local, 'permit', 'Site pass', v_today - 1);
  perform pg_temp.check_eq('a citizen''s expired permit is not s.55B',
    (select consequence from public.report_expiring_documents(v_org, 60)
      where employee_no = 'E2' and title = 'Site pass'), 'renewal');

  -- Personal data. An outsider reads none of it, and is refused by this
  -- function's own guard rather than by the policies behind it.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform count(*) from public.report_expiring_documents(v_org, 60);
    raise exception 'FAIL: an outsider read the document list';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not permitted to read employee documents',
    v_said like '%not permitted to read employee documents%');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may renew
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Siapa Boleh Baharu Sdn Bhd');
  v_emp  uuid;
  v_doc  uuid;
  v_out  uuid := pg_temp.another_user('nobody@ed.test');
  v_said text;
begin
  v_emp := pg_temp.ed_employee(v_org, 'E1', 'Encik Ali');
  insert into public.employee_documents
    (org_id, employee_id, doc_type, title, expires_date)
  values (v_org, v_emp, 'certificate', 'First aid', current_date + 30)
  returning id into v_doc;

  perform pg_temp.sign_in_as(v_out);
  begin
    perform public.renew_employee_document(v_doc, current_date + 400);
    raise exception 'FAIL: an outsider renewed a document';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not permitted to renew',
    v_said like '%not permitted to renew an employee document%');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- A document that is not there is not a document. Catching both
  -- codes on purpose: without the existence check the call falls
  -- through to `can_manage_hr(null)` and is refused as a permission
  -- problem, which is a true refusal for an untrue reason — and the
  -- person reading it goes looking for a role they already have.
  begin
    perform public.renew_employee_document(
      '00000000-0000-0000-0000-000000000000', current_date + 400);
    raise exception 'FAIL: a document that does not exist was renewed';
  exception when sqlstate 'P0002' or sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('no such document, said as such',
    v_said like '%No such document%');

  perform pg_temp.sign_out();
end $$;

rollback;
