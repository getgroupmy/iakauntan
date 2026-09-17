-- ---------------------------------------------------------------------
-- 0448  The payroll screens with nothing on them
-- ---------------------------------------------------------------------
-- 0446 gave `salary_components` a flag that decides whether a payment
-- is annualised for PCB, and put a checkbox on the HR setup screen to
-- set it. Then this, measured on production:
--
--   | company | employees | runs | payslips | components | leave types |
--   |---|---|---|---|---|---|
--   | Sinar Teknologi | 4 | 7 | 28 | **0** | **0** |
--
-- Every other tenant has none of any of it, which is right — they do
-- not buy payroll. Sinar does, and has run it seven times. What it has
-- never had is a single allowance, a single deduction, or a single kind
-- of leave.
--
-- So two setup screens are empty in the only company that can open
-- them. "Allowances and deductions" shows its empty state, and the
-- checkbox 0446 added has nothing to sit beside. "Leave types" shows
-- its empty state, and with it go the entitlement bands 0443 started
-- auditing, the balances `roll_leave_year` writes, and every leave
-- assertion's subject.
--
-- This is not the demo register reopening. That sweep asked which
-- modules had no tenant at all and is closed. This is the opposite
-- shape and one it could not see: a module with a tenant, real
-- transactions and posted books, and two of its tables empty.
--
-- ### What the seed adds, and why each one
--
--   * **a travelling allowance** — the component the Act and the PSMB
--     Act treat differently from everything else, which is why 0370
--     made the levy flag a decision. Taxable, outside all four
--     contributions;
--   * **a phone allowance**, on one person rather than everybody,
--     because a component the whole company gets is indistinguishable
--     from a salary increase on screen;
--   * **an annual bonus**, marked `is_additional_remuneration`, paid in
--     February and only in February. That is 0446 on the books: eleven
--     months still to come, and a deduction of the year's difference
--     rather than eleven times the bonus. A December bonus would have
--     demonstrated nothing, because the annualisation factor is 1;
--   * **annual and sick leave**, with the Employment Act bands applied
--     by `apply_statutory_leave_bands` rather than typed, and unpaid
--     leave, which is the one the payroll engine actually reads;
--   * **the leave year rolled**, so there are balances to show rather
--     than three types and no numbers.
--
-- The seed runs before the payroll loop, so the runs include the
-- allowances and the February payslip shows the bonus. It is
-- idempotent in the same way the rest of the demo is: everything is
-- `on conflict do nothing`, and re-running changes nothing.
--
-- ### Mutants
--
--   * the bonus left unmarked, so it is annualised like a salary --
--     killed by "and is marked as paid once";
--   * the extras seeded after the payroll loop rather than before --
--     killed by "the allowance reaches a payslip, and every one of
--     them";
--   * the bonus given no `effective_to`, so it is paid every month --
--     killed by "the bonus is paid once".
--
-- ### Two things the mutants found that were not mutants
--
-- **The demonstration was on the wrong person.** The bonus first went
-- to Aisyah, the highest earner, and the assertion about February's
-- deduction passed whether the flag was set or not. Measured: on 9,500
-- a month the two methods give 3,741.35 and 3,469.75 -- seven per cent
-- apart, because she is already near the top band, so annualising buys
-- little more tax and dividing by eleven gives most of it back. On Mei
-- Ling's 5,200 they give 2,641.35 and 1,268.95. A demonstration has to
-- be built where the thing demonstrated is visible, and mutation
-- testing is what said the first one was not.
--
-- **And the obvious assertion cannot be written here at all.** The
-- natural check is that February's deduction is below the annualised
-- one, computed by handing the payslip's own figures back to
-- `calc_pcb`. It passes with the flag removed, because `calc_pcb`
-- reads `payroll_ytd` and by the time the test looks that holds the
-- whole year rather than the one month February saw. A figure that
-- depends on accumulated state cannot be checked by recomputing it
-- later. The arithmetic is asserted in `payroll_run.sql`, where the
-- inputs are controlled; what belongs in the demo is that the flag is
-- carried and that the bonus month costs more.
-- ---------------------------------------------------------------------

