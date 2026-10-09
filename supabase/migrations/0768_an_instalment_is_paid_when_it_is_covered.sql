-- =====================================================================
-- 0768 :: an instalment is paid when what was paid covers it
--
-- Answered on 9 October: "the same fix as 0767".
--
-- CP204's schedule already said what was OUTSTANDING on each
-- instalment. The summary behind the tax tile did not read it: it
-- counted an instalment paid, not overdue, and not next due as soon as
-- any payment was recorded against it, and `record_tax_instalment` took
-- an explicit RM0 (the table allows `>= 0`). Reproduced: RM0 and RM1
-- recorded against two overdue RM10,000 instalments took the overdue
-- count from 8 to 6 and the overdue total from RM80,000 to RM60,000, and
-- moved "next due" past both, while the outstanding total still said
-- RM119,999. Production had no tax estimates when this was written.
--
-- 1. `record_tax_instalment` refuses an amount of nil or less -- the
--    amount given, or the scheduled one it defaults to.
-- 2. `tax_estimate_payment_summary` counts an instalment paid only when
--    nothing is outstanding on it, overdue and next due while anything
--    is, and the next due amount is what is still to pay. No column
--    changes, so it is replaced in place and keeps its grants.
--
-- Both restated from `0673`, whose text is the live one: replayed into
-- a rolled-back transaction each hashes to what production's
-- `pg_get_functiondef` hashes to (c0e76cea..., 787bf51d...).
-- =====================================================================

create or replace function public.record_tax_instalment(
  p_estimate_id   uuid,
  p_instalment_no integer,
  p_paid_on       date default null,
  p_amount        numeric default null,
  p_reference     text default null,
  p_notes         text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  v_root   uuid;
  v_sched  numeric;
  v_count  integer;
  v_id     uuid;
  v_amount numeric;
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.can_post(e.org_id) then
    raise exception 'Not permitted to record an instalment'
      using errcode = '42501';
  end if;

  -- The instalment has to be one the schedule actually has. Recording
  -- a thirteenth against a twelve-instalment estimate is not a typo to
  -- tidy up later; it is money somebody will look for and not find.
  select count(*), max(case when s.instalment_no = p_instalment_no
                            then s.amount end)
    into v_count, v_sched
    from public.tax_estimate_schedule(p_estimate_id) s;

  if p_instalment_no > v_count then
    raise exception
      'This estimate has % instalments, not %', v_count, p_instalment_no
      using errcode = '22023';
  end if;

  -- 0768. An instalment is paid with something. The table allowed
  -- nil, and the summary took any recorded row as the instalment paid,
  -- so RM0 took an overdue instalment off the tax tile. The default --
  -- the scheduled figure -- is what is checked, so a bare recording of
  -- an instalment a downward revision reduced to nothing is refused
  -- too: there is nothing to have paid.
  v_amount := round(coalesce(p_amount, v_sched, 0), 2);
  if v_amount <= 0 then
    raise exception
      'An instalment is paid with something: % is not an amount paid to LHDN.',
      v_amount
      using errcode = '23514';
  end if;

  v_root := app.tax_estimate_root(p_estimate_id);

  insert into public.tax_estimate_payments
    (org_id, root_estimate_id, recorded_against_id, instalment_no,
     paid_on, amount, reference, notes, recorded_by)
  values
    (e.org_id, v_root, p_estimate_id, p_instalment_no,
     -- Today rather than an error about a column: somebody recording a
     -- payment almost always means now.
     coalesce(p_paid_on, app.today()),
     -- And the scheduled figure rather than nothing, because paying
     -- exactly what was asked for is the ordinary case and typing it
     -- again is a chance to mistype it.
     v_amount,
     p_reference, p_notes, auth.uid())
  on conflict (org_id, root_estimate_id, instalment_no) do update
     set paid_on = excluded.paid_on,
         amount = excluded.amount,
         reference = excluded.reference,
         notes = excluded.notes,
         recorded_against_id = excluded.recorded_against_id,
         recorded_by = excluded.recorded_by,
         updated_at = now()
  returning id into v_id;

  return v_id;
end; $$;

create or replace function public.tax_estimate_payment_summary(
  p_estimate_id uuid)
returns table (
  scheduled_total   numeric,
  paid_total        numeric,
  outstanding_total numeric,
  instalments       integer,
  instalments_paid  integer,
  overdue_count     integer,
  overdue_total     numeric,
  late_count        integer,
  late_penalty      numeric,
  next_due_on       date,
  next_due_amount   numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare e record; r record; v_today date := app.today();
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;

  return query
  with s as (select * from public.tax_estimate_schedule(p_estimate_id))
  select
    coalesce(sum(s.amount), 0),
    coalesce(sum(s.paid_amount), 0),
    coalesce(sum(s.outstanding), 0),
    count(*)::integer,
    -- Paid IN FULL (0768). Each of these four read `paid_on`, so an
    -- instalment with any payment recorded against it -- RM1 of
    -- RM10,000, or nil -- was paid, not overdue and not next.
    count(*) filter (where s.paid_on is not null and s.outstanding = 0)::integer,
    -- Due, not covered, and the date has gone. An instalment of nothing
    -- -- which a downward revision leaves behind -- is not overdue,
    -- because there was nothing to pay: its outstanding is nil.
    count(*) filter (
      where s.outstanding > 0 and s.due_on < v_today
    )::integer,
    coalesce(sum(s.outstanding) filter (
      where s.outstanding > 0 and s.due_on < v_today), 0),
    count(*) filter (where s.paid_late)::integer,
    -- 10% of what was paid late. Says what the charge comes to, not
    -- that LHDN raised it -- which is not something this can know.
    round(coalesce(sum(s.paid_amount) filter (where s.paid_late), 0)
          * coalesce(r.late_instalment_penalty_percent, 0) / 100, 2),
    -- The next one not covered, and what is still to pay on it.
    min(s.due_on) filter (where s.outstanding > 0),
    (array_agg(s.outstanding order by s.due_on)
       filter (where s.outstanding > 0))[1]
  from s;
end; $$;

comment on function
  public.record_tax_instalment(uuid, integer, date, numeric, text, text) is
  'Records that one instalment was paid. Defaults to today and to the '
  'scheduled amount, because paying what was asked for on the day is '
  'the ordinary case. Keyed to the chain root so it survives a '
  'revision, and refuses an instalment number the schedule does not '
  'have. Refuses an amount of nil or less (0768): the summary reads a '
  'recorded payment against what is outstanding.';
