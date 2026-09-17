-- =====================================================================
-- iAkauntan :: billing a matter's time
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/matter_billing.sql
--
-- bill_matter_time and bill_project_time are two doors into one room:
-- both are eight-line wrappers around app.bill_time_internal, which
-- resolves the rate, groups a line per fee earner, rounds the hours
-- once at the end, marks the entries billed and posts the invoice.
-- timesheets.sql already drives all of that through the project door,
-- and none of it is repeated here.
--
-- Four things are the matter door's own, and none was tested:
--
--   the module gate is `legal` and not `timesheets`
--   the invoice goes to the matter's client, m.client_id
--   the time billed is the matter's, matched on matter_id
--   the subject names the matter
--
-- The third is the one with money in it. app.bill_time_internal selects
-- with `t.project_id is not distinct from p_project_id and t.matter_id
-- is not distinct from p_matter_id`, so billing one matter must not
-- sweep up another's time, or a project's, or a client's whose work has
-- nothing to do with it.
--
-- That matching is only safe because a time entry can carry a project
-- or a matter and not both -- the time_entries_one_anchor constraint --
-- so an entry with both set would be billed by neither door and sit
-- unbilled for ever while the timesheet report went on counting it.
-- The constraint is asserted below for that reason.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_owner   uuid := pg_temp.test_user();
  v_aminah  uuid;
  v_rajan   uuid;
  v_m1      uuid;
  v_m2      uuid;
  v_proj    uuid;
  v_inv     uuid;
  v_msg     text;
  r         record;
  v_n       integer;
  v_total   numeric;
