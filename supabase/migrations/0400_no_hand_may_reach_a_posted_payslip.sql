-- =====================================================================
-- iAkauntan :: 0400 no hand may reach a posted payslip
--
-- `0238` is called "the ledger becomes append-only" and its second
-- heading is "No hand may reach a posted journal". It is right, and the
-- reasoning is not about the ledger in particular: a figure that has
-- been reported is not a figure anybody may quietly change afterwards.
--
-- Nobody applied it to the payslip.
--
-- ---------------------------------------------------------------------
-- Measured, as an `hr_manager`, on a run whose status is `posted`
--
--   update payslip_lines set amount = 1     -- 550.00 -> 1.00, accepted
--   update payslips set epf_employee = 1,
--                       pcb = 0             -- accepted
--   delete from payslip_lines               -- accepted
--   audit rows written by all of that       -- 0
--
-- `payslip_lines` carries no triggers at all — not `set_updated_at`,
-- not `audit_changes`. `payslips` carries two and neither is about
-- this. So the EPF, SOCSO, EIS and PCB figures on a posted run can be
-- rewritten by hand, and nothing anywhere records that they were.
--
-- What is built from those figures: the EPF, SOCSO and LHDN
-- submissions; `post_payroll_run`'s journal, which has already reached
-- the ledger and is append-only by `0238`; and `0035`'s bank payment
-- file. Editing a posted payslip therefore makes the payslip disagree
-- with a ledger entry that cannot be corrected to match it, and with a
-- return that has been filed.
--
-- `CLAUDE.md` puts it as the project's own rule: "Statutory arithmetic
-- is asserted, not eyeballed … anything touching EPF, SOCSO, EIS, PCB
-- or an SSM deadline needs a test that would fail if the number moved."
-- `payroll_run.sql` and `statutory.sql` assert those numbers thoroughly
-- — at the moment the engine computes them. An assertion about a
-- calculation says nothing about a figure a hand changed afterwards.
--
-- ---------------------------------------------------------------------
-- Frozen when posted, and not before
--
-- Deliberately narrow. A run that is `draft`, `calculated` or
-- `approved` stays fully editable, because correcting a payroll before
-- it is posted is the ordinary business of running one — and because
-- `calculate_payroll_run` rebuilds the payslips from scratch anyway
-- (`delete from public.payslips where run_id = p_run_id`) whenever it
-- is asked to recalculate.
--
-- That is also why this breaks nothing. `calculate_payroll_run` refuses
-- outright unless the run is `draft` or `calculated`:
--
--     if v_run.status not in ('draft', 'calculated') then
--       raise exception 'This run is % and can no longer be recalculated'
--
-- and `post_payroll_run` writes only to `payroll_runs`. Checked, not
-- assumed: the engine is the only writer of either table, and it never
-- touches a posted run.
--
-- `void` is not frozen. Voiding is how a run is undone, and `0041`'s
-- reversal is the shape that undoing takes — a correction that is
-- visible, not one that overwrites.
--
-- ---------------------------------------------------------------------
-- A trigger, not a narrower policy
--
-- The policy `0038` wrote is `for all … using (app.can_run_payroll)`,
-- one line in a pattern applied across a dozen HR tables, with the
-- comment above it explaining only the *select* side. It was never a
-- decision about hand-editing statutory figures; it is the default that
-- fell out of a sweep. Narrowing it to exclude posted runs would put
-- the rule in a `using` clause where the next table added to that sweep
-- would not inherit it, and would give a bare `42501` with nothing to
-- read. A trigger says what happened and why.
--
-- What is *not* changed: `app.can_run_payroll` still decides who may
-- run payroll at all, and an unposted run is still theirs to correct.
-- This migration only says that posting is the point of no return, and
-- says it in the one place both tables pass through.
-- =====================================================================

create or replace function app.refuse_posted_payslip_change()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_run    uuid;
  v_status text;
  v_no     text;
begin
  -- The run to ask about is on the row for `payslips` and one join away
  -- for `payslip_lines`. On a delete there is no `new`.
  if tg_table_name = 'payslips' then
    v_run := coalesce(new.run_id, old.run_id);
  else
    select p.run_id into v_run from public.payslips p
     where p.id = coalesce(new.payslip_id, old.payslip_id);
  end if;

  select r.status::text, r.run_no into v_status, v_no
    from public.payroll_runs r where r.id = v_run;

  -- No run to speak of is not this trigger's business to refuse.
  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status in ('posted', 'paid') then
    raise exception
      'Payroll run % is %. Its payslips are what the EPF, SOCSO and '
      'LHDN submissions and the bank file were built from, and its '
      'journal is already in the ledger, which `0238` made append-only. '
      'Correct it by voiding the run and raising another, so the '
      'correction is visible; do not change the figures underneath it.',
      v_no, v_status
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end $$;

comment on function app.refuse_posted_payslip_change() is
  '`0238` for the payslip. Measured before `0400`: on a posted run an '
  'hr_manager could rewrite a payslip line from 550.00 to 1.00, rewrite '
  'the header''s epf_employee and pcb, and delete a line, with no audit '
  'row written by any of it.';

create trigger refuse_posted_change
  before update or delete on public.payslips
  for each row execute function app.refuse_posted_payslip_change();

create trigger refuse_posted_change
  before update or delete on public.payslip_lines
  for each row execute function app.refuse_posted_payslip_change();

revoke all on function app.refuse_posted_payslip_change()
  from public, anon, authenticated;
