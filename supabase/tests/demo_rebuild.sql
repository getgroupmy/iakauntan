-- =====================================================================
-- iAkauntan :: rebuilding the demo tenants
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_rebuild.sql
--
-- `app.demo_rebuild()` deletes and recreates every demo company. Two
-- things have to hold every time it runs, and only one of them is
-- obvious.
--
-- The obvious one: the tenants come back complete. A demo company that
-- is missing its tax codes or its fiscal calendar is the half-built
-- tenant this project already found one of — it cannot post, and the
-- screens open empty.
--
-- The one worth writing down: **the roles are the ones the sign-in page
-- advertises.** `demo_accounts.dart` offers `auditor@` as "Reads the
-- ledger, writes nothing". The seeded data made it an `admin`. Nothing
-- would ever have caught that except an assertion that reads the
-- promise and checks the database against it, so that is what this is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_report  text;
  v_orgs    integer;
  v_users   integer;
  v_modules integer;
  v_role    text;
  v_sinar   uuid;
  v_amanah  uuid;
  v_harta   uuid;
  v_warung  uuid;
  v_salon   uuid;
  v_stall   uuid;
  v_entities integer;
  v_units   integer;
  v_bank    numeric;
  v_gl      numeric;
  v_bad     integer;
  v_missing text;
