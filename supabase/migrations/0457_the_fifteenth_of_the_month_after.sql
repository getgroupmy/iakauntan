-- ---------------------------------------------------------------------
-- 0457  The fifteenth of the month after
-- ---------------------------------------------------------------------
-- Measured across every function in `public` and `app`: nothing named
-- CP39, EA, Form E, KWSP Form A or the PERKESO 8A, and no function
-- whose name contains `contribution`. `payroll_payment_instruction`
-- writes a bank file, and it pays the **staff**. What the company owes
-- the four bodies that took a slice of the same payroll -- KWSP,
-- PERKESO twice over, and LHDN -- is computed correctly, posted
-- correctly to the ledger, and then never mentioned again.
--
-- A payroll run therefore ends with the money out of the company and
-- five separate liabilities sitting in the accounts with nobody
-- reminded of them. Every one has the same deadline and every one
-- carries a penalty:
--
--   | body | what | late |
--   |---|---|---|
--   | KWSP | EPF, both halves | dividend plus a late-payment charge |
--   | PERKESO | SOCSO, both halves | interest |
--   | PERKESO | EIS, both halves | interest |
--   | LHDN | PCB and CP38 | an increase under section 103 |
--   | HRD Corp | the levy, employer only | 10 per cent |
--
-- ### The date
--
-- The fifteenth of the month following the month the wages were
-- **paid** -- not the month they were earned. A December salary paid on
-- 5 January is remitted by 15 February, and a company that reads the
-- period rather than the pay date will be a month early all year and a
-- month late once.
--
-- The day itself is a row, not a line of code:
-- `ref_statutory_remittances.due_day`. It has moved before -- PCB was
-- the tenth until LHDN moved it to the fifteenth -- and the next time
-- it moves this should be an update, not a migration to a function
-- body. That is the same reason `statutory_rates` is a table.
--
-- ### Zakat has no day here, deliberately
--
-- It is deducted through payroll and remitted to a state authority
-- under whatever arrangement the employer has with it. There is no
-- federal date, so `due_day` is null and the report says so rather than
-- inventing a deadline and colouring it red. A made-up deadline is
-- worse than none: it teaches people to ignore the ones that are real.
--
-- ### Mutants
--
-- Seven, restated into a built database and run against
-- `supabase/tests/statutory_remittances.sql`. Seven kills, on seven
-- different assertions:
--
--   * due in the month the wages were paid rather than the month after
--     -- killed by "wages paid in January are remitted in February",
--     2026-01-15 for 2026-02-15. Every payment a month early, for ever;
--   * the day hard-coded rather than read from the table -- killed by
--     the same assertion, reading **2026-02-10**, which is not an
--     arbitrary wrong answer: it is PCB's old deadline, and it is what
--     this code would say today if the day had been written into it
--     when the rule was written;
--   * a draft payroll counted as money owed -- killed by "a calculated
--     run owes nobody yet", 4 for 0. The figures exist and can still
--     change, and nothing has been deducted from anybody;
--   * bodies owed nothing listed anyway -- killed by "a body owed
--     nothing is not on the list". A company outside the levy's scope
--     would be reminded of HRD Corp every month for ever;
--   * the employee half reported as the amount to send -- killed by
--     "and the total is the two together", **550 for 1200**: what the
--     company deducted rather than what it owes, and a company that
--     paid the smaller figure would be short by the employer's half
--     every month;
--   * recording open to anybody in the company -- killed by "nor may
--     they record one";
--   * a remittance recorded against a payroll that has not been posted
--     -- killed by "and cannot be recorded as remitted".
-- ---------------------------------------------------------------------

create table public.ref_statutory_remittances (
  code          text primary key,
  name          text not null,
  authority     text not null,
  -- Null where no statute names a day. See the note above.
  due_day       smallint,
  employer_only boolean not null default false,
  sort_order    smallint not null default 0,
  note          text,
  constraint remittance_day_is_a_day
    check (due_day is null or due_day between 1 and 28)
);

insert into public.ref_statutory_remittances
  (code, name, authority, due_day, employer_only, sort_order, note)
values
  ('epf', 'EPF contributions', 'Kumpulan Wang Simpanan Pekerja',
   15, false, 1,
   'Employee and employer halves, remitted together on Form A.'),
  ('socso', 'SOCSO contributions', 'PERKESO', 15, false, 2,
   'Employment Injury and Invalidity schemes.'),
  ('eis', 'EIS contributions', 'PERKESO', 15, false, 3,
   'Employment Insurance System, on the same schedule as SOCSO.'),
  ('pcb', 'Monthly tax deduction (PCB)', 'Lembaga Hasil Dalam Negeri',
   15, true, 4,
   'Deducted from the employee, so the employer half is nil; CP38 '
   'instalments are remitted with it. The day was the tenth until '
   'LHDN moved it.'),
  ('hrdf', 'HRD Corp levy', 'HRD Corp', 15, true, 5,
   'Employer only, for employers within the Act''s scope.'),
  ('zakat', 'Zakat deducted', 'State zakat authority', null, true, 6,
   'Deducted through payroll and remitted under the arrangement the '
   'employer has with its state authority. No federal date.');

