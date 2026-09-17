-- =====================================================================
-- iAkauntan :: 0359 the payroll engine is monthly, and now says so
--
-- `app.pay_frequency` has four values — monthly, semi_monthly, weekly,
-- daily — and the engine honours exactly one of them. Not by choosing
-- to: `calculate_payroll_run` never reads the column at all. It takes
-- the period's dates, pro-rates a joiner or a leaver across them, and
-- then applies the EPF, SOCSO, EIS and PCB tables, all of which are
-- monthly, to whatever came out.
--
-- So a `pay_periods` row covering seven days and labelled `weekly` is
-- accepted, calculated, and wrong. `basic_salary` is paid in full
-- because a period the employee worked all of is not pro-rated; the
-- statutory tables are read at their monthly bands; and the run
-- finishes `calculated` with figures that would be remitted. Nothing
-- refuses and nothing warns.
--
-- ---------------------------------------------------------------------
-- Why a constraint rather than an implementation
--
-- Malaysian statutory returns are monthly. EPF Form A, the SOCSO and
-- EIS contributions and PCB under CP39 are all remitted for a calendar
-- month, and a firm paying weekly still files monthly. Non-monthly
-- *runs* are a real feature — some employers pay weekly and want a
-- payslip each week — but they need PCB computed by annualisation or
-- the additional-remuneration method rather than by reading a monthly
-- band, and inventing that is how a payroll comes to be confidently
-- wrong. It is not done here, and the enum is not going to pretend
-- otherwise in the meantime.
--
-- Both paths that create a period already produce a whole calendar
-- month: `ensure_pay_period` builds one from a year and a month, and
-- the demo seed loops months. The constraint therefore forbids nothing
-- that exists — what it forbids is a row somebody inserts directly
-- through the API, which is the only way the wrong numbers could ever
-- have been produced.
--
-- `employees.pay_frequency` is left alone and commented instead. How
-- often somebody is handed money is a real fact about their
-- employment, and a company may well pay weekly advances against a
-- monthly run. What it must not be read as is an instruction to the
-- engine, because nothing reads it as one.
-- =====================================================================

-- Named before it is refused.
--
-- A plain `add constraint` on a database holding a non-conforming row
-- fails with `check constraint "pay_periods_whole_month" is violated by
-- some row` — which is true, unhelpful, and stops the whole migration
-- run behind it. Both sanctioned creators make whole calendar months
-- (`ensure_pay_period` from a year and a month, the demo seed by
-- looping them), so the only way to hold one is to have inserted it
-- through the API by hand. If somebody has, this says which and why
-- rather than leaving them to work it out from a constraint name.
do $do$
declare v_bad text;
begin
  select string_agg(code, ', ' order by code) into v_bad
    from public.pay_periods
   where extract(day from period_start) <> 1
      or period_end <> (period_start + interval '1 month' - interval '1 day')::date
      or frequency <> 'monthly';
  if v_bad is not null then
    raise exception
      'These pay periods are not whole calendar months: %. The '
      'statutory engine reads monthly EPF, SOCSO, EIS and PCB tables '
      'and never reads a period''s frequency, so a shorter one is '
      'calculated at monthly rates. Correct or delete them, then run '
      'this migration again.', v_bad
      using errcode = '23514';
  end if;
end
$do$;

alter table public.pay_periods drop constraint if exists pay_periods_whole_month;
alter table public.pay_periods add constraint pay_periods_whole_month check (
  -- The first of a month, to the last day of that same month. Written
  -- with `extract` and interval arithmetic rather than `date_trunc`
  -- because a check constraint needs immutable expressions and
  -- `date_trunc` over a timestamptz is not one.
  extract(day from period_start) = 1
  and period_end = (period_start + interval '1 month' - interval '1 day')::date
  and frequency = 'monthly'
);

comment on constraint pay_periods_whole_month on public.pay_periods is
  'The statutory engine reads monthly EPF, SOCSO, EIS and PCB tables '
  'and never reads this row''s frequency, so a shorter period would be '
  'calculated at monthly rates and remitted. Whole calendar months '
  'only until a non-monthly run computes PCB the way LHDN requires for '
  'one.';

comment on column public.pay_periods.frequency is
  'Monthly, and constrained to it. Kept as a column rather than dropped '
  'because the enum is where a non-monthly run will be declared when '
  'one is built; until then it is a value the engine does not read.';

comment on column public.employees.pay_frequency is
  'How often this person is handed money — a fact about their '
  'employment, not an instruction to the payroll engine, which is '
  'monthly and does not read this. A weekly-paid employee still has '
  'one monthly run and one monthly statutory return.';