begin
  v_report := app.demo_rebuild();
  raise notice 'rebuild said: %', v_report;

  select count(*) into v_orgs  from public.organizations where is_demo;
  select count(*) into v_users from auth.users
   where raw_app_meta_data ->> 'demo' = 'true';

  -- Seven tenants plus the practice's four: the firm's own books and
  -- its three client companies. 0485 builds them in the same call,
  -- because the teardown at the top of this function takes every
  -- `is_demo` company and used to leave those four deleted.
  perform pg_temp.check_eq('eleven demo companies', v_orgs, 11);
  perform pg_temp.check_eq('fourteen demo logins', v_users, 14);

  -- The office holds two people. `invite_firm_member` was broken from
  -- 0450 to 0483, so until then it could only ever hold one.
  perform pg_temp.check_eq('the practice has two people in it',
    (select count(*)::integer from public.firm_members m
       join auth.users u on u.id = m.user_id
      where u.email in ('accountant@iakauntan.com', 'audit@iakauntan.com')
        and m.status = 'active'), 2);
  perform pg_temp.check_eq('and the manager sees the whole portfolio',
    (select count(*)::integer from public.org_members m
       join auth.users u on u.id = m.user_id
      where u.email = 'audit@iakauntan.com'), 4);

  -- --------------------------------------------------------------
  -- The promise on the sign-in page
  -- --------------------------------------------------------------
  select m.role::text into v_role
    from public.org_members m join auth.users u on u.id = m.user_id
   where u.email = 'auditor@iakauntan.com';
  perform pg_temp.check_true(
    'auditor@ is an auditor, which is what the picker says it is — it '
    'used to be an admin of the demo company', v_role = 'auditor');

  select m.role::text into v_role
    from public.org_members m join auth.users u on u.id = m.user_id
   where u.email = 'clerk@iakauntan.com';
  perform pg_temp.check_true(
    'clerk@ is an accounts clerk rather than a purchaser',
    v_role = 'accounts_clerk');

  -- --------------------------------------------------------------
  -- Complete tenants, not shells
  -- --------------------------------------------------------------
  select id into v_sinar from public.organizations
   where name = 'Sinar Teknologi Sdn Bhd';
  perform pg_temp.check_true('Sinar exists', v_sinar is not null);

  select string_agg(t, ', ') into v_missing from (
    select 'accounts'      as t where not exists (select 1 from public.accounts       where org_id = v_sinar)
    union all select 'tax_codes'      where not exists (select 1 from public.tax_codes      where org_id = v_sinar)
    union all select 'payment_terms'  where not exists (select 1 from public.payment_terms  where org_id = v_sinar)
    union all select 'warehouses'     where not exists (select 1 from public.warehouses     where org_id = v_sinar)
    union all select 'price_levels'   where not exists (select 1 from public.price_levels   where org_id = v_sinar)
    union all select 'pipeline_stages' where not exists (select 1 from public.pipeline_stages where org_id = v_sinar)
    -- The one the half-built tenant was missing, and the one that stops
    -- a company posting anything at all.
    union all select 'fiscal_years'   where not exists (select 1 from public.fiscal_years   where org_id = v_sinar)
  ) s;
  perform pg_temp.check_true(
    'a demo company is fully set up, not a shell: ' ||
    coalesce(v_missing, 'nothing missing'), v_missing is null);

  -- --------------------------------------------------------------
  -- The dining room is furnished, and in service
  -- --------------------------------------------------------------
  -- A demo whose floor plan shows eight free tables demonstrates a
  -- floor plan. The point of the warung is that service is under way,
  -- so what is asserted is the parties seated and the food ordered
  -- rather than the furniture.
  select id into v_warung from public.organizations
   where name = 'Warung Sedap Enterprise';
  perform pg_temp.check_true('the warung exists', v_warung is not null);
  perform pg_temp.check_true('with tables in more than one area',
    (select count(distinct t.area_id) from public.pos_tables t
      where t.org_id = v_warung) > 1);
  perform pg_temp.check_true('a kiosk among its tills',
    exists (select 1 from public.pos_registers r
             where r.org_id = v_warung and r.is_kiosk));
  perform pg_temp.check_true('parties actually seated',
    (select count(*) from public.pos_sales s
      where s.org_id = v_warung and s.status = 'parked'
        and s.table_id is not null) >= 2);
  perform pg_temp.check_true('with their order in the kitchen',
    exists (select 1 from public.pos_kitchen_tickets k where k.org_id = v_warung));
  perform pg_temp.check_true('and something already settled, so the day is not zero',
    exists (select 1 from public.pos_sales s
             where s.org_id = v_warung and s.status = 'completed'));

  -- --------------------------------------------------------------
  -- Every POS business type has somewhere to be looked at
  -- --------------------------------------------------------------
  --
  -- The gate this section exists to be: `app.pos_business_type` has
  -- five values, and a module sold on running five kinds of shop that
  -- can only be shown running three is a module whose demo argues
  -- against its own pitch. Counted rather than listed, so adding a
  -- sixth business type fails here until it has a tenant.
  perform pg_temp.check_eq(
    'every POS business type has a demo outlet',
    (select count(distinct o.business_type)
       from public.pos_outlets o
       join public.organizations g on g.id = o.org_id
      where g.is_demo),
    (select count(*) from unnest(enum_range(null::app.pos_business_type)) e
      -- kiosk is a register flag rather than a shop of its own; the
      -- warung's screen by the door is where it is demonstrated, and
      -- the assertion below is the one that covers it.
      where e::text <> 'kiosk'));

  -- --------------------------------------------------------------
  -- The dining room has somebody sitting in it
  -- --------------------------------------------------------------
  --
  -- `pos_floor_plan` derives occupancy from a parked sale pointing at a
  -- table, so a seed that opened its bills with `open_pos_sale` rather
  -- than `seat_table` would leave a room of empty tables -- and the
  -- floor plan is the one screen the food_beverage tenant exists to
  -- demonstrate. The same null would empty the `table_name` column
  -- `pos_open_orders` puts on every row.
  --
  -- Counted against the tables that exist, so a seed that stopped
  -- seating anybody fails here rather than quietly showing an empty
  -- restaurant.
  perform pg_temp.check_true(
    'the demo dining room has a bill on a table',
    (select count(*) from public.pos_sales s
       join public.organizations g on g.id = s.org_id
       join public.pos_outlets o on o.id = s.outlet_id
      where g.is_demo and o.business_type = 'food_beverage'
        and s.status = 'parked' and s.table_id is not null) > 0);

  perform pg_temp.check_true(
    'and the room it is in has tables to sit at',
    (select count(*) from public.pos_tables t
       join public.pos_outlets o on o.id = t.outlet_id
       join public.organizations g on g.id = o.org_id
      where g.is_demo and o.business_type = 'food_beverage') > 0);

  -- --------------------------------------------------------------
  -- The demo card can actually be spent
  -- --------------------------------------------------------------
  --
  -- The member earns six points from one RM6.50 sale and the scheme
  -- redeems from a hundred, so without an opening balance the loyalty
  -- panel on the tender sheet demonstrates itself by refusing —
  -- "Redeems from 100", greyed out, on the only tenant with a card.
  --
  -- Asserted against the programme's own minimum rather than a number
  -- typed here, so raising the minimum fails this instead of quietly
  -- making the demo useless again.
  perform pg_temp.check_true(
    'the demo card holds enough to redeem',
    (select app.loyalty_balance(a.id) >= p.min_redeem_points
       from public.loyalty_accounts a
       join public.loyalty_programs p on p.id = a.program_id
       join public.organizations g on g.id = a.org_id
      where g.is_demo and p.is_active and a.is_active
      limit 1));

  -- The positive control. The assertion above passes for free if the
  -- minimum is zero, which is exactly what a scheme set up carelessly
  -- would look like.
  perform pg_temp.check_true(
    'and the scheme has a minimum worth clearing',
    (select p.min_redeem_points > 0 from public.loyalty_programs p
       join public.organizations g on g.id = p.org_id
      where g.is_demo and p.is_active limit 1));

  -- Points handed out have to say why. `adjust_loyalty_points` refuses
  -- an unexplained one, so this is also the check that the seed used
  -- the real call rather than writing the ledger itself.
  perform pg_temp.check_true(
    'and the opening balance says where it came from',
    exists (select 1 from public.loyalty_entries e
              join public.organizations g on g.id = e.org_id
             where g.is_demo and e.kind = 'adjust'
               and nullif(btrim(coalesce(e.note, '')), '') is not null));

  -- --------------------------------------------------------------
  -- The salon: a day with all four states of a slot in it
  -- --------------------------------------------------------------
  --
  -- Writing the seed established that `arrived` is a state you pass
  -- through rather than rest in — completing the sale moves the
  -- booking to `completed`. So a demo that checked somebody in and
  -- then took their money would show nobody in the chair. Asserted
  -- here because it is exactly the sort of thing a later edit would
  -- quietly undo.
  select id into v_salon from public.organizations
   where name = 'Seri Ayu Salon & Spa Sdn Bhd';
  perform pg_temp.check_true('the salon exists', v_salon is not null);
  perform pg_temp.check_true('two chairs, and not on the same hours',
    (select count(distinct h.starts_at) from public.pos_provider_hours h
      where h.org_id = v_salon) > 1);
  perform pg_temp.check_true('somebody is in the chair, with the bill still open',
    exists (select 1 from public.pos_bookings b
             where b.org_id = v_salon and b.status = 'arrived'
               and b.sale_id is not null));
  perform pg_temp.check_true('one already done and paid for',
    exists (select 1 from public.pos_bookings b
             where b.org_id = v_salon and b.status = 'completed'));
  perform pg_temp.check_true('one still to come',
    exists (select 1 from public.pos_bookings b
             where b.org_id = v_salon and b.status = 'booked'));
  perform pg_temp.check_true('and one that did not turn up',
    exists (select 1 from public.pos_bookings b
             where b.org_id = v_salon and b.status = 'no_show'));
  perform pg_temp.check_true('with a membership to sell',
    exists (select 1 from public.pos_memberships m where m.org_id = v_salon));

  -- --------------------------------------------------------------
  -- The stall: takings that arrived after the fact, exactly once
  -- --------------------------------------------------------------
  --
  -- The seed deliberately sends the same batch twice. What is asserted
  -- is the count that would double if landing were not idempotent —
  -- the property the whole offline design exists for, carried by the
  -- tenant as evidence rather than only claimed in a test.
  select id into v_stall from public.organizations
   where name = 'Roti Warisan Enterprise';
  perform pg_temp.check_true('the stall exists', v_stall is not null);
  perform pg_temp.check_eq('three sales came in from the offline queue',
    (select count(*)::integer from public.pos_sales s
      where s.org_id = v_stall and s.offline_sold_at is not null), 3);
  perform pg_temp.check_eq(
    'and the batch sent twice landed once, not twice',
    (select count(*)::integer from public.pos_sales s
      where s.org_id = v_stall and s.status = 'completed'), 4);
  perform pg_temp.check_true(
    'the till''s clock is kept alongside the server''s',
    (select bool_and(s.offline_sold_at < s.completed_at)
       from public.pos_sales s
      where s.org_id = v_stall and s.offline_sold_at is not null));
  perform pg_temp.check_eq('and nothing was rejected',
    (select count(*)::integer from public.pos_offline_rejects r
      where r.org_id = v_stall), 0);

  -- --------------------------------------------------------------
  -- SST, set the only way that produces a coherent state
  -- --------------------------------------------------------------
  perform pg_temp.check_true(
    'Sinar is SST registered with an effective date and a rated default '
    '— all four facts, not three',
    exists (select 1 from public.organizations o
             where o.id = v_sinar and o.is_sst_registered
               and o.sst_registered_from is not null)
    and exists (select 1 from public.tax_codes t
                 where t.org_id = v_sinar and t.is_default and t.rate > 0));

  -- --------------------------------------------------------------
  -- The books balance, and carry the tax they should
  --
  -- A demo whose trial balance does not sum to zero is worse than an
  -- empty one: every report is wrong and nobody can tell which. And an
  -- SST-registered company with no output tax is an invoice that
  -- understates what was charged — the first draft of the seed produced
  -- exactly that, because `tax_rate` is stored on the line and naming
  -- the code alone is not enough.
  -- --------------------------------------------------------------
  perform pg_temp.check_eq('Sinar''s trial balance is zero',
    (select coalesce(sum(l.debit - l.credit), 0)
       from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_sinar and e.status = 'posted'), 0);

  perform pg_temp.check_true(
    'and it posted output SST, being registered',
    (select coalesce(sum(l.credit - l.debit), 0)
       from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_sinar and e.status = 'posted' and a.code = '2130') > 0);

  -- Sinar now collects some of what it invoices, so receivables are no
  -- longer the whole of revenue plus tax — they are what is left after
  -- the receipts. Stated with the receipts on the left rather than
  -- dropped, because it is the same identity and it is still the one a
  -- missing `tax_rate` silently breaks.
  --
  -- Every revenue account, not `4100` alone. `0436` gave Sinar a job to
  -- bill and `bill_project_time` credits `4840 Professional Fees`, so
  -- naming one account made the identity fail by exactly the RM3,330 of
  -- engineer time. `0429` widened Amanah's copy of this for the same
  -- reason; "revenue plus output SST" is what the sentence always
  -- meant, and it is a stronger assertion for covering the next income
  -- account somebody adds.
  perform pg_temp.check_eq(
    'receivables plus what was collected equal revenue plus output SST',
    (select coalesce(sum(l.debit - l.credit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_sinar and e.status = 'posted' and a.code = '1210')
    + (select coalesce(sum(amount), 0) from public.receipts
        where org_id = v_sinar and status = 'posted'),
    (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_sinar and e.status = 'posted'
        and (a.code like '4%' or a.code = '2130')));

  -- --------------------------------------------------------------
  -- Sinar's cash, staff and assets
  --
  -- Three subledgers that each keep their own running total and are each
  -- capable of disagreeing with the ledger without anything failing.
  --
  --   * `bank_accounts.current_balance` is a cached column. Receipts and
  --     payments maintain it; a journal that touches the bank account
  --     directly does not. The demo posts several of those — capital, an
  --     asset bought for cash, a salary run — so the column is a real
  --     opportunity to drift and the identity is worth asserting.
  --   * the fixed asset register carries cost and accumulated
  --     depreciation of its own, which the balance sheet then reports
  --     from the ledger. If those two ever part company the register and
  --     the accounts tell different stories about the same van.
  --   * net pay is credited to 2145 by `post_payroll_run()` and cleared
  --     by the bank transfer. A balance left there means the demo shows
  --     wages owing to people it also shows as paid.
  -- --------------------------------------------------------------
  perform pg_temp.check_true('Sinar has a bank account at all — it had '
    'none, which is why every invoice sat unpaid',
    exists (select 1 from public.bank_accounts where org_id = v_sinar));

  select b.current_balance into v_bank
    from public.bank_accounts b where b.org_id = v_sinar;
  select coalesce(sum(l.debit - l.credit), 0) into v_gl
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.bank_accounts b on b.account_id = l.account_id
   where e.org_id = v_sinar and e.status = 'posted' and b.org_id = v_sinar;
  perform pg_temp.check_eq(
    'the cached bank balance equals the ledger, which is the whole point '
    'of a cache nobody reconciles', v_bank, v_gl);

  -- Both aging buckets. Either extreme is a screen with nothing to read.
  select count(*) into v_units from public.sales_documents
   where org_id = v_sinar and doc_type = 'invoice' and status = 'posted';
  perform pg_temp.check_true(
    format('some invoices are still outstanding (%s), so the aging report '
           'has a current bucket', v_units), v_units > 0);
  select count(*) into v_units from public.receipts where org_id = v_sinar;
  perform pg_temp.check_true(
    format('and some were collected (%s receipts), so it has a settled '
           'side too', v_units), v_units > 0);

  perform pg_temp.check_eq(
    'the asset register''s cost equals the ledger''s property, plant and '
    'equipment — a register the balance sheet has never heard of is worse '
    'than an empty one',
    (select coalesce(sum(cost), 0) from public.fixed_assets
      where org_id = v_sinar and deleted_at is null),
    (select coalesce(sum(l.debit - l.credit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_sinar and e.status = 'posted'
        and a.code in ('1510', '1520')));

  perform pg_temp.check_eq(
    'and its accumulated depreciation equals the ledger''s',
    (select coalesce(sum(accumulated_depreciation), 0) from public.fixed_assets
      where org_id = v_sinar and deleted_at is null),
    (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_sinar and e.status = 'posted' and a.code = '1590'));

  select count(*) into v_units from public.payroll_runs where org_id = v_sinar;
  perform pg_temp.check_true(
    format('payroll ran (%s runs), which it could not do at all until the '
           'chart gained account 2145', v_units), v_units > 0);

  perform pg_temp.check_eq(
    'nothing is left in net salaries payable: everyone the demo shows as '
    'paid was actually paid',
    (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_sinar and e.status = 'posted' and a.code = '2145'), 0);

  -- --------------------------------------------------------------
  -- Amanah: the client register, which is the module's whole point
  --
  -- A corporate secretarial practice with client companies that have no
  -- officers and no share events is three empty screens. The register of
  -- members is *computed* from `corp_share_events`, so an entity without
  -- one shows a company that nobody owns.
  --
  -- Each assertion counts what it compared as well as what failed. An
  -- assertion that only counts failures passes when there is nothing
  -- there at all.
  -- --------------------------------------------------------------
  select id into v_amanah from public.organizations
   where name = 'Amanah Setiausaha Sdn Bhd';
  perform pg_temp.check_true('Amanah exists', v_amanah is not null);

  select count(*) into v_entities
    from public.corp_entities where org_id = v_amanah;
  perform pg_temp.check_true(
    format('Amanah acts for client companies (%s of them)', v_entities),
    v_entities >= 3);

  select count(*) into v_bad from public.corp_entities e
   where e.org_id = v_amanah
     and (not exists (select 1 from public.corp_officers o
                       where o.entity_id = e.id and o.role = 'director')
       or not exists (select 1 from public.corp_officers o
                       where o.entity_id = e.id and o.role = 'secretary')
       or not exists (select 1 from public.corp_share_events s
                       where s.entity_id = e.id and s.event_type = 'allotment'));
  perform pg_temp.check_eq(
    format('every one of those %s entities has a director, a secretary and '
           'shares in issue', v_entities), v_bad, 0);

  perform pg_temp.check_eq('Amanah''s trial balance is zero',
    (select coalesce(sum(l.debit - l.credit), 0)
       from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_amanah and e.status = 'posted'), 0);

  -- Not SST registered, so receivables are the fee and nothing else. The
  -- identity is the same one Sinar's checks; here it holds with no tax
  -- rather than with tax, which is the case a hardcoded 8% would break.
  --
  -- Against every revenue account rather than against `4100`. `0429`
  -- gave Amanah billable time, and `bill_project_time` credits whatever
  -- `app.time_income_account` returns -- `4840 Professional Fees` --
  -- not sales. Naming one account made this read as "receivables equal
  -- fee income" while asserting "receivables equal the sales account",
  -- and the two stopped being the same thing the moment the practice
  -- billed an hour. The wider form is what the sentence always meant
  -- and is the stronger assertion: no tax anywhere, not no tax on
  -- sales.
  perform pg_temp.check_true(
    'Amanah billed fees, and receivables equal them exactly — it is under '
    'the SST threshold, so there is no tax to add',
    (select coalesce(sum(l.debit - l.credit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_amanah and e.status = 'posted' and a.code = '1210')
    = (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
         join public.gl_entries e on e.id = l.entry_id
         join public.accounts a on a.id = l.account_id
        where e.org_id = v_amanah and e.status = 'posted'
          and a.code like '4%')
    and (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
           join public.gl_entries e on e.id = l.entry_id
           join public.accounts a on a.id = l.account_id
          where e.org_id = v_amanah and e.status = 'posted'
            and a.code like '4%') > 0);
  -- And the practice's revenue is now in two places, which is the point:
  -- statutory fee work and chargeable time are different income, and a
  -- profit and loss that showed one line would be hiding the split.
  perform pg_temp.check_true(
    'and it comes from both the fee work and the billed hours',
    (select count(distinct a.code) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_amanah and e.status = 'posted'
        and a.code like '4%' and l.credit > 0) >= 2);

  -- --------------------------------------------------------------
  -- Harta Prima: both halves of the property module
  --
  -- `tenure` splits property in two, and a demo carrying only one half
  -- leaves the other half unseen. Two things beyond that are load-bearing
  -- and neither announces itself when wrong:
  --
  --   * a maintenance charge is apportioned by share unit over the
  --     scheme's declared total, so parcels that do not add up to it
  --     apportion against the wrong denominator and every charge is
  --     quietly out;
  --   * a parcel with no owner cannot be charged, so a register that
  --     looks complete bills nobody.
  -- --------------------------------------------------------------
  select id into v_harta from public.organizations
   where name = 'Harta Prima Management Sdn Bhd';
  perform pg_temp.check_true('Harta Prima exists', v_harta is not null);

  select string_agg(t, ', ') into v_missing from (
    select 'strata' as t where not exists (
      select 1 from public.property_sites
       where org_id = v_harta and tenure = 'strata')
    union all select 'non_strata' where not exists (
      select 1 from public.property_sites
       where org_id = v_harta and tenure = 'non_strata')
  ) s;
  perform pg_temp.check_true(
    'the property tenant shows both tenures, not just one: ' ||
    coalesce(v_missing, 'both present'), v_missing is null);

  select count(*) into v_units
    from public.property_units u join public.property_sites s on s.id = u.site_id
   where u.org_id = v_harta and s.tenure = 'strata';
  perform pg_temp.check_true(
    format('the scheme has parcels (%s)', v_units), v_units > 0);

  perform pg_temp.check_eq(
    format('and all %s of them have an owner to charge', v_units),
    (select count(*) from public.property_units u
       join public.property_sites s on s.id = u.site_id
      where u.org_id = v_harta and s.tenure = 'strata'
        and u.owner_contact_id is null), 0);

  perform pg_temp.check_eq(
    'the parcels'' share units add up to the scheme''s declared total, '
    'which is the denominator every maintenance charge is apportioned over',
    (select coalesce(sum(u.share_units), 0) from public.property_units u
      where u.org_id = v_harta
        and u.site_id = (select site_id from public.strata_schemes
                          where org_id = v_harta limit 1)),
    (select total_share_units from public.strata_schemes
      where org_id = v_harta limit 1));

  select count(*) into v_units from public.tenancies
   where org_id = v_harta and status = 'active';
  perform pg_temp.check_true(
    format('the commercial block is let (%s active tenancies)', v_units),
    v_units > 0);

  perform pg_temp.check_eq('Harta Prima''s trial balance is zero',
    (select coalesce(sum(l.debit - l.credit), 0)
       from public.gl_lines l join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_harta and e.status = 'posted'), 0);

  perform pg_temp.check_true(
    'and it invoiced rent',
    (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = v_harta and e.status = 'posted' and a.code = '4100') > 0);

  -- --------------------------------------------------------------
  -- The service desk, and the two ways it can look full but be broken
  --
  -- A ticket with no team is in a queue nobody is looking at, and a
  -- ticket with no deadline is one no report can call late. Both render
  -- perfectly in a list, which is exactly why they are worth asserting
  -- rather than eyeballing.
  -- --------------------------------------------------------------
  select count(*) into v_units from public.tickets where org_id = v_sinar;
  perform pg_temp.check_true(
    format('the demo service desk has tickets in it (%s)', v_units), v_units > 0);

  perform pg_temp.check_eq(
    'every one of them was routed to a team',
    (select count(*) from public.tickets
      where org_id = v_sinar and team_id is null), 0);

  perform pg_temp.check_eq(
    'and every one carries the deadlines it was promised',
    (select count(*) from public.tickets
      where org_id = v_sinar and resolution_due_at is null), 0);

  perform pg_temp.check_true(
    'the queue shows more than one state — a demo where everything is '
    'closed is a screenshot, and one where nothing is is a backlog',
    (select count(distinct status) from public.tickets where org_id = v_sinar) >= 3);

  -- --------------------------------------------------------------
  -- Every module in the catalogue has somewhere to be seen
  -- --------------------------------------------------------------
  select count(*) into v_modules
    from public.platform_modules m
   where m.is_active and not m.is_core
     and not exists (
       select 1 from public.org_modules om
         join public.organizations o on o.id = om.org_id
        where om.module_code = m.code and om.is_enabled and o.is_demo);
  perform pg_temp.check_eq(
    'no active module is left without a demo tenant to show it in',
    v_modules, 0);

  -- --------------------------------------------------------------
  -- A practice's accounts name the client, not the practice
  -- --------------------------------------------------------------
  -- `fs_filings.corp_entity_id` had no writer until `e12d645`, so it was
  -- null on every filing and `report_fs_deadlines` fell back to
  -- `coalesce(e.name, o.name)` -- the practice's own name -- on every
  -- row, with no registration number beside it. A seed that left the
  -- column null would reproduce exactly that and look like a working
  -- demo.
  perform pg_temp.check_eq(
    'every set of accounts Amanah prepares names a client company',
    (select count(*) from public.fs_filings f
      where f.org_id = v_amanah and f.corp_entity_id is null), 0);
  -- `report_fs_deadlines` answers only a member of the organization, so
  -- the two assertions that go through it are made as one. Everything
  -- else in this file reads tables directly and needs no sign-in.
  perform pg_temp.sign_in_as(
    (select m.user_id from public.org_members m
      where m.org_id = v_amanah and m.role = 'owner' limit 1));
  perform pg_temp.check_true(
    'and the deadline list shows those names rather than the practice',
    not exists (select 1 from public.report_fs_deadlines(v_amanah, 400) d
                 where d.company = 'Amanah Setiausaha Sdn Bhd'));
  -- Both states, because they are the two arrangements the module has
  -- to show: a practice preparing accounts for companies it keeps the
  -- registers of, and a company preparing its own.
  perform pg_temp.check_eq(
    'while a company keeping its own books names none',
    (select count(*) from public.fs_filings f
      where f.org_id = v_sinar and f.corp_entity_id is not null), 0);
  -- The list is worth reading: one past its date and one still to come.
  -- A demo where every row is the same colour teaches nothing.
  perform pg_temp.check_true(
    'and the list has both a late one and one still in hand',
    (select count(*) filter (where d.is_late) from
       public.report_fs_deadlines(v_amanah, 400) d) >= 1
    and (select count(*) filter (where not d.is_late) from
       public.report_fs_deadlines(v_amanah, 400) d) >= 1);

  -- --------------------------------------------------------------
  -- A client that changed its name, and the letterhead s.28(4) wants
  -- --------------------------------------------------------------
  -- `0425` wired `corp_display_name` into the merge context and `0427`
  -- gave the demo a company it applies to. The assertion is on the
  -- merge field because that is what reaches the paper: the four
  -- assertions in `corp_particulars.sql` were true for as long as
  -- nothing called the function.
  perform pg_temp.check_true(
    'the renamed client carries both names on its documents',
    (select app.corp_merge_context(e.id) ->> 'company_name'
       from public.corp_entities e
      where e.org_id = v_amanah and e.name like 'Kilang%')
    like '%(formerly %)');
  -- The control: a company that never changed its name is unaffected,
  -- without which the assertion above is satisfied by appending
  -- "(formerly ...)" to everything.
  perform pg_temp.check_true(
    'and a client that did not carries one',
    (select app.corp_merge_context(e.id) ->> 'company_name'
       from public.corp_entities e
      where e.org_id = v_amanah and e.name like 'Bayu%')
    not like '%formerly%');
  -- The reason `0426` left this out, answered. A change of name is a
  -- fourteen-day filing under s.28, and a demo that opens one and never
  -- lodges it shows a client company in breach on every screen that
  -- counts deadlines.
  perform pg_temp.check_eq(
    'and the s.28 filing it opened was lodged, not left standing open',
    (select count(*) from public.corp_filings f
       join public.corp_entities e on e.id = f.entity_id
      where e.org_id = v_amanah and f.filing_type = 'change_of_name'
        and f.status <> 'lodged'), 0);
  -- Through the proper door: `change_company_name` writes both of these
  -- and `0377`'s trigger refuses a rename that does not.
  perform pg_temp.check_true(
    'the rename kept the old name and the date to count twelve from',
    (select e.former_names[1] is not null and e.name_changed_on is not null
       from public.corp_entities e
      where e.org_id = v_amanah and e.name like 'Kilang%'));

  perform pg_temp.sign_out();

  -- --------------------------------------------------------------
  -- A pipeline somebody could look at
  -- --------------------------------------------------------------
  -- `crm` is on every tenant and there had never been a lead in the
  -- product. What makes the seed worth having is not the row count but
  -- the spread: a board where every card is in one column shows nothing
  -- about a board.
  perform pg_temp.check_true('Sinar has a pipeline with leads in it',
    (select count(*) from public.leads where org_id = v_sinar) >= 5);
  perform pg_temp.check_true(
    'and the leads are in more than one state',
    (select count(distinct status) from public.leads
      where org_id = v_sinar) >= 3);
  perform pg_temp.check_true(
    'and the deals are open, won and lost rather than all one thing',
    (select count(distinct status) from public.opportunities
      where org_id = v_sinar) >= 3);

  -- Through the functions, not into the tables. `convert_lead` is the
  -- only thing that sets `converted_contact_id`, and it is what stops a
  -- lead becoming two customers; a seed that wrote `status =
  -- 'converted'` by hand would look identical on the board and leave
  -- that column null.
  perform pg_temp.check_eq(
    'a converted lead became a contact, which only convert_lead does',
    (select count(*) from public.leads
      where org_id = v_sinar and status = 'converted'
        and converted_contact_id is null), 0);
  -- `close_lead` refuses without one: "a list of dead leads with no
  -- reasons on it is a list nobody reads twice".
  perform pg_temp.check_eq(
    'and a lost lead says why',
    (select count(*) from public.leads
      where org_id = v_sinar and status = 'lost'
        and coalesce(btrim(lost_reason), '') = ''), 0);
  -- `0373`'s trigger dates the close when the stage moves, and `0422`
  -- pinned it to the Malaysian day.
  perform pg_temp.check_eq(
    'and a closed deal is dated',
    (select count(*) from public.opportunities
      where org_id = v_sinar and status <> 'open'
        and actual_close_date is null), 0);

  -- --------------------------------------------------------------
  -- A law firm, and the two rules client money is held under
  -- --------------------------------------------------------------
  -- `client_account.sql` opens by stating them, and until `0430` no
  -- demo showed either. `legal` was switched on at Amanah, a company
  -- secretarial practice, purely so the assertion above -- "no active
  -- module is left without a demo tenant to show it in" -- was
  -- satisfied by a tick.
  declare v_guaman uuid; v_client_bank uuid;
  begin
    select id into v_guaman from public.organizations
     where is_demo and name like 'Guaman%';
    perform pg_temp.check_true('there is a law firm now', v_guaman is not null);
    perform pg_temp.check_eq(
      'and legal is no longer switched on at the secretarial practice',
      (select count(*) from public.org_modules
        where org_id = v_amanah and module_code = 'legal' and is_enabled), 0);

    perform pg_temp.check_true('the firm has matters open',
      (select count(*) from public.matters where org_id = v_guaman) >= 3);

    -- Rule one: client money sits in a client account, never the
    -- firm's own. A seed that made its own bank account and called it
    -- one would put office money behind a label.
    select id into v_client_bank from public.bank_accounts
     where org_id = v_guaman and is_client_account;
    perform pg_temp.check_true('and a client account to hold money in',
      v_client_bank is not null);
    perform pg_temp.check_eq(
      'every client-money movement is against that account and no other',
      (select count(*) from public.client_account_transactions
        where org_id = v_guaman
          and bank_account_id is distinct from v_client_bank), 0);

    -- The ledger and the bank register agree. This does NOT catch an
    -- amount signed the wrong way -- `post_client_transaction` moves
    -- both from the same `v_amount`, so they agree whichever way it is
    -- signed, and a first draft of this file claimed otherwise.
    -- Measured: signing the payment positive leaves this green. What it
    -- does catch is the two drifting apart, which `0282` fixed once
    -- already.
    perform pg_temp.check_eq(
      'what the client account holds is what the ledger says it holds',
      (select current_balance from public.bank_accounts
        where id = v_client_bank),
      (select coalesce(sum(l.debit - l.credit), 0) from public.gl_lines l
         join public.gl_entries e on e.id = l.entry_id
         join public.accounts a on a.id = l.account_id
        where e.org_id = v_guaman and e.status = 'posted'
          and a.code = '1150'));
    -- Client money is a liability and never income: 1150 against 2300,
    -- not against revenue. If it ever landed in revenue the firm would
    -- be paying tax on money it does not own.
    perform pg_temp.check_eq(
      'and it is owed to the clients, not earned',
      (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
         join public.gl_entries e on e.id = l.entry_id
         join public.accounts a on a.id = l.account_id
        where e.org_id = v_guaman and e.status = 'posted'
          and a.code = '2300'),
      (select current_balance from public.bank_accounts
        where id = v_client_bank));

    -- Rule two: no client ledger in debit. Not asserted as a refusal --
    -- `client_account.sql` does that -- but as the state the demo is
    -- actually in, because a demo that quietly held a negative balance
    -- for one client would look fine in total.
    perform pg_temp.check_eq(
      'and no client is out of pocket to pay for another',
      (select count(*) from (
         select t.matter_id, sum(t.amount) as bal
           from public.client_account_transactions t
          where t.org_id = v_guaman and t.status = 'posted'
          group by t.matter_id) m where m.bal < 0), 0);

    -- The money crossed from client to office the only lawful way.
    perform pg_temp.check_true(
      'the firm took its fee by transferring it, not by helping itself',
      exists (select 1 from public.client_account_transactions
               where org_id = v_guaman
                 and transaction_type = 'transfer_to_office'
                 and status = 'posted'));

    -- And money out went out. `post_client_transaction` takes the
    -- amount as the caller signs it, so a payment written as a positive
    -- number debits the client bank a second time: the firm shows as
    -- holding more after paying the vendor than it ever received, and
    -- every balance check above still passes because the ledger and the
    -- register move together. This is the assertion that separates the
    -- two.
    perform pg_temp.check_true(
      'a matter that has paid money out holds less than it took in',
      (select sum(t.amount) from public.client_account_transactions t
        where t.org_id = v_guaman and t.status = 'posted'
          and t.matter_id = (
            select matter_id from public.client_account_transactions
             where org_id = v_guaman and transaction_type = 'payment'
             limit 1))
      < (select sum(t.amount) from public.client_account_transactions t
          where t.org_id = v_guaman and t.status = 'posted'
            and t.transaction_type = 'receipt'
            and t.matter_id = (
              select matter_id from public.client_account_transactions
               where org_id = v_guaman and transaction_type = 'payment'
               limit 1)));
  end;

  -- --------------------------------------------------------------
  -- The hours the practice bills
  -- --------------------------------------------------------------
  -- Amanah's whole business is billing time and it had recorded none.
  -- What makes the seed worth having is the two distinctions the module
  -- exists for: recorded against chargeable, and chargeable against
  -- billed.
  perform pg_temp.check_true('Amanah records time against engagements',
    (select count(*) from public.time_entries where org_id = v_amanah) >= 6);
  perform pg_temp.check_true(
    'not all of it chargeable, which is most of what a timesheet is for',
    (select count(*) from public.time_entries
      where org_id = v_amanah and not is_billable) >= 1);
  perform pg_temp.check_true(
    'and not all of the chargeable time is billed yet',
    (select count(*) from public.time_entries
      where org_id = v_amanah and is_billable and not is_billed) >= 1);

  -- Billed by the function that raises the invoice. `bill_project_time`
  -- writes the invoice, marks the entries and puts its id on them;
  -- setting `is_billed` by hand would set the same flag and leave no
  -- invoice, and the screen would show hours billed against nothing.
  perform pg_temp.check_eq(
    'every billed hour points at the invoice it was billed on',
    (select count(*) from public.time_entries
      where org_id = v_amanah and is_billed and invoice_id is null), 0);
  perform pg_temp.check_true(
    'and that invoice is a real one in the ledger',
    exists (select 1 from public.sales_documents d
             where d.org_id = v_amanah
               and d.id in (select invoice_id from public.time_entries
                             where org_id = v_amanah
                               and invoice_id is not null)
               and d.gl_entry_id is not null));

  -- --------------------------------------------------------------
  -- Every business buys something
  -- --------------------------------------------------------------
  -- `0432`. Six tenants had `purchases` enabled -- because
  -- `app.seed_org_modules` turns it on for every organization in this
  -- product, not because the demo chose to -- and no purchase document
  -- between them.
  perform pg_temp.check_eq(
    'every demo tenant has a posted bill',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (
          select 1 from public.purchase_documents d
           where d.org_id = o.id and d.doc_type = 'bill'
             and d.gl_entry_id is not null)), 0);

  -- Bills that are all settled leave the payables ageing and the
  -- supplier statement demonstrating themselves by being blank.
  perform pg_temp.check_eq(
    'and one still owed, so the ageing has something in it',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (
          select 1 from public.purchase_documents d
           where d.org_id = o.id and d.doc_type = 'bill'
             and d.gl_entry_id is not null
             and d.paid_amount < d.total_amount)), 0);

  -- And one actually paid. A seed that posted two bills and no payment
  -- would satisfy both assertions above.
  perform pg_temp.check_eq(
    'and one settled through a posted supplier payment',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (
          select 1 from public.purchase_documents d
            join public.payment_allocations a on a.bill_id = d.id
            join public.purchase_payments p on p.id = a.payment_id
           where d.org_id = o.id and p.gl_entry_id is not null
             and d.paid_amount >= d.total_amount)), 0);

  -- Rule 7 of the Solicitors' Accounts Rules 1990. The firm's own
  -- printer is not paid out of money held for a client, and the seed
  -- has to be checked for it like anything else that moves money.
  declare v_firm uuid;
  begin
    select id into v_firm from public.organizations
     where is_demo and name like 'Guaman%';
    perform pg_temp.check_eq(
      'and the law firm paid its supplier out of the office account',
      (select count(*) from public.purchase_payments p
         join public.bank_accounts b on b.id = p.bank_account_id
        where p.org_id = v_firm and b.is_client_account), 0);
  end;

  -- --------------------------------------------------------------
  -- One balance per bank account, not one per tenant
  -- --------------------------------------------------------------
  -- `app.demo_sync_bank_balance` wrote one org-wide total onto every
  -- `bank_accounts` row a tenant had. Right while no demo tenant had
  -- two; `0430` gave the law firm an office account and a client
  -- account, and `0432` was the first thing to call the function on it.
  -- The assertion above -- what the client account holds -- caught it,
  -- which is the assertion working, but it only looks at one tenant and
  -- one account. This asks it of every bank account in the demo.
  perform pg_temp.check_eq(
    'every bank account holds what its own ledger account holds',
    (select count(*) from public.bank_accounts b
       join public.organizations o on o.id = b.org_id and o.is_demo
      where b.current_balance <> coalesce((
        select sum(l.debit - l.credit)
          from public.gl_lines l
          join public.gl_entries e on e.id = l.entry_id
         where e.org_id = b.org_id and e.status = 'posted'
           and l.account_id = b.account_id), 0)), 0);

  -- The control: two accounts on one tenant holding different numbers.
  -- Without it the assertion above passes on a demo where every tenant
  -- has one account, which is the state that hid the defect.
  declare v_firm uuid;
  begin
    select id into v_firm from public.organizations
     where is_demo and name like 'Guaman%';
    perform pg_temp.check_true(
      'on a tenant that has two of them, holding different balances',
      (select count(distinct current_balance) from public.bank_accounts
        where org_id = v_firm) = 2);
  end;

  -- --------------------------------------------------------------
  -- An enquiry every business gets
  -- --------------------------------------------------------------
  -- `0433`. `crm` was enabled on all seven -- by `app.seed_org_modules`,
  -- like `purchases` -- and only Sinar had a lead in it.
  perform pg_temp.check_eq(
    'every demo tenant has somebody to call back',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (select 1 from public.leads l where l.org_id = o.id)), 0);

  -- A board where everything is already closed shows nothing about
  -- stages, which is the whole of what the screen is.
  perform pg_temp.check_eq(
    'and a deal still open on the board',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (
          select 1 from public.opportunities p
           where p.org_id = o.id and p.status = 'open')), 0);

  -- A board where every card sits in the first stage is a board that
  -- shows nothing about stages. Nothing else here would notice: the
  -- open deal would still be open and the won one still won.
  perform pg_temp.check_eq(
    'and the open one has moved past the first stage',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (
          select 1 from public.opportunities p
            join public.pipeline_stages st on st.id = p.stage_id
           where p.org_id = o.id and p.status = 'open'
             and st.sort_order > (
               select min(s2.sort_order) from public.pipeline_stages s2
                where s2.pipeline_id = st.pipeline_id))), 0);

  perform pg_temp.check_eq(
    'and one it won',
    (select count(*) from public.organizations o
      where o.is_demo
        and not exists (
          select 1 from public.opportunities p
           where p.org_id = o.id and p.status = 'won')), 0);

  -- The columns only `convert_lead` sets. Writing `status =
  -- ''converted''` into the table by hand looks identical on the board
  -- and leaves the contact unmade, which is how one enquiry becomes two
  -- customers later.
  perform pg_temp.check_eq(
    'every converted lead went through convert_lead',
    (select count(*) from public.leads l
       join public.organizations o on o.id = l.org_id and o.is_demo
      where l.status = 'converted'
        and (l.converted_contact_id is null or l.converted_at is null)), 0);

  -- `close_lead` refuses without a reason. A lead closed straight into
  -- the table would not have been refused.
  perform pg_temp.check_eq(
    'and every dead one says why it died',
    (select count(*) from public.leads l
       join public.organizations o on o.id = l.org_id and o.is_demo
      where l.status = 'lost'
        and coalesce(l.lost_reason, '') = ''), 0);

  -- --------------------------------------------------------------
  -- Nobody approves their own
  -- --------------------------------------------------------------
  -- `0434`. Amanah and Harta had `approvals` and one member each, so
  -- `decide_approval`'s refusal -- you raised this, so you cannot
  -- approve it -- made every chain unclearable. The module came off
  -- both; Sinar, which has three people, got the chain.
  declare v_tek uuid;
  begin
    select id into v_tek from public.organizations
     where is_demo and name like 'Sinar%';

    perform pg_temp.check_true('there is a rule to approve against',
      (select count(*) from public.approval_rules
        where org_id = v_tek and is_active) >= 1);

    -- A chain that has been decided, and one that has not. Either alone
    -- leaves half the screen demonstrating itself by being empty.
    perform pg_temp.check_true('a request the owner has cleared',
      (select count(*) from public.approval_requests
        where org_id = v_tek and status = 'approved') >= 1);
    perform pg_temp.check_true('and one still waiting on somebody',
      (select count(*) from public.approval_requests
        where org_id = v_tek and status = 'pending') >= 1);

    -- The rule that makes the module worth having. A seed that wrote
    -- the request row itself would satisfy everything above and prove
    -- nothing, because `decide_approval` is the only thing that refuses
    -- this.
    perform pg_temp.check_eq(
      'and nobody approved a document they raised themselves',
      (select count(*) from public.approval_requests q
         join public.approval_steps st on st.request_id = q.id
        where q.org_id = v_tek and st.decided_by = q.requested_by), 0);

    -- And the approved one actually posted, which the trigger would
    -- have refused without the decision.
    perform pg_temp.check_true(
      'the approved bill is in the ledger',
      exists (select 1 from public.approval_requests q
                join public.purchase_documents d on d.id = q.entity_id
               where q.org_id = v_tek and q.status = 'approved'
                 and d.gl_entry_id is not null));
  end;

  -- --------------------------------------------------------------
  -- The servers Sinar builds
  -- --------------------------------------------------------------
  -- `0435`. `manufacturing` was enabled on Sinar with no bill of
  -- materials, work centre or order in the product. It could not be
  -- turned off the way `0434` turned off `approvals`: the assertion
  -- above requires every active module to be enabled on some demo
  -- tenant, and none of the other six manufactures either.
  declare v_tek uuid; v_mo uuid;
  begin
    select id into v_tek from public.organizations
     where is_demo and name like 'Sinar%';

    select id into v_mo from public.manufacturing_orders
     where org_id = v_tek and status = 'done' and gl_entry_id is not null
     order by order_no limit 1;
    perform pg_temp.check_true(
      'a build that was actually run, not a draft on a screen',
      v_mo is not null);

    -- Components out and the finished item in. A seed that wrote the
    -- order row and stopped would satisfy nothing here, because only
    -- `post_manufacturing_order` writes these movement types -- they
    -- were in the enum from `0006` with no caller until `0422`.
    perform pg_temp.check_true('components were issued to it',
      (select count(*) from public.stock_movements
        where source_id = v_mo and movement_type = 'assembly_out') >= 4);
    perform pg_temp.check_true('and the finished servers came back in',
      (select coalesce(sum(quantity), 0) from public.stock_movements
        where source_id = v_mo and movement_type = 'assembly_in') > 0);

    -- The scrap allowance. `confirm_manufacturing_order` ADDS scrap
    -- rather than deducting it: four modules a server, two servers, and
    -- five per cent thrown away means issuing more than eight. A seed
    -- that wrote `mo_components` itself would have issued exactly
    -- eight, and every other assertion here would still pass.
    perform pg_temp.check_true(
      'and the scrap allowance was added, not deducted',
      (select c.quantity_required from public.mo_components c
         join public.items i on i.id = c.item_id
        where c.mo_id = v_mo and i.code = 'CMP-MEM') > 8);

    -- The bench, and what it charges. Without this the routing step and
    -- `work_centres.cost_per_hour` are dead configuration: dropping the
    -- operation from the BOM leaves every other assertion here passing
    -- and the finished item carried at components alone. Measured --
    -- the mutant that removed it survived until this was added.
    -- Two assertions, because either alone is satisfied by the mutant
    -- that removes the routing step: with no operation there is no
    -- conversion cost, and nothing minus nothing is zero.
    perform pg_temp.check_true('the bench time was absorbed at all',
      (select conversion_cost from public.manufacturing_orders
        where id = v_mo) > 0);

    perform pg_temp.check_eq(
      'and at the rate the work centre charges',
      (select round(m.conversion_cost - coalesce(sum(
                (case when o.actual_minutes > 0 then o.actual_minutes
                      else o.planned_minutes end)
                / 60.0 * w.cost_per_hour), 0), 2)
         from public.manufacturing_orders m
         left join public.mo_operations o on o.mo_id = m.id
         left join public.work_centres w on w.id = o.work_centre_id
        where m.id = v_mo
        group by m.conversion_cost), 0);

    -- What the order says it cost is what its components cost. The two
    -- are written by the same function from different sides -- the
    -- components from `stock_movements.total_cost`, the header by
    -- accumulating them -- so a costing error shows up as a gap.
    perform pg_temp.check_eq(
      'and what the order cost is what its components cost',
      (select round(m.component_cost
                    - coalesce(sum(c.total_cost), 0), 2)
         from public.manufacturing_orders m
         left join public.mo_components c on c.mo_id = m.id
        where m.id = v_mo
        group by m.component_cost), 0);
  end;

  -- --------------------------------------------------------------
  -- The last three empty screens
  -- --------------------------------------------------------------
  -- `0436`. `branches` and `timesheets` on Sinar and `fixed_assets` on
  -- Harta were the last three register lines that were gaps rather than
  -- deliberate absences.
  declare v_tek uuid; v_hrt uuid; v_north uuid; v_job uuid;
  begin
    select id into v_tek from public.organizations
     where is_demo and name like 'Sinar%';
    select id into v_hrt from public.organizations
     where is_demo and name like 'Harta%';

    -- A branch with nothing through it makes the branch report answer
    -- "nothing happened there".
    select id into v_north from public.branches
     where org_id = v_tek and code = 'PG';
    perform pg_temp.check_true('there is a second office',
      v_north is not null);
    perform pg_temp.check_true('with trade actually raised in it',
      (select count(*) from public.sales_documents
        where org_id = v_tek and branch_id = v_north
          and gl_entry_id is not null) >= 3);

    -- And head office is not the whole of the rest. The documents that
    -- predate the branch stay unassigned, because `branch_id` is one of
    -- the figures a journal is built from and the posting guard refuses
    -- to move it afterwards -- measured, the first draft of the seed
    -- was refused on INV-2026-00021.
    perform pg_temp.check_true(
      'and the year that predates the branch was left where it happened',
      (select count(*) from public.sales_documents
        where org_id = v_tek and branch_id is null) > 0);

    -- A timesheet where everything bills is not a timesheet.
    select id into v_job from public.projects
     where org_id = v_tek and code = 'JOB-001';
    perform pg_temp.check_true('there is a job with hours on it',
      (select count(*) from public.time_entries
        where org_id = v_tek and project_id = v_job) >= 5);
    perform pg_temp.check_true('some of which bill nothing',
      (select count(*) from public.time_entries
        where org_id = v_tek and project_id = v_job
          and not is_billable) >= 2);

    -- Billed through `bill_project_time`, which is the only thing that
    -- sets `invoice_id`. A seed writing `is_billed` by hand would leave
    -- the same rows looking billed with no invoice behind them.
    perform pg_temp.check_eq(
      'and every billed hour points at an invoice that exists',
      (select count(*) from public.time_entries t
        where t.org_id = v_tek and t.project_id = v_job and t.is_billed
          and not exists (select 1 from public.sales_documents d
                           where d.id = t.invoice_id
                             and d.gl_entry_id is not null)), 0);
    perform pg_temp.check_eq(
      'and nothing unbillable was billed',
      (select count(*) from public.time_entries
        where org_id = v_tek and project_id = v_job
          and not is_billable and is_billed), 0);

    -- Harta owns a van and a fit-out. Not the buildings it manages --
    -- those belong to the JMB, and a managing agent carrying the common
    -- property on its own balance sheet would be a demo of a serious
    -- accounting error.
    perform pg_temp.check_true('the managing agent owns something itself',
      (select count(*) from public.fixed_assets
        where org_id = v_hrt and deleted_at is null) >= 3);
    perform pg_temp.check_true('and has been depreciating it',
      (select coalesce(sum(accumulated_depreciation), 0)
         from public.fixed_assets where org_id = v_hrt) > 0);

    -- The register agrees with the ledger. Two running totals that can
    -- part company without anything failing, which is why the same
    -- identity is asserted for Sinar above.
    perform pg_temp.check_eq(
      'and the register agrees with the accounts',
      (select coalesce(sum(cost), 0) from public.fixed_assets
        where org_id = v_hrt and deleted_at is null),
      (select coalesce(sum(l.debit - l.credit), 0) from public.gl_lines l
         join public.gl_entries e on e.id = l.entry_id
         join public.accounts a on a.id = l.account_id
        where e.org_id = v_hrt and e.status = 'posted'
          and a.code in ('1510', '1520')));
  end;

  -- --------------------------------------------------------------
  -- And there is something in it when you get there
  -- --------------------------------------------------------------
  -- The assertion above is satisfied by a flag. `mbrs` passed it for as
  -- long as the module has existed: enabled on Sinar, and no demo
  -- tenant had ever had a set of accounts, so somebody signing in and
  -- opening Financial statements read "No accounts prepared yet". A
  -- guard that reads as "every module can be seen" and means "every
  -- module is ticked" is the shape worth being careful about.
  --
  -- So this asks the other half: for each module a demo tenant has
  -- enabled, is there a row in the table that holds its work. The
  -- register below is what is still empty, named rather than tolerated
  -- silently, and a twelfth joining it turns this red.
  --
  -- The probe is a hand-written map because there is no mechanical one:
  -- a module is a concept, and which table means "this tenant uses it"
  -- is a judgement. `chat` is left out because its tables are scoped
  -- through a conversation rather than by an `org_id` column, and
  -- `attachments`, `mailbox` and `workspace_address` because `0324` and
  -- `0329` enable them deliberately without rows and say why.
  declare
    r record;
    n bigint;
    gaps text[] := '{}';
    -- Enabled, empty, and known. Each is a demo somebody has not
    -- written yet, not a defect in the module.
    --
    -- Tenant and module, not module alone. As a list of module codes
    -- this could only record "crm is empty somewhere" and could never
    -- shrink by one tenant, so seeding Sinar's pipeline would have left
    -- it unchanged and the register would have stopped meaning
    -- anything. A register that cannot record partial progress stops
    -- being read.
    known text[] := array[
      -- Submitting to LHDN needs credentials, and
      -- `demo_credentials_locked` withholds them on purpose. A
      -- submission row would be a lie about a connection that was never
      -- made, so this one is not a gap to close -- it is the right
      -- answer, and it is here so the scan does not report it every
      -- time.
      'Amanah Setiausaha Sdn Bhd -> einvoice',
      'Harta Prima Management Sdn Bhd -> einvoice',
      'Roti Warisan Enterprise -> einvoice',
      'Seri Ayu Salon & Spa Sdn Bhd -> einvoice',
      'Sinar Teknologi Sdn Bhd -> einvoice',
      'Warung Sedap Enterprise -> einvoice',
      'Guaman Aziz & Rakan -> einvoice',
      -- 0485 brings the practice's four into the same rebuild, and the
      -- reason above covers them unchanged.
      'Accountant & Co. -> einvoice',
      'Bayu Digital Sdn Bhd -> einvoice',
      'Kilang Lestari Sdn Bhd -> einvoice',
      'Pinang Holdings Berhad -> einvoice'];
      -- Nothing else. Every line left is an `einvoice` line above, and
      -- every one of those is deliberate.
  begin
    for r in
      with probe(module_code, tbl) as (values
        ('approvals','approval_rules'), ('branches','branches'),
        ('crm','leads'), ('einvoice','einvoice_submissions'),
        ('fixed_assets','fixed_assets'), ('forecasting','forecast_runs'),
        ('hr','employees'), ('inventory','warehouses'),
        ('legal','matters'), ('manufacturing','manufacturing_orders'),
        ('mbrs','fs_filings'),
        ('memberships','pos_memberships'),
        ('payroll','payroll_runs'), ('pos','pos_outlets'),
        ('property_nonstrata','property_units'),
        ('property_strata','property_units'),
        ('purchases','purchase_documents'),
        ('secretarial','corp_entities'), ('ticketing','tickets'),
        ('timesheets','time_entries'), ('loyalty','loyalty_programs')
      )
      select o.name as org, o.id as org_id, om.module_code as m, pr.tbl as t
        from public.org_modules om
        join public.organizations o on o.id = om.org_id
        join probe pr on pr.module_code = om.module_code
       where o.is_demo and om.is_enabled
         and not (o.name || ' -> ' || om.module_code = any (known))
       order by o.name, om.module_code
    loop
      execute format('select count(*) from public.%I where org_id = $1', r.t)
        into n using r.org_id;
      if n = 0 then
        gaps := gaps || (r.org || ' -> ' || r.m);
      end if;
    end loop;

    -- The control. If the probe matched no rows at all -- a renamed
    -- table, a mistyped module code -- the loop would run zero times
    -- and the assertion below would pass on an empty hand.
    perform pg_temp.check_true(
      'the probe actually looked at some modules',
      (select count(*) from public.org_modules om
         join public.organizations o on o.id = om.org_id
        where o.is_demo and om.is_enabled
          and not (o.name || ' -> ' || om.module_code = any (known))) > 10);

    -- And the register is not carrying entries for pairs that no longer
    -- exist. A line left behind after a tenant is renamed or a module
    -- turned off reads as work outstanding when there is none, and the
    -- register is only worth having if it is true.
    perform pg_temp.check_eq(
      'every line in the register is a module a demo tenant still has',
      (select coalesce(string_agg(k, ', '), '')
         from unnest(known) k
        where not exists (
          select 1 from public.org_modules om
            join public.organizations o on o.id = om.org_id
           where o.is_demo and om.is_enabled
             and o.name || ' -> ' || om.module_code = k)), '');

    perform pg_temp.check_eq(
      'and a module a demo tenant has bought has something in it',
      coalesce(array_to_string(gaps, ', '), ''), '');
  end;
