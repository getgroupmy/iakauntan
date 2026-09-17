-- =====================================================================
-- iAkauntan :: every account reaches the face of the statement
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/fs_mapping_is_total.sql
--
-- `fs_prepare` iterates `mbrs_elements` and LEFT JOINs the figures to
-- it. `app.fs_figures_at` drops any figure whose element is null. So
-- there are three ways an account's balance can leave a statutory
-- filing without anybody being told:
--
--   1. `app.fs_default_element` has no answer for its subtype, so
--      `fs_element_for` returns null and `fs_figures_at`'s
--      `where element is not null` discards it.
--   2. It has an answer, but the code is not a row in
--      `mbrs_elements`, so the join in `fs_prepare` matches nothing.
--   3. The row is there but `is_active` is false, or its `framework`
--      is the other one -- both of which `fs_prepare` filters on, and
--      neither of which the default mapping can see.
--
-- None of the three raises anything. The money is simply not on the
-- page, and `fs_balance_check` only catches the subset of them that
-- unbalances the Statement of Financial Position -- a dropped expense
-- or a dropped revenue balances perfectly and is still a false set of
-- accounts.
--
-- Today the mapping is total: all 26 subtypes and all 5 types have an
-- answer, every answer is seeded, active and framework-neutral, and
-- `fs_account_map.element_code` has a foreign key. This asserts each
-- of those, so that extending `app.account_subtype`, deactivating an
-- element or giving one a framework fails here rather than at the SSM
-- counter.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- 1: the mapping answers for every pair the enums can produce
-- ---------------------------------------------------------------------
do $$
declare v_missing text;
begin
  select string_agg(t.t || '/' || s.s, ', ' order by t.t, s.s)
    into v_missing
    from (select unnest(enum_range(null::app.account_type)) t) t,
         (select unnest(enum_range(null::app.account_subtype)) s) s
   where app.fs_default_element(t.t, s.s) is null;

  perform pg_temp.check_eq(
    'every account type and subtype has a taxonomy element',
    coalesce(v_missing, 'none'), 'none');
end $$;

-- A subtype the mapper has never heard of is the case a future
-- migration creates: `alter type app.account_subtype add value` is one
-- line and touches nothing here. Passing null takes the identical
-- branch -- no `when` matches either way -- so this is the fallback a
-- new enum value would land on, exercised before it exists.
do $$
declare v_missing text;
begin
  select string_agg(t.t::text, ', ' order by t.t::text)
    into v_missing
    from (select unnest(enum_range(null::app.account_type)) t) t
   where app.fs_default_element(t.t, null) is null;

  perform pg_temp.check_eq(
    'a subtype the mapper does not know still lands on its type',
    coalesce(v_missing, 'none'), 'none');
end $$;

-- ---------------------------------------------------------------------
-- 2: and every answer survives the join in `fs_prepare`
-- ---------------------------------------------------------------------
create or replace function pg_temp.producible()
returns table (code text) language sql as $$
  select distinct app.fs_default_element(t.t, s.s)
    from (select unnest(enum_range(null::app.account_type)) t) t,
         (select unnest(enum_range(null::app.account_subtype)) s) s
   where app.fs_default_element(t.t, s.s) is not null
  union
  select distinct app.fs_default_element(t.t, null)
    from (select unnest(enum_range(null::app.account_type)) t) t
   where app.fs_default_element(t.t, null) is not null;
$$;

do $$
declare v_bad text;
begin
  select string_agg(p.code, ', ' order by p.code) into v_bad
    from pg_temp.producible() p
    left join public.mbrs_elements e on e.code = p.code
   where e.code is null;
  perform pg_temp.check_eq(
    'every element the mapping can name is seeded',
    coalesce(v_bad, 'none'), 'none');

  select string_agg(e.code, ', ' order by e.code) into v_bad
    from pg_temp.producible() p
    join public.mbrs_elements e on e.code = p.code
   where not e.is_active;
  perform pg_temp.check_eq(
    'and none of them has been deactivated',
    coalesce(v_bad, 'none'), 'none');

  -- The default mapping is given a type and a subtype. It is not given
  -- the filing's framework and could not honour it if it were, so an
  -- element it names that belongs to one framework is an account that
  -- disappears from every filing under the other.
  select string_agg(e.code || ' (' || e.framework || ')', ', ' order by e.code)
    into v_bad
    from pg_temp.producible() p
    join public.mbrs_elements e on e.code = p.code
   where e.framework is not null;
  perform pg_temp.check_eq(
    'and none is restricted to one framework',
    coalesce(v_bad, 'none'), 'none');
end $$;

-- ---------------------------------------------------------------------
-- 3: a company holding one account of every subtype loses none of them
--
-- The structural checks above are about the enums. This is about the
-- three functions in sequence, with money in them: if any figure is
-- dropped between `fs_figures_at` and `fs_prepare`, the two disagree.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_filing uuid; v_sub app.account_subtype;
  v_ids uuid[] := '{}'; v_i integer := 0; v_n integer;
  v_unmapped integer; v_fig_n integer; v_fig_sum numeric;
  v_prep_n integer; v_prep_sum numeric;
  v_extra uuid; v_before numeric; v_after numeric;
