-- =====================================================================
-- iAkauntan :: what was payable, and what was paid
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/tax_estimate_payments.sql
--
-- `0672` finished saying what every instalment was PAYABLE at.
-- `0673` records what was paid, and the hard part is not the
-- recording:
--
--   1. **A payment survives a revision.** A revision is a NEW estimate
--      row, so a payment recorded in month three sits against a row
--      month nine supersedes. Keyed to the chain ROOT, it is still
--      there afterwards — and keyed to the row it was made against it
--      would not be. This is the assertion the whole table shape
--      exists for.
--   2. **Late is its own answer**, because s.107C(9) charges 10% of an
--      instalment not paid by its due date — a separate charge from
--      under-estimating, and one a company can incur in a year it
--      estimated perfectly.
--   3. **An instalment of nothing is never overdue.** A downward
--      revision leaves nil instalments behind, and counting those as
--      late would put a penalty on money nobody owed.
--   4. **An overpayment is not a negative outstanding.** LHDN keeps it
--      against the assessment.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.co(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.year_of(p_org uuid)
returns uuid language sql stable as $$
  select id from public.fiscal_years
   where org_id = p_org
     and end_date between date '2026-01-01' and date '2026-12-31'
   order by end_date limit 1;
$$;

create or replace function pg_temp.revise_in(
  p_estimate uuid, p_amount numeric, p_month integer)
returns uuid language plpgsql as $$
declare v_new uuid;
begin
  v_new := public.revise_tax_estimate(p_estimate, p_amount);
  update public.tax_estimates set revision_month = p_month where id = v_new;
  return v_new;
end; $$;

-- ---------------------------------------------------------------------
-- Recording one
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; s record; sum_r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Bayar Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_true('nothing is paid to start with',
    s.paid_on is null and s.paid_amount is null);
  perform pg_temp.check_eq('and the whole instalment is outstanding',
    s.outstanding, 10000);

  -- No amount and no date: the scheduled figure, today. Paying what
  -- was asked for on the day is the ordinary case, and retyping the
  -- figure is a chance to mistype it.
  perform public.record_tax_instalment(v_est, 1);
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('a bare recording pays the scheduled figure',
    s.paid_amount, 10000);
  perform pg_temp.check_eq('on today''s date',
    s.paid_on::text, app.today()::text);
  perform pg_temp.check_eq('leaving nothing outstanding', s.outstanding, 0);

  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq('one of twelve paid', sum_r.instalments_paid, 1);
  perform pg_temp.check_eq('twelve in all', sum_r.instalments, 12);
  perform pg_temp.check_eq('ten thousand paid', sum_r.paid_total, 10000);
  perform pg_temp.check_eq('a hundred and ten still to go',
    sum_r.outstanding_total, 110000);
  perform pg_temp.check_eq('and the schedule still totals the estimate',
    sum_r.scheduled_total, 120000);

  -- A second recording corrects the first rather than making a rival
  -- claim about the same instalment.
  perform public.record_tax_instalment(
    v_est, 1, date '2026-02-10', 9500, 'RCPT-1');
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('recording it again corrects it',
    s.paid_amount, 9500);
  perform pg_temp.check_eq('and five hundred is left over',
    s.outstanding, 500);
  perform pg_temp.check_eq('with one payment row, not two',
    (select count(*) from public.tax_estimate_payments
      where org_id = v_org), 1);
end $$;

-- ---------------------------------------------------------------------
-- A payment survives a revision
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_est uuid; v_new uuid; s record; sum_r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Ubah Bayar Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  -- Three instalments paid at the original figure.
  perform public.record_tax_instalment(v_est, 1, date '2026-02-15', 10000);
  perform public.record_tax_instalment(v_est, 2, date '2026-03-15', 10000);
  perform public.record_tax_instalment(v_est, 3, date '2026-04-15', 10000);

  -- Then a revision, which is a NEW estimate row. Keyed to the row
  -- they were made against, those three payments would vanish here.
  v_new := pg_temp.revise_in(v_est, 240000, 9);

  select * into sum_r from public.tax_estimate_payment_summary(v_new);
  perform pg_temp.check_eq(
    'three payments made before the revision are still there',
    sum_r.instalments_paid, 3);
  perform pg_temp.check_eq('and still total thirty thousand',
    sum_r.paid_total, 30000);

  -- And they sit against the instalments they were made for, at the
  -- amounts those instalments were payable at.
  select * into s from public.tax_estimate_schedule(v_new)
   where instalment_no = 2;
  perform pg_temp.check_eq('each against its own instalment',
    s.paid_amount, 10000);
  perform pg_temp.check_eq('which was payable at the old figure',
    s.amount, 10000);
  perform pg_temp.check_eq('so nothing is outstanding on it',
    s.outstanding, 0);

  -- The revised instalments are unpaid and carry the new figure.
  select * into s from public.tax_estimate_schedule(v_new)
   where instalment_no = 8;
  perform pg_temp.check_true('the revised ones are unpaid',
    s.paid_on is null);
  perform pg_temp.check_eq('and outstanding at the revised figure',
    s.outstanding, 34000);

  -- Asking the OLD estimate finds them too: the payments hang off the
  -- root, not off whichever row is being looked at.
  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq('the superseded estimate sees them as well',
    sum_r.instalments_paid, 3);

  -- And the other direction, which is the half that says the RECORDING
  -- side resolves the root as well as the reading side: a payment made
  -- against the REVISED row has to be visible from the original. Keyed
  -- to the row it was made against, this one would be invisible to
  -- every lookup that started anywhere else -- and every assertion
  -- above would still pass, because those payments were made against
  -- the root itself.
  perform public.record_tax_instalment(v_new, 8, date '2026-09-15', 34000);

  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq(
    'a payment made against the REVISION is seen from the original',
    sum_r.instalments_paid, 4);
  perform pg_temp.check_eq('and counts toward the total paid',
    sum_r.paid_total, 64000);

  perform pg_temp.check_eq('with one payment row per instalment, still',
    (select count(*) from public.tax_estimate_payments
      where org_id = v_org), 4);
end $$;

-- ---------------------------------------------------------------------
-- Late is its own answer
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; s record; sum_r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Lewat Bayar Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  -- Instalment 1 is due 15 February. Paid on the 20th.
  perform public.record_tax_instalment(v_est, 1, date '2026-02-20', 10000);
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_true('paid after the due date is late', s.paid_late);

  -- On the day itself is on time. `>=` reads identically to `>` on
  -- every date except the one somebody paying at the last minute
  -- actually used.
  perform public.record_tax_instalment(v_est, 2, date '2026-03-15', 10000);
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 2;
  perform pg_temp.check_true('on the due date itself is not',
    not s.paid_late);

  perform public.record_tax_instalment(v_est, 3, date '2026-04-01', 10000);
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 3;
  perform pg_temp.check_true('and before it certainly is not',
    not s.paid_late);

  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq('one was late', sum_r.late_count, 1);
  -- s.107C(9): 10% of the instalment paid late. A separate charge
  -- from under-estimating, and one a company can incur in a year it
  -- estimated perfectly.
  perform pg_temp.check_eq('and the charge on it is a tenth',
    sum_r.late_penalty, 1000);
end $$;

-- ---------------------------------------------------------------------
-- An instalment of nothing is never overdue
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_new uuid; sum_r record; v_nil numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Turun Bayar Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);
  -- Revised down to less than has already been billed: the remaining
  -- instalments go to nil.
  v_new := pg_temp.revise_in(v_est, 50000, 9);

  select amount into v_nil from public.tax_estimate_schedule(v_new)
   where instalment_no = 12;
  perform pg_temp.check_eq('the last instalment is nothing', v_nil, 0);

  select * into sum_r from public.tax_estimate_payment_summary(v_new);
  -- Every instalment is unpaid and most of them are in the past, but
  -- counting the nil ones as overdue would put a penalty on money
  -- nobody owed.
  perform pg_temp.check_eq(
    'the nil instalments are not counted as overdue',
    sum_r.overdue_count, 7);
  perform pg_temp.check_true(
    'and the next thing due is not one of them',
    sum_r.next_due_amount is null or sum_r.next_due_amount > 0);