alter table public.ref_statutory_remittances enable row level security;

create policy ref_statutory_remittances_select
  on public.ref_statutory_remittances for select using (true);

revoke all on public.ref_statutory_remittances from public;
grant select on public.ref_statutory_remittances to authenticated, anon;

-- ---------------------------------------------------------------------
-- What the company actually sent, and when
-- ---------------------------------------------------------------------
create table public.statutory_remittances (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id)
               on delete cascade,
  period_id  uuid not null references public.pay_periods (id)
               on delete cascade,
  code       text not null references public.ref_statutory_remittances (code),
  amount     numeric(18,2) not null,
  due_date   date,
  paid_on    date not null,
  reference  text,
  paid_by    uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, period_id, code)
);

create index statutory_remittances_org_idx
  on public.statutory_remittances (org_id, paid_on desc);

alter table public.statutory_remittances enable row level security;

create policy statutory_remittances_select on public.statutory_remittances
  for select using (app.can_run_payroll(org_id));

-- Written only through `record_statutory_remittance`, which is what
-- stamps who and when.
revoke all on public.statutory_remittances from public;
grant select on public.statutory_remittances to authenticated;

create trigger audit_changes
  after insert or delete or update on public.statutory_remittances
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- When a month's contributions are due
-- ---------------------------------------------------------------------
create or replace function app.remittance_due(p_pay_date date, p_code text)
returns date
language sql stable
set search_path = public, app, pg_temp
as $$
  -- The month after the month the wages were paid in, on the day the
  -- body names. Read from the pay date rather than the period: a
  -- December salary paid in January is remitted in February.
  select case when r.due_day is null then null
         else (date_trunc('month', p_pay_date) + interval '1 month')::date
              + (r.due_day - 1)
         end
    from public.ref_statutory_remittances r
   where r.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- What is owed, per payroll month and per body
-- ---------------------------------------------------------------------
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
  is_overdue      boolean)
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
         sr.paid_on is null
           and app.remittance_due(s.pay_date, s.code) is not null
           and app.remittance_due(s.pay_date, s.code) < app.today()
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

-- ---------------------------------------------------------------------
-- Recording that one went
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- And what is about to be late
-- ---------------------------------------------------------------------
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
   where r.paid_on is null
     and r.due_date is not null
     and r.due_date <= app.today() + coalesce(p_within_days, 30)
   order by r.due_date, r.code;
$$;

revoke all on function public.report_statutory_remittances(uuid, date, date)
  from public;
revoke all on function public.record_statutory_remittance(
  uuid, uuid, text, numeric, date, text) from public;
revoke all on function public.report_statutory_due(uuid, integer) from public;

grant execute on function public.report_statutory_remittances(uuid, date, date)
  to authenticated;
grant execute on function public.record_statutory_remittance(
  uuid, uuid, text, numeric, date, text) to authenticated;
grant execute on function public.report_statutory_due(uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_due text := pg_get_functiondef(
    to_regprocedure('app.remittance_due(date, text)'));
  v_rep text := pg_get_functiondef(to_regprocedure(
    'public.report_statutory_remittances(uuid, date, date)'));
begin
  -- The day is a row, so that moving it is an update.
  if position('r.due_day' in v_due) = 0 then
    raise exception '0457: the deadline is written into the code';
  end if;

  -- And it is read from the pay date, not the period.
  if position('date_trunc(''month'', p_pay_date)' in v_due) = 0 then
    raise exception
      '0457: contributions are dated by the month the wages were earned';
  end if;

  if position('''posted'', ''paid''' in v_rep) = 0 then
    raise exception '0457: a draft payroll is reported as money owed';
  end if;

  if (select due_day from public.ref_statutory_remittances
       where code = 'zakat') is not null then
    raise exception '0457: zakat was given a deadline nobody set';
  end if;

  if (select count(*) from public.ref_statutory_remittances
       where due_day = 15) <> 5 then
    raise exception '0457: the five statutory bodies are not all on the 15th';
  end if;
end
$do$;

comment on function public.report_statutory_remittances(uuid, date, date) is
  'What a posted payroll leaves the company owing KWSP, PERKESO, LHDN '
  'and HRD Corp, with the fifteenth of the following month against '
  'each, and whether it went. See 0457.';