begin
  v_org := pg_temp.test_org('Probe FS Mapping');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2025-01-01');

  -- One account of every subtype, named for the subtype rather than
  -- taken from the seeded chart: the seed does not carry all 26, and a
  -- subtype it omits is exactly the one whose mapping nobody has ever
  -- exercised.
  for v_sub in select unnest(enum_range(null::app.account_subtype)) loop
    v_i := v_i + 1;
    insert into public.accounts (org_id, code, name, account_type, account_subtype)
    values (v_org, 'ZZ' || lpad(v_i::text, 3, '0'),
            'Probe ' || v_sub::text,
            case
              when v_sub::text in ('current_asset','bank','cash',
                                   'accounts_receivable','inventory',
                                   'fixed_asset','accumulated_depreciation',
                                   'other_asset') then 'asset'
              when v_sub::text in ('current_liability','accounts_payable',
                                   'tax_payable','long_term_liability',
                                   'other_liability') then 'liability'
              when v_sub::text in ('share_capital','retained_earnings',
                                   'reserves','drawings') then 'equity'
              when v_sub::text in ('sales','other_income') then 'revenue'
              else 'expense'
            end::app.account_type,
            v_sub)
    returning id into v_extra;
    v_ids := v_ids || v_extra;
  end loop;

  v_n := array_length(v_ids, 1);
  perform pg_temp.check_eq('an account for every subtype',
    v_n::text,
    (select count(*)::text from unnest(enum_range(null::app.account_subtype))));

  -- Paired off, so every one of them carries a figure. The amounts
  -- differ per pair so that two dropped elements cannot cancel each
  -- other out and leave the sums agreeing.
  for v_i in 1 .. (v_n / 2) loop
    insert into public.gl_entries
      (org_id, entry_no, entry_date, source, status, description)
    values (v_org, 'FSM-' || v_i, date '2025-03-31', 'manual', 'posted',
            'mapping probe')
    returning id into v_extra;
    insert into public.gl_lines
      (org_id, entry_id, line_no, account_id, debit, credit)
    values (v_org, v_extra, 1, v_ids[v_i * 2 - 1], 1000 + v_i * 37, 0),
           (v_org, v_extra, 2, v_ids[v_i * 2],     0, 1000 + v_i * 37);
  end loop;

  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count)
  values (v_org, date '2025-01-01', date '2025-12-31', 'mpers', 'audited', 3)
  returning id into v_filing;

  -- (a) nothing on either report fails to name an element
  select count(*) into v_unmapped from (
    select b.account_id, b.account_type, b.account_subtype
      from public.report_balance_sheet(v_org, date '2025-12-31') b
     union all
    select p.account_id, p.account_type, p.account_subtype
      from public.report_profit_loss(v_org, date '2025-01-01', date '2025-12-31') p
  ) r
   where app.fs_element_for(v_org, r.account_id, r.account_type,
                            r.account_subtype) is null;
  perform pg_temp.check_eq('no account on either report is unmapped',
    v_unmapped::text, '0');

  -- (b) and nothing the figures produce is lost on the way to the page
  select count(*), coalesce(sum(amount), 0) into v_fig_n, v_fig_sum
    from app.fs_figures_at(v_org, date '2025-01-01', date '2025-12-31');
  select count(*), coalesce(sum(current_amount), 0) into v_prep_n, v_prep_sum
    from public.fs_prepare(v_filing);

  perform pg_temp.check_eq('every figure reaches a line of the statement',
    v_fig_n::text, v_prep_n::text);
  perform pg_temp.check_eq('and carries its full amount there',
    v_fig_sum::text, v_prep_sum::text);
  perform pg_temp.check_true('with something actually on the page',
    v_prep_n > 5);

  -- (c) the deviation table is honoured, and what it names survives the
  -- same join. `InvestmentProperties` is seeded and reachable from no
  -- subtype at all, so a figure appearing against it can only have come
  -- from the map.
  v_before := (select coalesce(sum(current_amount), 0)
                 from public.fs_prepare(v_filing)
                where element_code = 'InvestmentProperties');
  perform pg_temp.check_eq('nothing lands on the mapped element by default',
    v_before::text, '0');

  insert into public.fs_account_map (org_id, account_id, element_code)
  select v_org, a.id, 'InvestmentProperties'
    from public.accounts a
   where a.org_id = v_org and a.account_subtype = 'fixed_asset';

  v_after := (select coalesce(sum(current_amount), 0)
                from public.fs_prepare(v_filing)
               where element_code = 'InvestmentProperties');
  perform pg_temp.check_true('and the mapping moves the figure there',
    v_after <> 0);

  -- The map must not lose it either: the totals still agree.
  select count(*), coalesce(sum(amount), 0) into v_fig_n, v_fig_sum
    from app.fs_figures_at(v_org, date '2025-01-01', date '2025-12-31');
  select count(*), coalesce(sum(current_amount), 0) into v_prep_n, v_prep_sum
    from public.fs_prepare(v_filing);
  perform pg_temp.check_eq('a mapped figure is not dropped either',
    v_fig_sum::text, v_prep_sum::text);

  raise notice 'fs mapping: 26 subtypes, 5 types, nothing falls off the page';
end $$;

rollback;
