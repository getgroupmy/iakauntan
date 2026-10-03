-- ---------------------------------------------------------------------
-- 0737  Four statutory papers, and a refund paid twice
--
-- The census's 38 down to 26: four wrappers and eight verdicts, every one
-- of the twelve MEASURED by calling the function twice against a built
-- database and counting what was left, not by reading the body.
--
-- This is the tranche where the duplicate is a DOCUMENT SOMEBODY ELSE
-- HOLDS. Three of the four leave a second paper outside the company --
-- with LHDN, with an employee, with a bank -- and the fourth pays real
-- money out twice.
--
-- | | |
-- | --- | --- |
-- | `settle_deposit` | **Measured: a 1,000 deposit went to 400 on two taps of a 300 refund.** 600 left the bank for a 300 refund, and the deposit note shows two events |
-- | `create_withholding` | two withholding certificates on one bill, each with its own number from `next_document_number` and its own one-month remittance deadline |
-- | `revise_tax_estimate` | **two live CP204 revisions of the same estimate.** Measured: the original is superseded once, and both revisions stay current |
-- | `submit_leave_request` | two requests AND **four pending days from one two-day request**, so the employee's balance is wrong and the approver has two identical rows |
--
-- `settle_deposit` is the worst of the eighteen wrapped so far.
-- Everything else in this programme leaves a row, a balance or a
-- message; this one moves money out of a bank account. The guard it has
-- -- "Deposit % has % left and this would take %" -- catches only the
-- FULL settlement. A partial refund retried takes the amount twice and
-- both calls are within the balance, which is why reading the body
-- found nothing and calling it twice found it at once.
--
-- `revise_tax_estimate` and `create_withholding` are the first statutory
-- filings in this programme. A second CP204 revision for the same year
-- of assessment is not a row somebody deletes: the revision month is
-- stamped on it, the instalment schedule is recomputed from it, and
-- which of the two the Revenue is holding is not a question the database
-- can answer.
--
-- `submit_leave_request` doubles twice over, and the second is the one
-- that is hard to see: `leave_balances.pending_days` went to 4 for a
-- two-day request. Deleting the duplicate request does not put the two
-- days back.
--
-- ## Eight verdicts, also measured
--
-- Seven refuse by name on a second call, and the eighth never gets as
-- far as a row:
--
-- * `clear_pdc` — "That cheque is cleared."
-- * `bounce_pdc` — "That cheque is bounced."
--   Both guard `status not in ('held','deposited')`, and the first call
--   moves the status out of that set.
-- * `receive_stock_transfer` — "That transfer is received, so there is
--   nothing on its way to receive."
-- * `bill_matter_time` and `bill_project_time` — "No unbilled chargeable
--   time on this engagement between % and %." The first call sets
--   `is_billed` on every entry it billed, and the check that raises this
--   runs BEFORE the invoice is inserted, so the second call writes
--   nothing at all.
-- * `recognise_revenue` — measured: first call made one journal, second
--   made none. It walks `revenue_schedule_periods where gl_entry_id is
--   null` and fills that column in.
-- * `run_depreciation` — measured: the first call returned a run id, the
--   second returned NULL, and ONE run row survived. `v_charge` is the
--   difference between what the asset should have depreciated to and
--   what it has, which is zero on a retry at the same date; the function
--   then deletes the empty run it opened. The null return is a wart --
--   a client that retries is told nothing happened rather than being
--   handed the first run -- but nothing is duplicated.
-- * `transition_ticket` — measured: two calls to the same status left
--   ONE `ticket_events` row. `if v_t.status = p_to then return; end if;`
--   is the first line of the internal, and it is the only one of the
--   eight whose guard is an early return rather than a raise.
--
-- ## Where the organization comes from
--
-- Only `submit_leave_request` takes one. The other three are given a
-- deposit note, a bill and an estimate, and the organization is read off
-- that row before the key is claimed -- which is what makes `0475`'s
-- membership guard apply to the key as well as to the write.
--
-- ## The arguments the client was not sending
--
-- `check_idempotent_calls.py` requires every parameter to be named,
-- because a wrapper that needs an overload resolved by name can have no
-- defaults. Six were being omitted conditionally and every one of them
-- is a `coalesce(p_x, ...)` in the body, so an explicit null is the same
-- call: `create_withholding`'s `p_gross_amount`, `p_rate` and
-- `p_cert_date`, `submit_leave_request`'s `p_reason`,
-- `p_half_day_period` and `p_contact_while_away`. `p_employee_id` was
-- never sent either and null there means "me", which is what the screen
-- intends. `settle_deposit` was missing only `p_date`.
--
-- `p_is_half_day` is the exception: it defaults to FALSE and not null, so
-- the wrapper passes `coalesce(p_is_half_day, false)` inward. The
-- fingerprint still records what the caller actually sent.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- settle_deposit
-- ---------------------------------------------------------------------
create or replace function public.settle_deposit(
  p_deposit uuid, p_kind text, p_amount numeric, p_reason text,
  p_bank uuid, p_date date, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select d.org_id into v_org from public.deposit_notes d
   where d.id = p_deposit;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'settle_deposit',
      jsonb_build_object('deposit', p_deposit, 'kind', p_kind,
                         'amount', p_amount, 'reason', p_reason,
                         'bank', p_bank, 'date', p_date));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.settle_deposit(p_deposit, p_kind, p_amount, p_reason,
                                p_bank, p_date);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- create_withholding
