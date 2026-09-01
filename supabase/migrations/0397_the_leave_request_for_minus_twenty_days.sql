-- =====================================================================
-- iAkauntan :: 0397 the leave request for minus twenty days
--
-- `submit_leave_request` takes the number of days from the caller:
--
--     p_total_days numeric,
--
-- and never relates it to the dates it was given. `leave_requests.sql`
-- has said since it was written that "who may file one, and who may
-- approve it, decides somebody's statutory figures". Nothing anywhere
-- checked *how much*.
--
-- ---------------------------------------------------------------------
-- Measured, on the harness
--
-- An employee with fourteen days of annual leave files one request, for
-- themselves, needing nobody:
--
--     submit_leave_request(org, annual, tomorrow, tomorrow, -20)
--
--   before        entitled 14.00  taken 0.00  pending  0.00  available 14
--   after submit                              pending -20.00 available 34
--   after approve                 taken -20.00 pending 0.00  available 34
--
-- Twenty days of annual leave, out of nothing. The hold is applied as
-- `pending_days = pending_days + p_total_days`, so a negative number
-- subtracts; `decide_leave_request` then moves it into `taken_days`,
-- which is where it stays. Nothing in the arithmetic below it objects,
-- because every step is a correct addition of a number nobody checked.
--
-- The manager approving it sees an ordinary request for one day. The
-- days are on the balance, not on the screen they clicked.
--
-- And unused annual leave is not a formality: it is commonly paid out
-- on termination, and it is what a resignation is settled against.
--
-- The other direction, on unpaid leave, has no balance to bound it at
-- all — the entitlement check is skipped for a type that is not paid,
-- deliberately and correctly. So a one-day request may claim 300 days,
-- and `calculate_payroll_run` reads exactly that figure:
--
--     v_unpaid_amt := v_unpaid * basic_salary / working_days_per_month
--
-- which comes off gross pay, off the EPF wage, off the SOCSO and EIS
-- wages and off taxable income. (It does not run the other way: the
-- payslip line is written only `if v_unpaid_amt > 0`, so a negative
-- figure writes no line and pays nobody extra. It is still recorded in
-- the payslip's own `unpaid_leave_days` and `unpaid_leave_amount`
-- columns, which is a payslip disagreeing with its own lines.)
--
-- ---------------------------------------------------------------------
-- What can be checked from the dates alone, and what cannot
--
-- The upper bound is exact and needs nothing: a request cannot be for
-- more days than the dates it covers. Fourteen calendar days is at most
-- fourteen days of leave.
--
-- The lower bound is not, and this migration does not pretend
-- otherwise. Ten calendar days over Chinese New Year may honestly be
-- three days of leave, and deciding which is which needs the work
-- calendar and the public holiday list — `work_shifts` and
-- `public_holidays` both exist and neither is consulted here. Inventing
-- a rule about working days would be worse than saying it is missing,
-- because it would be wrong for every company whose week is not the one
-- invented. What is enforced instead is that a request is for *some*
-- leave: at least half a day.
--
-- So: positive, at least half a day, no more than the span, and the
-- half-day flag and the figure agree with each other.
--
-- ---------------------------------------------------------------------
-- The half day `0365` guarded and nothing could ask for
--
-- `0365` added `app.enforce_half_day_rule`: a leave type may forbid half
-- days, and a request marked as one is refused if it does. The rule
-- works — put the flag on directly and it fires. Nothing has ever put
-- the flag on. `submit_leave_request` accepts `p_is_half_day` and no
-- caller passes it, which is how this whole sweep began, so `0365`
-- guards a door nobody could open.
--
-- The client half of that is a form field, and it is in this commit.
-- The rule that belongs in the database is the arithmetic: a half day
-- is 0.5 days on a single date, and 0.5 days is a half day. Written
-- both ways round on purpose — without the second, a caller reaches
-- past `0365`'s rule by claiming half a day and leaving the flag off.
--
-- ---------------------------------------------------------------------
-- A trigger, not a check in the function
--
-- `submit_leave_request` is not the only way in. `0038`'s insert policy
-- lets an employee write their own row and HR write anybody's, so the
-- rule has to sit on the table. Same reasoning as `0396`, and the
-- reason `0365` put its own half-day rule there too — this joins it
-- rather than duplicating it, because two triggers reading the same
-- columns is how two rules come to disagree about them.
-- =====================================================================

create or replace function app.check_leave_days()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_span integer := (new.end_date - new.start_date) + 1;
begin
  -- A request is for some leave. Null and zero are the same mistake,
  -- and a negative is the one that pays.
  if coalesce(new.total_days, 0) <= 0 then
    raise exception
      'A leave request is for some leave. % is not a number of days '
      'somebody can be away for.',
      coalesce(new.total_days::text, 'nothing')
      using errcode = '23514';
  end if;
  if new.total_days < 0.5 then
    raise exception
      'The shortest leave is half a day, not %.', new.total_days
      using errcode = '23514';
  end if;

  -- Nobody is away for more days than the request covers. The other
  -- bound is not checked here and the header says why: it needs the
  -- work calendar, and this schema does not consult one.
  if new.total_days > v_span then
    raise exception
      '% to % is % day(s). A request for % of them is for more leave '
      'than the dates cover.',
      to_char(new.start_date, 'DD Mon YYYY'),
      to_char(new.end_date, 'DD Mon YYYY'), v_span, new.total_days
      using errcode = '23514';
  end if;

  -- The flag and the figure, both ways round. Without the second, a
  -- caller reaches past `0365`'s rule by claiming half a day and
  -- leaving the flag off.
  if coalesce(new.is_half_day, false) then
    if new.total_days <> 0.5 then
      raise exception
        'A half day is half a day, not %.', new.total_days
        using errcode = '23514';
    end if;
    if new.start_date <> new.end_date then
      raise exception
        'A half day is on one date. % to % is % days.',
        to_char(new.start_date, 'DD Mon YYYY'),
        to_char(new.end_date, 'DD Mon YYYY'), v_span
        using errcode = '23514';
    end if;
  elsif new.total_days = 0.5 then
    raise exception
      'Half a day is a half-day request. Mark it as one, so the rule '
      'about which leave may be taken in half days is applied to it.'
      using errcode = '23514';
  end if;

  -- Which half is only meaningful on a half day.
  if new.half_day_period is not null
     and not coalesce(new.is_half_day, false) then
    raise exception
      'A morning or an afternoon is a half day. Mark it as one, or '
      'leave the period empty.'
      using errcode = '23514';
  end if;

  return new;
end $$;

-- Before `0365`'s, so the arithmetic is settled before the question of
-- whether this leave type allows a half day at all: `enforce_half_day_rule`
-- reads `is_half_day` and its answer only means something once the flag
-- and the figure are known to agree. Trigger order is by name, and
-- `check_leave_days` sorts before `enforce_half_day_rule`.
create trigger check_leave_days
  before insert or update on public.leave_requests
  for each row execute function app.check_leave_days();

revoke all on function app.check_leave_days() from public, anon, authenticated;

comment on function app.check_leave_days() is
  'The arithmetic of a leave request. `submit_leave_request` takes the '
  'number of days from its caller and `0397` measured what that allowed: '
  'a request for -20 days added twenty days to the employee''s available '
  'balance, and approving it moved them into taken_days for good.';