begin
  -- A law firm: legal, and deliberately not timesheets. The two are
  -- separate purchases, and the assertion at the end depends on this
  -- fixture withholding the other one.
  v_org := pg_temp.test_org('Guaman Probe & Rakan', array['legal']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'legal', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_aminah;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL2', 'Encik Rajan', 'customer') returning id into v_rajan;

  insert into public.matters
    (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_aminah, pg_temp.test_user())
  returning id into v_m1;
  insert into public.matters
    (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-2', 'A tenancy dispute', v_rajan, pg_temp.test_user())
  returning id into v_m2;

  insert into public.billing_rates
    (org_id, user_id, effective_from, hourly_rate)
  values (v_org, v_owner, date '2026-01-01', 400);

  -- Three hours on Puan Aminah's matter, and two on Encik Rajan's.
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, minutes, is_billable)
  values (v_org, v_m1, v_owner, date '2026-02-10', 'Drafting', 90, true),
         (v_org, v_m1, v_owner, date '2026-02-11', 'Attendance', 90, true),
         (v_org, v_m2, v_owner, date '2026-02-11', 'Advice', 120, true);

  -- And an hour that is not chargeable, which must not reach a bill.
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, minutes, is_billable)
  values (v_org, v_m1, v_owner, date '2026-02-12', 'Filing', 60, false);

  -- ==================================================================
  -- One matter's bill is one matter's work
  -- ==================================================================
  v_inv := public.bill_matter_time(v_m1, date '2026-02-01', date '2026-02-28');

  select * into r from public.sales_documents where id = v_inv;
  perform pg_temp.check_eq('the bill goes to the matter''s client',
    r.contact_id, v_aminah);
  perform pg_temp.check_eq('and names the matter', r.subject,
    'Professional fees — Sale of a house');
  perform pg_temp.check_eq('over the period asked for', r.reference,
    '2026-02-01 to 2026-02-28');

  -- Three chargeable hours at RM400. The unchargeable hour is not on it,
  -- and neither is Encik Rajan's.
  select sum(l.line_subtotal) into v_total
    from public.sales_document_lines l where l.document_id = v_inv;
  perform pg_temp.check_eq('three hours at four hundred', v_total, 1200.00);
  perform pg_temp.check_eq('on one line, because one person did the work',
    (select count(*) from public.sales_document_lines
      where document_id = v_inv), 1);

  perform pg_temp.check_eq('the matter''s chargeable time is marked billed',
    (select count(*) from public.time_entries
      where matter_id = v_m1 and is_billed), 2);
  perform pg_temp.check_eq('and carries the invoice it went on',
    (select count(distinct invoice_id) from public.time_entries
      where matter_id = v_m1 and is_billed), 1);
  perform pg_temp.check_true('the unchargeable hour is untouched',
    (select not is_billed from public.time_entries
      where matter_id = v_m1 and not is_billable));

  -- The assertion with the money in it.
  perform pg_temp.check_eq('the other matter''s time was not swept up',
    (select count(*) from public.time_entries
      where matter_id = v_m2 and is_billed), 0);

  -- Billing the same period twice has nothing left to bill.
  begin
    perform public.bill_matter_time(v_m1, date '2026-02-01', date '2026-02-28');
    raise exception 'FAIL: the same time was billed twice';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and cannot be billed a second time';
  end;

  -- Encik Rajan's matter still bills, to Encik Rajan.
  v_inv := public.bill_matter_time(v_m2, date '2026-02-01', date '2026-02-28');
  perform pg_temp.check_eq('the second matter bills to its own client',
    (select contact_id from public.sales_documents where id = v_inv),
    v_rajan);
  perform pg_temp.check_eq('for its own two hours',
    (select sum(line_subtotal) from public.sales_document_lines
      where document_id = v_inv), 800.00);

  -- ==================================================================
  -- What it refuses
  -- ==================================================================
  begin
    perform public.bill_matter_time(
      gen_random_uuid(), date '2026-02-01', date '2026-02-28');
    raise exception 'FAIL: a matter that does not exist was billed';
  exception when sqlstate 'P0002' then
    raise notice 'ok   there has to be a matter';
  end;

  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, minutes, is_billable)
  values (v_org, v_m1, v_owner, date '2026-03-05', 'More drafting', 60, true);

  begin
    perform public.bill_matter_time(v_m1, date '2026-03-31', date '2026-03-01');
    raise exception 'FAIL: a period that ends before it starts was billed';
  exception when sqlstate '22023' then
    raise notice 'ok   the period has to end after it starts';
  end;

  -- ==================================================================
  -- A time entry belongs to a matter or to a project, never both
  --
  -- app.bill_time_internal matches on both columns with `is not
  -- distinct from`, so an entry carrying a project and a matter at once
  -- would be reached by neither door: unbillable for ever, and still
  -- counted as unbilled by report_timesheet. The constraint is what
  -- stops that existing.
  -- ==================================================================
  insert into public.projects (org_id, code, name, contact_id)
  values (v_org, 'P1', 'A project', v_aminah) returning id into v_proj;
  begin
    insert into public.time_entries
      (org_id, project_id, matter_id, user_id, entry_date, description,
       minutes, is_billable)
    values (v_org, v_proj, v_m1, v_owner, date '2026-03-06', 'Both at once',
            60, true);
    raise exception 'FAIL: a time entry was anchored to both';
  exception when sqlstate '23514' then
    raise notice 'ok   time is recorded against a matter or a project, not both';
  end;

  -- ==================================================================
  -- The two modules are two modules
  --
  -- This firm bought legal and not timesheets. Matter billing works and
  -- project billing does not, which is the only thing that makes them
  -- separate purchases rather than one with two names.
  -- ==================================================================
  begin
    perform public.bill_project_time(
      v_proj, date '2026-03-01', date '2026-03-31');
    raise exception
      'FAIL: project billing ran for a firm that has not bought timesheets';
  exception when sqlstate '42501' then
    raise notice 'ok   project billing refuses a legal-only firm';
  end;

  -- And the other way round: switch legal off and matter billing stops,
  -- even though the timesheet data is all still there.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'legal';
  begin
    perform public.bill_matter_time(v_m1, date '2026-03-01', date '2026-03-31');
    raise exception 'FAIL: matter billing ran with the legal module off';
  exception when sqlstate '42501' then
    raise notice 'ok   and matter billing refuses without the legal module';
  end;
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'legal';

  -- ==================================================================
  -- Who may raise it
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.bill_matter_time(v_m1, date '2026-03-01', date '2026-03-31');
    raise exception 'FAIL: a stranger billed a matter';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot bill somebody else''s matter';
  end;
  perform pg_temp.sign_out();
end $$;

rollback;
