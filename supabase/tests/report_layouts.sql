-- =====================================================================
-- iAkauntan :: the layout an accountant signs off
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/report_layouts.sql
--
-- `0637`. G8: a company's own P&L and Balance Sheet layouts with
-- formula rows. The arithmetic moved into the database because the
-- moment a user can edit a layout, "gross profit" stops being
-- presentation and becomes a rule on a document somebody signs.
--
-- What has to hold:
--
--   * **a company with no layout still gets its report**, identical to
--     the one it got before this migration, and OPENING IT WRITES
--     NOTHING. The first draft seeded rows on read; `live_change_feed`
--     refused it and was right to.
--   * **the standard rows and a copied layout agree**, so the fallback
--     cannot drift from what the builder starts you on.
--   * **a formula may only look upwards**, which is what makes a cycle
--     impossible rather than merely detected. A forward reference
--     RAISES; reading it as zero would put a wrong figure on a signed
--     document silently.
--   * **a refused layout leaves the old one standing**, because
--     validating after deleting would lose a company's layout to a
--     typo.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company with a year open and one posted sale, so the P&L has
-- something in it. Revenue 1000, cost of sales 400, an expense of 100:
-- gross profit 600, net profit 500 -- three figures that cannot be
-- mistaken for one another.
create or replace function pg_temp.rl_org(p_name text)
returns uuid language plpgsql as $$
declare
  v_org uuid;
  v_rev uuid; v_cos uuid; v_exp uuid; v_bank uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select id into v_rev from public.accounts
   where org_id = v_org and code = '4000';
  select id into v_cos from public.accounts
   where org_id = v_org and code = '5000';
  select id into v_exp from public.accounts
   where org_id = v_org and code = '6110';
  select id into v_bank from public.accounts
   where org_id = v_org and code = '1110';

  perform public.create_gl_entry(
    v_org, date '2026-03-01', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 1000, 'credit', 0),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 1000)),
    'Jualan', null, null, null);

  perform public.create_gl_entry(
    v_org, date '2026-03-02', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_cos, 'debit', 400, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'debit', 0, 'credit', 400)),
    'Kos jualan', null, null, null);

  perform public.create_gl_entry(
    v_org, date '2026-03-03', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'debit', 0, 'credit', 100)),
    'Belanja', null, null, null);

  return v_org;
end;
$$;

-- Movement on an account that nets to zero: charged, then credited
-- back. An account with no movement at all is a different case and
-- would not distinguish the rule under test.
create or replace function pg_temp.rl_wash(p_org uuid, p_code text)
returns void language plpgsql as $$
declare v_acct uuid; v_bank uuid;
begin
  select id into v_acct from public.accounts
   where org_id = p_org and code = p_code;
  select id into v_bank from public.accounts
   where org_id = p_org and code = '1110';
  perform public.create_gl_entry(
    p_org, date '2026-05-01', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_acct, 'debit', 75, 'credit', 0),
      jsonb_build_object('account_id', v_bank, 'debit', 0, 'credit', 75)),
    'Caj', null, null, null);
  perform public.create_gl_entry(
    p_org, date '2026-05-02', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 75, 'credit', 0),
      jsonb_build_object('account_id', v_acct, 'debit', 0, 'credit', 75)),
    'Caj dikembalikan', null, null, null);
end;
$$;

-- One row's amount, by key. Section totals carry line_no 0; the
-- accounts listed under a section carry 1, 2, 3 and share the key.
create or replace function pg_temp.rl_amount(
  p_org uuid, p_kind app.report_kind, p_key text)
returns numeric language sql as $$
  select amount from public.report_with_layout(
    p_org, p_kind, date '2026-01-01', date '2026-12-31')
   where row_key = p_key and line_no = 0;
$$;

-- ---------------------------------------------------------------------
-- 1. A company with no layout gets the standard report, and writes
--    nothing opening it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Tiada Susun Atur Sdn Bhd');
  v_before bigint;
  v_after  bigint;