end $$;

-- ---------------------------------------------------------------------
-- The payroll screens with nothing on them (0448)
--
-- Sinar had four employees, seven payroll runs and twenty-eight
-- payslips, and not one salary component or leave type: two setup
-- screens showing their empty state in the only company that can open
-- them, and the checkbox 0446 added with nothing to sit beside.
--
-- These assertions are written against relationships rather than
-- figures, because the demo year is the current one and the number of
-- runs grows with the calendar. The one exception is the count of
-- bonus lines, which is one by construction.
-- ---------------------------------------------------------------------
do $$
declare
  v_sinar   uuid;
  v_n       integer;
  v_slips   integer;
  v_emp     uuid;
  v_bonus   numeric;
  v_bonus_pcb numeric;
  v_other   numeric;
begin
  select id into v_sinar from public.organizations
   where name = 'Sinar Teknologi Sdn Bhd';

  select count(*) into v_n from public.salary_components
   where org_id = v_sinar;
  perform pg_temp.check_true(
    'the allowances screen has something on it', v_n >= 3);

  select count(*) into v_n from public.leave_types where org_id = v_sinar;
  perform pg_temp.check_true('and so does the leave one', v_n >= 3);

  -- The bands come from the Act through apply_statutory_leave_bands,
  -- so three of them per scaling type rather than a number typed here.
  select count(*) into v_n
    from public.leave_entitlement_bands b
    join public.leave_types t on t.id = b.leave_type_id
   where t.org_id = v_sinar;
  perform pg_temp.check_true(
    'with the statutory bands under them', v_n >= 6);

  select count(*) into v_n from public.leave_balances where org_id = v_sinar;
  perform pg_temp.check_true(
    'and a balance for each person to look at', v_n > 0);

  -- Every payslip carries the travelling allowance, which is what
  -- proves the extras were seeded before the runs rather than after.
  select count(*) into v_slips from public.payslips where org_id = v_sinar;
  select count(*) into v_n
    from public.payslip_lines l
    join public.payslips p on p.id = l.payslip_id
   where p.org_id = v_sinar and l.code = 'TRAVEL';
  if v_slips > 0 then
    perform pg_temp.check_eq(
      'the allowance reaches a payslip, and every one of them',
      v_n, v_slips);
  end if;

  -- The bonus, which is February's and February's only.
  select count(*) into v_n
    from public.payslip_lines l
    join public.payslips p on p.id = l.payslip_id
   where p.org_id = v_sinar and l.code = 'BONUS';

  -- Nothing to check before March, because the February run has not
  -- happened: the demo raises runs for months that have closed.
  if v_n > 0 then
    perform pg_temp.check_eq('the bonus is paid once', v_n, 1);

    perform pg_temp.check_true('and is marked as paid once',
      (select l.is_additional_remuneration
         from public.payslip_lines l
         join public.payslips p on p.id = l.payslip_id
        where p.org_id = v_sinar and l.code = 'BONUS' limit 1));

    select p.employee_id, p.pcb, l.amount
      into v_emp, v_bonus_pcb, v_bonus
      from public.payslips p
      join public.payslip_lines l on l.payslip_id = p.id and l.code = 'BONUS'
     where p.org_id = v_sinar limit 1;

    select avg(p.pcb) into v_other
      from public.payslips p
     where p.org_id = v_sinar and p.employee_id = v_emp
       and not exists (select 1 from public.payslip_lines l
                        where l.payslip_id = p.id and l.code = 'BONUS');

    -- What is *not* asserted here, and why, because it was tried.
    --
    -- The obvious assertion is that February's deduction is smaller
    -- than the annualised one, computed by handing the payslip's own
    -- figures back to `calc_pcb` the old way. It does not work.
    -- `calc_pcb` reads `payroll_ytd`, which by the time this test runs
    -- holds the whole year rather than the one month February saw, so
    -- the recomputed figure is not the figure February took and the
    -- comparison passes whether the bonus is marked or not -- measured,
    -- with the flag removed and the assertion left in.
    --
    -- **A figure that depends on accumulated state cannot be checked by
    -- recomputing it later.** The PCB arithmetic is asserted where the
    -- inputs are controlled, in `payroll_run.sql`; what belongs here is
    -- that the demo carries the flag and that the bonus month costs
    -- more than an ordinary one.
    perform pg_temp.check_true('a bonus month costs more than an ordinary one',
      v_bonus_pcb > v_other * 2);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- The counter that had never taken money (0449)
