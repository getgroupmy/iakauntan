-- =====================================================================
-- iAkauntan :: 0795 a decision is the approver's
--
-- An expense claim goes up a chain of approvers (`0119`), each step
-- decided with `decide_claim_step`, and "only now is it approved" when
-- the last of them says yes; payroll then pays every approved claim
-- that is due (`calculate_payroll_run`). A leave request is filed with
-- `submit_leave_request`, which checks the balance and holds the days,
-- and decided with `decide_leave_request`, which moves them from held
-- to taken. `0038` said of the leave table's own policy:
--
--     A submitted request is out of the employee's hands; only HR or
--     the manager can change it after that, and they do it through
--     the RPC.
--
-- But the policies said less. `expense_claims_update` and
-- `leave_requests_update` let the employee write their own draft, and
-- HR, a manager and (for claims) anybody who may post write any row,
-- each WITH CHECK only that the HR module is on; the INSERT policies
-- asked whose the row was and never what it said. Measured on
-- 10 October 2026, locally, as a member with the employee's role -- no
-- HR, no posting: a claim inserted as 'approved' for RM5,000, and the
-- employee's own draft turned 'approved' at RM9,000. No step of any
-- chain was asked. The owner's next payroll run put RM14,000 on that
-- employee's payslip -- gross RM17,000 on a salary of RM3,000. The same
-- employee approved their own leave both ways; the balance was never
-- asked and the days were never taken. And the roads the policies open
-- to the people above: an accountant approving their own claim, and a
-- manager or accountant moving an approved claim onto another employee.
--
-- The app files a claim by inserting it as 'submitted' (the chain is
-- built on that insert), and does everything else on both tables
-- through the functions; it never updates or deletes either directly.
--
-- Answered "guard both tables". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger depth
-- -- that:
--
--   * files a claim as anything but a draft or submitted, or a leave
--     request as anything but a draft (`submit_leave_request` files
--     leave), or files either with its decision, posting or payment
--     already written;
--   * writes the status of either -- a decision is made by the
--     functions that ask whether the person may make it;
--   * changes anything on a request that has left draft;
--   * changes, on a draft, the company, the employee, or the decision,
--     posting and payment columns;
--   * deletes a request that has left draft.
--
-- The functions that file, decide, post and pay are SECURITY DEFINER
-- and run as their owner, so they pass. NOT security definer itself.
--
-- Production held no claim and no leave request on 10 October.
-- =====================================================================

create or replace function app.request_decision_is_the_databases()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_what  text := case tg_table_name
                    when 'expense_claims' then 'claim' else 'leave request' end;
  v_col   text;
  v_old   jsonb;
  v_new   jsonb;
  -- What a decision, a posting and a payment write. A column one table
  -- does not have reads as null on both sides and is never asked.
  v_decision constant text[] := array[
    'approved_amount', 'approver_id', 'decided_at', 'decision_note',
    'gl_entry_id', 'posted_at', 'paid_at'];
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception
        'A % that is % is the record of it, and is not deleted.',
        v_what, old.status
        using errcode = '42501';
    end if;
    return old;
  end if;

  v_new := to_jsonb(new);

  if tg_op = 'INSERT' then
    if tg_table_name = 'leave_requests' and new.status <> 'draft' then
      raise exception
        'Leave is filed with submit_leave_request, which checks the '
        'balance and holds the days.'
        using errcode = '42501';
    end if;
    if new.status not in ('draft', 'submitted') then
      raise exception
        'A claim is filed as a draft or submitted; it is approved or '
        'rejected through its approval chain.'
        using errcode = '42501';
    end if;
    foreach v_col in array v_decision loop
      if (v_col = 'approved_amount'
          and coalesce((v_new ->> v_col)::numeric, 0) <> 0)
         or (v_col <> 'approved_amount' and v_new ->> v_col is not null) then
        raise exception
          'The % of a % is written when it is decided, not when it is '
          'filed.', replace(v_col, '_', ' '), v_what
          using errcode = '42501';
      end if;
    end loop;
    return new;
  end if;

  if new.status is distinct from old.status then
    raise exception
      'A % is decided through its approval, not by writing its status.',
      v_what
      using errcode = '42501';
  end if;

  v_old := to_jsonb(old);
  -- Every column, `updated_at` too: this trigger fires first, so
  -- nothing of the database's own has touched the row yet.
  for v_col in select k from jsonb_object_keys(v_new) k order by k loop
    -- A draft is still the employee's to write, but not whose it is,
    -- nor what was decided, posted or paid on it.
    continue when old.status = 'draft'
              and v_col <> all (v_decision || array['org_id', 'employee_id']);
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception
        'The % of a % that is % is the database''s to write, not a '
        'client''s.', replace(v_col, '_', ' '), v_what, old.status
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $$;

revoke all on function app.request_decision_is_the_databases() from public, anon, authenticated;

comment on function app.request_decision_is_the_databases() is
  'On expense claims and leave requests: refuses a client''s own '
  'statement that files one already decided (or leave other than as a '
  'draft), writes a status, changes anything once it has left draft, '
  'changes the company, employee, decision, posting or payment of a '
  'draft, or deletes one that has left draft. The functions that file, '
  'decide, post and pay run as their owner and pass. 0795.';

-- Named to sort first. BEFORE triggers fire in name order, and whose
-- the write is comes before what it says: `check_leave_days` and
-- `refuse_reposting` would otherwise answer a client's forgery with a
-- complaint about the figures.
create trigger a_decision_is_the_approvers
  before insert or update or delete on public.expense_claims
  for each row execute function app.request_decision_is_the_databases();

create trigger a_decision_is_the_approvers
  before insert or update or delete on public.leave_requests
  for each row execute function app.request_decision_is_the_databases();
