-- =====================================================================
-- iAkauntan :: the chart of accounts can post a payroll
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_chart.sql
--
-- `post_payroll_run()` names an account for every line it posts. Where
-- payroll settings do not configure one, `app.payroll_gl_line()` falls
-- back to a hardcoded code and raises if the chart has no such account.
-- Four of those codes were missing from the seeded chart, and the first
-- of them — 2145, net salaries payable — is on a line whose amount is
-- never zero. Every company this product created was therefore unable to
-- post payroll at all, and nothing said so until somebody tried.
--
-- The codes are read out of the function's own source rather than listed
-- here. A list would have to be kept in step by hand, which is the same
-- failure one level up: someone adds a line with a new fallback code, the
-- test still passes, and the chart is short an account again.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_codes   text[];
  v_missing text;
  v_n       integer;
begin
  v_org := pg_temp.test_org('Payroll Chart Sdn Bhd');

  -- The third argument of every app.payroll_gl_line() call is the
  -- fallback account code.
  select array_agg(distinct m[1]) into v_codes
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(
      p.prosrc,
      'payroll_gl_line\(\s*[^,]+,\s*[^,]+,\s*''(\d{4})''', 'g') m
   where n.nspname = 'public' and p.proname = 'post_payroll_run';

  v_n := coalesce(array_length(v_codes, 1), 0);

  -- The positive control. If the pattern ever stops matching — the call
  -- is reformatted, the helper is renamed — the check below would find
  -- nothing missing out of nothing examined and pass while testing
  -- absolutely nothing.
  perform pg_temp.check_true(
    format('post_payroll_run names fallback accounts, and we found %s of '
           'them to check', v_n),
    v_n >= 10);

  select string_agg(c, ', ' order by c) into v_missing
    from unnest(v_codes) c
   where not exists (
     select 1 from public.accounts a
      where a.org_id = v_org and a.code = c and not a.is_group);

  perform pg_temp.check_true(
    format('a freshly seeded chart has all %s of them, so a new company '
           'can post its first payroll without editing the chart by '
           'hand — missing: %s', v_n, coalesce(v_missing, 'none')),
    v_missing is null);
end $$;

rollback;
