-- =====================================================================
-- iAkauntan :: expense claim posting tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/expense_claims.sql
--
-- `post_expense_claim` was written, granted, and never called by
-- anything: `decide_expense_claim` approves and does not post, and the
-- app had no button. An approved claim was approved and then nothing
-- happened — the expense was never recognised and the employee was
-- never credited.
--
-- The first thing a function gets when it finally acquires a caller is
-- its first real test, and this one found a rounding bug on the way
-- through: proportional allocation rounded each share independently, so
-- three equal shares of an approved 100.00 came to 99.99 against a
-- credit of 100.00 and the whole journal was refused. That case is
-- asserted below, and it is the reason 0090 exists.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- Approve a claim the way the company would, however many people the
-- chain asks.
--
-- 0119 turned one decision into up to four, so a single call to
-- `decide_expense_claim` now clears one step and leaves the claim
-- `submitted` — which is correct, and which made every posting
-- assertion in this file fail on the next line with "Only an approved
-- claim can be posted". These tests are about what reaches the ledger,
-- not about who signs, so they go through the real door and keep
-- pressing until it is open. The fixture's employee is the owner, and an
-- owner may act at any stage.
--
-- Bounded rather than `loop`: a chain that never clears is a bug worth
-- failing on, not one worth hanging CI over. `p_amount` is passed on
-- every call because only the one that clears the last step records it.
-- The argument list is `decide_expense_claim`'s so the call sites below
-- read as they always did.
create or replace function pg_temp.approve_fully(
  p_claim uuid, p_approve boolean,
  p_note text default null, p_amount numeric default null)
returns void language plpgsql as $$
declare v_status text;
begin
  for i in 1..6 loop
    select status into v_status from public.expense_claims where id = p_claim;
    exit when v_status <> 'submitted';
    perform public.decide_expense_claim(p_claim, p_approve, p_note, p_amount);
  end loop;

  select status into v_status from public.expense_claims where id = p_claim;
  if v_status = 'submitted' then
    raise exception 'FAIL the approval chain did not clear: chain is %',
      (select string_agg(stage || '=' || status, ' | ' order by step_no)
         from public.claim_approvals where claim_id = p_claim);
  end if;
end;
$$;

-- One employee, one claim type per named account, and a claim already
-- submitted — the state a decision starts from.
create or replace function pg_temp.claim_fixture(
  p_org uuid, p_no text, p_amounts numeric[], p_types uuid[],
  p_pay_with_payroll boolean default false)
returns uuid language plpgsql as $$
declare
  v_emp uuid; v_claim uuid; v_total numeric := 0; i integer;
begin
  select id into v_emp from public.employees
   where org_id = p_org limit 1;

  select sum(a) into v_total from unnest(p_amounts) a;

  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, total_amount,
     status, submitted_at, pay_with_payroll)
  values (p_org, p_no, v_emp, date '2026-03-15', 'Client visit', v_total,
          'submitted', now(), p_pay_with_payroll)
  returning id into v_claim;

  for i in 1 .. array_length(p_amounts, 1) loop
    insert into public.expense_claim_lines
      (org_id, claim_id, line_no, expense_date, description,
       amount, claim_type_id)
    values (p_org, v_claim, i, date '2026-03-15', 'Line ' || i,
            p_amounts[i], p_types[i]);
  end loop;

  return v_claim;
end;
$$;

create or replace function pg_temp.claim_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.employees
    (org_id, employee_no, user_id, full_name, hire_date, employment_status)
  values (v_org, 'EMP-001', pg_temp.test_user(), 'Fixture Employee',
          date '2025-01-01', 'active');
  return v_org;
end;
$$;

