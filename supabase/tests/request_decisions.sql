-- =====================================================================
-- iAkauntan :: a decision is the approver's (0795)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/request_decisions.sql
--
-- An expense claim is approved by its chain and paid by payroll; a
-- leave request is filed against a balance and decided by HR or the
-- manager. Before `0795` the policies let an employee insert their own
-- claim as 'approved', or turn their own draft so, and payroll paid it;
-- leave the same, with the balance never asked. `0795` takes the
-- status, the decision, the posting and the payment of both out of a
-- client's hands, a request that has left draft altogether, and its
-- deletion with it.
--
-- Everything that matters runs under `set local role authenticated`:
-- the employee, their manager, HR and an accountant, each with their
-- own login. Every column of a request that has left draft is asked,
-- read from the catalogue, so a column added later is asked without
-- this file being edited.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_rd (
  org uuid, owner uuid, u_staff uuid, u_boss uuid, u_hr uuid, u_acc uuid,
  staff uuid, boss uuid, acc uuid, lt uuid, ct uuid,
  c_draft uuid, c_sub uuid, c_appr uuid, c_acc uuid,
  l_draft uuid, l_sub uuid, l_appr uuid, l_filed uuid);
grant select, update on t_rd to authenticated, anon;

do $$
declare
  r t_rd;
  v_today date := pg_temp.today();
begin
  r.org := pg_temp.test_org('Keputusan Pelulus Sdn Bhd');
  r.owner := pg_temp.test_user();
  perform public.create_fiscal_year(r.org,
    make_date(extract(year from v_today)::int, 1, 1));

  r.u_staff := pg_temp.another_user('staf@keputusan.test');
  r.u_boss  := pg_temp.another_user('ketua@keputusan.test');
  r.u_hr    := pg_temp.another_user('hr@keputusan.test');
  r.u_acc   := pg_temp.another_user('akaun@keputusan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.u_staff, 'employee', 'active'),
         (r.org, r.u_boss, 'employee', 'active'),
         (r.org, r.u_hr, 'hr_manager', 'active'),
         (r.org, r.u_acc, 'accountant', 'active');

  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E-KETUA', 'Ketua', r.u_boss, v_today - 900)
  returning id into r.boss;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id)
  values (r.org, 'E-STAF', 'Staf', r.u_staff, v_today - 400, r.boss)
  returning id into r.staff;
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E-AKAUN', 'Akauntan', r.u_acc, v_today - 700)
  returning id into r.acc;

  insert into public.leave_types (org_id, code, name, default_days)
  values (r.org, 'AL', 'Annual', 8) returning id into r.lt;
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (r.org, 'TRAVEL', 'Travel',
          (select id from public.accounts
            where org_id = r.org and code = '6250' and not is_group))
  returning id into r.ct;

  -- The employee's claims: a draft, one submitted (its chain built on
  -- the insert), one approved. And the accountant's own, submitted.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (r.org, 'CLM-D', r.staff, v_today, 'Draf', 'draft', 80)
  returning id into r.c_draft;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount,
     submitted_at)
  values (r.org, 'CLM-S', r.staff, v_today, 'Hantar', 'submitted', 120, now())
  returning id into r.c_sub;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount,
     approved_amount, approver_id, decided_at, submitted_at)
  values (r.org, 'CLM-A', r.staff, v_today, 'Lulus', 'approved', 300, 300,
          r.u_boss, now(), now())
  returning id into r.c_appr;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount,
     submitted_at)
  values (r.org, 'CLM-K', r.acc, v_today, 'Akauntan', 'submitted', 150, now())
  returning id into r.c_acc;

  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (r.org, 'LV-D', r.staff, r.lt, v_today + 30, v_today + 30, 1, 'draft')
  returning id into r.l_draft;
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status, submitted_at)
  values (r.org, 'LV-S', r.staff, r.lt, v_today + 40, v_today + 41, 2,
          'submitted', now())
  returning id into r.l_sub;
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status, submitted_at, approver_id, decided_at)
  values (r.org, 'LV-A', r.staff, r.lt, v_today + 50, v_today + 50, 1,
          'approved', now(), r.u_hr, now())
  returning id into r.l_appr;

  insert into t_rd select r.*;
end $$;

