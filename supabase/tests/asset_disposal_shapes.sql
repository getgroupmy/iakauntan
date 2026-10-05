-- =====================================================================
-- iAkauntan :: selling an asset, and the note that says so
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/asset_disposal_shapes.sql
--
-- `depreciation_shapes.sql` swept the depreciation RUN. This file is
-- the other half of the module: `dispose_fixed_asset`,
-- `app.disposal_account`, and the two reports an auditor reads --
-- `report_asset_movements`, the fixed asset note, and
-- `report_depreciation_history`, one asset's life.
--
-- A sweep of 68 one-line mutants over those four killed 43. What lived
-- was of three kinds.
--
-- THE ACCOUNT A DISPOSAL CREATES. `app.disposal_account` makes 4930 or
-- 6510 the first time a company sells something, and every existing
-- assertion checked only which account the money landed in. Its TYPE,
-- its SUBTYPE and its PARENT were never looked at, so a loss account
-- filed as revenue under Sales would have passed -- and it does not
-- show up as a wrong number anywhere. It shows up as a profit and loss
-- where the loss on disposal has been added to turnover.
--
-- THE ACCOUNTS AN ASSET CARRIES ITS OWN. Every asset in every existing
-- fixture leaves `asset_account_id`, `accumulated_account_id` and
-- `expense_account_id` null and falls back to 1510/1590/6400. So three
-- `coalesce`s were doing nothing observable, and a company that files
-- its motor vehicles separately from its plant would have had the whole
-- disposal posted to the wrong three accounts.
--
-- AND EVERY BOUNDARY IN THE NOTE. The note has four dates -- bought
-- before the period, bought in it, sold in it, still held at the close
-- -- and eight comparisons implementing them. The existing fixture buys
-- on the first of a month and sells on the last of another, so nothing
-- ever lands ON a boundary and `<` cannot be told from `<=`. Six
-- mutants lived there. An asset sold on the last day of the year is the
-- ordinary case, not a corner one.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ad_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform public.create_fiscal_year(v_org, date '2027-01-01');
  return v_org;
end $$;

create or replace function pg_temp.ad_asset(
  p_org uuid, p_no text, p_name text, p_category text,
  p_bought date, p_cost numeric, p_life integer default 60,
  p_asset_ac uuid default null, p_accum_ac uuid default null,
  p_expense_ac uuid default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months,
     asset_account_id, accumulated_account_id, expense_account_id)
  values (p_org, p_no, p_name, p_category, p_bought, p_cost, 0,
          'straight_line', p_life, p_asset_ac, p_accum_ac, p_expense_ac)
  returning id into v;
  return v;
end $$;

-- What one account was debited and credited by one journal.
create or replace function pg_temp.ad_line(p_entry uuid, p_account uuid)
returns numeric language sql stable as $$
  select coalesce(sum(l.debit) - sum(l.credit), 0)
    from public.gl_lines l
   where l.entry_id = p_entry and l.account_id = p_account;
$$;

create or replace function pg_temp.ad_code_line(
  p_entry uuid, p_org uuid, p_code text)
returns numeric language sql stable as $$
  select coalesce(sum(l.debit) - sum(l.credit), 0)
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = p_entry and a.org_id = p_org and a.code = p_code;
$$;

-- =====================================================================
-- 1. The account a disposal creates
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.ad_org('Disposal Accounts Sdn Bhd');
  v_win uuid; v_lose uuid; v_fa2 uuid; v_e uuid;
  v_gain_ac uuid; v_loss_ac uuid; v_dead uuid;
  v_type text; v_subtype text; v_parent text;
