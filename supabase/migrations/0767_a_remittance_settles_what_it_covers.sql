-- =====================================================================
-- 0767 :: a remittance settles what it covers
--
-- Answered on 9 October: "refuse nil, and show the shortfall".
--
-- `report_statutory_remittances` decided whether KWSP, PERKESO or LHDN
-- had been paid by asking whether a `statutory_remittances` row
-- existed, and `report_statutory_due` -- the list that chases what is
-- about to be late -- dropped anything with one. The amount on the row
-- was never read back. Reproduced against an overdue RM1,200 of EPF:
-- recording RM0, or RM1, made it "not overdue" and took it off the
-- list. `record_statutory_remittance` took a negative amount too.
--
-- And the app could send nil without meaning to: the amount box starts
-- at what is owed, but it is free text read with `double.tryParse(...)
-- ?? 0`, so clearing it, or typing "1,234.50", recorded RM0 and said
-- "Recorded". The app now reads the comma; this refuses the nil.
--
-- Production had no remittances recorded, against nine posted
-- payrolls, when this was written, so nothing had been hidden.
--
-- 1. `record_statutory_remittance` refuses an amount of nil or less.
-- 2. `report_statutory_remittances` returns what was sent and what is
--    still short, and a contribution is overdue until what was sent
--    covers it. Sending more is allowed -- arrears are paid that way.
--    New columns are appended, so nothing reading the old ones moves;
--    the return type changes, so the function is dropped and made
--    again, with its grant and comment.
-- 3. `report_statutory_due` chases anything still short.
--
-- All three restated from `0457`, whose text is the live one: replayed
-- into a rolled-back transaction each hashes to what production's
-- `pg_get_functiondef` hashes to (e5ed9d33..., 16a29e1a...,
-- 1626e6b6...).
-- =====================================================================