-- A forged value for a column, of its own type and different from what
-- is there. Never reaches a constraint: the guard fires first.
create or replace function pg_temp.forged(p_col text, p_type text)
returns text language sql immutable as $$
  select case
    when p_type = 'uuid' then 'gen_random_uuid()'
    when p_type like 'timestamp%' then format('now() + interval %L', '50 years')
    when p_type = 'date' then format('%I + 1', p_col)
    when p_type in ('integer', 'numeric', 'smallint', 'bigint')
      then format('%I + 5', p_col)
    when p_type = 'boolean' then format('not %I', p_col)
    when p_type = 'character' then quote_literal('USD')
    else quote_literal('forged') end
$$;

-- ---------------------------------------------------------------------
-- 1. The employee, filing
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_staff from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  c t_rd;
  v_status text;
  v_col text;
  v_val text;
  v_id uuid;
begin
  select * into c from t_rd;
  perform pg_temp.check_eq('the employee is asked as a client',
    current_user, 'authenticated');
  perform pg_temp.check_true('and is the employee',
    app.my_employee_id(c.org) = c.staff);

  -- The finding itself: a claim filed already approved.
  foreach v_status in array array['approved', 'rejected', 'cancelled'] loop
    perform pg_temp.check_refused('a claim is not filed ' || v_status,
      format($q$insert into public.expense_claims
        (org_id, claim_no, employee_id, claim_date, title, status,
         total_amount, approved_amount, pay_with_payroll)
        values (%L, %L, %L, %L, 'Sendiri', %L, 5000, 5000, true)$q$,
        c.org, 'CLM-' || v_status, c.staff, pg_temp.today(), v_status),
      'A claim is filed as a draft or submitted; it is approved or rejected through its approval chain.',
      '42501');
  end loop;

  -- Nor submitted with its decision, posting or payment already on it.
  foreach v_col in array array['approved_amount', 'approver_id', 'decided_at',
      'decision_note', 'gl_entry_id', 'posted_at', 'paid_at'] loop
    v_val := case v_col
      when 'approved_amount' then '5000'
      when 'approver_id' then quote_literal(c.u_staff)
      when 'gl_entry_id' then 'gen_random_uuid()'
      when 'decision_note' then quote_literal('ok')
      else 'now()' end;
    perform pg_temp.check_refused('a claim is not filed with its ' || v_col,
      format($q$insert into public.expense_claims
        (org_id, claim_no, employee_id, claim_date, title, status,
         total_amount, %I)
        values (%L, %L, %L, %L, 'Sendiri', 'submitted', 5000, %s)$q$,
        v_col, c.org, 'CLM-' || v_col, c.staff, pg_temp.today(), v_val),
      'The ' || replace(v_col, '_', ' ')
        || ' of a claim is written when it is decided, not when it is filed.',
      '42501');
  end loop;

  -- What the app does: a claim filed submitted, its chain built on the
  -- insert. And a draft.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status,
     total_amount, submitted_at, pay_with_payroll)
  values (c.org, 'CLM-BARU', c.staff, pg_temp.today(), 'Baru', 'submitted',
          200, now(), false)
  returning id into v_id;
  perform pg_temp.check_true('a claim is still filed as the app files it',
    exists (select 1 from public.expense_claims
             where id = v_id and status = 'submitted' and approved_amount = 0));
  perform pg_temp.check_true('and its chain is built',
    exists (select 1 from public.claim_approvals
             where claim_id = v_id and status = 'pending'));
  insert into public.expense_claim_lines
    (org_id, claim_id, line_no, claim_type_id, expense_date, description, amount)
  values (c.org, v_id, 1, c.ct, pg_temp.today(), 'Perjalanan', 200);
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (c.org, 'CLM-DRAF2', c.staff, pg_temp.today(), 'Draf dua', 'draft', 10);

  -- Leave: filed only through submit_leave_request.
  foreach v_status in array array['submitted', 'approved', 'rejected', 'cancelled'] loop
    perform pg_temp.check_refused('leave is not filed ' || v_status || ' by hand',
      format($q$insert into public.leave_requests
        (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
         total_days, status)
        values (%L, %L, %L, %L, %L, %L, 3, %L)$q$,
        c.org, 'LV-' || v_status, c.staff, c.lt,
        pg_temp.today() + 10, pg_temp.today() + 12, v_status),
      'Leave is filed with submit_leave_request, which checks the balance and holds the days.',
      '42501');
  end loop;
  foreach v_col in array array['approver_id', 'decided_at', 'decision_note'] loop
    v_val := case v_col
      when 'approver_id' then quote_literal(c.u_staff)
      when 'decision_note' then quote_literal('ok')
      else 'now()' end;
    perform pg_temp.check_refused('a leave draft is not filed with its ' || v_col,
      format($q$insert into public.leave_requests
        (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
         total_days, status, %I)
        values (%L, %L, %L, %L, %L, %L, 1, 'draft', %s)$q$,
        v_col, c.org, 'LV-' || v_col, c.staff, c.lt,
        pg_temp.today() + 10, pg_temp.today() + 10, v_val),
      'The ' || replace(v_col, '_', ' ')
        || ' of a leave request is written when it is decided, not when it is filed.',
      '42501');
  end loop;
  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id, start_date, end_date,
     total_days, status)
  values (c.org, 'LV-DRAF2', c.staff, c.lt, pg_temp.today() + 60,
          pg_temp.today() + 60, 1, 'draft');

  -- And the road that is meant: the balance asked, the days held.
  v_id := public.submit_leave_request(c.org, c.lt, pg_temp.today() + 70,
    pg_temp.today() + 71, 2, 'Cuti');
  perform pg_temp.check_true('leave is still filed through its function',
    exists (select 1 from public.leave_requests
             where id = v_id and status = 'submitted'));
  update t_rd set l_filed = v_id;