create or replace function app.demo_payroll_extras_sinar(
  p_org uuid, p_owner uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_travel uuid;
  v_phone  uuid;
  v_bonus  uuid;
  v_annual uuid;
  v_sick   uuid;
  v_year   integer := extract(year from app.today())::integer;
  v_feb    date := make_date(extract(year from app.today())::integer, 2, 1);
  v_aisyah uuid;
  v_meiling uuid;
begin
  perform app.demo_act_as(p_owner);

  select id into v_aisyah from public.employees
   where org_id = p_org and employee_no = 'EMP-001';
  select id into v_meiling from public.employees
   where org_id = p_org and employee_no = 'EMP-002';
  if v_aisyah is null then return; end if;

  -- ------------------------------------------------------------------
  -- What is paid on top of the salary
  -- ------------------------------------------------------------------
  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_taxable, is_epf_liable,
     is_socso_liable, is_eis_liable, is_hrdf_liable,
     is_additional_remuneration, sort_order)
  values
    (p_org, 'TRAVEL', 'Travelling allowance', 'earning', 250,
     true, false, false, false, false, false, 10),
    (p_org, 'PHONE', 'Telephone allowance', 'earning', 100,
     true, false, false, false, false, false, 20),
    -- EPF is charged on a bonus and the levy is not: the PSMB Act
    -- counts basic wages and fixed allowances, and a bonus is neither.
    (p_org, 'BONUS', 'Annual bonus', 'earning', 0,
     true, true, false, false, false, true, 30)
  on conflict (org_id, code) do nothing;

  select id into v_travel from public.salary_components
   where org_id = p_org and code = 'TRAVEL';
  select id into v_phone from public.salary_components
   where org_id = p_org and code = 'PHONE';
  select id into v_bonus from public.salary_components
   where org_id = p_org and code = 'BONUS';

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  select p_org, e.id, v_travel, e.hire_date
    from public.employees e
   where e.org_id = p_org and e.employment_status = 'active'
  on conflict do nothing;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (p_org, v_aisyah, v_phone, date '2021-02-01')
  on conflict do nothing;

  -- February, and February only. The `effective_to` is what makes it a
  -- bonus rather than a monthly payment, and it is what puts the
  -- payslip in a month with eleven still to come.
  --
  -- Mei Ling rather than Aisyah, and that choice was measured. On
  -- Aisyah's 9,500 the two methods differ by seven per cent -- she is
  -- already near the top band, so annualising the bonus buys little
  -- more tax and dividing it by eleven gives most of that back. On Mei
  -- Ling's 5,200 the same bonus is 2,641.35 rolled into ordinary pay
  -- against 1,268.95 taken once. A demonstration belongs on the
  -- employee it is visible for.
  insert into public.employee_salary_components
    (org_id, employee_id, component_id, amount, effective_from, effective_to,
     notes)
  values (p_org, v_meiling, v_bonus, 12000, v_feb,
          (v_feb + interval '1 month - 1 day')::date,
          'Paid with February''s salary')
  on conflict do nothing;

  -- ------------------------------------------------------------------
  -- Leave, which had no types at all
  -- ------------------------------------------------------------------
  insert into public.leave_types
    (org_id, code, name, is_paid, default_days, scales_with_service,
     max_carry_forward, carry_forward_expiry_months, allow_half_day,
     notice_days, sort_order)
  values
    (p_org, 'AL', 'Annual leave', true, 8, true, 5, 6, true, 3, 10),
    (p_org, 'MC', 'Sick leave', true, 14, true, 0, 0, false, 0, 20),
    (p_org, 'UNPAID', 'Unpaid leave', false, 0, false, 0, 0, true, 7, 30)
  on conflict (org_id, code) do nothing;

  select id into v_annual from public.leave_types
   where org_id = p_org and code = 'AL';
  select id into v_sick from public.leave_types
   where org_id = p_org and code = 'MC';

  -- The bands come from the Act through the function that knows them,
  -- not from four numbers typed into a seed.
  if not exists (select 1 from public.leave_entitlement_bands
                  where leave_type_id = v_annual) then
    perform public.apply_statutory_leave_bands(v_annual, 'annual');
  end if;
  if not exists (select 1 from public.leave_entitlement_bands
                  where leave_type_id = v_sick) then
    perform public.apply_statutory_leave_bands(v_sick, 'sick');
  end if;

  perform app.roll_leave_year(p_org, v_year);
end;
$fn$;

-- ---------------------------------------------------------------------
-- Seeded before the runs, so the payslips carry them
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('app.demo_sinar_payroll(uuid, uuid)'));
  v_old text := '  v_month := date_trunc(''year'', app.today())::date;';
  v_new text :=
    '  -- The allowances, the bonus and the leave types, before the '
    || 'first' || chr(10) ||
    '  -- run, so every payslip carries them rather than the screens '
    || 'being' || chr(10) ||
    '  -- empty beside seven months of payroll -- see 0448.' || chr(10) ||
    '  perform app.demo_payroll_extras_sinar(p_org, p_owner);' || chr(10) ||
    chr(10) || '  v_month := date_trunc(''year'', app.today())::date;';
begin
  if v_src is null then
    raise exception '0448: app.demo_sinar_payroll(uuid, uuid) is not there';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception '0448: could not find where the payroll loop begins';
  end if;
  execute replace(v_src, v_old, v_new);
end
$do$;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('app.demo_sinar_payroll(uuid, uuid)'));
begin
  if position('demo_payroll_extras_sinar' in v_src) = 0 then
    raise exception '0448: the payroll seed does not call the extras';
  end if;

  -- Before the loop, or the runs are calculated without them.
  if position('demo_payroll_extras_sinar' in v_src)
     > position('while v_month <' in v_src) then
    raise exception '0448: the extras are seeded after the runs';
  end if;
end
$do$;

comment on function app.demo_payroll_extras_sinar(uuid, uuid) is
  'The allowances, the February bonus and the leave types Sinar had '
  'none of. The bonus is marked as additional remuneration, so the '
  'demo books show 0446 working rather than only the migration '
  'claiming it does.';
