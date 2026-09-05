-- =====================================================================
-- iAkauntan :: what a group trial balance adds up, and what it leaves out
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/group_trial_balance_shapes.sql
--
-- `group_reporting.sql` proves the two refusals that matter most -- a
-- company somebody may not read, and two currencies added together --
-- and that the combined report balances. A mutation sweep of
-- `report_group_trial_balance` killed 19 of 40 across it and the POS
-- consolidation.
--
-- What lived was THE ARITHMETIC. Every figure in that report is a
-- `sum()` over one row per company, and the fixture behind it posted a
-- single entry in a single company. So `sum` and `max` return the same
-- number; `count(*)` and `count(distinct code)` return the same number;
-- `min(name)` and `max(name)` return the same name; grouping by code and
-- grouping by code-and-name give the same rows. A report that quietly
-- showed the LARGEST subsidiary's turnover instead of the group's would
-- have passed every assertion in this repository.
--
-- Nor was the period tested. `p_from` and `p_to` were passed through and
-- never varied, so a report that ignored the dates it was handed and
-- totalled everything up to today read exactly the same.
--
-- Two companies in one group, with figures deliberately DIFFERENT so
-- that adding them up is distinguishable from picking one, are what the
-- rest of this file is.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.gtb_org(
  p_name text, p_owner uuid, p_group uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by, group_id)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner, p_group)
  returning id into v;
  perform app.seed_chart_of_accounts(v);
  return v;
end; $$;

-- An account of our own rather than one of the seeded chart's.
--
-- The codes below are picked so that ordering by CODE and ordering by
-- NAME disagree, which is the only way to tell one from the other, and
-- the seeded chart cannot be relied on to disagree about anything.
create or replace function pg_temp.gtb_account(
  p_org uuid, p_code text, p_name text,
  p_type app.account_type, p_subtype app.account_subtype,
  p_opening numeric default 0)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, opening_balance)
  values (p_org, p_code, p_name, p_type, p_subtype, p_opening)
  returning id into v;
  return v;
end; $$;

-- One balanced posted entry, dated.
create or replace function pg_temp.gtb_entry(
  p_org uuid, p_date date, p_debit uuid, p_credit uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (p_org, 'GTB-' || substr(gen_random_uuid()::text, 1, 8), p_date,
          'sales_invoice', 'fixture', p_amount, p_amount, 'posted', now())
  returning id into v_entry;
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, debit, credit)
  values (p_org, v_entry, 1, p_debit,  p_amount, 0),
         (p_org, v_entry, 2, p_credit, 0,        p_amount);
end; $$;

-- The report as a list, in the order it came back in. `with ordinality`
-- rather than `array_agg(... order by ...)`, because re-sorting the rows
-- to check their sort order asserts nothing.
create or replace function pg_temp.gtb_position(p_org uuid, p_code text,
  p_from date, p_to date)
returns integer language sql stable as $$
  select o::integer from public.report_group_trial_balance(p_org, p_from, p_to)
    with ordinality as t(code, name, account_type, account_subtype, companies,
                         opening_balance, debit, credit, closing_balance, o)
   where t.code = p_code;
$$;

do $$
declare
  v_boss     uuid := pg_temp.another_user('boss@gtb.test');
  v_outsider uuid := pg_temp.another_user('outsider@gtb.test');
  v_group uuid; v_a uuid; v_b uuid; v_c uuid; v_alone uuid;
  -- Last month, whole. The report is asked for exactly this window, and
  -- there is money on both sides of both ends of it.
  v_from date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_to   date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_before date := (date_trunc('month', current_date) - interval '2 months')::date;
  v_bank_a uuid; v_bank_b uuid; v_sales_a uuid; v_sales_b uuid;
  v_cf_a uuid; v_cf_b uuid; v_pre uuid; v_pre_contra uuid;
  v_post uuid; v_post_contra uuid;
  v_n integer; v_v numeric; v_name text;
begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan GTB', v_boss) returning id into v_group;

  v_a := pg_temp.gtb_org('GTB A Sdn Bhd', v_boss, v_group);
  v_b := pg_temp.gtb_org('GTB B Sdn Bhd', v_boss, v_group);
  -- In the same group, owned by somebody else. This is what makes the
  -- membership check in the report distinguishable from the one inside
  -- `app.group_orgs`: see the masking pair at the end of this file.
  v_c := pg_temp.gtb_org('GTB C Sdn Bhd', v_outsider, v_group);

  -- The boss's own company, in no group at all.
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('GTB Alone Sdn Bhd', 'gtb-alone-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_boss)
  returning id into v_alone;
  perform app.seed_chart_of_accounts(v_alone);

  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.allow_many_companies();

  -- -----------------------------------------------------------------
  -- The chart, built to disagree with itself
  -- -----------------------------------------------------------------
  -- `Z100` sorts FIRST by code and LAST by name; `Z400` the other way
  -- about. Nothing else in the report can tell `order by code` from
  -- `order by min(name)`.
  v_bank_a := pg_temp.gtb_account(v_a, 'Z100', 'Zed Bank', 'asset', 'bank');
  v_bank_b := pg_temp.gtb_account(v_b, 'Z100', 'Zed Bank', 'asset', 'bank');

  -- And `Z400` is called two different things in the two companies,
  -- which is the only way to tell `min(name)` from `max(name)` -- and
  -- the only way to tell grouping by code from grouping by code AND
  -- name, which would list this account twice.
  --
  -- The opening balances differ too: 100 against 400, so their sum is
  -- not their largest. Revenue carries an opening the other way up,
  -- hence the minus signs in the assertions below.
  v_sales_a := pg_temp.gtb_account(v_a, 'Z400', 'Aardvark Sales',
                                   'revenue', 'sales', 100);
  v_sales_b := pg_temp.gtb_account(v_b, 'Z400', 'Zulu Sales',
                                   'revenue', 'sales', 400);

  -- Two opening balances that CANCEL, on an account with no movement at
  -- all. The group's net position is nought and neither company's is,
  -- and the row still has to be reported: see `having` below.
  v_cf_a := pg_temp.gtb_account(v_a, 'Z500', 'Carried Forward',
                                'asset', 'other_asset', 500);
  v_cf_b := pg_temp.gtb_account(v_b, 'Z500', 'Carried Forward',
                                'asset', 'other_asset', -500);

  -- Money that moved BEFORE the period, and money that moved AFTER it.
  v_pre        := pg_temp.gtb_account(v_a, 'Z600', 'Before', 'asset', 'other_asset');
  v_pre_contra := pg_temp.gtb_account(v_a, 'Z650', 'Before Contra', 'asset', 'other_asset');
  v_post        := pg_temp.gtb_account(v_a, 'Z700', 'After', 'asset', 'other_asset');
  v_post_contra := pg_temp.gtb_account(v_a, 'Z750', 'After Contra', 'asset', 'other_asset');

  -- And an account nothing ever happened to, in both companies.
  perform pg_temp.gtb_account(v_a, 'Z800', 'Never Touched', 'asset', 'other_asset');
  perform pg_temp.gtb_account(v_b, 'Z800', 'Never Touched', 'asset', 'other_asset');

  -- -----------------------------------------------------------------
  -- The entries
  -- -----------------------------------------------------------------
  -- In the period, and unequal between the companies: 700 against 300,
  -- so the sum is 1,000 and the largest is 700.
  perform pg_temp.gtb_entry(v_a, v_from + 3, v_bank_a, v_sales_a, 700);
  perform pg_temp.gtb_entry(v_b, v_from + 3, v_bank_b, v_sales_b, 300);

  -- Before the period: this is an opening balance, not a movement.
  perform pg_temp.gtb_entry(v_a, v_before + 3, v_pre, v_pre_contra, 250);

  -- After the period, and before today: this is not in the report at
  -- all, and would be if the closing date were taken as today.
  perform pg_temp.gtb_entry(v_a, current_date, v_post, v_post_contra, 900);

  -- =================================================================
  -- Adding up, rather than picking one
  -- =================================================================
  select t.companies, t.debit into v_n, v_v
    from public.report_group_trial_balance(v_a, v_from, v_to) t
   where t.code = 'Z100';
  perform pg_temp.check_eq('the bank is one row for two companies', v_n, 2);
  perform pg_temp.check_eq(
    'and its debit is both companies added up, not the larger of them',
    v_v, 1000);

  select t.credit into v_v
    from public.report_group_trial_balance(v_a, v_from, v_to) t
   where t.code = 'Z400';
  perform pg_temp.check_eq(
    'the turnover is both companies added up, not the larger of them',
    v_v, 1000);

  select t.opening_balance into v_v
    from public.report_group_trial_balance(v_a, v_from, v_to) t
   where t.code = 'Z400';
  perform pg_temp.check_eq(
    'and so is what was brought forward: -100 and -400 make -500, not -100',
    v_v, -500);

  perform pg_temp.check_eq('one row per code, however many names it has',
    (select count(*) from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z400'), 1);

  perform pg_temp.check_eq(
    'the companies column counts COMPANIES, not the codes they share',
    (select t.companies from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z400'), 2);

  select t.name into v_name
    from public.report_group_trial_balance(v_a, v_from, v_to) t
   where t.code = 'Z400';
  perform pg_temp.check_eq(
    'where two companies name one code differently, the first one wins '
    'rather than the last -- either would do, but it has to be the same '
    'one every time or the report reorders itself between runs',
    v_name, 'Aardvark Sales');

  -- =================================================================
  -- The order it comes back in
  -- =================================================================
  -- By code. `Z100` is named "Zed Bank" and `Z400` "Aardvark Sales", so
  -- a report ordered by name would put them the other way round.
  perform pg_temp.check_true(
    'the listing is ordered by account code, not by account name',
    pg_temp.gtb_position(v_a, 'Z100', v_from, v_to)
      < pg_temp.gtb_position(v_a, 'Z400', v_from, v_to));

  -- =================================================================
  -- Which rows are there at all
  -- =================================================================
  perform pg_temp.check_eq(
    'an account nothing ever happened to is left out -- a trial balance '
    'of the whole seeded chart is a wall of noughts nobody reads',
    (select count(*) from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z800'), 0);

  perform pg_temp.check_eq(
    'but an account holding a balance brought forward and nothing else '
    'is reported: it is money, and it is somebody''s to explain',
    (select count(*) from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z600'), 1);

  perform pg_temp.check_eq(
    'and so is one where two companies'' brought-forward balances happen '
    'to cancel: +500 and -500 is not the same thing as nothing there',
    (select count(*) from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z500'), 1);
  perform pg_temp.check_eq('though the group''s net position on it is nought',
    (select t.opening_balance from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z500'), 0);

  -- =================================================================
  -- The period it was asked for
  -- =================================================================
  select t.opening_balance, t.debit into v_v, v_n
    from public.report_group_trial_balance(v_a, v_from, v_to) t
   where t.code = 'Z600';
  perform pg_temp.check_eq(
    'money that moved before the period is brought forward as an opening '
    'balance', v_v, 250);
  perform pg_temp.check_eq(
    'and is NOT counted again as movement inside it -- which is what a '
    'report that ignored its start date would do',
    v_n, 0);

  perform pg_temp.check_eq(
    'money that moved after the period is not in the report at all, '
    'however recent it is: a report closing at the month end that '
    'quietly closes today is a different report',
    (select count(*) from public.report_group_trial_balance(v_a, v_from, v_to) t
      where t.code = 'Z700'), 0);
  -- The control. Without it the assertion above is also satisfied by a
  -- report that returns nothing for any date.
  perform pg_temp.check_eq('and is in it when the period is widened to today',
    (select count(*) from public.report_group_trial_balance(v_a, v_from, current_date) t
      where t.code = 'Z700'), 1);

  -- =================================================================
  -- Who may ask
  -- =================================================================
  -- A MUTUALLY-MASKING PAIR, and the reason this is asserted on the
  -- MESSAGE rather than on the refusal. `app.group_orgs` carries its own
  -- `app.is_org_member(p_org_id)`, so deleting the report's check does
  -- not open the books: the group comes back empty and the report
  -- refuses one line later with "this company is not in a group".
  -- Two guards, each hiding the other's absence, and only the wording
  -- tells them apart -- which is an argument for wording them
  -- differently rather than for asserting less.
  perform pg_temp.sign_in_as(v_outsider);
  perform pg_temp.check_refused(
    'somebody in the group but not in that company is told they are not '
    'a member of it -- not that it is not in a group, which is untrue '
    'and sends them to fix the wrong thing',
    format('select count(*) from public.report_group_trial_balance(%L)', v_a),
    '%not a member of this company%');

  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_refused(
    'and a company in no group is refused rather than reported on as a '
    'group of one -- the report''s own name is a promise it cannot keep',
    format('select count(*) from public.report_group_trial_balance(%L)', v_alone),
    '%not in a group%');

  -- =================================================================
  -- What the rounding leans on
  -- =================================================================
  -- `round(sum(...), 2)` in the group report is a no-op and cannot be
  -- shown to be anything else: every figure it adds up has already been
  -- rounded to two places by `report_trial_balance`, and `gl_lines`
  -- holds sen in `numeric(18,2)` besides. So the rule the rounding
  -- depends on is asserted instead of the rounding.
  perform pg_temp.check_eq(
    'every figure the group report adds up arrives already in sen, so '
    'rounding the sum cannot change it',
    (select count(*) from public.report_trial_balance(v_a, v_from, v_to) t
      where scale(t.opening_balance) > 2 or scale(t.debit) > 2
         or scale(t.credit) > 2 or scale(t.closing_balance) > 2), 0);
  perform pg_temp.check_true('and there were figures to check',
    (select count(*) from public.report_trial_balance(v_a, v_from, v_to)) > 0);
end $$;

rollback;
