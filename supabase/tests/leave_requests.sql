-- =====================================================================
-- iAkauntan :: filing leave, and deciding it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/leave_requests.sql
--
-- Leave looks like an HR formality until you follow where it goes.
-- calculate_payroll_run reads approved requests whose leave type is not
-- paid and turns them into a negative earning line -- payroll_run.sql's
-- W3 is exactly that -- so an approved unpaid request comes off gross
-- pay, off the EPF wage, off the SOCSO and EIS wages and off taxable
-- income. Who may file one, and who may approve it, decides somebody's
-- statutory figures.
--
-- Neither function was called by a test, and submit_leave_request's
-- permission guard did not work: `v_emp <> app.my_employee_id(p_org_id)`
-- goes null for a caller with no employee record, and a null condition
-- never raises. 0283 makes the comparison null-safe. The first section
-- below is the regression test for it.
--
-- The last section is about a different silence. `contact_while_away`
-- has been a column on the table since 0027 and nothing ever wrote it,
-- because the only write path is a SECURITY DEFINER function that had
-- no parameter for it -- no form field could have reached it. 0395
-- gives it, lets the person who is away correct it, and gives it a
-- reader.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org      uuid;
  v_owner    uuid := pg_temp.test_user();
  v_clerk    uuid;
  v_boss     uuid;
  v_staff    uuid;
  v_e_boss   uuid;
  v_e_staff  uuid;
  v_annual   uuid;
  v_unpaid   uuid;
  v_req      uuid;
  v_req2     uuid;
  v_unpaid_req uuid;
  v_other    uuid;
  v_e_other  uuid;
  v_away     uuid;
  v_past     uuid;
  v_far      uuid;
  v_half     uuid;
  v_whole    uuid;
  v_bal      numeric;
  r          record;
  v_msg      text;