create or replace function public.record_statutory_remittance(
  p_org_id    uuid,
  p_period_id uuid,
  p_code      text,
  p_amount    numeric,
  p_paid_on   date default null,
  p_reference text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_pay date;
  v_id  uuid;
begin
  if not app.can_run_payroll(p_org_id) then
    raise exception 'Only somebody who may run payroll may record a remittance'
      using errcode = '42501';
  end if;

  select p.pay_date into v_pay
    from public.pay_periods p
   where p.id = p_period_id and p.org_id = p_org_id;
  if v_pay is null then
    raise exception 'No such pay period in this company' using errcode = '22023';
  end if;

  if not exists (select 1 from public.ref_statutory_remittances r
                  where r.code = p_code) then
    raise exception 'Nobody is owed anything called %', p_code
      using errcode = '22023';
  end if;

  -- 0767. A remittance is for something. The report used to count any
  -- row as the payment, so recording nil -- the app sent nil whenever
  -- the amount would not parse, "1,234.50" among them -- took an
  -- overdue contribution off every list that chased it.
  if round(coalesce(p_amount, 0), 2) <= 0 then
    raise exception
      'A remittance is for something: % is not an amount sent to anybody.',
      round(coalesce(p_amount, 0), 2)
      using errcode = '23514';
  end if;

  -- Against a payroll that has been posted. Recording a payment to
  -- KWSP for a run still in draft would be recording a payment of a
  -- figure that can still change.
  if not exists (select 1 from public.payroll_runs r
                  where r.org_id = p_org_id and r.period_id = p_period_id
                    and r.status in ('posted', 'paid')) then
    raise exception
      'That payroll has not been posted, so what is owed is not settled yet.'
      using errcode = '22023';
  end if;

  insert into public.statutory_remittances
    (org_id, period_id, code, amount, due_date, paid_on, reference, paid_by)
  values (p_org_id, p_period_id, p_code, round(coalesce(p_amount, 0), 2),
          app.remittance_due(v_pay, p_code),
          coalesce(p_paid_on, app.today()),
          nullif(btrim(p_reference), ''), auth.uid())
  on conflict (org_id, period_id, code) do update
     set amount = excluded.amount,
         paid_on = excluded.paid_on,
         reference = excluded.reference,
         paid_by = excluded.paid_by
  returning id into v_id;

  return v_id;
end;
$$;

drop function public.report_statutory_remittances(uuid, date, date);

create or replace function public.report_statutory_remittances(
  p_org_id uuid,
  p_from   date default null,
  p_to     date default null)
returns table (
  period_id       uuid,
  period_code     text,
  pay_date        date,
  code            text,
  name            text,
  authority       text,
  employee_amount numeric,
  employer_amount numeric,
  total_amount    numeric,
  due_date        date,
  paid_on         date,
  reference       text,
  is_overdue      boolean,
  paid_amount     numeric,
  short_amount    numeric)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  with runs as (
    -- Only what has been posted. A draft run is an intention, and the
    -- money it names has not been deducted from anybody.
    select r.period_id, p.code as period_code, p.pay_date,
           sum(r.total_epf_employee)   as epf_e,
           sum(r.total_epf_employer)   as epf_r,
           sum(r.total_socso_employee) as soc_e,
           sum(r.total_socso_employer) as soc_r,
           sum(r.total_eis_employee)   as eis_e,
           sum(r.total_eis_employer)   as eis_r,
           sum(r.total_pcb)            as pcb,
           sum(r.total_hrdf)           as hrdf,
           sum(r.total_zakat)          as zakat
      from public.payroll_runs r
      join public.pay_periods p on p.id = r.period_id
     where r.org_id = p_org_id
       and r.status in ('posted', 'paid')
       and (p_from is null or p.pay_date >= p_from)
       and (p_to is null or p.pay_date <= p_to)
     group by r.period_id, p.code, p.pay_date
  ),
  split as (
    select r.period_id, r.period_code, r.pay_date, x.code,
           x.employee_amount, x.employer_amount
      from runs r
      cross join lateral (values
        ('epf',   r.epf_e, r.epf_r),
        ('socso', r.soc_e, r.soc_r),
        ('eis',   r.eis_e, r.eis_r),
        ('pcb',   0::numeric, r.pcb),
        ('hrdf',  0::numeric, r.hrdf),
        ('zakat', 0::numeric, r.zakat)
      ) as x(code, employee_amount, employer_amount)
  )
  select s.period_id, s.period_code, s.pay_date, s.code, ref.name,
         ref.authority,
         round(s.employee_amount, 2), round(s.employer_amount, 2),
         round(s.employee_amount + s.employer_amount, 2),
         app.remittance_due(s.pay_date, s.code),
         sr.paid_on, sr.reference,
         -- Overdue until what was sent COVERS what is owed (0767). It
         -- asked only whether a payment had been recorded, so RM1
         -- against RM1,200 of EPF read as paid and stopped the chase.
         coalesce(sr.amount, 0)
             < round(s.employee_amount + s.employer_amount, 2)
           and app.remittance_due(s.pay_date, s.code) is not null
           and app.remittance_due(s.pay_date, s.code) < app.today(),
         sr.amount,
         greatest(round(s.employee_amount + s.employer_amount, 2)
                  - coalesce(sr.amount, 0), 0)
    from split s
    join public.ref_statutory_remittances ref on ref.code = s.code
    left join public.statutory_remittances sr
           on sr.org_id = p_org_id and sr.period_id = s.period_id
          and sr.code = s.code
   where app.can_run_payroll(p_org_id)
     -- A body that took nothing this month is not a line on a list of
     -- what to pay. A company outside the levy's scope would otherwise
     -- be reminded of HRD Corp every month for ever.
     and s.employee_amount + s.employer_amount <> 0
   order by s.pay_date desc, ref.sort_order;
$$;

revoke all on function public.report_statutory_remittances(uuid, date, date)
  from public, anon;
grant execute on function public.report_statutory_remittances(uuid, date, date)
  to authenticated;

comment on function public.report_statutory_remittances(uuid, date, date) is
  'What a posted payroll leaves the company owing KWSP, PERKESO, LHDN '
  'and HRD Corp, with the fifteenth of the following month against '
  'each, and whether it went. See 0457. A contribution is settled only '
  'when what was sent covers it: `paid_amount` is what was recorded and '
  '`short_amount` what is still owed, and one short-paid stays overdue '
  '(0767).';

create or replace function public.report_statutory_due(
  p_org_id      uuid,
  p_within_days integer default 30)
returns table (
  period_code  text,
  pay_date     date,
  code         text,
  name         text,
  authority    text,
  total_amount numeric,
  due_date     date,
  days_left    integer,
  is_overdue   boolean)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select r.period_code, r.pay_date, r.code, r.name, r.authority,
         r.total_amount, r.due_date,
         (r.due_date - app.today())::integer, r.is_overdue
    from public.report_statutory_remittances(p_org_id, null, null) r
   -- Still owed in part counts as owed (0767), not "a payment exists".
   where r.short_amount > 0
     and r.due_date is not null
     and r.due_date <= app.today() + coalesce(p_within_days, 30)
   order by r.due_date, r.code;
$$;

comment on function public.record_statutory_remittance(uuid, uuid, text, numeric, date, text) is
  'Records a payment over to KWSP, PERKESO or the Inland Revenue Board '
  'against a pay period. ONLY AGAINST A POSTED PAYROLL: recording a '
  'payment to KWSP for a run still in draft would be recording a '
  'payment of a figure that can still change. The code must be one the '
  'system knows somebody is owed under. Needs `can_run_payroll`, which '
  'is its own permission -- what people are paid is not something '
  'everybody who may edit a customer should see. REFUSES AN AMOUNT OF '
  'NIL OR LESS (0767): a recorded payment is what the reports read as '
  'the contribution having gone.';