end $$;

-- ---------------------------------------------------------------------
-- 2. The employee, on their own drafts
-- ---------------------------------------------------------------------
do $$
declare
  c t_rd;
  t record;
  col record;
  v_status text;
  v_n integer := 0;
begin
  select * into c from t_rd;

  for t in
    select * from (values
      ('expense_claims', c.c_draft, 'claim'),
      ('leave_requests', c.l_draft, 'leave request')) v(tbl, id, what)
  loop
    -- The finding's other half: a draft turned approved.
    foreach v_status in array array['submitted', 'approved', 'rejected', 'cancelled'] loop
      perform pg_temp.check_refused(t.tbl || ': a draft is not made ' || v_status,
        format('update public.%I set status = %L where id = %L',
               t.tbl, v_status, t.id),
        'A ' || t.what || ' is decided through its approval, not by writing its status.',
        '42501');
    end loop;

    for col in
      select column_name, data_type from information_schema.columns
       where table_schema = 'public' and table_name = t.tbl
         and column_name not in ('id', 'status', 'updated_at')
       order by ordinal_position
    loop
      if col.column_name in ('org_id', 'employee_id', 'approved_amount',
           'approver_id', 'decided_at', 'decision_note', 'gl_entry_id',
           'posted_at', 'paid_at') then
        perform pg_temp.check_refused(
          t.tbl || ': a draft''s ' || col.column_name || ' is not the employee''s',
          format('update public.%I set %I = %s where id = %L', t.tbl,
                 col.column_name,
                 pg_temp.forged(col.column_name, col.data_type), t.id),
          'The ' || replace(col.column_name, '_', ' ') || ' of a '
            || t.what || ' that is draft is the database''s to write, not a client''s.',
          '42501');
        v_n := v_n + 1;
      end if;
    end loop;
  end loop;

  -- What is still the employee's on a draft.
  update public.expense_claims
     set title = 'Draf dibetulkan', total_amount = 95, claim_date = claim_date - 1,
         pay_with_payroll = false
   where id = c.c_draft;
  update public.leave_requests
     set reason = 'Urusan keluarga', end_date = end_date + 1, total_days = 2
   where id = c.l_draft;
  perform pg_temp.check_true('a draft claim is still the employee''s to edit',
    exists (select 1 from public.expense_claims
             where id = c.c_draft and title = 'Draf dibetulkan'
               and total_amount = 95 and not pay_with_payroll));
  perform pg_temp.check_true('and a draft leave request',
    exists (select 1 from public.leave_requests
             where id = c.l_draft and reason = 'Urusan keluarga'
               and total_days = 2));

  -- Nine on a claim, five on a leave request.
  perform pg_temp.check_true('every guarded column of a draft was asked',
    v_n = 14);
