-- The three demo tenants, and the one call that rebuilds them.
--
-- `0182` gave the demo data a guarded way out and `0185` the pieces to
-- build it again. This assembles them into `app.demo_rebuild()`: tear
-- down, then seed, in one transaction. It is defined here and called by
-- hand — nothing in this file runs on migrate.
--
-- ## Why three companies
--
-- Because twenty modules do not fit in one. A trading company that also
-- manages strata schemes and files other people's annual returns is not
-- a demo, it is a shop window with everything in it. Each tenant is a
-- plausible business, and between them they light up the whole
-- catalogue:
--
--     Sinar Teknologi     trading and light manufacturing, SST
--                         registered, with staff on payroll
--     Amanah Setiausaha   a company secretarial and legal practice
--                         acting for other companies
--     Harta Prima         a property manager running one strata scheme
--                         and one commercial block
--
-- Every one of the twenty active modules is enabled on exactly one of
-- them, so nothing in the app opens to an empty screen and nothing is
-- enabled where it makes no sense.
--
-- ## The roles the sign-in page has always advertised
--
-- `demo_accounts.dart` describes `auditor@` as "Reads the ledger,
-- writes nothing" and `clerk@` as "Can prepare documents, cannot post
-- to the ledger". The seeded data said otherwise: `auditor@` was an
-- `admin` of the demo company and `clerk@` was a `purchaser`. The first
-- of those matters — the account offered as read-only could change
-- anything. Seeded here as `auditor` and `accounts_clerk`.
--
-- ## Idempotent by demolition
--
-- Not `on conflict do nothing` — a genuine teardown first. Demo data
-- that is topped up rather than rebuilt accumulates: last month's
-- invoices sit behind this month's, numbering drifts, and the figures
-- stop adding up in ways nobody can explain. `app.demo_teardown()`
-- refuses if a flagged company holds a real member, so the rebuild
-- inherits that protection unchanged.

create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed   text;
  v_demo      uuid;
  v_clerk     uuid;
  v_auditor   uuid;
  v_secretary uuid;
  v_property  uuid;
  v_sinar     uuid;
  v_amanah    uuid;
  v_harta     uuid;
begin
  -- Refuses of its own accord if a flagged company has a real member.
  v_removed := app.demo_teardown();

  -- ------------------------------------------------------------------
  -- The logins. These four addresses are compiled into the Flutter
  -- bundle; the fifth is new and goes with the property tenant.
  -- ------------------------------------------------------------------
  v_demo      := app.demo_user('demo@iakauntan.my',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.my',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.my',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.my', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.my',  'Tan Chee Keong');

  -- ------------------------------------------------------------------
  -- Sinar Teknologi Sdn Bhd — trading and light manufacturing
  --
  -- SST registered, and registered *through* set_sst_registration()
  -- rather than by passing the flag to create_organization(). The
  -- second would leave the boolean true with no effective date and a
  -- zero-rated default — the exact broken state 0181 exists to prevent,
  -- and not something the demo should be teaching.
  -- ------------------------------------------------------------------
  v_sinar := app.demo_company(
    v_demo, 'Sinar Teknologi Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201901004567', 'C20194567890', '46510',
    'Wholesale of computers and peripherals',
    '10', 'Petaling Jaya', '46200',
    'Level 8, Menara Sinar, Jalan Utara', '03-7955 1200',
    'accounts@sinartek.demo', 12::smallint);

  perform public.set_sst_registration(
    v_sinar, true, date_trunc('year', current_date)::date - 365,
    'W10-1808-31000123', 'ST8');

  perform app.demo_member(v_sinar, v_clerk,   'accounts_clerk');
  perform app.demo_member(v_sinar, v_auditor, 'auditor');

  perform app.demo_modules(v_sinar, array[
    'einvoice', 'purchases', 'inventory', 'crm', 'hr', 'payroll',
    'fixed_assets', 'approvals', 'manufacturing', 'branches',
    'timesheets', 'chat', 'mbrs']);

  -- ------------------------------------------------------------------
  -- Amanah Setiausaha Sdn Bhd — company secretarial and legal practice
  --
  -- Not SST registered: a small practice under the threshold, which is
  -- the commoner case and worth showing beside a registered one.
  -- ------------------------------------------------------------------
  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);

  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat']);

  -- ------------------------------------------------------------------
  -- Harta Prima Management Sdn Bhd — property manager
  --
  -- Both property modules on one tenant deliberately: a managing agent
  -- with a strata scheme and a commercial block is ordinary, and it is
  -- the only way to show the two halves side by side.
  -- ------------------------------------------------------------------
  v_harta := app.demo_company(
    v_property, 'Harta Prima Management Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202101007890', 'C20217890123', '68201',
    'Property management on a fee or contract basis',
    '10', 'Shah Alam', '40150',
    'Ground Floor, Blok A, Pusat Perniagaan Harta', '03-5511 4400',
    'admin@hartaprima.demo', 12::smallint);

  perform app.demo_modules(v_harta, array[
    'property_strata', 'property_nonstrata', 'purchases', 'fixed_assets',
    'approvals', 'chat']);

  -- The claim is transaction-local and would expire with this call
  -- anyway; cleared explicitly so nothing later in the same transaction
  -- runs as the last demo owner by accident.
  perform set_config('request.jwt.claims', '', true);

  return format(
    '%s Rebuilt: Sinar Teknologi (%s), Amanah Setiausaha (%s), '
    'Harta Prima (%s); 5 demo logins.',
    v_removed, v_sinar, v_amanah, v_harta);
end $$;

comment on function app.demo_rebuild() is
  'Tears down every is_demo company and rebuilds the three demo tenants '
  'with their logins, roles and module entitlements. Called by hand, '
  'never on migrate. Refuses if a flagged company holds a real member.';

revoke all on function app.demo_rebuild() from public, anon, authenticated;