begin
  -- A soft-deleted 6510 already on file. Somebody tidied the chart, and
  -- the disposal now needs the account back.
  --
  -- THIS IS WHERE `0532` CAME FROM. The lookup filtered `deleted_at is
  -- null` and the insert ran into `accounts_org_id_code_key`, which does
  -- not: once a company retired its 6510 it could never record selling
  -- anything at a loss again, and what it got was a constraint
  -- violation. A chart holds one account per code, so the retired one
  -- is revived rather than duplicated.
  -- Retired the way `retire_account` retires: switched OFF as well as
  -- marked deleted. Bringing it back has to undo both, or the account
  -- returns invisible to every screen that lists active accounts.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype,
     is_active, deleted_at)
  values (v_org, '6510', 'Loss on Disposal (retired)',
          'expense', 'other_expense', false, now())
  returning id into v_dead;

  -- Sold for more than it is worth, and sold for less.
  v_win  := pg_temp.ad_asset(v_org, 'FA-W', 'Winner', 'Plant',
                             date '2026-01-01', 6000, 60);
  v_lose := pg_temp.ad_asset(v_org, 'FA-L', 'Loser', 'Plant',
                             date '2026-01-01', 6000, 60);

  -- Three months at 100 a month: net book value 5,700 at 31 March.
  v_e := public.dispose_fixed_asset(v_win, date '2026-03-31', 9000, (select pg_temp.a_bank_account(f.org_id) from public.fixed_assets f where f.id = v_win));
  perform pg_temp.check_eq('a gain is the proceeds over the book value',
    pg_temp.ad_code_line(v_e, v_org, '4930'), -3300);

  v_e := public.dispose_fixed_asset(v_lose, date '2026-03-31', 1000, (select pg_temp.a_bank_account(f.org_id) from public.fixed_assets f where f.id = v_lose));
  perform pg_temp.check_eq('and a loss is the book value over the proceeds',
    pg_temp.ad_code_line(v_e, v_org, '6510'), 4700);

  select id into v_loss_ac from public.accounts
   where org_id = v_org and code = '6510' and deleted_at is null;
  perform pg_temp.check_eq(
    'the retired 6510 is the one that comes back, rather than a second '
    'account with a code the chart says is unique',
    v_loss_ac, v_dead);
  perform pg_temp.check_eq('there is still exactly one 6510',
    (select count(*) from public.accounts
      where org_id = v_org and code = '6510'), 1);
  perform pg_temp.check_eq('and the loss went to it',
    pg_temp.ad_line(v_e, v_loss_ac), 4700);
  perform pg_temp.check_true('with the account no longer deleted',
    (select a.deleted_at is null from public.accounts a
      where a.id = v_loss_ac));
  perform pg_temp.check_true(
    'and switched back on -- an account that comes back deactivated is '
    'one nobody can see, on a chart that now has money in it',
    (select a.is_active from public.accounts a where a.id = v_loss_ac));


  -- WHAT KIND OF ACCOUNT EACH ONE IS. Never asserted before, and
  -- invisible in every figure: a loss on disposal filed as revenue is
  -- added to turnover, and a gain filed under expenses is deducted from
  -- it. Nothing on any screen would show it — the disposal journal
  -- balances either way.
  -- AND THE RULE `app.revive_account` LEANS ON: it is only ever reached
  -- after the live lookup has failed, so its own `deleted_at is not
  -- null` cannot be observed. What is asserted instead is the lookup --
  -- a second disposal finds the account already there and does not go
  -- near the revive.
  declare v_again uuid;
  begin
    v_fa2 := pg_temp.ad_asset(v_org, 'FA-L3', 'Another loser', 'Plant',
                              date '2026-01-01', 6000, 60);
    v_e := public.dispose_fixed_asset(v_fa2, date '2026-03-31', 1000, (select pg_temp.a_bank_account(f.org_id) from public.fixed_assets f where f.id = v_fa2));
    select id into v_again from public.accounts
     where org_id = v_org and code = '6510' and deleted_at is null;
    perform pg_temp.check_eq(
      'a second loss goes to the account already on the chart',
      v_again, v_loss_ac);
    perform pg_temp.check_eq('and there is still only one of it',
      (select count(*) from public.accounts
        where org_id = v_org and code = '6510'), 1);
  end;

  select id into v_gain_ac from public.accounts
   where org_id = v_org and code = '4930' and deleted_at is null;
  select a.account_type::text, a.account_subtype::text,
         (select p.code from public.accounts p where p.id = a.parent_id)
    into v_type, v_subtype, v_parent
    from public.accounts a where a.id = v_gain_ac;
  perform pg_temp.check_eq('a gain on disposal is revenue', v_type, 'revenue');
  perform pg_temp.check_eq('of the other kind', v_subtype, 'other_income');
  perform pg_temp.check_eq('filed under revenue', v_parent, '4000');

  -- And the loss account made from scratch, in a company that never
  -- retired one. The revived account above keeps whatever it was.
  declare
    v_clean uuid := pg_temp.ad_org('Clean Chart Sdn Bhd');
    v_fa uuid; v_j uuid; v_ac uuid;
  begin
    v_fa := pg_temp.ad_asset(v_clean, 'FA-L2', 'Loser', 'Plant',
                             date '2026-01-01', 6000, 60);
    v_j := public.dispose_fixed_asset(v_fa, date '2026-03-31', 1000, (select pg_temp.a_bank_account(f.org_id) from public.fixed_assets f where f.id = v_fa));
    select a.id, a.account_type::text, a.account_subtype::text,
           (select p.code from public.accounts p where p.id = a.parent_id)
      into v_ac, v_type, v_subtype, v_parent
      from public.accounts a
     where a.org_id = v_clean and a.code = '6510' and a.deleted_at is null;
    perform pg_temp.check_eq('a loss on disposal is an expense',
      v_type, 'expense');
    perform pg_temp.check_eq('of the other kind', v_subtype, 'other_expense');
    perform pg_temp.check_eq('filed under expenses, not under sales',
      v_parent, '6000');
  end;
end $$;

-- =====================================================================
-- 2. The accounts an asset carries its own
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.ad_org('Own Accounts Sdn Bhd');
  v_asset_ac uuid; v_accum_ac uuid; v_expense_ac uuid;
  v_bank_a uuid; v_bank_b uuid; v_bank_ac_a uuid; v_bank_ac_b uuid;
  v_fa uuid; v_e uuid;
