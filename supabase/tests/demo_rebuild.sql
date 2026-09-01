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

  perform pg_temp.check_eq('six demo companies', v_orgs, 6);
  perform pg_temp.check_eq('eight demo logins', v_users, 8);

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
        and a.code in ('4100', '2130')));

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
        where e.org_id = v_amanah and e.status = 'posted' and a.code = '4100')
    and (select coalesce(sum(l.credit - l.debit), 0) from public.gl_lines l
           join public.gl_entries e on e.id = l.entry_id
           join public.accounts a on a.id = l.account_id
          where e.org_id = v_amanah and e.status = 'posted'
            and a.code = '4100') > 0);

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
    known text[] := array[
      -- Nobody has demonstrated a pipeline in any tenant.
      'crm',
      -- Submitting to LHDN needs credentials, and `demo_credentials_locked`
      -- withholds them on purpose. A submission row would be a lie.
      'einvoice',
      -- Sinar is the only tenant that buys anything.
      'purchases',
      -- Written for Sinar's scale; the other tenants approve nothing.
      'approvals',
      'branches', 'manufacturing', 'timesheets', 'legal', 'fixed_assets'];
  begin
    for r in
      with probe(module_code, tbl) as (values
        ('approvals','approval_rules'), ('branches','branches'),
        ('crm','leads'), ('einvoice','einvoice_submissions'),
        ('fixed_assets','fixed_assets'), ('forecasting','forecast_runs'),
        ('hr','employees'), ('inventory','warehouses'),
        ('legal','matters'), ('manufacturing','manufacturing_orders'),
        ('mbrs','fs_filings'), ('memberships','pos_memberships'),
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
         and not (om.module_code = any (known))
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
          and not (om.module_code = any (known))) > 10);

    perform pg_temp.check_eq(
      'and a module a demo tenant has bought has something in it',
      coalesce(array_to_string(gaps, ', '), ''), '');
  end;
end $$;

rollback;