end $$;

-- ---------------------------------------------------------------------
-- 3. HR, the manager and the accountant, on what has left draft
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_hr from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  c t_rd;
  t record;
  col record;
  v_n integer := 0;
begin
  select * into c from t_rd;
  perform pg_temp.check_true('HR may manage HR here', app.can_manage_hr(c.org));

  for t in
    select * from (values
      ('expense_claims', c.c_sub,  'claim', 'submitted'),
      ('expense_claims', c.c_appr, 'claim', 'approved'),
      ('leave_requests', c.l_sub,  'leave request', 'submitted'),
      ('leave_requests', c.l_appr, 'leave request', 'approved')) v(tbl, id, what, status)
  loop
    perform pg_temp.check_refused(t.tbl || ': HR does not write the status of one ' || t.status,
      format('update public.%I set status = %L where id = %L', t.tbl,
             case t.status when 'approved' then 'cancelled' else 'approved' end, t.id),
      'A ' || t.what || ' is decided through its approval, not by writing its status.',
      '42501');

    -- Every other column, each in turn.
    for col in
      select column_name, data_type from information_schema.columns
       where table_schema = 'public' and table_name = t.tbl
         and column_name <> 'status'
       order by ordinal_position
    loop
      perform pg_temp.check_refused(
        t.tbl || ': HR does not write the ' || col.column_name || ' of one ' || t.status,
        format('update public.%I set %I = %s where id = %L', t.tbl,
               col.column_name,
               pg_temp.forged(col.column_name, col.data_type), t.id),
        'The ' || replace(col.column_name, '_', ' ') || ' of a ' || t.what
          || ' that is ' || t.status || ' is the database''s to write, not a client''s.',
        '42501');
      v_n := v_n + 1;
    end loop;

    perform pg_temp.check_refused(t.tbl || ': HR does not delete one ' || t.status,
      format('delete from public.%I where id = %L', t.tbl, t.id),
      'A ' || t.what || ' that is ' || t.status || ' is the record of it, and is not deleted.',
      '42501');
  end loop;

  -- A loop over no columns reports nothing just as quietly as one that
  -- passes: 20 on a claim, 20 on a leave request, each asked twice.
  perform pg_temp.check_true('every column of all four was asked', v_n >= 80);

  -- The leave decision, by its own road, on the request filed by its
  -- own road: the days held when it was filed are taken now.
  perform public.decide_leave_request(c.l_filed, true, 'Diluluskan');
  perform pg_temp.check_true('HR still decides leave through its function',
    exists (select 1 from public.leave_requests
             where id = c.l_filed and status = 'approved' and approver_id = c.u_hr));
  perform pg_temp.check_true('and the days held are taken',
    (select b.taken_days = 2 and b.pending_days = 0
       from public.leave_balances b join public.leave_requests l
         on l.employee_id = b.employee_id and l.leave_type_id = b.leave_type_id
        and b.leave_year = extract(year from l.start_date)::int
      where l.id = c.l_filed));
end $$;

-- The accountant, who may post: not their own claim's approval.
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_acc from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c t_rd;
begin
  select * into c from t_rd;
  perform pg_temp.check_true('the accountant may post', app.can_post(c.org));
  perform pg_temp.check_refused('an accountant does not approve their own claim',
    format($q$update public.expense_claims
      set status = 'approved', approved_amount = 150 where id = %L$q$, c.c_acc),
    'A claim is decided through its approval, not by writing its status.',
    '42501');
  perform pg_temp.check_refused('nor move an approved claim onto themselves',
    format('update public.expense_claims set employee_id = %L where id = %L',
           c.acc, c.c_appr),
    'The employee id of a claim that is approved is the database''s to write, not a client''s.',
    '42501');
  perform pg_temp.check_refused('nor mark it paid',
    format('update public.expense_claims set paid_at = now() where id = %L',
           c.c_appr),
    'The paid at of a claim that is approved is the database''s to write, not a client''s.',
    '42501');
end $$;

