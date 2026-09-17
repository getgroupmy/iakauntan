-- =====================================================================
-- iAkauntan :: 0608 what the EA form has boxes for
--
-- README lists four statutory submission files as "computable from what
-- is stored, but no exporter is written": CP39, Borang A, Lampiran 1
-- and the EA form. This is the EA form, and it is first for a reason
-- that is worth writing down.
--
-- ---------------------------------------------------------------------
-- Why the EA form and not CP39
--
-- Three of the four are MACHINE files. CP39 is a fixed-width text file
-- uploaded to LHDN; KWSP's Form A and PERKESO's Lampiran 1 are the same
-- idea for their own portals. A fixed-width file is right or it is
-- rejected, and the layouts are published by the bodies themselves --
-- field by field, column by column, in documents this repository's
-- build machine cannot reach. Writing one from memory would produce a
-- file that looks correct in a diff and is refused at the counter,
-- which is the worst of the three possible outcomes.
--
-- The EA form is not a machine file. It is C.P.8A: a statement of
-- remuneration the employer gives the EMPLOYEE, by the end of February,
-- so they can file their own return. Nothing parses it. What has to be
-- right is the arithmetic, and the arithmetic is all here.
--
-- So this migration does the whole of the EA form and none of the other
-- three. The layouts for those are recorded as a gap rather than
-- guessed at.
--
-- ---------------------------------------------------------------------
-- What this employer paid, and only that
--
-- The single thing easiest to get wrong. `employee_ytd_opening` holds
-- what a PREVIOUS employer paid somebody who joined mid-year -- gross,
-- EPF, PCB, zakat and benefits in kind. It exists so this year's PCB is
-- computed on the right cumulative figure, and `0530` and the payroll
-- engine read it for exactly that.
--
-- It must not appear on this form. An EA form covers one employment.
-- The previous employer issues their own for the same year, and an
-- employee handed two forms that both include the first job's salary
-- declares it twice.
--
-- So the statement is built from `payslips`, which are this employer's,
-- and the opening figures are returned in a section of their own that
-- says what they are. `ea_form.sql` asserts both halves: that the
-- opening gross is excluded from the total, and that it is still
-- reported, because silently dropping it is the other way to be wrong.
--
-- ---------------------------------------------------------------------
-- The year is the year of the PAY DATE
--
-- Not the period. December's salary paid on 5 January is income for the
-- new year -- `payroll_engine_sweep.sql` already says so, and
-- `post_payroll_run` files its year-to-date row under
-- `extract(year from pay_date)` for the same reason. This reads the
-- same thing, from the payslip where it is recorded and from the period
-- where it is not.
--
-- ---------------------------------------------------------------------
-- The boxes are a table
--
-- The C.P.8A has named boxes -- gross salary, fees and commission,
-- perquisites, benefits in kind, living accommodation, compensation for
-- loss of employment, and the exempt allowances in Part F. A payroll
-- system cannot know which of them an employer's "Elaun Perjalanan"
-- component belongs in; only the employer can say.
--
-- `ea_categories` is that list and `salary_components.ea_category` is
-- where the employer says. The list is seeded from the form's own
-- layout, and it is a TABLE rather than an enum or a case expression
-- for the same reason `statutory_rates` and
-- `ref_statutory_remittances.due_day` are tables: the form has been
-- renumbered before and will be again, and the next time should be an
-- update rather than a migration.
--
-- A component nobody has classified still lands somewhere defensible:
-- an ordinary earning is salary and an additional one is fees,
-- commission or bonus, which is what `is_additional_remuneration`
-- already means -- it is the flag the PCB engine uses to apply the
-- additional-remuneration formula. That default is asserted, because a
-- company that classifies nothing is the common case and an EA form
-- with every figure in "other" is not one anybody can file.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The boxes
-- ---------------------------------------------------------------------
create table public.ea_categories (
  code text primary key
    check (code ~ '^[a-z][a-z0-9_]{1,40}$'),

  -- Which part of the form. 'B' is remuneration, 'C' pension and
  -- others, 'F' the tax-exempt allowances listed separately.
  part text not null check (part in ('B', 'C', 'F')),

  -- The number printed beside the box, as printed: '1(a)', '2', '5'.
  -- Text, because it is a label rather than an ordering.
  box text not null,

  label text not null,
  label_my text,

  -- Whether an amount in this box is exempt from tax. Part F is the
  -- exempt list; everything in B and C is not. Carried on the row
  -- rather than derived from `part` so a future box that breaks that
  -- correspondence has somewhere to say so.
  is_exempt boolean not null default false,

  sort_order integer not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.ea_categories is
  'The boxes on the EA form (C.P.8A) that a salary component can be '
  'reported in. A table rather than an enum because the form has been '
  'renumbered before. 0608.';

create index ea_categories_order_idx
  on public.ea_categories (sort_order, code) where is_active;

insert into public.ea_categories
  (code, part, box, label, sort_order, is_exempt)
values
  ('salary',        'B', '1(a)',
   'Gross salary, wages or leave pay',                        10, false),
  ('fees_bonus',    'B', '1(b)',
   'Fees, commission or bonus',                               20, false),
  ('perquisites',   'B', '1(c)',
   'Gross tips, perquisites, awards or other allowances',     30, false),
  ('tax_borne',     'B', '1(d)',
   'Income tax borne by the employer',                        40, false),
  ('esos',          'B', '1(e)',
   'Employee share option scheme benefit',                    50, false),
  ('gratuity',      'B', '1(f)',
   'Gratuity',                                                60, false),
  ('bik',           'B', '2',
   'Benefits in kind',                                        70, false),
  ('accommodation', 'B', '3',
   'Value of living accommodation',                           80, false),
  ('pension_refund','B', '4',
   'Refund from an unapproved pension or provident fund',     90, false),
  ('compensation',  'B', '5',
   'Compensation for loss of employment',                    100, false),
  ('pension',       'C', '1',
   'Pension',                                                110, false),
  ('annuity',       'C', '2',
   'Annuity or other periodical payment',                    120, false),
  ('exempt',        'F', '1',
   'Tax exempt allowances, perquisites, gifts or benefits',  130, true)
on conflict (code) do nothing;

alter table public.ea_categories enable row level security;

create policy ea_categories_read on public.ea_categories
  for select to authenticated using (true);

grant select on public.ea_categories to authenticated;

-- ---------------------------------------------------------------------
-- Where the employer says which box a component is
--
-- Null on purpose, and null is not "unclassified and therefore
-- nowhere": `ea_statement` below falls back to `salary` for an ordinary
-- earning and `fees_bonus` for an additional one. A company that has
-- never opened this setting still gets a form it can hand out.
--
-- `on delete restrict`: a box in use is not one to remove, for the same
-- reason a kind of business in use is not.
-- ---------------------------------------------------------------------
alter table public.salary_components
  add column if not exists ea_category text
  references public.ea_categories (code)
  on update cascade on delete restrict;

comment on column public.salary_components.ea_category is
  'Which box on the EA form this component is reported in. Null falls '
  'back to gross salary for an ordinary earning and to fees, '
  'commission or bonus for an additional one -- which is what '
  '`is_additional_remuneration` already means. 0608.';

-- ---------------------------------------------------------------------
-- One employee's statement of remuneration
--
-- Everything the form needs, as one object, so the screen and the PDF
-- read the same figures rather than each doing their own arithmetic.
--
-- Who may read it: whoever may run payroll, or the employee themselves.
-- That is exactly the `payslips` policy, and deliberately -- an EA form
-- is a year of payslips added up, and somebody entitled to twelve of
-- those is entitled to their total.
--
-- SECURITY DEFINER because it reads `employees`, `payslips`,
-- `payroll_settings` and `organizations` in one pass and the guard is
-- clearer said once at the top than inferred from four policies.
-- ---------------------------------------------------------------------
create or replace function public.ea_statement(
  p_employee_id uuid,
  p_tax_year integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_emp     public.employees;
  v_org     public.organizations;
  v_set     public.payroll_settings;
  v_open    public.employee_ytd_opening;
  v_boxes   jsonb;
  v_totals  record;
  v_first   date;
  v_last    date;
begin
  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'No such employee' using errcode = 'P0002';
  end if;

  -- `coalesce`, and it is not decoration. `app.my_employee_id` returns
  -- null for somebody who is not an employee of this company, so
  -- `p_employee_id = null` is NULL rather than false, `false or NULL`
  -- is NULL, and `if not NULL then` does not run its body. Without the
  -- coalesce this guard lets through exactly the person it is for: a
  -- colleague with no payroll role and no employee record, reading
  -- somebody else's statement of remuneration.
  --
  -- Found by `ea_form.sql`, which asserts the refusal.
  if not coalesce(
       app.can_run_payroll(v_emp.org_id)
         or p_employee_id = app.my_employee_id(v_emp.org_id),
       false) then
    raise exception 'An EA form is the employee''s own or the payroll '
                    'administrator''s'
      using errcode = '42501';
  end if;

  if not app.can_read_module(v_emp.org_id, 'payroll') then
    raise exception 'The Payroll module is not switched on for this company'
      using errcode = '42501';
  end if;

  select * into v_org from public.organizations where id = v_emp.org_id;
  select * into v_set from public.payroll_settings where org_id = v_emp.org_id;
  select * into v_open from public.employee_ytd_opening
   where employee_id = p_employee_id and tax_year = p_tax_year;

  -- ------------------------------------------------------------------
  -- Part B and Part C, by box
  --
  -- Every taxable earning line on every payslip this employer paid in
  -- the year of assessment, grouped into the box the employer put its
  -- component in -- or, where they have not said, into salary for an
  -- ordinary line and fees/bonus for an additional one.
  --
  -- The year is the PAY DATE's year. `payslips.pay_date` where it is
  -- set and the period's otherwise, because that column arrived after
  -- the payslips that predate it.
  --
  -- Only POSTED runs. A calculated run is a set of figures that can
  -- still change and a payment nobody has received.
  --
  -- `is_taxable` decides whether the line is here at all. An untaxed
  -- reimbursement is not remuneration, and Part F -- the exempt list --
  -- is reached by classifying a component into it explicitly, which is
  -- what `is_exempt` on the box means.
  -- ------------------------------------------------------------------
  with paid as (
    select p.id, coalesce(p.pay_date, pp.pay_date) as pay_date
      from public.payslips p
      join public.payroll_runs r on r.id = p.run_id
      join public.pay_periods pp on pp.id = r.period_id
     where p.employee_id = p_employee_id
       and r.posted_at is not null
       and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year
  ), lines as (
    select
      coalesce(
        sc.ea_category,
        case when l.is_additional_remuneration then 'fees_bonus'
             else 'salary' end) as box,
      l.amount
      from public.payslip_lines l
      join paid on paid.id = l.payslip_id
      left join public.salary_components sc on sc.id = l.component_id
     where l.kind = 'earning'
       and l.is_taxable
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', c.code, 'part', c.part, 'box', c.box,
           'label', c.label, 'is_exempt', c.is_exempt,
           'amount', round(t.amount, 2))
         order by c.sort_order, c.code), '[]'::jsonb)
    into v_boxes
    from (select box, sum(amount) as amount from lines group by box) t
    join public.ea_categories c on c.code = t.box;

  -- ------------------------------------------------------------------
  -- Part D and Part E, and the period actually worked
  --
  -- `pcb` and `cp38` are separate columns on the payslip and separate
  -- boxes on the form. `payroll_ytd` adds them together, which is right
  -- for the cumulative figure the PCB engine needs and wrong here, so
  -- this does not read that table.
  -- ------------------------------------------------------------------
  select
    coalesce(sum(p.gross_pay), 0)      as gross,
    coalesce(sum(p.pcb), 0)            as pcb,
    coalesce(sum(p.cp38), 0)           as cp38,
    coalesce(sum(p.zakat), 0)          as zakat,
    coalesce(sum(p.epf_employee), 0)   as epf_employee,
    coalesce(sum(p.epf_employer), 0)   as epf_employer,
    coalesce(sum(p.socso_employee), 0) as socso_employee,
    coalesce(sum(p.socso_employer), 0) as socso_employer,
    coalesce(sum(p.eis_employee), 0)   as eis_employee,
    coalesce(sum(p.eis_employer), 0)   as eis_employer,
    count(*)                           as months_paid,
    min(coalesce(p.pay_date, pp.pay_date)) as first_paid,
    max(coalesce(p.pay_date, pp.pay_date)) as last_paid
    into v_totals
    from public.payslips p
    join public.payroll_runs r on r.id = p.run_id
    join public.pay_periods pp on pp.id = r.period_id
   where p.employee_id = p_employee_id
     and r.posted_at is not null
     and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year;

  -- The employment period the form asks for, clamped to the year: a
  -- form for 2025 says "1 January to 31 December" for somebody who was
  -- there throughout, not their hire date in 2019.
  v_first := greatest(coalesce(v_emp.hire_date, make_date(p_tax_year, 1, 1)),
                      make_date(p_tax_year, 1, 1));
  v_last  := least(coalesce(v_emp.last_working_date,
                            make_date(p_tax_year, 12, 31)),
                   make_date(p_tax_year, 12, 31));

  return jsonb_build_object(
    'tax_year', p_tax_year,
    'employer', jsonb_build_object(
      'name', v_org.name,
      'legal_name', coalesce(v_org.legal_name, v_org.name),
      -- The E number. The form's own heading asks for it and nothing
      -- else in this schema holds it.
      'employer_tax_no', v_set.employer_tax_no,
      'epf_no', v_set.employer_epf_no,
      'socso_no', v_set.employer_socso_no,
      'registration_no', v_org.registration_no,
      'address', concat_ws(', ',
        nullif(v_org.address_line1, ''), nullif(v_org.city, ''),
        nullif(v_org.postcode, ''))),
    'employee', jsonb_build_object(
      'id', v_emp.id,
      'employee_no', v_emp.employee_no,
      'name', v_emp.full_name,
      'nric', v_emp.nric,
      'passport_no', v_emp.passport_no,
      'income_tax_no', coalesce(v_emp.income_tax_no, v_emp.tin),
      'epf_no', v_emp.epf_no,
      'socso_no', v_emp.socso_no,
      'employed_from', v_first,
      'employed_to', v_last),
    'boxes', v_boxes,
    'gross_pay', round(coalesce(v_totals.gross, 0), 2),
    'deductions', jsonb_build_object(
      'mtd', round(coalesce(v_totals.pcb, 0), 2),
      'cp38', round(coalesce(v_totals.cp38, 0), 2),
      'zakat', round(coalesce(v_totals.zakat, 0), 2)),
    'contributions', jsonb_build_object(
      'epf_employee', round(coalesce(v_totals.epf_employee, 0), 2),
      'epf_employer', round(coalesce(v_totals.epf_employer, 0), 2),
      'socso_employee', round(coalesce(v_totals.socso_employee, 0), 2),
      'socso_employer', round(coalesce(v_totals.socso_employer, 0), 2),
      'eis_employee', round(coalesce(v_totals.eis_employee, 0), 2),
      'eis_employer', round(coalesce(v_totals.eis_employer, 0), 2)),
    'months_paid', coalesce(v_totals.months_paid, 0),
    'first_paid', v_totals.first_paid,
    'last_paid', v_totals.last_paid,
    -- ----------------------------------------------------------------
    -- What somebody else paid them this year
    --
    -- NOT part of any figure above, and here so that nobody has to go
    -- looking for it to find out whether it was left out on purpose.
    -- The previous employer issues their own EA form for this; an
    -- employee handed two that both include the first job declares it
    -- twice.
    -- ----------------------------------------------------------------
    'previous_employer', case when v_open.employee_id is null then null
      else jsonb_build_object(
        'gross_pay', round(coalesce(v_open.gross_pay, 0), 2),
        'epf_employee', round(coalesce(v_open.epf_employee, 0), 2),
        'pcb_paid', round(coalesce(v_open.pcb_paid, 0), 2),
        'zakat_paid', round(coalesce(v_open.zakat_paid, 0), 2),
        'benefits_in_kind', round(coalesce(v_open.benefits_in_kind, 0), 2),
        'notes', v_open.notes) end);
