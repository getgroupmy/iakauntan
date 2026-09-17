-- =====================================================================
-- iAkauntan :: reporting across a company group
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/group_reporting.sql
--
-- A combined trial balance is a statutory-looking number, and the two
-- ways it goes wrong are both silent:
--
--   it includes a company the person asking may not read, or
--   it adds two currencies together and calls the total money.
--
-- Both are asserted here, each against the thing that must still work.
--
-- The fixture posts GL entries directly rather than through the sales
-- pipeline, and that is deliberate: the reports read the ledger, so the
-- ledger is what they should be tested against — and writing the lines
-- by hand pins the shape that matters, which is a sales invoice whose
-- receivable and revenue carry the contact and whose tax line does not.
-- That asymmetry is what makes naive elimination unbalance the report.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.grp_org(
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

-- One balanced entry shaped like a posted sales invoice: the receivable
-- and the revenue carry the contact, the tax line does not.
create or replace function pg_temp.grp_invoice(
  p_org uuid, p_contact uuid, p_net numeric, p_tax numeric)
returns void language plpgsql as $$
declare v_entry uuid; v_ar uuid; v_rev uuid; v_tax uuid;
begin
  select id into v_ar from public.accounts
   where org_id = p_org and account_subtype = 'accounts_receivable'
     and not is_group limit 1;
  select id into v_rev from public.accounts
   where org_id = p_org and account_type = 'revenue' and not is_group limit 1;
  select id into v_tax from public.accounts
   where org_id = p_org and account_subtype = 'tax_payable'
     and not is_group limit 1;

  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (p_org, 'IC-' || substr(gen_random_uuid()::text, 1, 8), current_date,
          'sales_invoice', 'intercompany', p_net + p_tax, p_net + p_tax,
          'posted', now())
  returning id into v_entry;

  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, debit, credit, contact_id)
  values (p_org, v_entry, 1, v_ar,  p_net + p_tax, 0,     p_contact),
         (p_org, v_entry, 2, v_rev, 0,             p_net, p_contact),
         (p_org, v_entry, 3, v_tax, 0,             p_tax, null);
end; $$;

do $$
declare
  v_boss    uuid := pg_temp.another_user('boss@group.test');
  v_outsider uuid := pg_temp.another_user('outsider@group.test');
  v_group uuid; v_a uuid; v_b uuid; v_c uuid;
  v_contact_a uuid; v_contact_b uuid;
  v_n int; v_amount numeric; v_revenue numeric;
  v_role text;
begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Ujian', v_boss) returning id into v_group;

  v_a := pg_temp.grp_org('Group A Sdn Bhd', v_boss, v_group);
  v_b := pg_temp.grp_org('Group B Sdn Bhd', v_boss, v_group);
  -- In the same group, and the boss is not a member of it. Everything
  -- below turns on this company staying out of his numbers.
  v_c := pg_temp.grp_org('Group C Sdn Bhd', v_outsider, v_group);

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-B', 'Group B', 'customer', v_b) returning id into v_contact_a;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'IC-A', 'Group A', 'supplier', v_a) returning id into v_contact_b;

  -- A invoices B for 1,000 plus 60 of SST. C trades on its own account.
  perform pg_temp.grp_invoice(v_a, v_contact_a, 1000, 60);
  perform pg_temp.grp_invoice(v_c, null, 5000, 300);

  perform pg_temp.sign_in_as(v_boss);

  perform pg_temp.check_eq('a combined report covers only the companies '
    'the person belongs to', (select count(*) from app.group_orgs(v_a)), 2);

  -- The assertion the whole design turns on. Naive elimination drops the
  -- receivable and the revenue and leaves the tax line behind, and this
  -- is what catches it.
  perform pg_temp.check_eq('the combined trial balance balances',
    (select round(sum(t.debit) - sum(t.credit), 2)
       from public.report_group_trial_balance(v_a) t), 0);

  select t.closing_balance into v_amount
    from public.report_group_trial_balance(v_a) t
   where t.account_subtype = 'accounts_receivable';
  perform pg_temp.check_eq(
    'the receivable is A''s 1,060 and not C''s 5,300 as well',
    v_amount, 1060);

  select t.closing_balance into v_revenue
    from public.report_group_trial_balance(v_a) t
   where t.account_type = 'revenue';
  perform pg_temp.check_eq('and the revenue is A''s 1,000', v_revenue, -1000);

  -- What a consolidation would have to remove, shown rather than done.
  perform pg_temp.check_eq('one inter-company relationship is reported',
    (select count(*) from public.report_group_intercompany(v_a)), 1);

  select r.receivable, r.revenue into v_amount, v_revenue
    from public.report_group_intercompany(v_a) r;
  perform pg_temp.check_eq('the inter-company receivable', v_amount, 1060);
  perform pg_temp.check_eq('and the inter-company turnover', v_revenue, 1000);

  -- ---------------------------------------------------------------
  -- Two currencies are refused, not added
  -- ---------------------------------------------------------------
  update public.organizations set base_currency = 'SGD' where id = v_b;
  -- On the words. Three of the four refusals in this file are 42501
  -- and they are three different rules, so recording only that
  -- something failed passes when the wrong one fires -- and passes
  -- with the rule under test deleted.
  perform pg_temp.check_refused(
    'ringgit and dollars are refused rather than summed into a number '
    'that looks like money and is not',
    format($q$ select count(*) from public.report_group_trial_balance(%L) $q$,
           v_a),
    '%different currencies%', '22000');
  -- A caught exception rolls back to a savepoint and takes the sign-in
  -- with it. `check_refused` catches too, so this is still needed.
  perform pg_temp.sign_in_as(v_boss);

  update public.organizations set base_currency = 'MYR' where id = v_b;
  perform pg_temp.check_true('and with one currency the report works again',
    (select count(*) from public.report_group_trial_balance(v_a)) > 0);

  -- ---------------------------------------------------------------
  -- The group names a relationship; it does not open the books
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_outsider);
  perform pg_temp.check_refused(
    'somebody in the group but not in that company cannot report on it',
    format($q$ select count(*) from public.report_group_trial_balance(%L) $q$,
           v_a),
    '%not a member of this company%', '42501');
  perform pg_temp.sign_in_as(v_outsider);
  perform pg_temp.check_true('while their own company reports normally',
    (select count(*) from public.report_group_trial_balance(v_c)) > 0);

  -- And the reports are reachable by an ordinary client, not only by a
  -- superuser — a grant this test would otherwise never exercise.
  perform pg_temp.sign_in_as(v_boss);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_n from public.report_group_trial_balance(v_a);
  end;
  reset role;
  perform pg_temp.check_true('the report ran as a signed-in client',
    v_role = 'authenticated');
  perform pg_temp.check_true('and returned rows', v_n > 0);
end $$;

-- ---------------------------------------------------------------------
-- Linking a contact to a company you cannot see
-- ---------------------------------------------------------------------
do $$
declare
  v_boss  uuid := pg_temp.another_user('boss2@group.test');
  v_other uuid := pg_temp.another_user('other2@group.test');
  v_group uuid; v_a uuid; v_b uuid; v_hidden uuid; v_contact uuid;

begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Dua', v_boss) returning id into v_group;
  v_a      := pg_temp.grp_org('Two A Sdn Bhd', v_boss, v_group);
  v_b      := pg_temp.grp_org('Two B Sdn Bhd', v_boss, v_group);
  v_hidden := pg_temp.grp_org('Two Hidden Sdn Bhd', v_other, v_group);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_a, 'C-1', 'Somebody', 'customer') returning id into v_contact;

  perform pg_temp.sign_in_as(v_boss);

  -- A company in the group that this person is not a member of.
  perform pg_temp.check_refused(
    'a contact cannot be pointed at a group company you are not in — '
    'otherwise linking becomes a way to discover which companies exist',
    format($q$ select public.link_group_contact(%L, %L) $q$,
           v_contact, v_hidden),
    '%not a company in this group that you belong to%', '42501');
  perform pg_temp.sign_in_as(v_boss);

  -- Itself.
  perform pg_temp.check_refused('and a company cannot be its own customer',
    format($q$ select public.link_group_contact(%L, %L) $q$, v_contact, v_a),
    '%cannot be its own customer%', '42501');
  perform pg_temp.sign_in_as(v_boss);

  -- The control for both. Without it the two refusals above would pass
  -- for a function that refuses everything, including a broken one.
  perform public.link_group_contact(v_contact, v_b);
  perform pg_temp.check_true(
    'while the other company in the group, which he is in, links',
    (select linked_org_id = v_b from public.contacts where id = v_contact));

  -- And unlinking, which asserts nothing and so is always allowed.
  perform public.link_group_contact(v_contact, null);
  perform pg_temp.check_true('and it can be unlinked again',
    (select linked_org_id is null from public.contacts where id = v_contact));
end $$;

rollback;