create or replace function pg_temp.claim_type_for(p_org uuid, p_code text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (p_org, p_code, p_code,
          (select id from public.accounts
            where org_id = p_org and code = case p_code
              when 'TRAVEL' then '6250'
              when 'MEALS'  then '6260'
              else '6900' end
              and not is_group limit 1))
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Accrued: the expense is recognised, the employee is owed
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.claim_org('Accrued Claim Sdn Bhd');
  v_type uuid; v_claim uuid; v_entry uuid; v_row public.expense_claims;
begin
  v_type := pg_temp.claim_type_for(v_org, 'TRAVEL');
  v_claim := pg_temp.claim_fixture(v_org, 'EC-001',
    array[250.00]::numeric[], array[v_type]);

  perform pg_temp.approve_fully(v_claim, true);
  v_entry := public.post_expense_claim(v_claim);

  select * into v_row from public.expense_claims where id = v_claim;
  perform pg_temp.check_true('the claim carries its journal',
    v_row.gl_entry_id = v_entry);
  perform pg_temp.check_true('and is marked posted', v_row.posted_at is not null);

  -- Posted is not paid. Nothing left the bank, so the employee is still
  -- owed the money and `paid_at` must stay empty — this is the field the
  -- "who have we not reimbursed" question is answered from.
  perform pg_temp.check_true('but not paid', v_row.paid_at is null);

  perform pg_temp.check_eq('the expense account is debited',
    (select sum(l.debit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '6250'), 250.00);
  perform pg_temp.check_eq('and accruals credited',
    (select sum(l.credit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '2120'), 250.00);
end $$;

-- ---------------------------------------------------------------------
-- Reimbursed: the bank pays it, and the claim is settled
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.claim_org('Reimbursed Claim Sdn Bhd');
  v_type uuid; v_claim uuid; v_entry uuid; v_bank uuid; v_row public.expense_claims;
begin
  v_type := pg_temp.claim_type_for(v_org, 'MEALS');
  insert into public.bank_accounts (org_id, account_id, name)
  values (v_org,
          (select id from public.accounts
            where org_id = v_org and code = '1110' and not is_group limit 1),
          'Maybank Current')
  returning id into v_bank;

  v_claim := pg_temp.claim_fixture(v_org, 'EC-001',
    array[80.00]::numeric[], array[v_type]);
  perform pg_temp.approve_fully(v_claim, true);
  v_entry := public.post_expense_claim(v_claim, v_bank);

  select * into v_row from public.expense_claims where id = v_claim;
  perform pg_temp.check_true('paying it marks it paid', v_row.paid_at is not null);
  perform pg_temp.check_eq('the bank account is credited',
    (select sum(l.credit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '1110'), 80.00);
  perform pg_temp.check_eq('and nothing sits in accruals',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '2120'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Approving less than was claimed
--
-- The allocation follows the approved amount, not what was asked for.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.claim_org('Part Approved Sdn Bhd');
  v_travel uuid; v_meals uuid; v_claim uuid; v_entry uuid;
begin
  v_travel := pg_temp.claim_type_for(v_org, 'TRAVEL');
  v_meals  := pg_temp.claim_type_for(v_org, 'MEALS');
  v_claim := pg_temp.claim_fixture(v_org, 'EC-001',
    array[300.00, 100.00]::numeric[], array[v_travel, v_meals]);

  perform pg_temp.approve_fully(v_claim, true, 'Cut the hotel', 200.00);
  v_entry := public.post_expense_claim(v_claim);

  perform pg_temp.check_eq('travel takes three quarters',
    (select sum(l.debit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '6250'), 150.00);
  perform pg_temp.check_eq('meals the rest',
    (select sum(l.debit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '6260'), 50.00);
  perform pg_temp.check_eq('and the credit is what was approved',
    (select sum(credit) from public.gl_lines where entry_id = v_entry),
    200.00);
end $$;

-- ---------------------------------------------------------------------
-- The rounding case, which used to make the claim unpostable
--
-- Three equal shares of 100.00 are 33.33 each. Rounded independently
-- they come to 99.99, the credit is 100.00, and
-- `create_gl_entry_internal` refuses the journal with 23514 — so a claim
-- in this shape could never be posted at all, by anyone, ever.
--
-- One cent goes on the largest share. This is the assertion that would
-- have caught it, and it fails against the pre-0090 function.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.claim_org('Rounding Sdn Bhd');
  v_a uuid; v_b uuid; v_c uuid; v_claim uuid; v_entry uuid;
begin
  v_a := pg_temp.claim_type_for(v_org, 'TRAVEL');
  v_b := pg_temp.claim_type_for(v_org, 'MEALS');
  v_c := pg_temp.claim_type_for(v_org, 'OTHER');

  v_claim := pg_temp.claim_fixture(v_org, 'EC-001',
    array[100.00, 100.00, 100.00]::numeric[], array[v_a, v_b, v_c]);
  perform pg_temp.approve_fully(v_claim, true, 'Goodwill', 100.00);

  v_entry := public.post_expense_claim(v_claim);

  perform pg_temp.check_eq('the debits come to the approved amount',
    (select sum(debit) from public.gl_lines where entry_id = v_entry),
    100.00);
  perform pg_temp.check_eq('and match the credit',
    (select sum(credit) from public.gl_lines where entry_id = v_entry),
    100.00);
  perform pg_temp.check_eq('across three expense accounts',
    (select count(*) from public.gl_lines l
      where l.entry_id = v_entry and l.debit > 0), 3);

  -- The cent lands on one line, not spread across all of them.
  perform pg_temp.check_eq('one line carries the residual',
    (select count(*) from public.gl_lines
      where entry_id = v_entry and debit = 33.34), 1);
end $$;

-- ---------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.claim_org('Refused Claim Sdn Bhd');
  v_type uuid; v_claim uuid; v_payroll uuid;
begin
  v_type := pg_temp.claim_type_for(v_org, 'TRAVEL');

  -- Not yet decided.
  v_claim := pg_temp.claim_fixture(v_org, 'EC-001',
    array[50.00]::numeric[], array[v_type]);
  begin
    perform public.post_expense_claim(v_claim);
    raise exception 'FAIL: posted a claim nobody has approved';
  exception when sqlstate '22023' then
    raise notice 'ok   an undecided claim cannot be posted';
  end;

  -- Approved, then posted twice. The second must not double the expense.
  perform pg_temp.approve_fully(v_claim, true);
  perform public.post_expense_claim(v_claim);
  begin
    perform public.post_expense_claim(v_claim);
    raise exception 'FAIL: posted the same claim twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a posted claim cannot be posted again';
  end;

  -- Marked for payroll: the run posts it, and posting it here as well
  -- would recognise the expense twice.
  v_payroll := pg_temp.claim_fixture(v_org, 'EC-002',
    array[50.00]::numeric[], array[v_type], true);
  perform pg_temp.approve_fully(v_payroll, true);
  begin
    perform public.post_expense_claim(v_payroll);
    raise exception 'FAIL: posted a claim payroll will also post';
  exception when sqlstate '22023' then
    raise notice 'ok   a payroll claim is left to payroll';
  end;

  -- And somebody with no right to post the ledger cannot.
  perform pg_temp.sign_out();
  begin
    perform public.post_expense_claim(v_payroll);
    raise exception 'FAIL: a signed-out caller posted a claim';
  exception when sqlstate '42501' then
    raise notice 'ok   a signed-out caller cannot post a claim';
  end;
end $$;

-- ---------------------------------------------------------------------
-- `post_expense_claim` still works after 0089 withdrew `create_gl_entry`
--
-- It calls `create_gl_entry`, which `authenticated` no longer holds.
-- EXECUTE inside a SECURITY DEFINER function is checked against the
-- owner rather than the caller, so this is fine — but "so this is fine"
-- is exactly the reasoning that ships a broken posting route, and every
-- successful post above is the evidence. This asserts the premise
-- directly, so a future change of owner is caught here rather than in
-- production.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('post_expense_claim is a definer function',
    (select prosecdef from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'post_expense_claim'));

  perform pg_temp.check_true('and its owner may still call create_gl_entry',
    has_function_privilege(
      (select proowner::regrole::text from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'post_expense_claim'),
      'public.create_gl_entry(uuid, date, app.journal_source, jsonb, text, '
      'text, uuid, text, character, numeric)', 'execute'));
end $$;

rollback;