begin
  -- A company that keeps its motor vehicles apart from its plant, which
  -- is what the three columns on `fixed_assets` are for.
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '1512', 'Motor Vehicles at Cost', 'asset', 'fixed_asset')
  returning id into v_asset_ac;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '1592', 'Motor Vehicles Depreciation', 'asset',
          'accumulated_depreciation')
  returning id into v_accum_ac;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6402', 'Motor Vehicles Depreciation Charge', 'expense',
          'depreciation_expense')
  returning id into v_expense_ac;

  -- Two bank accounts, because one cannot tell "the account named" from
  -- "an account of this company's".
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '1121', 'Maybank', 'asset', 'bank') returning id into v_bank_ac_a;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '1122', 'CIMB', 'asset', 'bank') returning id into v_bank_ac_b;
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_type, currency, account_id)
  values (v_org, 'Maybank current', 'Maybank', '1111', 'current', 'MYR',
          v_bank_ac_a)
  returning id into v_bank_a;
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_type, currency, account_id)
  values (v_org, 'CIMB current', 'CIMB', '2222', 'current', 'MYR', v_bank_ac_b)
  returning id into v_bank_b;

  v_fa := pg_temp.ad_asset(v_org, 'FA-V', 'Van', 'Motor Vehicles',
                           date '2026-01-01', 12000, 60,
                           v_asset_ac, v_accum_ac, v_expense_ac);

  -- Never depreciated by a run, so the whole six months is a catch-up
  -- the disposal has to charge. 200 a month.
  v_e := public.dispose_fixed_asset(v_fa, date '2026-06-30', 11500, v_bank_b);

  perform pg_temp.check_eq(
    'the cost comes off the asset''s OWN account, not the chart''s 1510',
    pg_temp.ad_line(v_e, v_asset_ac), -12000);
  perform pg_temp.check_eq('and 1510 has no line on this journal',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_e and a.org_id = v_org and a.code = '1510'), 0);

  -- Both sides, separately. The catch-up credits this account and the
  -- disposal debits it straight back, so its NET on this journal is
  -- nought whichever account was used -- which is exactly how a
  -- disposal posted to the wrong accumulated account hides.
  perform pg_temp.check_eq(
    'the catch-up credits the asset''s own accumulated account',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
      where l.entry_id = v_e and l.account_id = v_accum_ac), 1200);
  perform pg_temp.check_eq('and the disposal debits it straight back out',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
      where l.entry_id = v_e and l.account_id = v_accum_ac), 1200);
  perform pg_temp.check_eq('1590 has no line on this journal at all',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_e and a.org_id = v_org and a.code = '1590'), 0);

  perform pg_temp.check_eq(
    'the catch-up is charged to the asset''s own expense account',
    pg_temp.ad_line(v_e, v_expense_ac), 1200);
  perform pg_temp.check_eq('and 6400 has no line on this journal',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_e and a.org_id = v_org and a.code = '6400'), 0);

  -- The bank named, not a bank belonging to the company.
  perform pg_temp.check_eq('the money lands in the account it was paid into',
    pg_temp.ad_line(v_e, v_bank_ac_b), 11500);
  perform pg_temp.check_eq('and the other one has no line at all',
    (select count(*) from public.gl_lines l
      where l.entry_id = v_e and l.account_id = v_bank_ac_a), 0);

  -- 12,000 cost, 1,200 written off, sold for 11,500: a gain of 700.
  perform pg_temp.check_eq('and the gain is what is left over',
    pg_temp.ad_code_line(v_e, v_org, '4930'), -700);

  -- What the journal is filed as. A disposal is a depreciation-module
  -- journal, and `refuse_unapproved_posting` lets it through on that
  -- basis: filed as `manual` it would join the approval queue, and an
  -- asset sale would sit unposted waiting for somebody to approve a
  -- journal they did not type.
  perform pg_temp.check_eq('the journal is filed as a depreciation one',
    (select e.source::text from public.gl_entries e where e.id = v_e),
    'depreciation');

  -- And the asset is marked charged up to the day it left, or the next
  -- run would charge the same months again.
  perform pg_temp.check_eq('the asset is depreciated to the day it went',
    (select fa.depreciated_to::text from public.fixed_assets fa
      where fa.id = v_fa), '2026-06-30');
  perform pg_temp.check_eq('carrying the whole charge',
    (select fa.accumulated_depreciation from public.fixed_assets fa
      where fa.id = v_fa), 1200);

  -- And what the disposal deliberately does NOT do, asserted because
  -- `0599` publishes it: the proceeds debit the bank account's LEDGER
  -- account and no statement line is invented to go with them. The
  -- money is in the books and absent from the reconciliation until the
  -- real credit arrives from the bank, which is right -- a disposal is
  -- not evidence that anybody has paid.
  --
  -- A future migration that had the disposal write its own
  -- `bank_transactions` row would make that description false AND
  -- double the money at reconciliation, matching the invented line
  -- against the real one. Nothing else would say so.
  perform pg_temp.check_eq(
    'no statement line is invented for the proceeds',
    (select count(*) from public.bank_transactions bt
      where bt.bank_account_id = v_bank_b), 0);
  perform pg_temp.check_eq('nor for any other account of this company',
    (select count(*) from public.bank_transactions bt
      join public.bank_accounts ba on ba.id = bt.bank_account_id
     where ba.org_id = v_org), 0);