end $$;

-- ---------------------------------------------------------------------
-- Overdue means the date has gone, and nil is never next
-- ---------------------------------------------------------------------
-- The fiscal year is anchored to the CURRENT month rather than to
-- 2026, so every instalment is in the future whatever day this runs
-- on. A fixture with a fixed year passes both of these by accident
-- for part of its life and stops distinguishing anything once the
-- year is behind us -- which is how the two mutants below survived
-- the first sweep.
do $$
declare
  v_org uuid; v_est uuid; v_new uuid; sum_r record; v_start date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Bulan Ini Sdn Bhd');
  v_start := date_trunc('month', app.today())::date;
  perform public.create_fiscal_year(v_org, v_start);
  v_est := public.open_tax_estimate(
    v_org,
    (select id from public.fiscal_years where org_id = v_org
      order by end_date desc limit 1),
    120000);

  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq('twelve unpaid instalments',
    sum_r.instalments - sum_r.instalments_paid, 12);
  -- None of them is overdue, because none of the dates has gone.
  -- Unpaid and overdue are different questions and a summary that
  -- answered the first when asked the second would report a year that
  -- has not started as entirely late.
  perform pg_temp.check_eq('and not one of them is overdue',
    sum_r.overdue_count, 0);
  perform pg_temp.check_eq('with nothing overdue to total',
    sum_r.overdue_total, 0);

  -- Now revise down so instalment 1 stands at 10,000 and everything
  -- after it goes to nil. Month THREE: the first instalment falls in
  -- month 2 of the basis period, so a revision in month 2 would
  -- govern that one too and re-spread it to 833.33 -- which it did,
  -- the first time this was written.
  v_new := pg_temp.revise_in(v_est, 10000, 3);
  perform pg_temp.check_eq('the first still stands',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 1), 10000);
  perform pg_temp.check_eq('and the second is nothing',
    (select amount from public.tax_estimate_schedule(v_new)
      where instalment_no = 2), 0);

  select * into sum_r from public.tax_estimate_payment_summary(v_new);
  perform pg_temp.check_eq('the first is what is next due',
    sum_r.next_due_amount, 10000);

  -- Pay it, and there is nothing next: the eleven that remain are
  -- nil. Offering one of them as "next due" would tell somebody to
  -- send nothing on a date.
  perform public.record_tax_instalment(v_new, 1);
  select * into sum_r from public.tax_estimate_payment_summary(v_new);
  perform pg_temp.check_true('and once it is paid nothing is next',
    sum_r.next_due_on is null and sum_r.next_due_amount is null);
  perform pg_temp.check_eq('with nothing left outstanding',
    sum_r.outstanding_total, 0);