begin
  v_org := pg_temp.test_org('Cuti Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

  v_boss  := pg_temp.another_user('manager@example.test');
  v_staff := pg_temp.another_user('staff@example.test');
  v_clerk := pg_temp.another_user('clerk@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_boss,  'viewer', 'active'),
         (v_org, v_staff, 'viewer', 'active'),
         -- A member with a real role, real access, and no employee
         -- record of their own. This is the account the guard missed.
         (v_org, v_clerk, 'accounts_clerk', 'active');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id)
  values (v_org, 'E1', 'Puan Siti', date '2020-01-01', 8000,
          date '1985-01-01', 'citizen', v_boss)
  returning id into v_e_boss;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id, manager_id)
  values (v_org, 'E2', 'Encik Zul', date '2021-01-01', 4000,
          date '1995-01-01', 'citizen', v_staff, v_e_boss)
  returning id into v_e_staff;

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'AL', 'Annual leave', true) returning id into v_annual;
  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'UNPAID', 'Unpaid leave', false) returning id into v_unpaid;

  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days)
  values (v_org, v_e_staff, v_annual, 2026, 8);

  -- ==================================================================
  -- Filing for somebody else
  -- ==================================================================
  -- The regression test. Before 0283 the accounts clerk -- a member of
  -- the company, not HR, with no employee record -- could file leave
  -- against anybody, because the guard compared against a null and a
  -- null condition does not raise.
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('the clerk really has no employee record',
    app.my_employee_id(v_org) is null);
  perform pg_temp.check_true('and really is not HR',
    not app.can_manage_hr(v_org));
  begin
    perform public.submit_leave_request(
      v_org, v_unpaid, date '2026-03-02', date '2026-03-06', 5,
      'Not mine to file', false, null, v_e_staff);
    raise exception
      'FAIL: a member with no employee record filed leave for somebody else';
  exception when sqlstate '42501' then
    raise notice 'ok   a member who is not HR cannot file leave for another';
  end;
  perform pg_temp.check_eq('and nothing was filed',
    (select count(*) from public.leave_requests where org_id = v_org), 0);
  -- Nor is a hold left behind on the balance the request never reached.
  perform pg_temp.check_eq('nor held against anybody''s balance',
    (select coalesce(sum(pending_days), 0) from public.leave_balances
      where org_id = v_org), 0);

  -- Filing for themselves is a different refusal: there is nobody to
  -- file for, which is P0002 rather than a permission error.
  begin
    perform public.submit_leave_request(
      v_org, v_unpaid, date '2026-03-02', date '2026-03-06', 5);
    raise exception 'FAIL: somebody with no employee record filed their own leave';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and cannot file their own, having no record to file it against';
  end;

  -- HR may, which is what the guard exists to allow.
  perform pg_temp.sign_in_as(v_owner);
  v_req := public.submit_leave_request(
    v_org, v_annual, date '2026-04-06', date '2026-04-07', 2,
    'Filed by HR', false, null, v_e_staff);
  perform pg_temp.check_eq('HR may file for an employee',
    (select employee_id from public.leave_requests where id = v_req),
    v_e_staff);
  perform pg_temp.check_eq('and it is submitted, not approved',
    (select status::text from public.leave_requests where id = v_req),
    'submitted');
  perform pg_temp.check_eq('numbered from the leave series',
    left((select request_no from public.leave_requests where id = v_req), 3),
    'LV-');

  -- ==================================================================
  -- The hold on the balance
  -- ==================================================================
  perform pg_temp.check_eq('a submitted request is held against the balance',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 2);
  perform pg_temp.check_eq('and nothing is taken yet',
    (select taken_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 0);

  -- Eight days entitled, two held. Seven more would fit the entitlement
  -- but not the entitlement less the hold, which is the whole reason
  -- the hold exists: two requests must not each pass a check the pair
  -- of them would fail.
  perform pg_temp.sign_in_as(v_staff);
  begin
    perform public.submit_leave_request(
      v_org, v_annual, date '2026-05-04', date '2026-05-12', 7,
      'Seven more');
    raise exception 'FAIL: two requests together exceeded the entitlement';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal says how many days are left',
      v_msg like '%6.00 day(s) of Annual leave%');
    raise notice 'ok   a pending request is counted against the next one';
  end;

  -- Six fits exactly.
  v_req2 := public.submit_leave_request(
    v_org, v_annual, date '2026-05-04', date '2026-05-11', 6, 'Six');
  perform pg_temp.check_eq('what is left may be taken to the day',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 8);

  -- Unpaid leave has no entitlement to run out of.
  v_unpaid_req := public.submit_leave_request(
    v_org, v_unpaid, date '2026-06-01', date '2026-06-30', 30,
    'A month unpaid');
  perform pg_temp.check_true('unpaid leave is not checked against a balance',
    v_unpaid_req is not null);

  begin
    perform public.submit_leave_request(
      v_org, v_annual, date '2026-07-10', date '2026-07-01', 1, 'Backwards');
    raise exception 'FAIL: leave that ends before it starts was filed';
  exception when sqlstate '22023' then
    raise notice 'ok   leave has to end after it starts';
  end;

  begin
    perform public.submit_leave_request(
      v_org, gen_random_uuid(), date '2026-07-01', date '2026-07-02', 2, 'What');
    raise exception 'FAIL: an unknown leave type was accepted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and be of a leave type the company has';
  end;

  -- ==================================================================
  -- Deciding
  -- ==================================================================
  perform pg_temp.sign_in_as(v_staff);
  begin
    perform public.decide_leave_request(v_req2, true);
    raise exception 'FAIL: an employee approved their own leave';
  exception when sqlstate '42501' then
    raise notice 'ok   nobody approves their own leave';
  end;

  -- The manager may, because Encik Zul reports to Puan Siti.
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('the manager is recognised as the manager',
    app.manages_employee(v_e_staff));
  perform public.decide_leave_request(v_req2, false, 'Too close to the audit');

  select * into r from public.leave_requests where id = v_req2;
  perform pg_temp.check_eq('a rejected request says so', r.status::text,
    'rejected');
  perform pg_temp.check_eq('with the reason kept', r.decision_note,
    'Too close to the audit');
  perform pg_temp.check_eq('and the approver recorded', r.approver_id, v_boss);
  -- Rejecting releases the hold and takes nothing.
  perform pg_temp.check_eq('rejecting gives the days back',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 2);
  perform pg_temp.check_eq('and takes none of them',
    (select taken_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 0);

  begin
    perform public.decide_leave_request(v_req2, true);
    raise exception 'FAIL: a decided request was decided again';
  exception when sqlstate '22023' then
    raise notice 'ok   a request is decided once';
  end;

  -- Approving moves the days from held to taken.
  perform public.decide_leave_request(v_req, true, 'Enjoy');
  perform pg_temp.check_eq('approving releases the hold',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 0);
  perform pg_temp.check_eq('and consumes the entitlement',
    (select taken_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 2);
  perform pg_temp.check_eq('the request is approved',
    (select status::text from public.leave_requests where id = v_req),
    'approved');

  -- A stranger is refused on a request that is still open, so the
  -- refusal is the permission check and not the decided-once guard
  -- standing in front of it.
  perform pg_temp.check_eq('the unpaid month is still undecided',
    (select status::text from public.leave_requests where id = v_unpaid_req),
    'submitted');
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.decide_leave_request(v_unpaid_req, true);
    raise exception 'FAIL: a stranger decided a leave request';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot decide somebody''s leave';
  end;

  -- The handover to payroll. calculate_payroll_run selects approved
  -- requests whose leave type is not paid; payroll_run.sql asserts what
  -- it does with one, and this is the point at which one comes to exist.
  perform pg_temp.sign_in_as(v_boss);
  perform public.decide_leave_request(v_unpaid_req, true, 'Granted unpaid');
  perform pg_temp.check_eq(
    'an approved unpaid request is what payroll goes looking for',
    (select count(*) from public.leave_requests lr
       join public.leave_types lt on lt.id = lr.leave_type_id
      where lr.employee_id = v_e_staff and lr.status = 'approved'
        and not lt.is_paid), 1);
  perform pg_temp.check_eq('for the days it was granted for',
    (select lr.total_days from public.leave_requests lr
       join public.leave_types lt on lt.id = lr.leave_type_id
      where lr.employee_id = v_e_staff and lr.status = 'approved'
        and not lt.is_paid), 30);

  -- ==================================================================
  -- How many days it is actually for
  -- ==================================================================
  -- submit_leave_request took the number of days from its caller and
  -- never related it to the dates. Measured before 0397: an employee
  -- with fourteen days of annual leave filed one request for themselves
  -- for -20 days, their available balance became 34, and approving it
  -- moved the twenty days into taken_days for good. Every step below it
  -- is a correct addition of a number nobody checked.
  perform pg_temp.sign_in_as(v_staff);
  select coalesce(entitled_days, 0) + coalesce(carried_forward, 0)
       + coalesce(adjustment_days, 0) - coalesce(taken_days, 0)
       - coalesce(pending_days, 0)
    into v_bal from public.leave_balances
   where employee_id = v_e_staff and leave_type_id = v_annual;

  begin
    perform public.submit_leave_request(
      v_org, v_annual, current_date + 10, current_date + 10, -20,
      'Manufacture');
    raise exception 'FAIL: leave for minus twenty days was filed';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    -- The message, not only the sqlstate. A negative is not somebody
    -- confused about the minimum, and the branch that says so is only
    -- worth having if something notices when it stops being reached:
    -- `total_days < 0.5` refuses -20 too, with the wrong sentence.
    perform pg_temp.check_true('and the refusal is about it not being leave',
      v_msg like '%is for some leave%' and v_msg like '%-20%');
    raise notice 'ok   a leave request is for some leave';
  end;
  perform pg_temp.check_eq('and the balance is untouched',
    (select coalesce(entitled_days, 0) + coalesce(carried_forward, 0)
          + coalesce(adjustment_days, 0) - coalesce(taken_days, 0)
          - coalesce(pending_days, 0)
       from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), v_bal);

  begin
    perform public.submit_leave_request(
      v_org, v_annual, current_date + 10, current_date + 10, 0, 'None');
    raise exception 'FAIL: leave for no days was filed';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and it is the same refusal as a negative',
      v_msg like '%is for some leave%');
    raise notice 'ok   and zero is the same mistake as a negative';
  end;

  begin
    perform public.submit_leave_request(
      v_org, v_annual, current_date + 10, current_date + 10, 0.25,
      'A quarter');
    raise exception 'FAIL: a quarter of a day was filed';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    -- And this one is a different sentence, so the two branches are
    -- told apart rather than merely both present.
    perform pg_temp.check_true('the shortest leave is named',
      v_msg like '%shortest leave is half a day%');
    raise notice 'ok   the shortest leave is half a day';
  end;

  -- The upper bound, which needs nothing but the dates.
  begin
    perform public.submit_leave_request(
      v_org, v_unpaid, current_date + 10, current_date + 10, 300,
      'One day, three hundred claimed');
    raise exception 'FAIL: one day was filed as three hundred';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal gives both figures',
      v_msg like '%1 day(s)%' and v_msg like '%300%');
    raise notice 'ok   nobody is away longer than the dates they gave';
  end;

  -- Exactly the span is the boundary and is allowed: unpaid, so no
  -- entitlement stands in for the check being made.
  perform pg_temp.check_true('a request for exactly its own span is fine',
    public.submit_leave_request(
      v_org, v_unpaid, current_date + 50, current_date + 52, 3,
      'Three of three') is not null);

  -- ------------------------------------------------------------------
  -- The half day 0365 guarded and nothing could ask for
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  insert into public.leave_types (org_id, code, name, is_paid, allow_half_day)
  values (v_org, 'HALF', 'Half-day leave', false, true)
  returning id into v_half;
  insert into public.leave_types (org_id, code, name, is_paid, allow_half_day)
  values (v_org, 'WHOLE', 'Whole days only', false, false)
  returning id into v_whole;
  perform pg_temp.sign_in_as(v_staff);

  perform pg_temp.check_true('a half day may be asked for at last',
    public.submit_leave_request(
      v_org, v_half, current_date + 60, current_date + 60, 0.5,
      'Afternoon off', true, 'afternoon') is not null);

  begin
    perform public.submit_leave_request(
      v_org, v_half, current_date + 61, current_date + 61, 1,
      'Marked half, asking for a whole', true, 'morning');
    raise exception 'FAIL: a half day was filed as a whole one';
  exception when sqlstate '23514' then
    raise notice 'ok   a half day is half a day';
  end;

  begin
    perform public.submit_leave_request(
      v_org, v_half, current_date + 62, current_date + 63, 0.5,
      'Half a day across two', true, 'morning');
    raise exception 'FAIL: a half day spanned two dates';
  exception when sqlstate '23514' then
    raise notice 'ok   and it is on one date';
  end;

  -- Both ways round. Without this, 0365's rule is reached past by
  -- claiming half a day and leaving the flag off -- which is exactly
  -- what every caller did, since nothing ever set the flag.
  begin
    perform public.submit_leave_request(
      v_org, v_whole, current_date + 64, current_date + 64, 0.5,
      'Half, quietly');
    raise exception
      'FAIL: half a day was taken on a type that forbids half days';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and it is the arithmetic that spoke first',
      v_msg like '%Mark it as one%');
    raise notice 'ok   half a day has to say that it is one';
  end;

  -- Which is what lets 0365's own rule finally be reached.
  begin
    perform public.submit_leave_request(
      v_org, v_whole, current_date + 65, current_date + 65, 0.5,
      'Half, openly', true, 'morning');
    raise exception 'FAIL: 0365''s half-day rule did not fire';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and then 0365 refuses it by name',
      v_msg like '%taken in whole days%');
    raise notice 'ok   a type that forbids half days still does';
  end;

  begin
    perform public.submit_leave_request(
      v_org, v_half, current_date + 66, current_date + 66, 1,
      'Which half of a whole day?', false, 'morning');
    raise exception 'FAIL: a period was set on a whole-day request';
  exception when sqlstate '23514' then
    raise notice 'ok   a morning or an afternoon is a half day';
  end;

  -- ==================================================================
  -- Where to reach somebody who is away
  -- ==================================================================
  -- `leave_requests.contact_while_away` has been on the table since
  -- 0027 and nothing wrote it: submit_leave_request had no parameter
  -- for it, so no form could reach it. 0395 adds the parameter, a way
  -- to correct it after the request is out of the employee's hands,
  -- and a reader. All three, because a column needs all three.
  --
  -- Dates are relative to today rather than pinned to 2026: half of
  -- what is asserted here is whether the leave is still ahead of the
  -- person, so a hard-coded year would stop meaning what it says.
  -- Unpaid leave, so no balance row has to exist for a given year.
  -- 0395 dropped the nine-argument version rather than letting a
  -- default overload it. Two functions of this name and a call giving
  -- only the six required arguments matches both, which is 42725 at
  -- run time and in no test -- so the count is the assertion.
  perform pg_temp.check_eq('there is one submit_leave_request, not two',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'submit_leave_request'), 1);
  perform pg_temp.check_eq('and it takes the contact',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'submit_leave_request'
        and 'p_contact_while_away' = any (p.proargnames)), 1);

  perform pg_temp.sign_in_as(v_staff);
  v_away := public.submit_leave_request(
    v_org, v_unpaid, current_date + 30, current_date + 34, 5,
    'Kampung', false, null, null, '+60 12-555 0101');
  perform pg_temp.check_eq('the contact given at submission is kept',
    (select contact_while_away from public.leave_requests where id = v_away),
    '+60 12-555 0101');

  -- A form that posts every field posts the empty ones too, and a
  -- contact of '' reads on a report as a contact that was given.
  v_far := public.submit_leave_request(
    v_org, v_unpaid, current_date + 200, current_date + 201, 2,
    'Later', false, null, null, '   ');
  perform pg_temp.check_true('a blank contact is stored as no contact',
    (select contact_while_away from public.leave_requests where id = v_far)
      is null);

  -- ------------------------------------------------------------------
  -- Correcting it once the request is out of the employee's hands
  -- ------------------------------------------------------------------
  -- 0038's update policy lets the employee change their own request
  -- only while it is draft, which is right for the dates and wrong for
  -- this one field: where somebody is changes, and the number given a
  -- fortnight before departure is a hotel they have since left.
  perform pg_temp.check_eq('the request is submitted, not draft',
    (select status::text from public.leave_requests where id = v_away),
    'submitted');
  perform pg_temp.check_eq('so the policy alone would refuse the employee',
    (select count(*) from public.leave_requests
      where id = v_away
        and (app.can_manage_hr(org_id)
             or app.manages_employee(employee_id)
             or (employee_id = app.my_employee_id(org_id)
                 and status = 'draft'))), 0);
  perform public.update_leave_contact(v_away, '+60 19-555 0202');
  perform pg_temp.check_eq('and the function lets them correct it anyway',
    (select contact_while_away from public.leave_requests where id = v_away),
    '+60 19-555 0202');
  perform public.update_leave_contact(v_away, '  ');
  perform pg_temp.check_true('a blank correction clears it rather than blanking it',
    (select contact_while_away from public.leave_requests where id = v_away)
      is null);
  perform public.update_leave_contact(v_away, '+60 19-555 0202');

  -- The 0283 guard, in a second function. `v_req.employee_id <> v_me`
  -- is null for a member with no employee record and a null condition
  -- never raises, so this is written `is distinct from`. Turning it
  -- back into `<>` has to fail here.
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.update_leave_contact(v_away, '+60 11-555 9999');
    raise exception
      'FAIL: a member with no employee record changed somebody''s contact';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and it is that guard that spoke',
      v_msg like 'Only the employee on leave or HR%');
    raise notice 'ok   only the employee or HR may say where to reach them';
  end;
  perform pg_temp.check_eq('and the contact is unchanged',
    (select contact_while_away from public.leave_requests where id = v_away),
    '+60 19-555 0202');

  -- HR may, which is what the guard exists to allow.
  perform pg_temp.sign_in_as(v_owner);
  perform public.update_leave_contact(v_away, '+60 19-555 0303');
  perform pg_temp.check_eq('HR may correct it on the employee''s behalf',
    (select contact_while_away from public.leave_requests where id = v_away),
    '+60 19-555 0303');

  -- Leave that has already ended has nobody away to reach, and a
  -- rejected request is not an absence at all. Both refusals name
  -- which one spoke.
  v_past := public.submit_leave_request(
    v_org, v_unpaid, current_date - 10, current_date - 5, 6,
    'Already back', false, null, v_e_staff);
  begin
    perform public.update_leave_contact(v_past, '+60 12-555 0404');
    raise exception 'FAIL: the contact was changed on leave that has ended';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('the refusal is about the leave having ended',
      v_msg like '%ended on%');
    raise notice 'ok   leave that is over has nobody away to reach';
  end;

  perform pg_temp.sign_in_as(v_boss);
  perform public.decide_leave_request(v_far, false, 'Not that far ahead');

  -- The manager may decide the request but may not say where to reach
  -- somebody, and the permission check runs before the status checks:
  -- Puan Siti is refused for not being Encik Zul, and is not told in
  -- passing what state his request is in. Reordering the two would
  -- answer a question the caller was not entitled to ask.
  begin
    perform public.update_leave_contact(v_far, '+60 12-555 0505');
    raise exception 'FAIL: the manager changed somebody else''s contact';
  exception when sqlstate '42501' then
    raise notice 'ok   deciding leave is not the same as being on it';
  end;

  perform pg_temp.sign_in_as(v_staff);
  begin
    perform public.update_leave_contact(v_far, '+60 12-555 0505');
    raise exception 'FAIL: the contact was changed on a rejected request';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('the refusal is about the status',
      v_msg like '%was rejected%');
    raise notice 'ok   a rejected request is not an absence';
  end;

  -- ------------------------------------------------------------------
  -- Reading it
  -- ------------------------------------------------------------------
  -- Only approved leave is an absence: a request awaiting a decision
  -- is a plan.
  perform pg_temp.check_eq('the trip is not approved yet',
    (select status::text from public.leave_requests where id = v_away),
    'submitted');
  perform pg_temp.check_eq('so nobody is away',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 30, current_date + 34)), 0);
  perform pg_temp.sign_in_as(v_boss);
  perform public.decide_leave_request(v_away, true, 'Enjoy');

  select * into r from public.report_who_is_away(
    v_org, current_date + 30, current_date + 34);
  perform pg_temp.check_eq('an approved absence is reported', r.request_id,
    v_away);
  perform pg_temp.check_eq('with the contact', r.contact_while_away,
    '+60 19-555 0303');
  perform pg_temp.check_true('and flagged as having one', r.has_contact);
  perform pg_temp.check_eq('named by employee', r.employee_name, 'Encik Zul');
  perform pg_temp.check_eq('and by leave type', r.leave_type, 'Unpaid leave');

  -- The same set 0038's select policy allows, so Encik Zul sees his own
  -- absence: the report is scoped, not hidden from the person it is
  -- about.
  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_eq('the employee sees their own absence',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 30, current_date + 34)), 1);

  -- The window is inclusive at both ends and the overlap is the
  -- ordinary one: leave that spans the window without either of its
  -- own dates falling inside it is still somebody who is away.
  perform pg_temp.check_eq('the first day is inside the window',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 34, current_date + 40)), 1);
  perform pg_temp.check_eq('and the last day is too',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 20, current_date + 30)), 1);
  perform pg_temp.check_eq('leave spanning the window counts',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 31, current_date + 32)), 1);
  perform pg_temp.check_eq('the day before it starts does not',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 29, current_date + 29)), 0);
  perform pg_temp.check_eq('nor the day after it ends',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 35, current_date + 35)), 0);
  begin
    perform public.report_who_is_away(
      v_org, current_date + 34, current_date + 30);
    raise exception 'FAIL: a window that ends before it begins was accepted';
  exception when sqlstate '22023' then
    raise notice 'ok   a window ends after it begins';
  end;

  -- A contact-while-away is a personal number, so the report shows the
  -- same set 0038's select policy already allows: HR the organization,
  -- anybody else their own reporting line. Puan Siti manages Encik Zul
  -- and sees him; she does not manage the third employee.
  perform pg_temp.sign_in_as(v_owner);
  v_other := pg_temp.another_user('other@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_other, 'viewer', 'active');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id)
  values (v_org, 'E3', 'Cik Mei', current_date - 400, 5000,
          date '1990-01-01', 'citizen', v_other)
  returning id into v_e_other;

  perform public.submit_leave_request(
    v_org, v_unpaid, current_date + 30, current_date + 34, 5,
    'Hers', false, null, v_e_other, '+60 13-555 0606');
  perform public.decide_leave_request(
    (select id from public.leave_requests
      where employee_id = v_e_other order by created_at desc limit 1),
    true, 'Granted');
  perform pg_temp.check_eq('HR sees the whole organization',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 30, current_date + 34)), 2);

  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('the manager is not HR',
    not app.can_manage_hr(v_org));
  perform pg_temp.check_eq('and sees only their own reporting line',
    (select count(*) from public.report_who_is_away(
       v_org, current_date + 30, current_date + 34)), 1);
  perform pg_temp.check_eq('which is the one they manage',
    (select employee_name from public.report_who_is_away(
       v_org, current_date + 30, current_date + 34)), 'Encik Zul');

  -- Somebody with no employee record is neither, and is told so rather
  -- than handed an empty result: an empty report and a refused one mean
  -- different things to whoever is looking.
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.report_who_is_away(
      v_org, current_date + 30, current_date + 34);
    raise exception 'FAIL: a member with no employee record read who is away';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and that guard named itself',
      v_msg like 'Only HR or a manager%');
    raise notice 'ok   a contact-while-away is not a directory entry';
  end;

  perform pg_temp.sign_out();
end $$;

rollback;