--
-- `demo_pos_sinar` built the outlet, two registers and the walk-in
-- customer and then said so itself: "No sale has been rung through it
-- yet." It was the last gap left by the sweep 0448 came from -- every
-- demo tenant, every org-scoped table, attributed to the narrowest
-- module whose tenants are a superset of the tenants that populate it.
-- ---------------------------------------------------------------------
do $$
declare
  v_sinar uuid;
  v_n     integer;
begin
  select id into v_sinar from public.organizations
   where name = 'Sinar Teknologi Sdn Bhd';

  select count(*) into v_n from public.pos_sales
   where org_id = v_sinar and status = 'completed';
  perform pg_temp.check_eq('the counter took money', v_n, 1);

  select count(*) into v_n
    from public.pos_tenders t
    join public.pos_sales s on s.id = t.sale_id
   where s.org_id = v_sinar;
  perform pg_temp.check_eq('and it was tendered for', v_n, 1);

  -- The sale is refused unless it is paid for in full, which the seed
  -- exercises by offering half first. If that ever starts being
  -- accepted there would be two tenders here, not one.
  perform pg_temp.check_eq('a sale that is not paid for is refused',
    (select count(*)::integer from public.pos_tenders t
       join public.pos_sales s on s.id = t.sale_id
      where s.org_id = v_sinar), 1);

  select count(*) into v_n
    from public.pos_shifts s
    join public.pos_registers r on r.id = s.register_id
   where r.org_id = v_sinar and s.status = 'closed';
  perform pg_temp.check_eq('the till was cashed up', v_n, 1);

  -- Sinar is SST-registered, which is what makes this counter worth
  -- ringing: the other POS tenants do not charge it.
  perform pg_temp.check_true('and tax was charged over the counter',
    (select coalesce(sum(s.tax_amount), 0) > 0 from public.pos_sales s
      where s.org_id = v_sinar and s.status = 'completed'));

  -- And the goods left the warehouse. This is asserted through the
  -- invoice the sale raises, because that is how POS moves stock: the
  -- delivery is against the `sales_documents` row, so a movement with
  -- `source_table = 'pos_sales'` does not exist and never did. Looking
  -- for one is what made this appear broken for an hour, and the
  -- assertion is written this way so nobody repeats it.
  perform pg_temp.check_true('and the goods left the warehouse',
    exists (select 1
              from public.pos_sales s
              join public.stock_movements m
                on m.source_table = 'sales_documents'
               and m.source_id = s.invoice_id
             where s.org_id = v_sinar
               and s.status = 'completed'
               and m.movement_type = 'sales_delivery'
               and m.quantity < 0));
end $$;

-- ---------------------------------------------------------------------
-- And what the teardown leaves behind
-- ---------------------------------------------------------------------
-- Last, because it takes the whole demo away. A firm is not a company:
-- `demo_teardown` deletes organizations and demo logins, and the
-- `firms` row survives both -- with nobody in it and nothing under it.
--
-- That is not merely untidy. `demo_practice_rebuild` finds its firm
-- through the partner's membership, which the teardown has just swept,
-- so an empty firm left standing is invisible to the next run and a
-- second firm appears beside it. Then a third. 0485 clears it away.
do $$
declare
  v_before integer;
  v_after  integer;
begin
  select count(*) into v_before from public.firms;
  perform pg_temp.check_true('the demo built a firm', v_before > 0);

  perform app.demo_teardown();

  select count(*) into v_after from public.firms;
  perform pg_temp.check_eq(
    'a firm nobody is left in goes with the teardown', v_after, 0);
end $$;

rollback;