end;
$function$;

comment on function public.ea_statement(uuid, integer) is
  'One employee''s EA form (C.P.8A) figures for a year of assessment: '
  'this employer''s payslips only, by the year of the PAY DATE, from '
  'posted runs. What a previous employer paid is reported separately '
  'and is in no total. 0608.';

revoke all on function public.ea_statement(uuid, integer) from public, anon;
grant execute on function public.ea_statement(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Everybody's, for the year
--
-- An employer issues one of these per employee by the end of February,
-- so the list is what the screen actually works from: who is owed one,
-- what their total was, and whether anything is missing that would make
-- the form wrong to hand out.
--
-- Anybody the company paid in the year, including leavers -- a leaver
-- is owed an EA form for the months they were there, and a list built
-- from current employees would quietly omit exactly the people most
-- likely to chase it.
-- ---------------------------------------------------------------------
create or replace function public.ea_statements(
  p_org_id uuid,
  p_tax_year integer)
returns table (
  employee_id uuid,
  employee_no text,
  name text,
  nric text,
  income_tax_no text,
  employment_status text,
  months_paid bigint,
  gross_pay numeric,
  mtd numeric,
  cp38 numeric,
  zakat numeric,
  epf_employee numeric,
  epf_employer numeric,
  socso_employee numeric,
  has_previous_employer boolean,
  missing text[])
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if not app.can_run_payroll(p_org_id) then
    raise exception 'Payroll access required' using errcode = '42501';
  end if;
  if not app.can_read_module(p_org_id, 'payroll') then
    raise exception 'The Payroll module is not switched on for this company'
      using errcode = '42501';
  end if;

  return query
    select
      e.id,
      e.employee_no,
      e.full_name,
      e.nric,
      coalesce(e.income_tax_no, e.tin),
      e.employment_status::text,
      count(p.id),
      round(coalesce(sum(p.gross_pay), 0), 2),
      round(coalesce(sum(p.pcb), 0), 2),
      round(coalesce(sum(p.cp38), 0), 2),
      round(coalesce(sum(p.zakat), 0), 2),
      round(coalesce(sum(p.epf_employee), 0), 2),
      round(coalesce(sum(p.epf_employer), 0), 2),
      round(coalesce(sum(p.socso_employee), 0), 2),
      exists (select 1 from public.employee_ytd_opening o
               where o.employee_id = e.id and o.tax_year = p_tax_year),
      -- What would make the form wrong to hand out, named rather than
      -- left for LHDN to find. A missing tax file number is the one
      -- that matters: the employee cannot file against a form that
      -- does not carry it.
      array_remove(array[
        case when coalesce(nullif(btrim(coalesce(e.income_tax_no, e.tin)), ''),
                           '') = ''
             then 'income tax number' end,
        case when coalesce(nullif(btrim(coalesce(e.nric, e.passport_no)), ''),
                           '') = ''
             then 'NRIC or passport' end,
        case when coalesce(nullif(btrim(e.epf_no), ''), '') = ''
               and coalesce(sum(p.epf_employee), 0) > 0
             then 'EPF number' end
      ], null)
      from public.employees e
      join public.payslips p on p.employee_id = e.id
      join public.payroll_runs r on r.id = p.run_id
      join public.pay_periods pp on pp.id = r.period_id
     where e.org_id = p_org_id
       and r.posted_at is not null
       and extract(year from coalesce(p.pay_date, pp.pay_date)) = p_tax_year
     group by e.id, e.employee_no, e.full_name, e.nric, e.income_tax_no,
              e.tin, e.employment_status, e.epf_no, e.passport_no
     order by e.employee_no nulls last, e.full_name;
end;
$function$;

comment on function public.ea_statements(uuid, integer) is
  'Who is owed an EA form for a year of assessment and what each one '
  'comes to, leavers included. `missing` names what would make the '
  'form wrong to hand out. 0608.';

revoke all on function public.ea_statements(uuid, integer) from public, anon;
grant execute on function public.ea_statements(uuid, integer) to authenticated;
