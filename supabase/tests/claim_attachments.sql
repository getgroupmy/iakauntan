-- =====================================================================
-- iAkauntan :: who may file a receipt against a claim
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/claim_attachments.sql
--
-- A claim is a request to be paid back for money already spent, and the
-- receipt is the evidence. Attaching one used to need `can_write` on the
-- organization, which an ordinary employee does not have — so the one
-- person holding the receipt was the one person who could not attach it.
--
-- 0118 opens exactly that door and no other, which is what this pins
-- down. The interesting assertions are the refusals: an employee may
-- attach to *their own* claim, and to nothing else.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Two employees in one company, each with a claim
-- ---------------------------------------------------------------------
create or replace function pg_temp.claim_for(p_org uuid, p_employee uuid)
returns uuid language plpgsql as $$
declare v_claim uuid;
begin
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (p_org, 'CLM-' || substr(gen_random_uuid()::text, 1, 8), p_employee,
          current_date, 'Parking', 'submitted', 12.00)
  returning id into v_claim;
  return v_claim;
end; $$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Resit Sdn Bhd');
  v_staff_user uuid;
  v_other_user uuid;
  v_staff uuid;
  v_other uuid;
  v_mine uuid;
  v_theirs uuid;
  v_refused boolean;
  v_allowed boolean;
  v_why text;
  v_role text;
begin
  -- Two people who are members of the company but not staff: no
  -- `can_write`, which is the ordinary case for somebody who only ever
  -- files claims and looks at their own payslip.
  v_staff_user := pg_temp.another_user('aminah@resit.test');
  v_other_user := pg_temp.another_user('rajesh@resit.test');

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_staff_user, 'employee'), (v_org, v_other_user, 'employee')
  on conflict do nothing;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-001', 'Aminah', v_staff_user, current_date)
  returning id into v_staff;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-002', 'Rajesh', v_other_user, current_date)
  returning id into v_other;

  v_mine := pg_temp.claim_for(v_org, v_staff);
  v_theirs := pg_temp.claim_for(v_org, v_other);

  -- ------------------------------------------------------------------
  -- As Aminah, who is nobody's manager and cannot write
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_staff_user);

  perform pg_temp.check_true('an employee has no write permission',
    not app.can_write(v_org));

  perform pg_temp.check_true('but may attach to their own claim',
    app.can_attach_to(v_org, 'expense_claims', v_mine));

  -- The one that matters. Same table, same organization, somebody
  -- else's money.
  perform pg_temp.check_true('and not to a colleague''s claim',
    not app.can_attach_to(v_org, 'expense_claims', v_theirs));

  -- Not a licence to attach to anything else in the company either.
  perform pg_temp.check_true('nor to a contact',
    not app.can_attach_to(v_org, 'contacts', gen_random_uuid()));
  perform pg_temp.check_true('nor to a bill',
    not app.can_attach_to(v_org, 'purchase_documents', gen_random_uuid()));
  perform pg_temp.check_true('nor to a claim that does not exist',
    not app.can_attach_to(v_org, 'expense_claims', gen_random_uuid()));

  -- The row policy agrees with the function, which is the half that
  -- actually stops anything.
  --
  -- Two things here are load-bearing, and this assertion was worthless
  -- without either of them.
  --
  -- `set local role authenticated` is the first. CI connects as the
  -- `postgres` superuser, and a superuser bypasses row level security
  -- altogether — so a policy test on the default connection asserts
  -- nothing whatsoever about the policy. The role has to be the one
  -- PostgREST actually uses.
  --
  -- A well-formed `storage_path` is the second. The column has a check
  -- that the path reads `<org>/<table>/<record>/<file>`, and the first
  -- version of this test passed a placeholder that failed it. Paired
  -- with `when others`, that turned a constraint violation into what
  -- looked like a refusal: the insert would have been rejected the same
  -- way on the employee's *own* claim, which is the opposite of what is
  -- being claimed. The handler is now narrowed to the one error that
  -- means "the policy said no".
  -- The role is set inside each block, not once around both. A caught
  -- exception in plpgsql is a rollback to an implicit savepoint, and
  -- `SET LOCAL` is undone by exactly that — so a role set before the
  -- first insert is already gone by the second, quietly back to the
  -- superuser this connects as. That would not have failed; it would
  -- have passed, with the control proving nothing.
  perform pg_temp.sign_in_as(v_staff_user);
  begin
    set local role authenticated;
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'expense_claims', v_theirs, 'not-mine.jpg',
            v_org || '/expense_claims/' || v_theirs || '/not-mine.jpg');
    v_refused := false;
  exception when insufficient_privilege then
    v_refused := true;
  end;

  -- The positive control, and the reason the above means anything: the
  -- identical insert on their own claim goes through. Without this, a
  -- refusal for any reason at all reads as the policy working.
  --
  -- It keeps the error rather than a bare boolean. A control that fails
  -- is saying the door is shut on the person it was opened for, and
  -- "expected true" is the least useful possible way to be told that.
  begin
    set local role authenticated;
    v_role := current_user;
    insert into public.attachments
      (org_id, entity_table, entity_id, file_name, storage_path)
    values (v_org, 'expense_claims', v_mine, 'mine.jpg',
            v_org || '/expense_claims/' || v_mine || '/mine.jpg');
    v_allowed := true;
  exception when others then
    v_allowed := false;
    v_why := sqlstate || ' ' || sqlerrm;
  end;
  reset role;

  perform pg_temp.check_true(
    'the policy refuses a receipt on somebody else''s claim', v_refused);

  -- The control has to have run as the role the policy applies to. A
  -- superuser bypasses row level security, so this insert would have
  -- succeeded no matter what the policy said.
  perform pg_temp.check_true('the control ran under row level security',
    v_role = 'authenticated');
  if not v_allowed then
    raise exception
      'FAIL an employee cannot attach to their own claim: %', v_why;
  end if;
  raise notice 'ok   and accepts one on their own';

  -- ------------------------------------------------------------------
  -- Once it is in the ledger it is the accountant's record
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  update public.expense_claims
     set posted_at = now(), status = 'approved'
   where id = v_mine;

  perform pg_temp.sign_in_as(v_staff_user);
  perform pg_temp.check_true('a posted claim takes no more paperwork',
    not app.can_attach_to(v_org, 'expense_claims', v_mine));

  -- ------------------------------------------------------------------
  -- Staff are unaffected
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an owner may still attach to any claim',
    app.can_attach_to(v_org, 'expense_claims', v_theirs));
  perform pg_temp.check_true('and to a bill',
    app.can_attach_to(v_org, 'purchase_documents', gen_random_uuid()));
end $$;

-- ---------------------------------------------------------------------
-- Nobody outside the company reaches any of it
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := (select id from public.organizations
                        where name = 'Resit Sdn Bhd');
begin
  perform pg_temp.sign_out();
  perform pg_temp.check_true('signed out, nothing is attachable',
    not app.can_attach_to(v_org, 'expense_claims', gen_random_uuid()));
end $$;

rollback;