end $$;

-- ---------------------------------------------------------------------
-- An overpayment is not a negative outstanding
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; s record; sum_r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Lebih Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  -- LHDN accepts what it is sent. Paying more than was asked for is
  -- not an error to refuse; it is a figure to record.
  perform public.record_tax_instalment(v_est, 1, date '2026-02-15', 15000);
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 1;
  perform pg_temp.check_eq('the overpayment is recorded as made',
    s.paid_amount, 15000);
  perform pg_temp.check_eq('and nothing is outstanding on it',
    s.outstanding, 0);

  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq(
    'the outstanding total does not go down by the excess',
    sum_r.outstanding_total, 110000);
  perform pg_temp.check_eq('though the paid total counts all of it',
    sum_r.paid_total, 15000);
end $$;

-- ---------------------------------------------------------------------
-- Clearing one, and what cannot be recorded
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; s record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Batal Bayar Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  perform public.record_tax_instalment(v_est, 4, date '2026-05-15', 10000);
  perform public.clear_tax_instalment(v_est, 4);
  select * into s from public.tax_estimate_schedule(v_est)
   where instalment_no = 4;
  perform pg_temp.check_true('clearing it puts it back to unpaid',
    s.paid_on is null);
  perform pg_temp.check_eq('and outstanding again', s.outstanding, 10000);

  -- A thirteenth instalment against a twelve-instalment estimate is
  -- money somebody will look for and not find.
  perform pg_temp.check_refused(
    'an instalment the schedule does not have is refused',
    format('select public.record_tax_instalment(%L, 13)', v_est),
    'This estimate has 12 instalments, not 13%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- A person's instalments record the same way
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; sum_r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kedai Runcit Pak Usop');
  update public.organizations set entity_type = 'sole_proprietor'
   where id = v_org;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 60000);

  perform public.record_tax_instalment(v_est, 1, date '2026-03-30', 10000);
  select * into sum_r from public.tax_estimate_payment_summary(v_est);
  perform pg_temp.check_eq('six instalments for a person',
    sum_r.instalments, 6);
  perform pg_temp.check_eq('one of them paid', sum_r.instalments_paid, 1);
  perform pg_temp.check_eq('fifty thousand to go',
    sum_r.outstanding_total, 50000);

  -- A seventh does not exist for a CP500, and the refusal says the
  -- right number.
  perform pg_temp.check_refused(
    'and a seventh is refused with the right count',
    format('select public.record_tax_instalment(%L, 7)', v_est),
    'This estimate has 6 instalments, not 7%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- Who may do it
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_est uuid; v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.co('Kedai Sulit Bayar Sdn Bhd');
  v_est := public.open_tax_estimate(v_org, pg_temp.year_of(v_org), 120000);

  v_other := pg_temp.another_user('payer@example.com');
  perform pg_temp.sign_in_as(v_other);

  perform pg_temp.check_refused(
    'somebody outside the company cannot record a payment',
    format('select public.record_tax_instalment(%L, 1)', v_est),
    'Not permitted to record an instalment%', '42501');

  perform pg_temp.check_refused(
    'nor clear one',
    format('select public.clear_tax_instalment(%L, 1)', v_est),
    'Not permitted to clear an instalment%', '42501');

  perform pg_temp.check_refused(
    'nor read where the year stands',
    format('select count(*) from public.tax_estimate_payment_summary(%L)',
           v_est),
    'Insufficient privileges%', '42501');
end $$;

rollback;
