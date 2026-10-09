-- =====================================================================
-- 0769 :: one payroll for one pay period
--
-- Answered on 9 October: "one live run per period".
--
-- `create_payroll_run` asked only `can_run_payroll`, and
-- `calculate_payroll_run` pays every employee active in the period
-- their whole basic salary -- there are no run types, so a second run
-- over a period can only be the first one again. Reproduced: two
-- January runs, both calculated and posted. One RM5,000 employee had
-- two payslips and RM10,000 of basic; the salary journal doubled; EPF
-- owed went from RM1,200 to RM2,400. The app's "New run" offered
-- January again. No production period had a second run when this was
-- written.
--
-- 1. A partial unique index: one run per pay period that is not void.
--    It holds whatever writes the row -- `payroll_runs` is writable by
--    somebody who may run payroll -- and it is what settles two people
--    pressing the button at once.
-- 2. `create_payroll_run` refuses first, naming the run that exists,
--    so the person is told what to do rather than shown a constraint.
--    Restated from `0037`, whose text is the live one: replayed into a
--    rolled-back transaction it hashes to what production's
--    `pg_get_functiondef` hashes to (f3539b22...). The idempotent
--    wrapper (`0738`) calls it and needs no change: a replay of the
--    same key hands back the run it made.
-- =====================================================================

create unique index if not exists payroll_runs_one_live_per_period
  on public.payroll_runs (org_id, period_id)
  where status <> 'void';

create or replace function public.create_payroll_run(
  p_org_id uuid, p_period_id uuid, p_description text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id   uuid;
  v_live public.payroll_runs;
begin
  if not app.can_run_payroll(p_org_id) then
    raise exception 'Not permitted to run payroll' using errcode = '42501';
  end if;

  -- 0769. One run for one period. Every run pays every employee the
  -- whole period, so a second is the first one paid again.
  select * into v_live from public.payroll_runs r
   where r.org_id = p_org_id and r.period_id = p_period_id
     and r.status <> 'void'
   limit 1;
  if v_live.id is not null then
    raise exception
      'Pay period % already has payroll run % (%). Recalculate that run '
      'rather than starting another: each run pays every employee for '
      'the whole period.',
      (select p.code from public.pay_periods p where p.id = p_period_id),
      v_live.run_no, v_live.status
      using errcode = '23505';
  end if;

  insert into public.payroll_runs
    (org_id, run_no, period_id, description, created_by)
  values (p_org_id, public.next_document_number(p_org_id, 'payroll_run'),
          p_period_id, p_description, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_payroll_run(uuid, uuid, text) is
  'Opens a payroll run over a pay period, ready for employees to be '
  'added and the statutory amounts computed. Needs `can_run_payroll`, '
  'which is its own permission and not `can_write` -- what people are '
  'paid is not something everybody who may edit a customer should see. '
  'Refuses a period that already has a run that is not void (0769): '
  'every run pays every employee for the whole period.';
