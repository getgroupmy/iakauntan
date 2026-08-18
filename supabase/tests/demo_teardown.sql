-- =====================================================================
-- iAkauntan :: tearing down demo tenants
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_teardown.sql
--
-- `app.demo_teardown()` deletes companies. On this deployment it runs
-- against a project that also carries a real tenant, so the assertion
-- that matters is not "does it delete the demo data" — it is **does it
-- refuse when the flag is wrong**.
--
-- A flag set by mistake is survivable. A teardown that trusts the flag
-- and deletes a real company's books is not, and no amount of care in
-- setting the flag makes the second one acceptable. So the refusal is
-- tested first and tested hardest, and the successful deletion is tested
-- afterwards to prove the refusal is not simply "it never deletes
-- anything".
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A user carrying the demo flag, which is what the teardown keys off.
create or replace function pg_temp.demo_user(p_email text, p_demo boolean)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, email, encrypted_password, raw_app_meta_data,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (v, p_email, crypt('Demo!Akaun2026', gen_salt('bf')),
          case when p_demo then jsonb_build_object('demo', true)
               else '{}'::jsonb end,
          '', '', '', '', '', '', '', '');
  return v;
end; $$;

create or replace function pg_temp.plain_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name,' ','-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  -- add_creator_as_owner may already have done this; make it certain
  -- without duplicating.
  insert into public.org_members (org_id, user_id, role)
  values (v, p_owner, 'owner')
  on conflict (org_id, user_id) do nothing;
  return v;
end; $$;

-- ---------------------------------------------------------------------
-- The refusal
-- ---------------------------------------------------------------------
do $$
declare
  v_demo_user uuid := pg_temp.demo_user('td-demo@iakauntan.test', true);
  v_real_user uuid := pg_temp.demo_user('td-real@example.test', false);
  v_org       uuid;
  v_ok        boolean := false;
  v_msg       text;
  v_still     boolean;
begin
  -- A company flagged demo that a real person is a member of. This is
  -- the mistake the guard exists for.
  v_org := pg_temp.plain_org('Wrongly Flagged Sdn Bhd', v_demo_user);
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_real_user, 'accountant');
  update public.organizations set is_demo = true where id = v_org;

  begin
    perform app.demo_teardown();
  exception when others then v_ok := true; v_msg := sqlerrm;
  end;

  perform pg_temp.check_true(
    'a demo-flagged company with a real member is not torn down', v_ok);
  perform pg_temp.check_true(
    'and the refusal names the account, so the flag can be fixed',
    coalesce(v_msg, '') like '%td-real@example.test%');

  select exists (select 1 from public.organizations where id = v_org)
    into v_still;
  perform pg_temp.check_true('and the company is still there', v_still);
end $$;

rollback;

-- ---------------------------------------------------------------------
-- The deletion, in a transaction of its own
--
-- Separate because the block above deliberately raised inside a
-- subtransaction, and mixing a genuine teardown into the same fixture
-- would leave it unclear which company each assertion is about.
-- ---------------------------------------------------------------------
begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.demo_user(p_email text, p_demo boolean)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, email, encrypted_password, raw_app_meta_data,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (v, p_email, crypt('Demo!Akaun2026', gen_salt('bf')),
          case when p_demo then jsonb_build_object('demo', true)
               else '{}'::jsonb end,
          '', '', '', '', '', '', '', '');
  return v;
end; $$;

create or replace function pg_temp.plain_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name,' ','-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  insert into public.org_members (org_id, user_id, role)
  values (v, p_owner, 'owner')
  on conflict (org_id, user_id) do nothing;
  return v;
end; $$;

do $$
declare
  v_demo_user uuid := pg_temp.demo_user('td-demo2@iakauntan.test', true);
  v_real_user uuid := pg_temp.demo_user('td-real2@example.test', false);
  v_demo_org  uuid;
  v_real_org  uuid;
  v_group     uuid;
  v_conv      uuid;
  v_report    text;
