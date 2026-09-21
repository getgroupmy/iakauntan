-- =====================================================================
-- iAkauntan :: 0672 a revision does not undo the year
--
-- Measured, not guessed. A company estimating RM120,000 and revising
-- to RM240,000 in the ninth month is handed, today, twelve instalments
-- of RM20,000 starting in February — eight of them already past, and
-- every one of them at a figure that was never payable on the date
-- beside it. The company has actually paid eight instalments of
-- RM10,000 and owes RM40,000 on each of the four that remain.
--
-- That is a wrong number rather than a missing feature, which is why
-- it goes ahead of the things that are merely absent.
--
-- ---------------------------------------------------------------------
-- The rule
--
-- s.107C(7). A revision does not re-open the instalments that have
-- already fallen due; it spreads what is left. Each instalment is
-- payable at whatever the estimate in force ON ITS DUE DATE said,
-- and a revision divides
--
--     revised estimate  −  everything already scheduled before it
--
-- over the instalments that remain. Two revisions are allowed, in the
-- sixth and ninth months, so this has to compose: the ninth-month
-- revision spreads over what is left after the sixth-month one, not
-- after the original.
--
-- ---------------------------------------------------------------------
-- Revising DOWNWARD
--
-- A company that over-estimated and revises down can owe less for the
-- rest of the year than it has already been billed for. The remaining
-- instalments go to nil rather than negative — LHDN does not refund
-- through the instalment schedule, and a negative instalment on a
-- screen reads as money coming back on a date when none is.
--
-- The excess is recovered at assessment, which `tax_estimate_exposure`
-- already measures against the computation. This says nothing about
-- it, because a schedule is a schedule.
--
-- ---------------------------------------------------------------------
-- What this does not do
--
-- It does not know what was actually PAID. The schedule says what was
-- payable; a company that missed an instalment sees the same rows as
-- one that paid every one. Recording payments is its own piece of work
-- and is not this.
-- =====================================================================

-- The return type gains a column, so the old one has to go first --
-- `create or replace` refuses to change the row type OUT parameters
-- define. `or replace` is kept after the drop because
-- `scripts/mutate_sql.py` looks for exactly that phrase when it
-- extracts a function to break on purpose.
drop function if exists public.tax_estimate_schedule(uuid);

create or replace function public.tax_estimate_schedule(p_estimate_id uuid)
returns table (
  instalment_no    integer,
  due_on           date,
  amount           numeric,
  -- Whether this instalment's amount was set by a revision rather
  -- than by the original estimate. The screen draws the two
  -- differently, because "this changed after you started paying" is
  -- the thing somebody needs to see on a revised schedule.
  set_by_revision  boolean)
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
  v_first  date;
  v_month  date;
  v_in_force integer := 1;   -- index into `totals`
  v_each   numeric;
  v_sofar  numeric := 0;
  v_amount numeric;
  v_imonth integer;
  i        integer;
  j        integer;
  v_exempt boolean;
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
    -- `check_discarded_values.py` refuses a computed-and-unread
    -- variable in Dart and there is no SQL equivalent, so this is the
    -- note instead.
    totals := array_prepend(v_amount, totals);
    months := array_prepend(coalesce(v_imonth, 0), months);
    v_cur := v_prev;
  end loop;

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

    return query select
      i,
      -- Clamped to the length of the month. CP500 falls on the 30th,
      -- and a schedule that reached February would otherwise raise
      -- rather than land on the 28th.
      app.tax_filing_fixed_date(
        extract(year from v_month)::integer,
        extract(month from v_month)::integer,
        r.instalment_day),
      v_amount,
      (v_in_force > 1);
  end loop;
end; $$;

revoke all on function public.tax_estimate_schedule(uuid) from public, anon;
grant execute on function public.tax_estimate_schedule(uuid)
  to authenticated;

comment on function public.tax_estimate_schedule(uuid) is
  'The instalments an estimate is paid in, on the rhythm its FORM '
  'names, EMPTY where a qualifying new SME owes none, and -- where '
  'the estimate has been revised -- with the instalments already due '
  'left at what was payable on their dates and the balance spread '
  'over those that remain. Says what was payable, never what was '
  'paid.';
