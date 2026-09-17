-- =====================================================================
-- iAkauntan :: a failing assertion has to reach psql
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/the_helpers_fail_loudly.sql
--
-- Every other file here asserts something about the application. This
-- one asserts something about the files themselves, and it exists
-- because three assertions in this suite were silently passing while
-- checking nothing.
--
-- The shape is everywhere, and it is the right shape:
--
--   begin
--     perform <the thing that must be refused>;
--     perform pg_temp.check_true('X can happen', false);   -- must not reach
--   exception when others then
--     get stacked diagnostics v_msg = message_text;
--     perform pg_temp.check_true('X is refused', v_msg like '%X%');
--   end;
--
-- The trap is that `when others` catches the marker too. When the
-- refusal does NOT happen, the marker raises
-- `FAIL X can happen: expected true`, the handler below catches THAT,
-- and matches it against its own pattern. Where the label contains the
-- pattern -- which it naturally does, both describing the same rule --
-- the test passes BECAUSE it failed.
--
-- Found by a mutation sweep of create_contra: `app.same_party` could be
-- deleted outright and contra.sql still read green, which meant one
-- customer's invoice could be written off against an unrelated
-- supplier's bill with the suite saying nothing. The same shape had
-- killed the "nothing left to credit" assertion in
-- credit_note_return.sql, where the guard stops an invoice being
-- credited twice.
--
-- The fix is one clause in `_helpers.sql`: every failure is raised with
-- errcode 'P0004', assert_failure, which is one of the two conditions
-- (with query_canceled) that `when others` does not catch. This file
-- holds that property down.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare v_escaped boolean := false;
begin
  -- The whole point: a failing check_true must pass straight through a
  -- `when others` handler. If this notice is ever reached, every
  -- refusal assertion in the suite is only as good as its label.
  begin
    begin
      perform pg_temp.check_true('a marker that must escape', false);
    exception when others then
      raise exception
        'check_true was SWALLOWED by `when others`. Every begin/exception '
        'block in this suite that ends with check_true(..., false) is now '
        'asserting its own label rather than the application.'
        using errcode = '23514';
    end;
  exception when assert_failure then
    v_escaped := true;
  end;
  perform pg_temp.check_true(
    'a failing check_true escapes `when others`', v_escaped);

  -- The same for the other three helpers, since a later edit could fix
  -- one and leave the rest.
  v_escaped := false;
  begin
    begin
      perform pg_temp.check_eq('a numeric marker', 1::numeric, 2::numeric);
    exception when others then null;
    end;
  exception when assert_failure then v_escaped := true;
  end;
  perform pg_temp.check_true(
    'and so does a failing numeric check_eq', v_escaped);

  v_escaped := false;
  begin
    begin
      perform pg_temp.check_eq('a text marker', 'a'::text, 'b'::text);
    exception when others then null;
    end;
  exception when assert_failure then v_escaped := true;
  end;
  perform pg_temp.check_true(
    'and a failing text check_eq', v_escaped);

  v_escaped := false;
  begin
    begin
      perform pg_temp.check_eq('a uuid marker',
        '00000000-0000-0000-0000-000000000001'::uuid,
        '00000000-0000-0000-0000-000000000002'::uuid);
    exception when others then null;
    end;
  exception when assert_failure then v_escaped := true;
  end;
  perform pg_temp.check_true(
    'and a failing uuid check_eq', v_escaped);

  -- And it still passes when it should, or the four above are satisfied
  -- by helpers that raise no matter what.
  perform pg_temp.check_true('a passing check_true does not raise', true);
  perform pg_temp.check_eq('a passing check_eq does not raise',
    1::numeric, 1::numeric);

  raise notice 'the helpers fail loudly: every marker escapes';
end $$;

rollback;