begin
  v_demo_org := pg_temp.plain_org('Proper Demo Sdn Bhd', v_demo_user);
  update public.organizations set is_demo = true where id = v_demo_org;

  v_real_org := pg_temp.plain_org('Real Books Sdn Bhd', v_real_user);

  -- A platform invoice, whose foreign key is `restrict` rather than
  -- `cascade`: it does not follow the company out, it *blocks* the
  -- delete. Seeded deliberately so this assertion is about a company
  -- that actually had one, and would fail outright if the teardown
  -- stopped clearing it.
  insert into public.platform_invoices
    (invoice_no, org_id, issue_date, currency, issuer_name, bill_to_name,
     description, subtotal, tax_rate, tax_amount, total_amount, status)
  values ('DEMO-TD-1', v_demo_org, current_date, 'MYR', 'iAkauntan',
          'Proper Demo Sdn Bhd', 'Subscription', 100, 0, 0, 100, 'issued');

  -- Two references to the demo user that no organization will carry out
  -- with it, because neither table has an organization at all.
  --
  -- `chat_conversations.created_by` is the one that actually broke this:
  -- a single conversation started by a demo user makes the delete fail
  -- with 23503 on chat_conversations_created_by_fkey, *after* the
  -- companies are already gone. Verified against the hosted project by
  -- reproducing the old teardown step by step.
  --
  -- `company_groups` is here for the other half of the rule: it is
  -- nullable, so the row must survive with its creator forgotten rather
  -- than be deleted along with the user.
  insert into public.chat_conversations (created_by) values (v_demo_user)
    returning id into v_conv;
  insert into public.company_groups (name, created_by)
    values ('Teardown Probe Group', v_demo_user)
    returning id into v_group;

  -- 0183 stops the audit trigger writing a row for a tenant's own
  -- deletion, because that row references the company that is going and
  -- the insert fails. The guard has to be exactly that and no wider, so
  -- prove an ordinary update is still audited before relying on it.
  update public.organizations set phone = '03-9999 0000' where id = v_demo_org;
  perform pg_temp.check_true(
    'an update to a company is still written to the audit trail',
    exists (select 1 from public.audit_logs
             where org_id = v_demo_org and table_name = 'organizations'
               and action = 'update'));

  -- 0184's guard must not be wider than the problem: an ordinary delete
  -- inside a company that still exists has to go on being audited.
  -- tax_codes rather than contacts, because contacts carries no
  -- audit_changes trigger at all and a control measuring nothing passes
  -- for the wrong reason.
  insert into public.tax_codes (org_id, code, name, tax_type_code, rate,
    applies_to, is_exempt, is_default)
  values (v_demo_org, 'TDX', 'Teardown Probe', '06', 0, 'both', false, false);
  delete from public.tax_codes where org_id = v_demo_org and code = 'TDX';
  perform pg_temp.check_true(
    'an ordinary delete in a living company is still audited',
    exists (select 1 from public.audit_logs
             where org_id = v_demo_org and table_name = 'tax_codes'
               and action = 'delete'));

  v_report := app.demo_teardown();
  raise notice 'teardown said: %', v_report;

  perform pg_temp.check_true(
    'the demo company is gone',
    not exists (select 1 from public.organizations where id = v_demo_org));
  perform pg_temp.check_true(
    'its platform invoice went too, though that key is restrict and '
    'would otherwise have blocked the whole delete',
    not exists (select 1 from public.platform_invoices where org_id = v_demo_org));
  perform pg_temp.check_true(
    'the demo user is gone, having nothing left to belong to',
    not exists (select 1 from auth.users where id = v_demo_user));

  perform pg_temp.check_true(
    'the conversation it started no longer names it — without this the '
    'whole teardown fails on a foreign key after the companies are gone',
    exists (select 1 from public.chat_conversations
             where id = v_conv and created_by is null));

  perform pg_temp.check_true(
    'and the company group it created survives, with its creator '
    'forgotten rather than the row deleted: the column is nullable, so '
    'erasing the demo identity does not mean erasing the record',
    exists (select 1 from public.company_groups
             where id = v_group and created_by is null));

  -- The control. Everything above passes equally well if the function
  -- deleted the entire database, so name what had to survive.
  perform pg_temp.check_true(
    'the real company is untouched',
    exists (select 1 from public.organizations where id = v_real_org));
  perform pg_temp.check_true(
    'and so is the real user',
    exists (select 1 from auth.users where id = v_real_user));
end $$;

rollback;

-- =====================================================================
-- The flag disagreeing with reality, the other way round
--
-- The first transaction covers a real person inside a company marked
-- demo. This is its mirror: a demo login that is a member of a company
-- which is *not* marked demo — which is what happens the moment a
-- visitor signed in as `demo@` presses "create company".
--
-- The old teardown did not fail on this. It did something worse: it
-- skipped that user, because it only removed demo users with no
-- membership at all, and reported success. The next rebuild then died on
-- the unique email index with everything else already deleted, and the
-- error mentioned neither the company nor the person who made it.
--
-- So it must refuse, and it must refuse *before* deleting anything.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.demo_user(p_email text, p_demo boolean)
returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, email, encrypted_password, raw_app_meta_data,
    confirmation_token, recovery_token, email_change_token_new,
    email_change_token_current, phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (v, p_email, crypt('Demo!Akaun2026', gen_salt('bf')),
          case when p_demo then jsonb_build_object('demo', true)
               else '{}'::jsonb end,
          '', '', '', '', '', '', '', '');
  return v;
end;
$$;

create or replace function pg_temp.plain_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name,' ','-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  insert into public.org_members (org_id, user_id, role)
  values (v, p_owner, 'owner')
  on conflict (org_id, user_id) do nothing;
  return v;
end; $$;

do $$
declare
  v_demo_user uuid := pg_temp.demo_user('td-demo3@iakauntan.test', true);
  v_demo_org  uuid;
  v_their_org uuid;
  v_refused   boolean := false;
  v_message   text;
begin
  v_demo_org := pg_temp.plain_org('Proper Demo 3 Sdn Bhd', v_demo_user);
  update public.organizations set is_demo = true where id = v_demo_org;

  -- The company the demo login made for itself. Nothing marks it demo,
  -- because create_organization does not.
  v_their_org := pg_temp.plain_org('Made By A Visitor Sdn Bhd', v_demo_user);

  begin
    perform app.demo_teardown();
  exception when insufficient_privilege then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform pg_temp.check_true(
    'it refuses when a demo login belongs to a company that is not '
    'flagged, rather than silently leaving the account behind for the '
    'next rebuild to trip over', v_refused);

  perform pg_temp.check_true(
    'and it names the company, so whoever reads the error knows what to '
    'decide about: ' || coalesce(v_message, '(no message)'),
    v_message like '%Made By A Visitor Sdn Bhd%');

  -- It has to refuse before it deletes, not part way through. A teardown
  -- that removes the companies and then raises has already done the
  -- damage the refusal exists to prevent.
  perform pg_temp.check_true(
    'the demo company is still there, so nothing was deleted before the '
    'refusal',
    exists (select 1 from public.organizations where id = v_demo_org));
  perform pg_temp.check_true(
    'and so is the one the visitor made',
    exists (select 1 from public.organizations where id = v_their_org));
  perform pg_temp.check_true(
    'and the account itself',
    exists (select 1 from auth.users where id = v_demo_user));
end $$;

rollback;
