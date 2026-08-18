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

  perform pg_temp.check_eq('three demo companies', v_orgs, 3);
  perform pg_temp.check_eq('five demo logins', v_users, 5);

  -- --------------------------------------------------------------
  -- The promise on the sign-in page
  -- --------------------------------------------------------------
  select m.role::text into v_role
    from public.org_members m join auth.users u on u.id = m.user_id
   where u.email = 'auditor@iakauntan.my';
  perform pg_temp.check_true(
    'auditor@ is an auditor, which is what the picker says it is — it '
    'used to be an admin of the demo company', v_role = 'auditor');

  select m.role::text into v_role
    from public.org_members m join auth.users u on u.id = m.user_id
   where u.email = 'clerk@iakauntan.my';
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
end $$;

rollback;