end $$;

-- =====================================================================
-- 3. The note, on its boundaries
-- =====================================================================
--
-- The period is the quarter to 30 June 2026, and every asset below is
-- placed ON one of its two ends rather than safely inside it.
do $$
declare
  v_org uuid := pg_temp.ad_org('Note Boundaries Sdn Bhd');
  v_from date := date '2026-04-01';
  v_to   date := date '2026-06-30';
  v_open uuid; v_close uuid; v_out_first uuid; v_out_last uuid;
  v_gone uuid; v_later uuid; v_blank uuid; v_e uuid; v_n numeric;
begin
  -- Bought on the last day of the period. Held at the close, and an
  -- addition of the period.
  v_close := pg_temp.ad_asset(v_org, 'FA-C', 'Bought on the last day',
                              'Boundary', v_to, 1000, 60);
  -- Sold on the last day of the period. NOT held at the close, and a
  -- disposal of the period.
  v_out_last := pg_temp.ad_asset(v_org, 'FA-X', 'Sold on the last day',
                                 'Boundary', date '2026-01-01', 2000, 60);
  -- Sold on the FIRST day of the period. It was on the books when the
  -- period opened -- a company that owns something in the morning owns
  -- it at the start of the day.
  v_out_first := pg_temp.ad_asset(v_org, 'FA-F', 'Sold on the first day',
                                  'Boundary', date '2026-01-01', 3000, 60);
  -- Deleted from the register.
  v_gone := pg_temp.ad_asset(v_org, 'FA-D', 'Deleted', 'Boundary',
                             date '2026-01-01', 9000, 60);
  -- Bought after the period closed, and in a category of its own: under
  -- 'Boundary' it would contribute nothing to any column and be
  -- invisible. On its own it is a row of noughts on a note, which is
  -- what an asset the company did not own yet looks like.
  v_later := pg_temp.ad_asset(v_org, 'FA-N', 'Bought later', 'Not Yet',
                              date '2026-07-15', 8000, 60);
  -- And one whose category is two spaces, which is not a category.
  v_blank := pg_temp.ad_asset(v_org, 'FA-B', 'Untidy', '   ',
                              date '2026-01-01', 500, 60);

  v_e := public.dispose_fixed_asset(v_out_last, v_to, 0, null);
  v_e := public.dispose_fixed_asset(v_out_first, v_from, 0, null);
  update public.fixed_assets set deleted_at = now() where id = v_gone;

  -- A charge dated exactly on the first day of the period. It belongs
  -- to the period, not to what was brought forward into it.
  v_e := public.run_depreciation(v_org, v_from);

  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'an asset bought on the last day of the period is held at the close',
    (select m.assets from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'
        and m.cost_closing > 0), 1);
  perform pg_temp.check_eq('and its cost is carried forward',
    (select m.cost_closing from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'), 1000);
  perform pg_temp.check_eq('as an addition of the period',
    (select m.additions from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'), 1000);

  perform pg_temp.check_eq(
    'an asset sold on the last day is a disposal of the period, and is '
    'NOT carried forward: 2,000 out and 3,000 out',
    (select m.disposals_cost from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'), 5000);

  perform pg_temp.check_eq(
    'and an asset sold on the FIRST day was on the books when the '
    'period opened -- 2,000 and 3,000 brought forward, 9,000 deleted '
    'and 8,000 not yet bought',
    (select m.cost_opening from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'), 5000);

  -- Which also says the deleted asset is off the note, because its
  -- 9,000 would have shown up above.
  perform pg_temp.check_eq('one row for the category, not one per asset',
    (select count(*) from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'), 1);

  perform pg_temp.check_eq(
    'an asset the company did not own yet has no row on the note -- '
    'a category of noughts reads as a category with nothing in it, '
    'which is not the same as one that is not there',
    (select count(*) from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Not Yet'), 0);
  -- The control: it IS on the note once the period reaches it.
  perform pg_temp.check_eq('and has one once the period reaches it',
    (select m.additions from public.report_asset_movements(
       v_org, v_from, date '2026-07-31') m where m.category = 'Not Yet'),
    8000);

  -- A category of whitespace is no category.
  perform pg_temp.check_eq('an asset filed under nothing is Uncategorised',
    (select m.cost_closing from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Uncategorised'), 500);

  -- The charge on the first day is the period's, not the opening's.
  select m.accum_opening, m.charge
    into v_n, v_n
    from public.report_asset_movements(v_org, v_from, v_to) m
   where m.category = 'Boundary';
  perform pg_temp.check_eq(
    'a charge dated on the first day of the period is IN the period, '
    'not in what was brought into it',
    (select m.accum_opening from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary'), 0);
  perform pg_temp.check_true('and there was a charge to place',
    (select m.charge from public.report_asset_movements(v_org, v_from, v_to) m
      where m.category = 'Boundary') > 0);
end $$;

-- =====================================================================
-- 4. What left with the asset
-- =====================================================================
--
-- The note reports a disposal's accumulated depreciation from the FIGURE
-- FROZEN ON THE ASSET by the disposal, not by re-reading the entries.
-- The two agree for an asset this system depreciated from new. They do
-- not agree for an asset that arrived carrying a balance, and that is
-- the case worth pinning -- see docs/unreachable.md.
do $$
declare
  v_org uuid := pg_temp.ad_org('Brought In Sdn Bhd');
  v_fa uuid; v_e uuid;
begin
  -- Bought two years ago and already three-fifths written down when it
  -- was keyed in. Nothing in this system charged that 3,000.
  v_fa := pg_temp.ad_asset(v_org, 'FA-I', 'Imported', 'Plant',
                           date '2024-01-01', 5000, 60);
  update public.fixed_assets
     set accumulated_depreciation = 3000, depreciated_to = date '2026-03-31'
   where id = v_fa;

  v_e := public.dispose_fixed_asset(v_fa, date '2026-06-30', 1500, (select pg_temp.a_bank_account(f.org_id) from public.fixed_assets f where f.id = v_fa));

  perform pg_temp.check_eq(
    'what left with the asset is what the asset said it had, not what '
    'this system happens to have charged it',
    (select m.disposals_accum from public.report_asset_movements(
       v_org, date '2026-04-01', date '2026-06-30') m
      where m.category = 'Plant'), 3000);

  -- AND THE RULE `greatest(..., 0)` LEANS ON. Thirty months at 5,000
  -- over sixty is 2,500, and the row already says 3,000: the formula
  -- has less to say than the register does, so the catch-up is
  -- NEGATIVE before it is floored. Dropping the floor changes nothing,
  -- because `v_catchup` is only ever read as `> 0` -- so what is
  -- asserted is that reading: nothing is charged, and no run is
  -- written.
  perform pg_temp.check_eq(
    'an asset already written down further than the formula says is '
    'not charged a negative catch-up on the way out',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_e and a.org_id = v_org and a.code = '6400'), 0);
  perform pg_temp.check_eq('and leaves no depreciation run behind it',
    (select count(*) from public.depreciation_runs r
      where r.org_id = v_org), 0);
  perform pg_temp.check_eq('while keeping the 3,000 it arrived with',
    (select fa.accumulated_depreciation from public.fixed_assets fa
      where fa.id = v_fa), 3000);
end $$;

-- =====================================================================
-- 5. One asset's life
-- =====================================================================
do $$
declare
  v_org   uuid := pg_temp.ad_org('History Sdn Bhd');
  v_other uuid;
  v_fa uuid; v_gone uuid; v_e uuid; v_run uuid;
  v_stranger uuid; v_first text; v_source text;
begin
  v_other := pg_temp.ad_org('Somebody Else Sdn Bhd');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  v_fa   := pg_temp.ad_asset(v_org, 'FA-H', 'Press', 'Plant',
                             date '2026-01-01', 12000, 60);
  v_gone := pg_temp.ad_asset(v_org, 'FA-G', 'Deleted press', 'Plant',
                             date '2026-01-01', 12000, 60);

  -- Two runs, the FIRST of which charges more than the second: three
  -- months at 200 against one. So ordering by date and ordering by
  -- amount disagree, which is the only way to tell them apart.
  v_e := public.run_depreciation(v_org, date '2026-03-31');
  v_e := public.run_depreciation(v_org, date '2026-04-30');

  select h.source into v_first
    from public.report_depreciation_history(v_org, v_fa) h limit 1;
  perform pg_temp.check_eq('the history opens with the earliest run',
    (select h.charge from public.report_depreciation_history(v_org, v_fa) h
     limit 1), 600);

  -- A run with no journal behind it, on an asset that has not been
  -- disposed of. Both are null, and `is not distinct from` would call
  -- this a disposal.
  insert into public.depreciation_runs
    (org_id, run_date, gl_entry_id, total_amount, posted_by)
  values (v_org, date '2026-05-31', null, 200, pg_temp.test_user())
  returning id into v_run;
  insert into public.depreciation_entries
    (org_id, run_id, asset_id, amount, opening_accumulated, closing_accumulated)
  values (v_org, v_run, v_fa, 200, 800, 1000);

  select h.source into v_source
    from public.report_depreciation_history(v_org, v_fa) h
   where h.run_date = date '2026-05-31';
  perform pg_temp.check_eq(
    'a run carrying no journal is a depreciation run, not a disposal -- '
    'two nulls are not a match',
    v_source, 'Depreciation run');

  -- And the real thing, so the label is not simply never used.
  v_e := public.dispose_fixed_asset(v_fa, date '2026-06-30', 5000, (select pg_temp.a_bank_account(f.org_id) from public.fixed_assets f where f.id = v_fa));
  select h.source into v_source
    from public.report_depreciation_history(v_org, v_fa) h
   where h.run_date = date '2026-06-30';
  perform pg_temp.check_eq('while the disposal''s own charge says so',
    v_source, 'Disposal');

  -- An asset deleted from the register has no history to show.
  update public.fixed_assets set deleted_at = now() where id = v_gone;
  perform pg_temp.check_eq('a deleted asset has no history',
    (select count(*) from public.report_depreciation_history(v_org, v_gone)), 0);

  -- Somebody else's asset, asked for under a company this person can
  -- read. The org is the only thing standing between them.
  perform pg_temp.check_eq(
    'and asking under your own company does not open somebody else''s '
    'asset',
    (select count(*) from public.report_depreciation_history(v_other, v_fa)), 0);

  -- The ledger check itself. Asserted on the message, because a
  -- stranger is refused by RLS in several places and only this one
  -- names the ledger.
  v_stranger := pg_temp.another_user('stranger@assets.test');
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_refused(
    'somebody with no reason to be in this company cannot read an '
    'asset''s history',
    format('select count(*) from public.report_depreciation_history(%L, %L)',
           v_org, v_fa),
    '%privileges to read the ledger%');
  perform pg_temp.check_refused('nor the fixed asset note',
    format('select count(*) from public.report_asset_movements(%L)', v_org),
    '%privileges to read the ledger%');
end $$;

-- ---------------------------------------------------------------------
-- The thirteen a SECOND sweep found, including two of 0729's own fixes
--
-- The sweep in this file's header mutated the note and the accounts.
-- This one mutated `dispose_fixed_asset` itself -- 37 mutants across
-- the four files that reach it -- and 24 died. The thirteen that lived
-- divide cleanly, and the first group is the one that matters.
--
-- **TWO OF THEM ARE RULES `0729` ADDED AND NOTHING EVER TESTED.** That
-- migration's own comment says it: proceeds that named no account used
-- to be debited to the 1120 heading, and `and b.org_id = a.org_id` on
-- the bank lookup "is new and is a cross-tenant fix, not tidying,
-- because p_bank_account_id is an ARGUMENT, so none of 0160's composite
-- foreign keys cover it". Both were shipped and neither was asserted.
-- `money_names_the_account.sql` names this function in a comment and in
-- a static sweep of function BODIES, and never calls it.
--
-- The rest: the two guards at the top (who may, and not twice), both
-- sides of the acquisition-date boundary, the catch-up floor, the
-- cents, three `> 0` conditions whose `>= 0` form posts a leg of two
-- zeroes, the missing-chart refusal, the link back to the asset, and
-- the depreciation run's own figure.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_other  uuid;
  v_bank   uuid; v_bank_ac uuid; v_their_bank uuid;
  v_a      uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;
  v_entry  uuid; v_msg text;
  v_1510   uuid; v_1590 uuid;
  v_runs   integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.ad_org('Alat Lupus Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_bank    := pg_temp.test_bank_account(v_org, 'Maybank current');
  v_bank_ac := pg_temp.bank_gl(v_bank);
  select id into v_1510 from public.accounts
   where org_id = v_org and code = '1510';
  select id into v_1590 from public.accounts
   where org_id = v_org and code = '1590';

  -- ------------------------------------------------------------------
  -- 1. PROCEEDS THAT NAME NO ACCOUNT -- 0729's first fix
  -- ------------------------------------------------------------------
  -- Before 0729 this debited 1120 Bank Accounts, the heading the real
  -- accounts hang under: the asset read as sold, the gain was right,
  -- the journal balanced, and no bank balance moved and no
  -- reconciliation could ever match it.
  v_a := pg_temp.ad_asset(v_org, 'FA-NOBANK', 'Lathe', 'plant',
                          date '2026-01-01', 12000);
  perform pg_temp.check_refused(
    'proceeds have to be received into a named account',
    format('select public.dispose_fixed_asset(%L, %L, 5000, null)',
           v_a, date '2026-06-30'),
    'Say which account the FA-NOBANK proceeds were received into. Without '
    'one there is nothing for a reconciliation to match.', '23514');
  perform pg_temp.check_eq('and the asset is still in service',
    (select status::text from public.fixed_assets where id = v_a),
    'active');

  -- But a disposal for NOTHING adds no cash leg and needs no account,
  -- which is the other side of the same `> 0`. Scrapping a worn-out
  -- machine is the commonest disposal there is.
  v_b := pg_temp.ad_asset(v_org, 'FA-SCRAP', 'Old press', 'plant',
                          date '2026-01-01', 6000);
  v_entry := public.dispose_fixed_asset(v_b, date '2026-06-30', 0, null);
  perform pg_temp.check_true('an asset scrapped for nothing needs no account',
    v_entry is not null);
  perform pg_temp.check_eq('and no leg touches any bank account',
    (select count(*) from public.gl_lines l
       join public.bank_accounts ba on ba.account_id = l.account_id
      where l.entry_id = v_entry), 0);

  -- ------------------------------------------------------------------
  -- 2. ANOTHER COMPANY'S BANK ACCOUNT -- 0729's second fix
  -- ------------------------------------------------------------------
  -- The reach an ARGUMENT has that a composite foreign key cannot see.
  -- Without the check, the proceeds are debited to THEIR ledger account
  -- inside THIS company's journal.
  v_other := pg_temp.ad_org('Syarikat Seberang Lupus Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_their_bank := pg_temp.test_bank_account(v_other, 'Their account');
  perform pg_temp.sign_in_as(v_owner);
  v_c := pg_temp.ad_asset(v_org, 'FA-THEIRS', 'Van', 'motor_vehicle',
                          date '2026-01-01', 30000);
  perform pg_temp.check_refused(
    'the proceeds cannot be banked into another company''s account',
    format('select public.dispose_fixed_asset(%L, %L, 9000, %L)',
           v_c, date '2026-06-30', v_their_bank),
    'That bank account is not this company''s.', '42501');
  perform pg_temp.check_eq('and nothing reached their ledger',
    (select count(*) from public.gl_lines l
      where l.account_id = (select account_id from public.bank_accounts
                             where id = v_their_bank)), 0);

  -- ------------------------------------------------------------------
  -- 3. WHO MAY, AND NOT TWICE
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-lupus@iakauntan.test'));
  begin
    perform public.dispose_fixed_asset(v_c, date '2026-06-30', 0, null);
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.sign_in_as(v_owner);
  -- The WHOLE message: three other refusals in this function are 42501
  -- or 23514 and say different things.
  perform pg_temp.check_eq('somebody who may not post cannot dispose',
    v_msg, 'Insufficient privileges to post');
  perform pg_temp.check_eq('and the van is still in service',
    (select status::text from public.fixed_assets where id = v_c),
    'active');

  perform public.dispose_fixed_asset(v_c, date '2026-06-30', 9000, v_bank);
  perform pg_temp.check_refused(
    'an asset is disposed of once',
    format('select public.dispose_fixed_asset(%L, %L, 1, %L)',
           v_c, date '2026-07-31', v_bank),
    'Asset FA-THEIRS has already been disposed of', '23514');

  -- ------------------------------------------------------------------
  -- 4. BOTH SIDES OF THE ACQUISITION-DATE BOUNDARY
  -- ------------------------------------------------------------------
  -- `p_date < a.acquisition_date`. An asset bought and sold on the SAME
  -- day is a real thing -- a machine delivered wrong and returned the
  -- same afternoon -- and it is the first date that is allowed.
  v_b := pg_temp.ad_asset(v_org, 'FA-SAMEDAY', 'Wrong press', 'plant',
                          date '2026-03-15', 4000);
  perform pg_temp.check_true(
    'an asset can be disposed of on the very day it was acquired',
    public.dispose_fixed_asset(v_b, date '2026-03-15', 4000, v_bank)
      is not null);
  v_e := pg_temp.ad_asset(v_org, 'FA-EARLY', 'Not yet ours', 'plant',
                          date '2026-03-15', 4000);
  perform pg_temp.check_refused(
    'but not on the day before it',
    format('select public.dispose_fixed_asset(%L, %L, 0, null)',
           v_e, date '2026-03-14'),
    'Asset FA-EARLY was acquired on 2026-03-15, after the disposal '
    'date 2026-03-14', '23514');

  -- ------------------------------------------------------------------
  -- 5. THE THREE `> 0` LEGS, WHICH BALANCE AT ZERO
  -- ------------------------------------------------------------------
  -- LAND, which is never depreciated. `app.accumulated_depreciation_at`
  -- returns 0 when `cost - residual_value <= 0`, so a plot carried at
  -- its residual value has NO accumulated charge and NO catch-up; sold
  -- at exactly what it cost, it has no gain or loss either. All three
  -- of the function's `> 0` legs are absent at once, and the journal is
  -- two lines: the cash in and the asset out.
  --
  -- The first version of this used an asset bought and sold on the SAME
  -- DAY and expected two lines. It got six: `app.months_held` counts
  -- the month of acquisition as a whole month -- which is the Malaysian
  -- convention and right -- so a same-day disposal accumulates one
  -- month's charge, posts a catch-up, and strikes a gain of exactly
  -- that. A fixture built to make three things zero made none of them.
  insert into public.fixed_assets
    (org_id, asset_no, name, category, acquisition_date, cost,
     residual_value, method, useful_life_months)
  values (v_org, 'FA-LAND', 'Plot in Rawang', 'land',
          date '2026-01-01', 80000, 80000, 'straight_line', 60)
  returning id into v_d;
  v_entry := public.dispose_fixed_asset(v_d, date '2026-06-30', 80000, v_bank);

  perform pg_temp.check_eq(
    'land sold at cost is exactly two lines, and no leg of two zeroes',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);
  perform pg_temp.check_eq('the cash in',
    (select debit from public.gl_lines
      where entry_id = v_entry and account_id = v_bank_ac), 80000);
  perform pg_temp.check_eq('and the asset out, at cost',
    (select credit from public.gl_lines
      where entry_id = v_entry and account_id = v_1510), 80000);
  perform pg_temp.check_eq(
    'with nothing at all on accumulated depreciation',
    (select count(*) from public.gl_lines
      where entry_id = v_entry and account_id = v_1590), 0);
  perform pg_temp.check_eq('nor on gain or loss on disposal',
    (select count(*) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code in ('4930', '6510')), 0);
  -- And no depreciation run was recorded for a catch-up of nothing.
  perform pg_temp.check_eq('and no depreciation run for a charge of nothing',
    (select count(*) from public.depreciation_runs
      where gl_entry_id = v_entry), 0);

  -- ------------------------------------------------------------------
  -- 6. THE CENTS, AND THE CATCH-UP's OWN FIGURE
  -- ------------------------------------------------------------------
  -- Every disposal in this suite is a round thousand, so
  -- `round(proceeds - nbv, 2)` had no cents to lose. And the
  -- depreciation RUN the catch-up writes carries `v_catchup`, the
  -- months since the last run -- not `v_accum`, the whole charge since
  -- the asset was bought. With one run and no history those are the
  -- same number; with a prior run they are not.
  v_a := pg_temp.ad_asset(v_org, 'FA-SEN', 'Server', 'computer',
                          date '2026-01-01', 11111.11, 60);
  -- Three months of charge posted the ordinary way first, so the
  -- catch-up has something to be measured FROM.
  perform public.run_depreciation(v_org, date '2026-03-31');
  v_entry := public.dispose_fixed_asset(v_a, date '2026-06-30', 9999.99, v_bank);
  -- Cost 11111.11 over 60 months is 185.19 a month; six months of that
  -- against proceeds of 9999.99 cannot come out in whole ringgit. The
  -- figure is not written here because the point is not the figure --
  -- it is that `round(..., 2)` and `round(..., 0)` differ, which they
  -- cannot for any disposal in the rest of this suite.
  perform pg_temp.check_true('the gain or loss keeps its sen',
    (select round(sum(l.debit - l.credit), 2) <> round(sum(l.debit - l.credit), 0)
       from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code in ('4930', '6510')));

  -- The run the disposal wrote carries THREE months, not six: the
  -- quarter already posted is not the disposal's to charge again.
  perform pg_temp.check_eq(
    'the disposal''s own run charges only the months since the last one',
    (select r.total_amount from public.depreciation_runs r
      where r.gl_entry_id = v_entry),
    (select sum(l.debit) from public.gl_lines l
       join public.accounts ac on ac.id = l.account_id
      where l.entry_id = v_entry and ac.code = '6400'));
  perform pg_temp.check_true(
    'which is LESS than everything the asset ever accumulated',
    (select r.total_amount from public.depreciation_runs r
      where r.gl_entry_id = v_entry)
    < (select accumulated_depreciation from public.fixed_assets where id = v_a));

  -- ------------------------------------------------------------------
  -- 7. THE LINK BACK TO THE ASSET
  -- ------------------------------------------------------------------
  -- `report_depreciation_history` and the fixed asset note both find a
  -- disposal by its source. Without it the journal is in the ledger and
  -- belongs to nothing.
  perform pg_temp.check_eq('the disposal journal names the asset it sold',
    (select source_id from public.gl_entries where id = v_entry), v_a);
  perform pg_temp.check_eq('in the table that asset lives in',
    (select source_table from public.gl_entries where id = v_entry),
    'fixed_assets');

  -- ------------------------------------------------------------------
  -- 8. A CHART WITH NO 1510 OR 1590
  -- ------------------------------------------------------------------
  -- Refused in words rather than posted somewhere arbitrary. A company
  -- that has renamed its chart is the case, and the refusal names both
  -- codes because either can be the missing one.
  -- A company of its own, because the account has to be really GONE
  -- and this one has posted to 1590 several times above.
  --
  -- SOFT-DELETING IT IS NOT ENOUGH, AND THAT IS A FINDING RATHER THAN A
  -- FIXTURE DETAIL. The fallback is
  -- `(select id from public.accounts where org_id = ... and code =
  -- '1590')` with NO `deleted_at is null`, so an account somebody
  -- retired is still found and still posted to. `app.cheque_account`
  -- filters on `deleted_at is null` and then REVIVES the row rather
  -- than posting to a retired one, which is the shape `0532`
  -- established; these three fallbacks (1510, 1590, 6400) do not. The
  -- first version of this assertion soft-deleted 1590 and was not
  -- refused at all, which is how the difference was found. Recorded in
  -- docs/handoff.md; not changed here, because what a disposal posts to
  -- is not a test's decision to make.
  v_other := pg_temp.ad_org('Carta Kurang Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_b := pg_temp.ad_asset(v_other, 'FA-NOCHART', 'Press', 'plant',
                          date '2026-01-01', 5000);
  delete from public.accounts where org_id = v_other and code = '1590';
  perform pg_temp.check_refused(
    'a chart with no accumulated depreciation account refuses the disposal',
    format('select public.dispose_fixed_asset(%L, %L, 0, null)',
           v_b, date '2026-06-30'),
    'No fixed asset (1510) or accumulated depreciation (1590) account in '
    'the chart. Add them, or name accounts on the asset.', 'P0002');

  raise notice 'ok   disposal: 0729''s two fixes, the boundary, the sen and the zero legs';
end $$;


rollback;