begin
  perform pg_temp.check_eq('revenue is the revenue',
    pg_temp.rl_amount(v_org, 'profit_loss', 'revenue'), 1000::numeric);
  perform pg_temp.check_eq('cost of sales is its own figure',
    pg_temp.rl_amount(v_org, 'profit_loss', 'cost_of_sales'), 400::numeric);
  perform pg_temp.check_eq('gross profit is revenue less cost of sales',
    pg_temp.rl_amount(v_org, 'profit_loss', 'gross_profit'), 600::numeric);
  perform pg_temp.check_eq('expenses exclude cost of sales',
    pg_temp.rl_amount(v_org, 'profit_loss', 'expenses'), 100::numeric);
  perform pg_temp.check_eq('net profit is gross profit less expenses',
    pg_temp.rl_amount(v_org, 'profit_loss', 'net_profit'), 500::numeric);

  -- The assertion the first draft of 0637 failed. A P&L is the
  -- most-read screen in the product; seeding a layout on read wrote
  -- five rows and woke every colleague's feed.
  select count(*) into v_before from public.report_layouts
   where org_id = v_org;
  perform public.report_with_layout(v_org, 'profit_loss',
    date '2026-01-01', date '2026-12-31');
  perform public.report_with_layout(v_org, 'balance_sheet',
    null, date '2026-12-31');
  select count(*) into v_after from public.report_layouts
   where org_id = v_org;

  perform pg_temp.check_eq('opening a report stores no layout',
    v_before::int, 0);
  perform pg_temp.check_eq('and still none after opening two',
    v_after::int, 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. The accounts under a section, and the ones left out
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Baris Akaun Sdn Bhd');
  v_n   integer;
begin
  select count(*)::int into v_n from public.report_with_layout(
    v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
   where row_key = 'revenue' and line_no > 0;
  perform pg_temp.check_eq('the one revenue account is listed', v_n, 1);

  -- A chart has dozens of expense accounts and this company used one.
  -- Listing the rest at zero is a page nobody reads.
  select count(*)::int into v_n from public.report_with_layout(
    v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
   where row_key = 'expenses' and line_no > 0;
  perform pg_temp.check_eq('only the expense account that moved', v_n, 1);

  -- An account that MOVED and nets to zero. Every account in the
  -- gathered balances has movement behind it, so this is the only
  -- shape that tells "leave out the untouched" apart from "leave out
  -- the zero" -- and a P&L listing a nil account is exactly the noise
  -- the rule exists to stop.
  perform pg_temp.rl_wash(v_org, '6120');
  select count(*)::int into v_n from public.report_with_layout(
    v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
   where row_key = 'expenses' and line_no > 0;
  perform pg_temp.check_eq('an account that nets to zero is left out',
    v_n, 1);
  perform pg_temp.check_eq('and the total is unchanged by it',
    pg_temp.rl_amount(v_org, 'profit_loss', 'expenses'), 100::numeric);

  -- A formula row has no accounts under it, whatever show_accounts
  -- says, because there are no accounts behind an arithmetic result.
  select count(*)::int into v_n from public.report_with_layout(
    v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
   where row_key = 'gross_profit' and line_no > 0;
  perform pg_temp.check_eq('a formula lists nothing', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- 2b. A voided entry is not in the report
--
-- `create_gl_entry` posts outright, so 'posted' looks like the only
-- reachable status until you notice `reverse_gl_entry` writes 'void'.
-- A P&L that counted reversed entries would overstate revenue and
-- balance perfectly while doing it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Entri Dibatalkan Sdn Bhd');
  v_rev uuid;
  v_bank uuid;
  v_entry uuid;
begin
  select id into v_rev from public.accounts
   where org_id = v_org and code = '4000';
  select id into v_bank from public.accounts
   where org_id = v_org and code = '1110';

  v_entry := public.create_gl_entry(
    v_org, date '2026-04-01', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 250, 'credit', 0),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 250)),
    'Jualan tambahan', null, null, null);

  perform pg_temp.check_eq('the extra sale is in the report',
    pg_temp.rl_amount(v_org, 'profit_loss', 'revenue'), 1250::numeric);

  update public.gl_entries set status = 'void' where id = v_entry;

  perform pg_temp.check_eq('and out of it once voided',
    pg_temp.rl_amount(v_org, 'profit_loss', 'revenue'), 1000::numeric);
  perform pg_temp.check_eq('which moves net profit with it',
    pg_temp.rl_amount(v_org, 'profit_loss', 'net_profit'), 500::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 3. The standard rows and a copied layout agree
--
-- The fallback and the builder's starting point must be the same
-- thing, or a company that customises gets a different report before
-- it has changed anything.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Salinan Sama Sdn Bhd');
  v_id  uuid;
  k     app.report_kind;
begin
  foreach k in array array['profit_loss', 'balance_sheet']::app.report_kind[]
  loop
    v_id := public.create_layout_from_builtin(v_org, k);
    perform pg_temp.check_eq(
      format('a copied %s layout has the same rows as the standard one', k),
      (select count(*)::int from public.report_layout_rows
        where layout_id = v_id),
      (select count(*)::int from app.builtin_layout_rows(k)));

    perform pg_temp.check_eq(
      format('and the same keys in the same order for %s', k),
      (select string_agg(row_key, ',' order by sort_order)
         from public.report_layout_rows where layout_id = v_id),
      (select string_agg(row_key, ',' order by sort_order)
         from app.builtin_layout_rows(k)));
  end loop;

  -- And the figures do not move when a company customises nothing.
  perform pg_temp.check_eq('a copied layout produces the same net profit',
    pg_temp.rl_amount(v_org, 'profit_loss', 'net_profit'), 500::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 4. A formula may only look upwards
--
-- The rule that makes a cycle impossible rather than detected.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Rujukan Hadapan Sdn Bhd');
  v_id  uuid := public.create_layout_from_builtin(v_org, 'profit_loss');
begin
  perform pg_temp.check_refused(
    'a formula cannot refer to a row below it',
    format($q$ select public.save_layout_rows(%L::uuid, $j$[
      {"row_key": "total", "kind": "formula",
       "formula": [{"row": "revenue", "sign": 1}]},
      {"row_key": "revenue", "kind": "section",
       "account_types": ["revenue"]}
    ]$j$::jsonb) $q$, v_id),
    '%not above it%', '23514');

  perform pg_temp.check_refused(
    'nor to itself',
    format($q$ select public.save_layout_rows(%L::uuid, $j$[
      {"row_key": "loop", "kind": "formula",
       "formula": [{"row": "loop", "sign": 1}]}
    ]$j$::jsonb) $q$, v_id),
    '%not above it%', '23514');

  perform pg_temp.check_refused(
    'nor to a row that does not exist',
    format($q$ select public.save_layout_rows(%L::uuid, $j$[
      {"row_key": "a", "kind": "section", "account_types": ["revenue"]},
      {"row_key": "b", "kind": "formula",
       "formula": [{"row": "ghost", "sign": 1}]}
    ]$j$::jsonb) $q$, v_id),
    '%not above it%', '23514');

  perform pg_temp.check_refused(
    'two rows cannot share a key',
    format($q$ select public.save_layout_rows(%L::uuid, $j$[
      {"row_key": "a", "kind": "section", "account_types": ["revenue"]},
      {"row_key": "a", "kind": "section", "account_types": ["expense"]}
    ]$j$::jsonb) $q$, v_id),
    '%share the key%', '23514');

  -- Every refusal above left the layout it was given alone.
  --
  -- Note this holds however the two are ordered inside
  -- `save_layout_rows`: a `raise` rolls the whole statement back,
  -- including a delete that ran first. Validating before deleting is
  -- for the reader of the function, not for this assertion, and a
  -- mutant that swaps the order is equivalent rather than uncaught.
  perform pg_temp.check_eq('a refused layout keeps the rows it had',
    (select count(*)::int from public.report_layout_rows
      where layout_id = v_id),
    (select count(*)::int from app.builtin_layout_rows('profit_loss')));

  -- The message, not just the refusal. Dropping the duplicate-key
  -- guard leaves the unique index to refuse it -- correctly, but with
  -- "duplicate key value violates constraint", which tells a person
  -- building a layout nothing about which row to fix.
  perform pg_temp.check_refused(
    'and the duplicate is named, not left to the index',
    format($q$ select public.save_layout_rows(%L::uuid, $j$[
      {"row_key": "a", "kind": "section", "account_types": ["revenue"]},
      {"row_key": "a", "kind": "section", "account_types": ["expense"]}
    ]$j$::jsonb) $q$, v_id),
    'Two rows share the key "a"');
end $$;

-- ---------------------------------------------------------------------
-- 4b. The reader refuses a forward reference too
--
-- `save_layout_rows` catches one before it can ever be stored, so the
-- reader's own guard is unreachable through the RPC -- and a guard
-- nothing can reach is a guard nothing asserts. These rows are written
-- straight into the table, which is what a bad import or a hand-edited
-- row would do.
--
-- It matters that this RAISES rather than reading the missing row as
-- zero: a Net profit line quietly missing Gross profit is a wrong
-- figure on a document somebody signs, and nothing would say so.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Rujukan Terus Sdn Bhd');
  v_id  uuid;
begin
  insert into public.report_layouts (org_id, kind, name, is_active)
  values (v_org, 'profit_loss', 'Ditulis terus', true)
  returning id into v_id;

  insert into public.report_layout_rows
    (org_id, layout_id, row_key, kind, label, sort_order, formula,
     account_types)
  values
    (v_org, v_id, 'total', 'formula', 'Jumlah', 10,
     '[{"row": "revenue", "sign": 1}]'::jsonb, null),
    (v_org, v_id, 'revenue', 'section', 'Revenue', 20, null,
     array['revenue']::app.account_type[]);

  perform pg_temp.check_refused(
    'the reader refuses a forward reference rather than reading zero',
    format($q$ select * from public.report_with_layout(%L::uuid,
             'profit_loss'::app.report_kind, date '2026-01-01',
             date '2026-12-31') $q$, v_org),
    '%not above it%', '23514');
end $$;

-- ---------------------------------------------------------------------
-- 5. A layout somebody actually wants
--
-- An accountant who wants Other income above the operating line, and
-- an EBITDA figure. This is the whole point of the feature, so it is
-- asserted end to end rather than by counting rows.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Susun Atur Sendiri Sdn Bhd');
  v_id  uuid := public.create_layout_from_builtin(v_org, 'profit_loss');
  v_n   integer;
begin
  perform public.save_layout_rows(v_id, $j$[
    {"row_key": "revenue", "kind": "section", "label": "Turnover",
     "account_subtypes": ["sales"]},
    {"row_key": "cos", "kind": "section", "label": "Direct costs",
     "account_subtypes": ["cost_of_sales"]},
    {"row_key": "gp", "kind": "formula", "label": "Gross profit",
     "formula": [{"row": "revenue", "sign": 1}, {"row": "cos", "sign": -1}]},
    {"row_key": "admin", "kind": "section", "label": "Administrative",
     "show_accounts": false,
     "account_subtypes": ["operating_expense", "payroll_expense"]},
    {"row_key": "ebitda", "kind": "formula", "label": "EBITDA",
     "emphasise": true,
     "formula": [{"row": "gp", "sign": 1}, {"row": "admin", "sign": -1}]}
  ]$j$::jsonb);

  perform pg_temp.check_eq('the layout renames revenue',
    (select label from public.report_with_layout(
       v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
      where row_key = 'revenue' and line_no = 0), 'Turnover');
  perform pg_temp.check_eq('EBITDA is computed from two rows above it',
    pg_temp.rl_amount(v_org, 'profit_loss', 'ebitda'), 500::numeric);

  -- `show_accounts: false` is the accountant's one-line block with the
  -- detail in a note. Without this the flag would be a column nothing
  -- reads, which is the defect this whole audit keeps finding.
  select count(*)::int into v_n from public.report_with_layout(
    v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
   where row_key = 'admin' and line_no > 0;
  perform pg_temp.check_eq('a section can show its total only', v_n, 0);

  -- And the block it replaced is gone: the old keys are not lingering.
  select count(*)::int into v_n from public.report_with_layout(
    v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
   where row_key = 'net_profit';
  perform pg_temp.check_eq('the replaced rows are gone', v_n, 0);
end $$;

-- ---------------------------------------------------------------------
-- 6. One active layout, and archiving the active one still reports
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Satu Aktif Sdn Bhd');
  v_a   uuid := public.create_layout_from_builtin(v_org, 'profit_loss', 'A');
  v_b   uuid := public.create_layout_from_builtin(v_org, 'profit_loss', 'B');
begin
  perform pg_temp.check_eq('exactly one layout is active',
    (select count(*)::int from public.report_layouts
      where org_id = v_org and kind = 'profit_loss' and is_active
        and deleted_at is null), 1);
  perform pg_temp.check_eq('and it is the one made last',
    (select id from public.report_layouts
      where org_id = v_org and kind = 'profit_loss' and is_active
        and deleted_at is null), v_b);

  perform public.activate_report_layout(v_a);
  perform pg_temp.check_eq('activating moves it',
    (select id from public.report_layouts
      where org_id = v_org and kind = 'profit_loss' and is_active
        and deleted_at is null), v_a);

  -- The index, not only the functions that respect it.
  perform pg_temp.check_refused(
    'two active layouts cannot be written directly either',
    format('update public.report_layouts set is_active = true where id = %L',
           v_b),
    '%report_layouts_one_active%');

  -- Archiving the active one leaves the company with none, and the
  -- report still draws -- from the standard rows. There is always a
  -- report, whatever somebody deletes.
  perform public.archive_report_layout(v_a);
  perform public.archive_report_layout(v_b);
  perform pg_temp.check_eq('with every layout archived the report still draws',
    pg_temp.rl_amount(v_org, 'profit_loss', 'net_profit'), 500::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 7. A balance sheet ignores the from date rather than honouring it
--
-- A balance sheet "from March" is not a thing. Honouring it would
-- produce a figure that balances and is wrong, which is the worst way
-- to be wrong.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.rl_org('Kunci Kira Kira Sdn Bhd');
  v_all  numeric;
  v_part numeric;
begin
  select amount into v_all from public.report_with_layout(
    v_org, 'balance_sheet', null, date '2026-12-31')
   where row_key = 'assets' and line_no = 0;
  select amount into v_part from public.report_with_layout(
    v_org, 'balance_sheet', date '2026-06-01', date '2026-12-31')
   where row_key = 'assets' and line_no = 0;

  perform pg_temp.check_eq('a from date does not change a balance sheet',
    v_part, v_all);
  -- 1000 in, 400 and 100 out.
  perform pg_temp.check_eq('and the assets are what was banked',
    v_all, 500::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 7b. The project and department filters survive the layout
--
-- `report_profit_loss_by_dimension` has offered these since 0088 and
-- the screen exposes them. A layout-composed P&L that could not filter
-- would be a regression dressed as a feature.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rl_org('Dimensi Sdn Bhd');
  v_rev uuid; v_bank uuid;
begin
  select id into v_rev from public.accounts
   where org_id = v_org and code = '4000';
  select id into v_bank from public.accounts
   where org_id = v_org and code = '1110';

  perform public.create_gl_entry(
    v_org, date '2026-06-01', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 300, 'credit', 0,
                         'project_code', 'P1'),
      jsonb_build_object('account_id', v_rev, 'debit', 0, 'credit', 300,
                         'project_code', 'P1')),
    'Jualan projek', null, null, null);

  perform pg_temp.check_eq('unfiltered, both sales are counted',
    (select amount from public.report_with_layout(
       v_org, 'profit_loss', date '2026-01-01', date '2026-12-31')
      where row_key = 'revenue' and line_no = 0), 1300::numeric);

  perform pg_temp.check_eq('filtered to the project, only its sale',
    (select amount from public.report_with_layout(
       v_org, 'profit_loss', date '2026-01-01', date '2026-12-31',
       null, 'P1')
      where row_key = 'revenue' and line_no = 0), 300::numeric);

  -- And the formula rows follow the filter rather than the whole
  -- company, which is the failure that would look right at a glance.
  perform pg_temp.check_eq('and the formula follows the filter',
    (select amount from public.report_with_layout(
       v_org, 'profit_loss', date '2026-01-01', date '2026-12-31',
       null, 'P1')
      where row_key = 'gross_profit' and line_no = 0), 300::numeric);

  perform pg_temp.check_refused(
    'a balance sheet refuses a dimension rather than ignoring it',
    format($q$ select * from public.report_with_layout(%L::uuid,
             'balance_sheet'::app.report_kind, null, date '2026-12-31',
             null, 'P1') $q$, v_org),
    '%opening balances carry neither%', '0A000');
end $$;

-- ---------------------------------------------------------------------
-- 8. Who may read and write one
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.rl_org('Kebenaran Susun Atur Sdn Bhd');
  v_id    uuid := public.create_layout_from_builtin(v_org, 'profit_loss');
  v_other uuid := pg_temp.another_user('outsider@iakauntan.test');
  v_seen  integer;
  v_role  text;
begin
  perform pg_temp.sign_in_as(v_other);

  perform pg_temp.check_refused(
    'a stranger cannot read the report',
    format($q$ select * from public.report_with_layout(%L::uuid,
             'profit_loss'::app.report_kind) $q$, v_org),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor save rows into a layout',
    format($q$ select public.save_layout_rows(%L::uuid, $j$[
      {"row_key": "a", "kind": "section", "account_types": ["revenue"]}
    ]$j$::jsonb) $q$, v_id),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused(
    'nor archive one',
    format('select public.archive_report_layout(%L::uuid)', v_id),
    '%Insufficient privileges%', '42501');

  -- The RLS policy, under the role it is written for. This file
  -- otherwise runs as the owner of the tables and would pass with the
  -- policy deleted.
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*)::int into v_seen from public.report_layouts
     where org_id = v_org;
  end;
  reset role;
  perform pg_temp.check_true('the read ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('nor see that a layout exists', v_seen, 0);
end $$;

rollback;

\echo 'report_layouts.sql passed'
