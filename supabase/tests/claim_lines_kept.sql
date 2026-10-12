-- =====================================================================
-- iAkauntan :: a claim is what was decided (0846)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/claim_lines_kept.sql
--
-- What a claim pays is the approver's figure, spread across expense
-- accounts by its lines. Before `0846` the claimant could rewrite an
-- approved claim's lines -- what was spent on, the amount, the
-- category and so the account -- add to them, or delete the only one. Asked as
-- the claimant with the role `authenticated`, as the claims screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ck (org uuid, staff_user uuid, travel uuid, ent uuid,
  decided uuid, undecided uuid, draft uuid, approved uuid, cancelled uuid,
  decided_line uuid, undecided_line uuid, approved_line uuid);
grant select on t_ck to authenticated;

create or replace function pg_temp.ck_claim(
  p_org uuid, p_staff uuid, p_no text, p_status text, p_type uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (p_org, p_no, p_staff, pg_temp.today(), 'Trip', p_status::app.request_status, p_amount)
  returning id into v_id;
  insert into public.expense_claim_lines
    (org_id, claim_id, line_no, claim_type_id, expense_date, description, amount)
  values (p_org, v_id, 1, p_type, pg_temp.today(), 'Taxi to client', p_amount);
  return v_id;
end $$;

do $$
declare r t_ck; v_staff uuid; v_a1 uuid; v_a2 uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Tuntutan Kekal Sdn Bhd', array['hr']);
  r.staff_user := pg_temp.another_user('staf@tuntutankekal.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (r.org, r.staff_user, 'employee', 'active', now());
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E-1', 'Staf', r.staff_user, pg_temp.today()) returning id into v_staff;
  select id into v_a1 from public.accounts
   where org_id = r.org and account_type = 'expense' and not is_group order by code limit 1;
  select id into v_a2 from public.accounts
   where org_id = r.org and account_type = 'expense' and not is_group order by code desc limit 1;
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (r.org, 'TRV', 'Travel', v_a1) returning id into r.travel;
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (r.org, 'ENT', 'Client entertainment', v_a2) returning id into r.ent;

  -- One claim with a step decided and the claim still open, one with
  -- nothing decided, one still a draft, and one approved to the end.
  r.decided := pg_temp.ck_claim(r.org, v_staff, 'CLM-1', 'submitted', r.travel, 500);
  perform public.decide_claim_step(r.decided, true, 'Looks right', 500);
  r.undecided := pg_temp.ck_claim(r.org, v_staff, 'CLM-2', 'submitted', r.travel, 300);
  r.draft := pg_temp.ck_claim(r.org, v_staff, 'CLM-3', 'draft', r.travel, 200);
  r.approved := pg_temp.ck_claim(r.org, v_staff, 'CLM-4', 'submitted', r.travel, 400);
  -- And one withdrawn before anybody decided anything: its state alone
  -- says it is finished.
  r.cancelled := pg_temp.ck_claim(r.org, v_staff, 'CLM-5', 'cancelled', r.travel, 100);
  for i in 1..6 loop
    exit when (select status from public.expense_claims where id = r.approved) <> 'submitted';
    perform public.decide_claim_step(r.approved, true, 'Fine', 400);
  end loop;
  select id into r.decided_line from public.expense_claim_lines where claim_id = r.decided;
  select id into r.undecided_line from public.expense_claim_lines where claim_id = r.undecided;
  select id into r.approved_line from public.expense_claim_lines where claim_id = r.approved;
  insert into t_ck select r.*;

  perform pg_temp.check_eq('the premise: a step decided and the claim still open, and one approved',
    (select status::text from public.expense_claims where id = r.decided) || ' / ' ||
    (select count(*)::text from public.claim_approvals where claim_id = r.decided and status = 'approved') || ' / ' ||
    (select status::text from public.expense_claims where id = r.approved),
    'submitted / 1 / approved');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select staff_user from t_ck), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ck;
begin
  select * into d from t_ck;
  perform pg_temp.check_true('the claimant, asking as a client who is not HR',
    current_user = 'authenticated' and not app.can_manage_hr(d.org));

  -- What was measured.
  perform pg_temp.check_refused('an approved claim''s line is not rewritten',
    format($q$update public.expense_claim_lines
                 set amount = 5000, description = 'Taxi, and dinner', claim_type_id = %L
               where id = %L$q$, d.ent, d.approved_line),
    'Claim CLM-4 has been decided on, and its lines are what was decided. A change after that is a fresh claim.',
    '42501');
  perform pg_temp.check_refused('nor added to',
    format($q$insert into public.expense_claim_lines
                (org_id, claim_id, line_no, expense_date, description, amount)
              values (%L, %L, 2, %L, 'Added after approval', 900)$q$,
           d.org, d.approved, pg_temp.today()),
    'Claim CLM-4 has been decided on%', '42501');
  perform pg_temp.check_refused('nor its only line deleted',
    format('delete from public.expense_claim_lines where id = %L', d.approved_line),
    'Claim CLM-4 has been decided on%', '42501');

  -- Nor once one approver has decided, though the claim is still open.
  -- (A step counts as decided when it is approved or REJECTED. The
  -- rejected half has no assertion of its own and its mutant survives
  -- as an equivalent one: `decide_claim_step` rejects the whole claim
  -- the moment one step is rejected, so the claim's own state already
  -- refuses.)
  perform pg_temp.check_refused('a claim one approver has passed is not rewritten under the next',
    format('update public.expense_claim_lines set amount = 50 where id = %L', d.decided_line),
    'Claim CLM-1 has been decided on%', '42501');
  perform pg_temp.check_refused('nor a claim withdrawn before anybody decided',
    format('update public.expense_claim_lines set amount = 1 where claim_id = %L', d.cancelled),
    'Claim CLM-5 has been decided on%', '42501');
  -- Nor moved, either way, between a decided claim and an open one.
  perform pg_temp.check_refused('a line is not moved onto a claim already decided on',
    format('update public.expense_claim_lines set claim_id = %L where id = %L',
           d.decided, d.undecided_line),
    'Claim CLM-1 has been decided on%', '42501');
  perform pg_temp.check_refused('nor off one',
    format('update public.expense_claim_lines set claim_id = %L where id = %L',
           d.undecided, d.decided_line),
    'Claim CLM-1 has been decided on%', '42501');

  -- What the claims screen does is as before.
  update public.expense_claim_lines set description = 'Taxi to client, both ways'
   where id = d.undecided_line;
  insert into public.expense_claim_lines
    (org_id, claim_id, line_no, claim_type_id, expense_date, description, amount)
  values (d.org, d.undecided, 2, d.travel, pg_temp.today(), 'Parking', 12);
  update public.expense_claim_lines set amount = 250 where claim_id = d.draft;
  perform pg_temp.check_eq('a claim nobody has decided, and a draft, are still written',
    (select count(*)::text from public.expense_claim_lines where claim_id = d.undecided) || ' / ' ||
    (select description from public.expense_claim_lines where id = d.undecided_line) || ' / ' ||
    (select amount::text from public.expense_claim_lines where claim_id = d.draft),
    '2 / Taxi to client, both ways / 250.00');
end $$;

reset role;

-- HR still corrects a decided claim's lines.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ck;
begin
  select * into d from t_ck;
  update public.expense_claim_lines set claim_type_id = d.ent where id = d.approved_line;
  perform pg_temp.check_true('HR still corrects an approved claim''s category',
    app.can_manage_hr(d.org)
    and (select claim_type_id = d.ent from public.expense_claim_lines where id = d.approved_line));
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: every claim function is a definer, which runs as
-- the owner at any depth.
do $$
declare d t_ck;
begin
  select * into d from t_ck;
  update public.expense_claim_lines set notes = 'Checked' where id = d.approved_line;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select notes from public.expense_claim_lines where id = d.approved_line), 'Checked');
end $$;

rollback;
