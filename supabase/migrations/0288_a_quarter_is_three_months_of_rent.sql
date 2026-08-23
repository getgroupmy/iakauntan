-- ---------------------------------------------------------------------
-- Billing a quarter charged less than billing its three months
--
-- `app.months_between` has two branches. Whole calendar months — the
-- period starts on the first and ends on a last — count as whole months,
-- which is right and is what 0163 set out to get: "a quarter is 3, not
-- 92/30.4". Anything else is pro-rated on days "against the length of
-- the month the period starts in", and that is the defect.
--
-- The divisor is one month's length applied to a period that may run
-- across several. A tenant who moves in on 15 January, on a site billed
-- quarterly:
--
--     months_between('2026-01-15','2026-03-31')
--       = (76 days) / (31 days in January)
--       = 2.4516
--
-- when what the tenant occupies is the back of January plus two whole
-- months: 17/31 + 1 + 1 = 2.5484. At RM2,000 a month that is RM4,903.20
-- charged against RM5,096.80 owed, and the same shortfall falls on
-- strata Charges and sinking fund, which reach this through
-- `strata_preview` and `raise_strata_charges`.
--
-- It needs no argument about which convention is right, because the
-- application already disagrees with itself. Bill that tenant one month
-- at a time and the three runs come to RM5,096.80; bill the same
-- quarter in one run and it comes to RM4,903.20. Only one of those can
-- be the rent, and the monthly answer is the one `property.sql` has
-- asserted since 0163 — seventeen days of January at 0.5484.
--
-- So: the period is decomposed into the calendar months it touches, and
-- each contributes the days it holds over its own length. Whole months
-- contribute exactly 1, so the whole-month case is unchanged and needs
-- no separate branch. Billing monthly and billing quarterly now agree
-- by construction, which is the property worth having — a managing
-- agent should not be able to change what an owner owes by changing how
-- often the button is pressed.
--
-- One case moves that no test asserted: a period of a month that does
-- not sit on calendar boundaries. 15 January to 14 February was 1.0000
-- and is now 0.5484 + 0.5000 = 1.0484 — seventeen of January's
-- thirty-one days and fourteen of February's twenty-eight. That is more
-- than one month's rent for thirty-one days of occupancy, and it is
-- what pro-rating each month by its own length means: February days
-- cost more than January days because February is shorter. It is the
-- convention a managing agent's ledger uses and the one the single
-- month case here already used; the alternative is to price every day
-- the same, which would have to change 0.5484 too.
--
-- A period that ends before it starts returns 0 rather than a negative
-- number of months. Both callers refuse one upstream with 22023 before
-- they reach this, so that is a floor rather than a meaning.
-- ---------------------------------------------------------------------

create or replace function app.months_between(p_from date, p_to date)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp as $$
  select case when p_to < p_from then 0::numeric else coalesce(round(sum(
    (least(p_to, m.month_end) - greatest(p_from, m.month_start) + 1)::numeric
      / (m.month_end - m.month_start + 1)::numeric
  ), 4), 0) end
  from (
    select s::date as month_start,
           (s + interval '1 month' - interval '1 day')::date as month_end
      from generate_series(date_trunc('month', p_from::timestamp),
                           date_trunc('month', p_to::timestamp),
                           interval '1 month') s
  ) m;
$$;