-- ---------------------------------------------------------------------
create or replace function public.create_withholding(
  p_bill_id uuid, p_wht_code text, p_gross_amount numeric, p_rate numeric,
  p_cert_date date, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  -- `deleted_at is null` as well as the id, so the key is claimed
  -- against the same bill the inner function will agree to work on.
  select b.org_id into v_org from public.purchase_documents b
   where b.id = p_bill_id and b.deleted_at is null;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'create_withholding',
      jsonb_build_object('bill', p_bill_id, 'code', p_wht_code,
                         'gross', p_gross_amount, 'rate', p_rate,
                         'cert_date', p_cert_date));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.create_withholding(p_bill_id, p_wht_code, p_gross_amount,
                                    p_rate, p_cert_date);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- revise_tax_estimate
-- ---------------------------------------------------------------------
create or replace function public.revise_tax_estimate(
  p_estimate_id uuid, p_estimated_tax numeric, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select e.org_id into v_org from public.tax_estimates e
   where e.id = p_estimate_id;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'revise_tax_estimate',
      jsonb_build_object('estimate', p_estimate_id,
                         'estimated_tax', p_estimated_tax));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.revise_tax_estimate(p_estimate_id, p_estimated_tax);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- submit_leave_request
-- ---------------------------------------------------------------------
create or replace function public.submit_leave_request(
  p_org_id uuid, p_leave_type_id uuid, p_start_date date, p_end_date date,
  p_total_days numeric, p_reason text, p_is_half_day boolean,
  p_half_day_period text, p_employee_id uuid, p_contact_while_away text,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_seen jsonb; v_id uuid;
begin
  v_seen := app.idempotency_begin(p_org_id, p_idempotency_key,
    'submit_leave_request',
    jsonb_build_object('leave_type', p_leave_type_id,
                       'start_date', p_start_date,
                       'end_date', p_end_date,
                       'total_days', p_total_days,
                       'reason', p_reason,
                       'is_half_day', p_is_half_day,
                       'half_day_period', p_half_day_period,
                       'employee', p_employee_id,
                       'contact_while_away', p_contact_while_away));
  if v_seen is not null then
    return nullif(v_seen ->> 'id', '')::uuid;
  end if;

  -- `coalesce(.., false)` because this is the one argument whose default
  -- is not null. A caller who omits it means "a whole day", and null
  -- would reach the insert as null rather than as false.
  v_id := public.submit_leave_request(p_org_id, p_leave_type_id,
    p_start_date, p_end_date, p_total_days, p_reason,
    coalesce(p_is_half_day, false), p_half_day_period, p_employee_id,
    p_contact_while_away);
  perform app.idempotency_end(p_org_id, p_idempotency_key,
                              jsonb_build_object('id', v_id));
  return v_id;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- these are new signatures and arrive with no grant at all.
grant execute on function public.settle_deposit(
  uuid, text, numeric, text, uuid, date, text) to authenticated;
grant execute on function public.create_withholding(
  uuid, text, numeric, numeric, date, text) to authenticated;
grant execute on function public.revise_tax_estimate(
  uuid, numeric, text) to authenticated;
grant execute on function public.submit_leave_request(
  uuid, uuid, date, date, numeric, text, boolean, text, uuid, text, text)
  to authenticated;

comment on function public.settle_deposit(
  uuid, text, numeric, text, uuid, date, text) is
  'Settles a deposit once per idempotency key. MEASURED: without one, '
  'two taps of a 300 refund took a 1,000 deposit to 400 -- 600 out of '
  'the bank for a 300 refund, and two events on the note. The balance '
  'guard the function already has catches only a FULL settlement; a '
  'partial one retried is within the balance both times. The '
  'organization comes from the deposit note. Every parameter must be '
  'named. Refuses a key already used for different arguments (22023), a '
  'key still in flight (55006), and a caller who is not a member of the '
  'organization.';

comment on function public.create_withholding(
  uuid, text, numeric, numeric, date, text) is
  'Raises one withholding certificate per idempotency key. MEASURED: '
  'without one, two taps left two certificates on the same bill, each '
  'with its own number and its own one-month remittance deadline. The '
  'organization comes from the bill. As settle_deposit for the key and '
  'the refusals.';

comment on function public.revise_tax_estimate(uuid, numeric, text) is
  'Revises a CP204 estimate once per idempotency key. MEASURED: without '
  'one, two taps left TWO live revisions of the same estimate -- the '
  'original is superseded once and both revisions stay current, each '
  'with its own revision month and instalment schedule. The '
  'organization comes from the estimate. As settle_deposit for the key '
  'and the refusals.';

comment on function public.submit_leave_request(
  uuid, uuid, date, date, numeric, text, boolean, text, uuid, text, text) is
  'Files one leave request per idempotency key. MEASURED: without one, '
  'two taps left two requests AND four pending days for a two-day '
  'request, so deleting the duplicate does not put the balance back. '
  'p_is_half_day is the one argument whose default is false rather than '
  'null and the wrapper coalesces it inward. As settle_deposit for the '
  'key and the refusals.';
