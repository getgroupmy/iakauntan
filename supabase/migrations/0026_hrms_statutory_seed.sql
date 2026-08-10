-- =====================================================================
-- iAkauntan :: 0026 statutory schedules (Malaysia)
--
-- These are the published statutory *percentages* and thresholds. KWSP
-- and PERKESO also gazette contribution *tables* whose band amounts can
-- differ from a straight percentage by a few sen. Every schedule here is
-- therefore marked is_verified = false: the engine works, the arithmetic
-- is right, but before anyone files a real return they should load the
-- authority's own table and mark it verified.
--
-- Rate rows carry both a rate and an optional flat amount. Where an
-- amount is set it wins, which is how EPF's flat employer contribution
-- for certain non-citizens is expressed without a second mechanism.
-- =====================================================================

-- ---------------------------------------------------------------------
-- EPF / KWSP
-- ---------------------------------------------------------------------
with s as (
  insert into public.statutory_schedules
    (body, name, method, effective_from, wage_round_up_to, result_rounding,
     source, is_verified, notes)
  values (
    'epf', 'EPF statutory rates', 'percentage', date '2024-01-01', 20, 'up_ringgit',
    'KWSP published contribution rates', false,
    'Wages rounded up to the next RM20 and the contribution up to the next ringgit, following the Third Schedule convention. Load the gazetted table for exact band amounts.')
  returning id
)
insert into public.statutory_rates
  (schedule_id, category, wage_from, wage_to, employee_rate, employer_rate,
   employee_amount, employer_amount, sort_order)
select s.id, v.category, v.wage_from, v.wage_to, v.employee_rate,
       v.employer_rate, v.employee_amount, v.employer_amount, v.sort_order
  from s, (values
    -- Malaysians and permanent residents below 60
    ('citizen_under60',    0::numeric, 5000::numeric, 11::numeric, 13::numeric, null::numeric, null::numeric, 1),
    ('citizen_under60', 5000.01,       null,          11,          12,          null,          null,          2),
    -- 60 and over: the employee side stops, the employer side reduces
    ('citizen_60plus',     0,          null,           0,           4,          null,          null,          3),
    -- Non-citizens who joined the scheme before August 1998 pay the
    -- employee rate against a flat employer contribution.
    ('noncitizen_under60', 0,          null,          11,           0,          null,          5,             4),
    ('noncitizen_60plus',  0,          null,           0,           0,          null,          5,             5)
  ) as v(category, wage_from, wage_to, employee_rate, employer_rate,
         employee_amount, employer_amount, sort_order);

-- ---------------------------------------------------------------------
-- SOCSO / PERKESO
-- ---------------------------------------------------------------------
with s as (
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, source, is_verified, notes)
  values (
    'socso', 'SOCSO contribution rates', 'percentage', date '2024-10-01', 'nearest_5sen',
    'PERKESO published rates, insured wage ceiling RM6,000', false,
    'Act 4 covers Employment Injury and Invalidity for those under 60. Act 800 covers Employment Injury only, for those 60 and over and for anyone first registered at 55 or later.')
  returning id
)
insert into public.statutory_rates
  (schedule_id, category, wage_from, wage_to, employee_rate, employer_rate,
   wage_ceiling, sort_order)
select s.id, v.category, 0, null, v.employee_rate, v.employer_rate, 6000, v.sort_order
  from s, (values
    ('act4',   0.5::numeric, 1.75::numeric, 1),
    ('act800', 0::numeric,   1.25::numeric, 2)
  ) as v(category, employee_rate, employer_rate, sort_order);

-- ---------------------------------------------------------------------
-- EIS / SIP
-- ---------------------------------------------------------------------
with s as (
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, source, is_verified, notes)
  values (
    'eis', 'Employment Insurance System rates', 'percentage', date '2024-10-01',
    'nearest_5sen', 'PERKESO published rates, insured wage ceiling RM6,000', false,
    'Not payable for employees aged 60 and over, or first employed at 57 or later.')
  returning id
)
insert into public.statutory_rates
  (schedule_id, category, wage_from, wage_to, employee_rate, employer_rate,
   wage_ceiling, sort_order)
select s.id, 'default', 0, null, 0.2, 0.2, 6000, 1 from s;

-- ---------------------------------------------------------------------
-- HRD Corp levy (employer only)
-- ---------------------------------------------------------------------
with s as (
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, source, is_verified, notes)
  values (
    'hrdf', 'HRD Corp levy', 'percentage', date '2021-03-01', 'nearest_cent',
    'PSMB Act 2001 as amended', false,
    'One per cent of monthly wages where the employer has ten or more Malaysian employees; half a per cent where five to nine and the employer has opted in.')
  returning id
)
insert into public.statutory_rates
  (schedule_id, category, wage_from, wage_to, employee_rate, employer_rate, sort_order)
select s.id, v.category, 0, null, 0, v.employer_rate, v.sort_order
  from s, (values
    ('mandatory_10plus', 1::numeric,   1),
    ('optional_5to9',    0.5::numeric, 2)
  ) as v(category, employer_rate, sort_order);

