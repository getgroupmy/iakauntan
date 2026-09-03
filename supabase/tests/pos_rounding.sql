-- =====================================================================
-- iAkauntan :: the five sen a till cannot pay
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_rounding.sql
--
-- Malaysia withdrew the one sen coin in 2008, and Bank Negara's rounding
-- mechanism settles a cash bill to the nearest five sen: endings of 1
-- and 2 round down, 3 and 4 round up. `app.pos_cash_due` is where that
-- lives, and it is asked at every tender sheet in the product.
--
-- Three things about it could be changed with nothing failing —
-- rounding to ten sen instead of five, rounding a shop that turned
-- rounding off, and handing back a negative amount due. Found by
-- changing each and re-running; the rounding is the one that matters,
-- because ten sen is a plausible-looking mistake that overcharges half
-- the customers who pay cash and shortchanges the other half.
--
-- The function is pure, so this file needs no fixtures and asserts it
-- directly.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
begin
  -- ------------------------------------------------------------------
  -- The four endings, which is the whole of the mechanism
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('one sen rounds down',   app.pos_cash_due(10.01), 10.00);
  perform pg_temp.check_eq('two sen rounds down',   app.pos_cash_due(10.02), 10.00);
  perform pg_temp.check_eq('three sen rounds up',   app.pos_cash_due(10.03), 10.05);
  perform pg_temp.check_eq('four sen rounds up',    app.pos_cash_due(10.04), 10.05);
  perform pg_temp.check_eq('six sen rounds down',   app.pos_cash_due(10.06), 10.05);
  perform pg_temp.check_eq('seven sen rounds down', app.pos_cash_due(10.07), 10.05);
  perform pg_temp.check_eq('eight sen rounds up',   app.pos_cash_due(10.08), 10.10);
  perform pg_temp.check_eq('nine sen rounds up',    app.pos_cash_due(10.09), 10.10);

  -- Five sen and nothing are already payable and must not move. A rule
  -- rounding to ten sen would take 10.05 to 10.10, which is the mistake
  -- this block exists to catch.
  perform pg_temp.check_eq('a five sen ending is already payable',
    app.pos_cash_due(10.05), 10.05);
  perform pg_temp.check_eq('and a round ringgit stays where it is',
    app.pos_cash_due(10.00), 10.00);
  perform pg_temp.check_eq('as does fifteen sen',
    app.pos_cash_due(10.15), 10.15);

  -- ------------------------------------------------------------------
  -- A shop that does not round
  --
  -- The flag exists because not every tender is cash across a counter:
  -- an account sale or a delivery settled to the sen should be asked
  -- for to the sen.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('rounding off means the sen are asked for',
    app.pos_cash_due(10.03, 0, false), 10.03);
  perform pg_temp.check_eq('and nothing is moved either way',
    app.pos_cash_due(10.07, 0, false), 10.07);

  -- ------------------------------------------------------------------
  -- What the card already paid
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the non-cash tender comes off first',
    app.pos_cash_due(10.03, 5.00), 5.05);
  perform pg_temp.check_eq('and rounding applies to what is left, not the bill',
    app.pos_cash_due(10.00, 4.98), 5.00);

  -- Paid in full by card, and more than in full: a till owing negative
  -- cash is change at the drawer, which is a different transaction.
  perform pg_temp.check_eq('nothing is due when the card covered it',
    app.pos_cash_due(10.00, 10.00), 0);
  perform pg_temp.check_eq('nor when it covered more than it',
    app.pos_cash_due(10.00, 25.00), 0);
  perform pg_temp.check_eq('and the same with rounding off',
    app.pos_cash_due(10.00, 25.00, false), 0);

  -- Nothing owed on nothing.
  perform pg_temp.check_eq('a nil bill asks for nothing',
    app.pos_cash_due(0), 0);
  perform pg_temp.check_eq('and a null total is not an error',
    app.pos_cash_due(null), 0);
end $$;

rollback;
