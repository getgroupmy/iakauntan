-- =====================================================================
-- iAkauntan :: 0860 the company's tax is the ledger's
--
-- Since `0855` the tax computation, its lines, the partnership
-- allocation and the estimate's exposure ask `app.can_read_ledger`.
-- The tables under them still answered every member
-- (`app.is_org_member`): `tax_computations` (gross business income,
-- losses and allowances brought forward), `tax_adjustments`,
-- `tax_other_income`, `tax_relief_claims`, `tax_partners` (each
-- partner's salary, interest and share), `tax_estimates` (the CP204
-- figure) and `tax_estimate_payments`. And two functions asked only
-- membership: `tax_estimate_schedule` and
-- `tax_estimate_payment_summary`.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated` (`can_read_ledger` false): gross business income
-- 2,345,678.90, a loss brought forward of 120,000, an "Entertainment"
-- add-back of 45,000, an estimated tax of 456,000, its twelve
-- instalments and what was paid against them.
--
-- Answered "figures need ledger access, deadlines stay":
--
--   * the seven tables' select policies ask `app.can_read_ledger`. The
--     writes were already `app.can_post`'s, every one of whom reads the
--     ledger;
--   * `tax_estimate_schedule` refuses a role that does not read the
--     ledger;
--   * `tax_estimate_payment_summary` still answers every member, since
--     `module_dashboard`'s tax tile asks it for every member of a
--     company with accounting -- how many instalments are behind and
--     when the next falls due. Those stay. The six sums of money come
--     back blank, not nought, to such a role;
--   * `tax_filings` and `tax_upcoming_filings` -- forms, dates and
--     status, no figure -- are not touched.
--
-- The summary read the public schedule, which now refuses the very
-- members the summary still answers. So the schedule's body moves,
-- word for word, to `app.tax_estimate_schedule_of`, which no client may
-- call; the public schedule is its refusals and that function, and the
-- summary reads that function too.
-- =====================================================================

alter policy tax_computations_select on public.tax_computations
  using (app.can_read_ledger(org_id));

alter policy tax_adjustments_select on public.tax_adjustments
  using (app.can_read_ledger(org_id));

alter policy tax_other_income_select on public.tax_other_income
  using (app.can_read_ledger(org_id));

alter policy tax_relief_claims_select on public.tax_relief_claims
  using (app.can_read_ledger(org_id));

alter policy tax_partners_select on public.tax_partners
  using (app.can_read_ledger(org_id));

alter policy tax_estimates_select on public.tax_estimates
  using (app.can_read_ledger(org_id));

alter policy tax_estimate_payments_select on public.tax_estimate_payments
  using (app.can_read_ledger(org_id));

-- The schedule's arithmetic, restated from `0673` word for word under a
-- name no client calls. Both functions below read it; the public
-- schedule refuses a role that does not read the ledger, the summary
-- does not, and neither may ask the other.
create or replace function app.tax_estimate_schedule_of(p_estimate_id uuid)
returns table (
  instalment_no    integer,
  due_on           date,
  amount           numeric,
  set_by_revision  boolean,
  paid_on          date,
  paid_amount      numeric,
  -- Paid AFTER the due date. Its own column rather than two dates for
  -- the reader to subtract, because it is what s.107C(9) charges 10%
  -- on and the two sit in different columns of the same row.
  paid_late        boolean,
  -- Scheduled less paid, floored at nothing. An overpayment is not a
  -- negative outstanding: LHDN keeps it against the assessment.
  outstanding      numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  r        record;
  totals   numeric[];
  months   integer[];
  v_cur    uuid;
  v_prev   uuid;
  v_root   uuid;
  v_first  date;
  v_month  date;
  v_due    date;
  v_in_force integer := 1;
  v_each   numeric;
  v_sofar  numeric := 0;
  v_amount numeric;
  v_imonth integer;
  i        integer;
  j        integer;
  v_exempt boolean;
  p        record;
begin
  select te.*, fy.start_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  -- A qualifying new SME owes none. Twelve rows of demands for money
  -- on dates nobody has to meet is worse than an empty list with a
  -- sentence under it, which is what the screen draws instead.
  select fp.exempt_instalments into v_exempt
    from public.tax_estimate_first_period(p_estimate_id) fp;
  if v_exempt then
    return;
  end if;

  -- The chain, OLDEST first. `revises_id` points backwards, so this
  -- walks back to the original and then reverses -- there are at most
  -- three links (an original and two permitted revisions), and the
  -- loop is bounded by that rather than trusting the data not to
  -- contain a cycle.
  totals := array[]::numeric[];
  months := array[]::integer[];
  v_cur := p_estimate_id;
  for j in 1..10 loop
    exit when v_cur is null;
    -- `v_prev` is a separate variable on purpose. Reading the row's
    -- own id and its `revises_id` into the SAME variable in one INTO
    -- list assigns both, the second wins, and the chain quietly ends
    -- up holding every link's PARENT rather than the link.
    select te.estimated_tax, te.revises_id, te.revision_month
      into v_amount, v_prev, v_imonth
      from public.tax_estimates te where te.id = v_cur;
    -- Prepend: the walk is newest-first and the arithmetic below needs
    -- oldest-first.
    --
    -- The ids themselves are deliberately NOT collected. A third array
    -- holding them was written first, never read, and a mutation
    -- sweep proved it: breaking what went into it changed nothing.
    totals := array_prepend(v_amount, totals);
    months := array_prepend(coalesce(v_imonth, 0), months);
    v_cur := v_prev;
  end loop;

  -- Payments hang off the ROOT, so they are found whichever estimate
  -- in the chain this was asked about.
  v_root := app.tax_estimate_root(p_estimate_id);

  v_each := round(totals[1] / r.instalments, 2);

  -- The month the first instalment falls in, counted from the start of
  -- the basis period.
  v_first := date_trunc('month',
               e.start_date
               + make_interval(months => r.first_instalment_month - 1))::date;

  for i in 1..r.instalments loop
    v_month := (v_first
                + make_interval(
                    months => (i - 1) * r.months_between))::date;

    -- Which month of the BASIS PERIOD this instalment falls in, so it
    -- can be compared with the month a revision was made in.
    v_imonth := r.first_instalment_month + (i - 1) * r.months_between;

    -- Has a later estimate come into force by now? A revision made in
    -- month 9 governs the instalments due in month 9 and after, and
    -- leaves the earlier ones exactly as they were payable.
    while v_in_force < array_length(totals, 1)
          and months[v_in_force + 1] <= v_imonth loop
      v_in_force := v_in_force + 1;
      -- Spread what is left of the REVISED total over the instalments
      -- that remain, including this one. Never below nothing: a
      -- company that revised downward owes nil for the rest of the
      -- year rather than being shown money coming back on a date when
      -- none is.
      v_each := round(
        greatest(totals[v_in_force] - v_sofar, 0)
        / (r.instalments - i + 1), 2);
    end loop;

    v_amount := case
      -- The last one absorbs whatever the division left over, so the
      -- schedule adds up to whatever is in force exactly.
      when i = r.instalments
        then round(greatest(totals[v_in_force] - v_sofar, 0), 2)
      else v_each
    end;
    v_sofar := v_sofar + v_amount;

    v_due := app.tax_filing_fixed_date(
      extract(year from v_month)::integer,
      extract(month from v_month)::integer,
      r.instalment_day);

    select tp.paid_on, tp.amount into p
      from public.tax_estimate_payments tp
     where tp.root_estimate_id = v_root and tp.instalment_no = i;

    return query select
      i,
      v_due,
      v_amount,
      (v_in_force > 1),
      p.paid_on,
      p.amount,
      (p.paid_on is not null and v_due is not null and p.paid_on > v_due),
      greatest(v_amount - coalesce(p.amount, 0), 0);
  end loop;
end; $$;

revoke all on function app.tax_estimate_schedule_of(uuid)
  from public, anon, authenticated;

-- Restated from `0673`: the same refusals, the ledger's added, and the
-- rows from the function above.
create or replace function public.tax_estimate_schedule(p_estimate_id uuid)
returns table (
  instalment_no    integer,
  due_on           date,
  amount           numeric,
  set_by_revision  boolean,
  paid_on          date,
  paid_amount      numeric,
  -- Paid AFTER the due date. Its own column rather than two dates for
  -- the reader to subtract, because it is what s.107C(9) charges 10%
  -- on and the two sit in different columns of the same row.
  paid_late        boolean,
  -- Scheduled less paid, floored at nothing. An overpayment is not a
  -- negative outstanding: LHDN keeps it against the assessment.
  outstanding      numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select te.org_id into v_org
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if v_org is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  -- `0860`. What each instalment is, what was paid and what is left
  -- are the company's tax, and the ledger's to show.
  if not app.can_read_ledger(v_org) then
    raise exception 'Insufficient privileges to read the ledger' using errcode = '42501';
  end if;

  return query select * from app.tax_estimate_schedule_of(p_estimate_id);
end; $$;

-- Restated from `0768`, its text unchanged but for the three marked
-- places: the ledger asked, the schedule read from the inner function,
-- and the six sums of money blank where the answer was no.
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
declare e record; r record; v_today date := app.today(); v_ledger boolean;
begin
  select te.* into e from public.tax_estimates te where te.id = p_estimate_id;
  if e.id is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  -- `0860`. The dashboard's tax tile asks this of every member for how
  -- many instalments are behind and when the next falls due, and those
  -- stay everybody's. What they come to is the ledger's: blank, not
  -- nought, to a role that does not read it.
  v_ledger := app.can_read_ledger(e.org_id);

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;

  return query
  with s as (select * from app.tax_estimate_schedule_of(p_estimate_id))
  select
    case when v_ledger then coalesce(sum(s.amount), 0) end,
    case when v_ledger then coalesce(sum(s.paid_amount), 0) end,
    case when v_ledger then coalesce(sum(s.outstanding), 0) end,
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
    case when v_ledger then coalesce(sum(s.outstanding) filter (
      where s.outstanding > 0 and s.due_on < v_today), 0) end,
    count(*) filter (where s.paid_late)::integer,
    -- 10% of what was paid late. Says what the charge comes to, not
    -- that LHDN raised it -- which is not something this can know.
    case when v_ledger then
    round(coalesce(sum(s.paid_amount) filter (where s.paid_late), 0)
          * coalesce(r.late_instalment_penalty_percent, 0) / 100, 2) end,
    -- The next one not covered, and what is still to pay on it.
    min(s.due_on) filter (where s.outstanding > 0),
    case when v_ledger then (array_agg(s.outstanding order by s.due_on)
       filter (where s.outstanding > 0))[1] end
  from s;
end; $$;