-- ---------------------------------------------------------------------
-- PCB / MTD — annual scale for resident individuals
--
-- PCB is a monthly instalment against an annual liability, so the engine
-- projects the year, computes the tax, and divides what is left over the
-- remaining months. That is arithmetically the same as LHDN's M/R/B
-- table, which is itself derived from this scale.
-- ---------------------------------------------------------------------
with s as (
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, source, is_verified, notes)
  values (
    'pcb', 'Income tax scale, resident individual', 'percentage', date '2023-01-01',
    'nearest_cent', 'Income Tax Act 1967, Schedule 1 Part I', false,
    'Non-residents are deducted at a flat rate under the noncitizen category rather than this scale.')
  returning id
), brackets as (
  insert into public.tax_brackets
    (schedule_id, chargeable_from, chargeable_to, rate_percent, cumulative_tax, sort_order)
  select s.id, v.f, v.t, v.r, v.c, v.o
    from s, (values
      (0::numeric,       5000::numeric,    0::numeric,      0::numeric,      1),
      (5000.01,          20000,            1,               0,               2),
      (20000.01,         35000,            3,               150,             3),
      (35000.01,         50000,            6,               600,             4),
      (50000.01,         70000,            11,              1500,            5),
      (70000.01,         100000,           19,              3700,            6),
      (100000.01,        400000,           25,              9400,            7),
      (400000.01,        600000,           26,              84400,           8),
      (600000.01,        2000000,          28,              136400,          9),
      (2000000.01,       null,             30,              528400,          10)
    ) as v(f, t, r, c, o)
  returning schedule_id
), flat as (
  -- Non-resident employment income is deducted at a flat rate with no
  -- reliefs, which the engine reads from here rather than hard-coding.
  insert into public.statutory_rates
    (schedule_id, category, wage_from, wage_to, employee_rate, employer_rate, sort_order)
  select distinct schedule_id, 'nonresident', 0, null::numeric, 30, 0, 1 from brackets
  returning schedule_id
)
insert into public.tax_reliefs
  (schedule_id, code, name, is_automatic, default_amount, max_amount, applies_to, sort_order)
select distinct f.schedule_id, v.code, v.name, v.auto, v.amt, v.cap, v.applies, v.o
  from flat f, (values
    ('individual',      'Individual and dependent relatives', true,  9000::numeric, 9000::numeric,  'individual',   1),
    ('epf',             'EPF contributions',                  true,  0,             4000,           'epf',          2),
    ('socso_eis',       'SOCSO and EIS contributions',        true,  0,             350,            'socso',        3),
    ('spouse',          'Spouse with no income',              false, 4000,          4000,           'spouse',       4),
    ('child',           'Child under 18',                     false, 2000,          null,           'child',        5),
    ('child_tertiary',  'Child in higher education',          false, 8000,          null,           'child',        6),
    ('child_disabled',  'Disabled child',                     false, 6000,          null,           'child',        7),
    ('disabled_self',   'Disabled individual',                false, 6000,          6000,           'disabled_self',8),
    ('disabled_spouse', 'Disabled spouse',                    false, 5000,          5000,           'spouse',       9),
    ('life_insurance',  'Life insurance and takaful',         false, 0,             3000,           'manual',      10),
    ('lifestyle',       'Lifestyle',                          false, 0,             2500,           'manual',      11),
    ('medical_parents', 'Medical expenses for parents',       false, 0,             8000,           'manual',      12),
    ('education_self',  'Education fees, self',               false, 0,             7000,           'manual',      13)
  ) as v(code, name, auto, amt, cap, applies, o);

-- ---------------------------------------------------------------------
-- Per-tenant payroll settings
-- ---------------------------------------------------------------------
create table public.payroll_settings (
  org_id uuid primary key references public.organizations (id) on delete cascade,

  -- Which HRD Corp category applies, or none.
  hrdf_category text check (hrdf_category in ('mandatory_10plus', 'optional_5to9')),
  employer_epf_no text,
  employer_socso_no text,
  employer_tax_no text,          -- LHDN employer file, E number
  hrdf_registration_no text,

  -- Ledger accounts payroll posts to. Defaults resolve by code at
  -- posting time when these are left empty.
  salary_expense_account_id uuid references public.accounts (id),
  epf_expense_account_id uuid references public.accounts (id),
  socso_expense_account_id uuid references public.accounts (id),
  eis_expense_account_id uuid references public.accounts (id),
  hrdf_expense_account_id uuid references public.accounts (id),
  salary_payable_account_id uuid references public.accounts (id),
  epf_payable_account_id uuid references public.accounts (id),
  socso_payable_account_id uuid references public.accounts (id),
  eis_payable_account_id uuid references public.accounts (id),
  pcb_payable_account_id uuid references public.accounts (id),
  zakat_payable_account_id uuid references public.accounts (id),

  -- Payday, as a day of month; 0 means the last day.
  pay_day integer not null default 25 check (pay_day between 0 and 31),
  -- Overtime multipliers under the Employment Act 1955.
  ot_normal_multiplier numeric(5, 2) not null default 1.5,
  ot_restday_multiplier numeric(5, 2) not null default 2.0,
  ot_holiday_multiplier numeric(5, 2) not null default 3.0,

  updated_at timestamptz not null default now()
);

create trigger set_updated_at before update on public.payroll_settings
  for each row execute function app.set_updated_at();
