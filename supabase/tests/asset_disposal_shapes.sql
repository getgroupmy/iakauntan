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
  v_e := public.dispose_fixed_asset(v_win, date '2026-03-31', 9000, null);
  perform pg_temp.check_eq('a gain is the proceeds over the book value',
    pg_temp.ad_code_line(v_e, v_org, '4930'), -3300);

  v_e := public.dispose_fixed_asset(v_lose, date '2026-03-31', 1000, null);
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
    v_e := public.dispose_fixed_asset(v_fa2, date '2026-03-31', 1000, null);
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
    v_j := public.dispose_fixed_asset(v_fa, date '2026-03-31', 1000, null);
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

  v_e := public.dispose_fixed_asset(v_fa, date '2026-06-30', 1500, null);

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
  v_e := public.dispose_fixed_asset(v_fa, date '2026-06-30', 5000, null);
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

rollback;