-- ---------------------------------------------------------------------
-- 4. The chain, as the app walks it: manager, HR, finance -- and then
--    posted. Each a client, each through the function.
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_boss from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c t_rd;
begin
  select * into c from t_rd;
  perform pg_temp.check_true('the manager manages the employee',
    app.manages_employee(c.staff));
  perform pg_temp.check_refused('a manager does not approve a claim by writing it',
    format($q$update public.expense_claims set status = 'approved',
      approved_amount = total_amount where claim_no = 'CLM-BARU' and org_id = %L$q$,
      c.org),
    'A claim is decided through its approval, not by writing its status.',
    '42501');
  perform pg_temp.check_refused('nor leave',
    format($q$update public.leave_requests set status = 'approved' where id = %L$q$,
      c.l_sub),
    'A leave request is decided through its approval, not by writing its status.',
    '42501');
end $$;

select public.decide_expense_claim(
  (select id from public.expense_claims where claim_no = 'CLM-BARU'), true);

reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_hr from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;
select public.decide_expense_claim(
  (select id from public.expense_claims where claim_no = 'CLM-BARU'), true);

reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_acc from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  c t_rd;
  v_id uuid := (select id from public.expense_claims where claim_no = 'CLM-BARU');
  v_entry uuid;
begin
  select * into c from t_rd;
  perform pg_temp.check_true('two steps decided by the manager and HR',
    (select count(*) = 2 from public.claim_approvals
      where claim_id = v_id and status = 'approved'));
  perform public.decide_expense_claim(v_id, true);
  perform pg_temp.check_true('the chain still approves a claim',
    exists (select 1 from public.expense_claims
             where id = v_id and status = 'approved' and approved_amount = 200
               and approver_id = c.u_acc));
  v_entry := public.post_expense_claim(v_id);
  perform pg_temp.check_true('and it is still posted through its function',
    exists (select 1 from public.expense_claims
             where id = v_id and gl_entry_id = v_entry and posted_at is not null));
end $$;

-- ---------------------------------------------------------------------
-- 5. The employee again: their own drafts can go, and the contact on
--    approved leave is still theirs through its function.
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select u_staff from t_rd),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c t_rd;
begin
  select * into c from t_rd;
  perform public.update_leave_contact(c.l_appr, '012-3456789');
  perform pg_temp.check_eq('the contact on approved leave is still the employee''s',
    (select contact_while_away from public.leave_requests where id = c.l_appr),
    '012-3456789');

  delete from public.expense_claims where id = c.c_draft;
  delete from public.leave_requests where id = c.l_draft;
  perform pg_temp.check_true('a draft can still be thrown away',
    not exists (select 1 from public.expense_claims where id = c.c_draft)
    and not exists (select 1 from public.leave_requests where id = c.l_draft));
end $$;

reset role;

-- ---------------------------------------------------------------------
-- 6. The finding, end to end: nothing the employee tried reached a
--    payslip.
-- ---------------------------------------------------------------------
do $$
declare
  c t_rd;
  v_period uuid; v_run uuid;
  v_start date := date_trunc('month', pg_temp.today())::date;
begin
  select * into c from t_rd;
  update public.employees set basic_salary = 3000, working_days_per_month = 26,
         working_hours_per_day = 8, date_of_birth = date '1990-01-01',
         marital_status = 'single', residency_status = 'citizen'
   where org_id = c.org;
  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (c.org, 'P-KEPUTUSAN', v_start, (v_start + interval '1 month - 1 day')::date,
          (v_start + interval '1 month - 1 day')::date)
  returning id into v_period;
  insert into public.payroll_runs (org_id, period_id, run_no)
  values (c.org, v_period, 'R-KEPUTUSAN') returning id into v_run;
  perform pg_temp.sign_in_as(c.owner);
  perform public.calculate_payroll_run(v_run);
  perform pg_temp.check_eq('payroll pays the employee only the claim the chain approved',
    (select claims_amount from public.payslips
      where run_id = v_run and employee_id = c.staff), 300.00);
  perform pg_temp.sign_out();

  perform pg_temp.check_eq('the rule is on both tables',
    (select count(*)::integer from pg_trigger
      where tgname = 'a_decision_is_the_approvers'
        and tgrelid in ('public.expense_claims'::regclass,
                        'public.leave_requests'::regclass)), 2);
end $$;

rollback;
