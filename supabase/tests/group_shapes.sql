-- =====================================================================
-- iAkauntan :: what belongs in a consolidation, and what does not
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/group_shapes.sql
--
-- `group_consolidation.sql` carries the assertion that matters most --
-- the eliminations sum to zero -- and pins the four directions the
-- adjustment can go in. A mutation sweep of the five functions behind
-- it killed 17 of 37.
--
-- What lived was the SELECTION. `app.group_intercompany_lines` is one
-- query with eight conditions on it, and the fixture posts one pair of
-- entries between two companies in one group on one day: an entry
-- outside the period, an unposted entry, a company outside the group,
-- a bank line, a line with no contact on it, and a company trading with
-- itself are all rows that query exists to exclude, and none of them
-- had ever been written.
--
-- A consolidation that eliminates the wrong thing does not fail loudly.
-- It produces a balanced set of accounts that is wrong by whatever was
-- taken out, which is the one error an auditor cannot see by looking.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.gs_org(
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
end $$;

-- A management fee in one direction: the seller's invoice in the
-- seller's ledger, and nothing in the buyer's unless asked for.
create or replace function pg_temp.gs_sale(
  p_seller uuid, p_contact uuid, p_no text, p_net numeric, p_tax numeric,
  p_on date, p_status text default 'posted')
returns uuid language plpgsql as $$
declare v_e uuid; v_ar uuid; v_rev uuid; v_tax uuid;
begin
  select id into v_ar from public.accounts where org_id = p_seller
    and account_subtype = 'accounts_receivable' and not is_group order by code limit 1;
  select id into v_rev from public.accounts where org_id = p_seller
    and account_type = 'revenue' and not is_group order by code limit 1;
  select id into v_tax from public.accounts where org_id = p_seller
    and account_subtype = 'tax_payable' and not is_group order by code limit 1;
  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (p_seller, p_no, p_on, 'sales_invoice', 'inter-company',
          p_net + p_tax, p_net + p_tax, p_status,
          case when p_status = 'posted' then now() end)
  returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit, contact_id)
  values (p_seller, v_e, 1, v_ar,  p_net + p_tax, 0, p_contact),
         (p_seller, v_e, 2, v_rev, 0, p_net, p_contact),
         (p_seller, v_e, 3, v_tax, 0, p_tax, null);
  return v_e;
end $$;

create or replace function pg_temp.gs_purchase(
  p_buyer uuid, p_contact uuid, p_no text, p_net numeric, p_tax numeric,
  p_on date, p_status text default 'posted')
returns uuid language plpgsql as $$
declare v_e uuid; v_ap uuid; v_exp uuid; v_in uuid;
begin
  select id into v_ap from public.accounts where org_id = p_buyer
    and account_subtype = 'accounts_payable' and not is_group order by code limit 1;
  select id into v_exp from public.accounts where org_id = p_buyer
    and account_type = 'expense' and not is_group order by code limit 1;
  select id into v_in from public.accounts where org_id = p_buyer
    and code = '1410' order by code limit 1;
  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (p_buyer, p_no, p_on, 'purchase_bill', 'inter-company',
          p_net + p_tax, p_net + p_tax, p_status,
          case when p_status = 'posted' then now() end)
  returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit, contact_id)
  values (p_buyer, v_e, 1, v_exp, p_net, 0, p_contact),
         (p_buyer, v_e, 2, v_in,  p_tax, 0, null),
         (p_buyer, v_e, 3, v_ap,  0, p_net + p_tax, p_contact);
  return v_e;
end $$;

-- =====================================================================
-- 1. Which companies are in the group at all
-- =====================================================================
do $$
declare
  v_boss  uuid;
  v_other uuid;
  v_g1    uuid;
  v_g2    uuid;
  v_a     uuid;
  v_b     uuid;
  v_alone uuid;
  v_theirs uuid;
begin
  v_boss  := pg_temp.another_user('gsboss@example.test');
  v_other := pg_temp.another_user('gsother@example.test');

  insert into public.company_groups (name, created_by)
  values ('Kumpulan Satu', v_boss) returning id into v_g1;
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Dua', v_other) returning id into v_g2;

  v_a := pg_temp.gs_org('Shapes A Sdn Bhd', v_boss, v_g1);
  v_b := pg_temp.gs_org('Shapes B Sdn Bhd', v_boss, v_g1);
  update public.organizations set parent_org_id = v_a where id = v_b;

  -- MUTANT: `o.group_id is not null` dropped. A company that belongs to
  -- no group would join every group's consolidation, because
  -- `null = null` is not true but `is not null` is what stops the
  -- comparison being reached at all.
  v_alone := pg_temp.gs_org('Shapes Alone Sdn Bhd', v_boss, null);

  -- MUTANT: the group_id comparison dropped. Another proprietor's
  -- company, in another group, consolidated into this one.
  v_theirs := pg_temp.gs_org('Shapes Theirs Sdn Bhd', v_boss, v_g2);

  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_eq('the group is the two companies in it',
    (select count(*) from app.group_orgs(v_a)), 2);
  perform pg_temp.check_eq('a company in no group is not in this one',
    (select count(*) from app.group_orgs(v_a) g where g.org_id = v_alone), 0);
  perform pg_temp.check_eq('nor is a company in another group',
    (select count(*) from app.group_orgs(v_a) g where g.org_id = v_theirs), 0);
  -- The positive control: a company with no group has no group, rather
  -- than a group of one.
  perform pg_temp.check_eq('and a company in no group has no group at all',
    (select count(*) from app.group_orgs(v_alone)), 0);

  -- MUTANT: `app.is_org_member(p_org_id)` dropped. `group_orgs` is
  -- SECURITY DEFINER and every consolidation report is built on it, so
  -- that one condition is what stops a stranger reading a group's
  -- companies -- and then, through the reports above it, their ledgers.
  perform pg_temp.sign_out();
  perform pg_temp.sign_in_as(pg_temp.another_user('gsstranger@example.test'));
  perform pg_temp.check_eq('a stranger sees no companies in the group',
    (select count(*) from app.group_orgs(v_a)), 0);
  perform pg_temp.check_refused('and cannot read the inter-company check',
    format($q$ select * from public.report_group_elimination_check(%L) $q$, v_a),
    '%not a member%', '42501');
  perform pg_temp.sign_out();

  raise notice 'ok   which companies are in the group at all';
end $$;

-- =====================================================================
-- 2. Which lines are inter-company
-- =====================================================================
do $$
declare
  v_boss    uuid;
  v_g       uuid;
  v_a       uuid;
  v_b       uuid;
  v_outside uuid;
  v_ca      uuid;
  v_cb      uuid;
  v_cout    uuid;
  v_cself   uuid;
  v_bank_a  uuid;
  v_e       uuid;
begin
  perform pg_temp.allow_many_companies();
  v_boss := pg_temp.another_user('gsboss2@example.test');
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Garis', v_boss) returning id into v_g;

  v_a := pg_temp.gs_org('Garis A Sdn Bhd', v_boss, v_g);
  v_b := pg_temp.gs_org('Garis B Sdn Bhd', v_boss, v_g);
  update public.organizations set parent_org_id = v_a where id = v_b;
  v_outside := pg_temp.gs_org('Garis Luar Sdn Bhd', v_boss, null);

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-B', 'Garis B', 'customer', v_b) returning id into v_ca;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'IC-A', 'Garis A', 'supplier', v_a) returning id into v_cb;

  -- MUTANT: `c.linked_org_id in (select org_id from orgs)` dropped. A
  -- customer linked to a company OUTSIDE the group is an ordinary
  -- customer; eliminating what they owe removes a real receivable from
  -- the consolidated balance sheet.
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'OUT', 'Garis Luar', 'customer', v_outside)
  returning id into v_cout;

  -- MUTANT: `c.linked_org_id <> l.org_id` dropped. A company linked to
  -- ITSELF -- which is what a branch record looks like before somebody
  -- corrects it -- would have its own trading eliminated against
  -- itself, taking real revenue out of the group.
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'SELF', 'Garis A itself', 'customer', v_a)
  returning id into v_cself;

  perform pg_temp.sign_in_as(v_boss);

  -- The one real inter-company pair: 1,000 plus 80 of tax.
  perform pg_temp.gs_sale(v_a, v_ca, 'A-1', 1000, 80, date '2026-03-15');
  perform pg_temp.gs_purchase(v_b, v_cb, 'B-1', 1000, 80, date '2026-03-15');

  -- And every kind of row that must not join it.
  perform pg_temp.gs_sale(v_a, v_cout,  'A-OUT',  5000, 400, date '2026-03-15');
  perform pg_temp.gs_sale(v_a, v_cself, 'A-SELF', 7000, 560, date '2026-03-15');
  perform pg_temp.gs_sale(v_a, v_ca, 'A-DRAFT', 9000, 720, date '2026-03-15',
                          'draft');
  perform pg_temp.gs_sale(v_a, v_ca, 'A-LATE', 3000, 240, date '2026-05-15');
  perform pg_temp.gs_sale(v_a, v_ca, 'A-EARLY', 2000, 160, date '2026-01-15');

  -- MUTANT: the account-type filter dropped. A bank line carrying a
  -- contact is not an inter-company balance; it is cash. The `case`
  -- returns NULL for it, so it would join with no category at all.
  select id into v_bank_a from public.accounts where org_id = v_a
    and account_subtype = 'bank' and not is_group order by code limit 1;
  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (v_a, 'A-BANK', date '2026-03-15', 'receipt', 'cash from B',
          500, 500, 'posted', now()) returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit, contact_id)
  select v_a, v_e, 1, v_bank_a, 500, 0, v_ca
  union all
  select v_a, v_e, 2,
         (select id from public.accounts where org_id = v_a
           and account_subtype = 'accounts_receivable' and not is_group order by code limit 1),
         0, 500, v_ca;

  -- What the March quarter's inter-company lines actually are: A's
  -- receivable of 1,080 less the 500 received, A's revenue of 1,000,
  -- B's payable of 1,080 and B's expense of 1,000.
  perform pg_temp.check_eq('only the four inter-company lines are counted',
    (select count(*) from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31')), 4);
  perform pg_temp.check_eq('the receivable is net of the cash received',
    (select l.amount from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31') l
      where l.org_id = v_a and l.category = 'receivable'), 580);
  perform pg_temp.check_eq('the revenue is the fee',
    (select l.amount from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31') l
      where l.org_id = v_a and l.category = 'revenue'), 1000);
  perform pg_temp.check_eq('and nothing is categorised as nothing',
    (select count(*) from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31') l
      where l.category is null), 0);
  perform pg_temp.check_eq('the outside customer is not eliminated',
    (select count(*) from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31') l
      where l.counterparty = v_outside), 0);
  -- The B-side rows legitimately have A as their counterparty, so what
  -- is asked for here is a company that is BOTH sides of one line.
  perform pg_temp.check_eq('nor is the company trading with itself',
    (select count(*) from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31') l
      where l.org_id = l.counterparty), 0);

  -- MUTANT: the `having ... <> 0` dropped. A pair that nets to nothing
  -- -- an invoice and a credit note for the same amount in the same
  -- quarter, which is a correction -- is not something to eliminate,
  -- and a line of nought in the adjustment set makes the elimination
  -- report read as though something happened.
  --
  -- A credit note is the same entry with the sides swapped, not the
  -- same entry with minus signs: `gl_lines_debit_check` refuses a
  -- negative debit, which is the ledger insisting that a reversal is a
  -- posting rather than an erasure.
  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (v_a, 'A-CN', date '2026-03-20', 'sales_invoice', 'credit to B',
          1080, 1080, 'posted', now()) returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit, contact_id)
  select v_a, v_e, 1,
         (select id from public.accounts where org_id = v_a
           and account_type = 'revenue' and not is_group order by code limit 1),
         1000, 0, v_ca
  union all
  select v_a, v_e, 2,
         (select id from public.accounts where org_id = v_a
           and account_subtype = 'tax_payable' and not is_group order by code limit 1),
         80, 0, null
  union all
  select v_a, v_e, 3,
         (select id from public.accounts where org_id = v_a
           and account_subtype = 'accounts_receivable' and not is_group order by code limit 1),
         0, 1080, v_ca;
  perform pg_temp.check_eq('a pair that cancels out leaves no line',
    (select count(*) from app.group_intercompany_lines(
       v_a, date '2026-03-01', date '2026-03-31') l
      where l.org_id = v_a and l.category = 'revenue'), 0);

  perform pg_temp.sign_out();
  raise notice 'ok   which lines are inter-company';
end $$;

-- =====================================================================
-- 3. What the check reports when the two sides disagree
-- =====================================================================
do $$
declare
  v_boss uuid;
  v_g    uuid;
  v_a    uuid;
  v_b    uuid;
  v_ca   uuid;
  v_cb   uuid;
  r      record;
begin
  perform pg_temp.allow_many_companies();
  v_boss := pg_temp.another_user('gsboss3@example.test');
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Semak', v_boss) returning id into v_g;

  v_a := pg_temp.gs_org('Semak A Sdn Bhd', v_boss, v_g);
  v_b := pg_temp.gs_org('Semak B Sdn Bhd', v_boss, v_g);
  update public.organizations set parent_org_id = v_a where id = v_b;

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-B', 'Semak B', 'customer', v_b) returning id into v_ca;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'IC-A', 'Semak A', 'supplier', v_a) returning id into v_cb;

  perform pg_temp.sign_in_as(v_boss);

  -- A raises 1,000 + 80. B has booked only 900 + 72: the bill arrived
  -- late and somebody keyed the wrong figure, which is the ordinary
  -- reason a group's two sides disagree at a quarter end.
  perform pg_temp.gs_sale(v_a, v_ca, 'A-1', 1000, 80, date '2026-03-15');
  perform pg_temp.gs_purchase(v_b, v_cb, 'B-1', 900, 72, date '2026-03-15');

  select * into r from public.report_group_elimination_check(
    v_a, date '2026-03-01', date '2026-03-31') c
   where c.what = 'Balances owed';
  perform pg_temp.check_eq('the seller''s side is what the seller booked',
    r.their_side, 1080);
  perform pg_temp.check_eq('the buyer''s side is what the buyer booked',
    r.our_side, 972);

  -- MUTANT: `round(a_side - b_side, 2)` reported the other way round.
  -- The column says how much MORE the seller thinks it is owed, and a
  -- sign the wrong way sends somebody to correct the wrong ledger.
  perform pg_temp.check_eq('and the difference is the seller''s excess',
    r.difference, 108);
  -- MUTANT: `= 0` weakened to `>= 0`. A difference is a difference.
  perform pg_temp.check_true('which is not eliminated', not r.eliminated);

  select * into r from public.report_group_elimination_check(
    v_a, date '2026-03-01', date '2026-03-31') c
   where c.what = 'Trading';
  perform pg_temp.check_eq('trading is checked separately from the balance',
    r.their_side::text || '/' || r.our_side::text, '1000.00/900.00');
  perform pg_temp.check_true('and it does not reconcile either',
    not r.eliminated);

  -- MUTANT: `x.category = 'expense'` -> `'revenue'`, so revenue is
  -- paired against the counterparty's revenue rather than its cost.
  -- B has no inter-company revenue at all, so under the mutant the
  -- buyer's side would be nought rather than nine hundred.
  perform pg_temp.check_true('the buyer''s side of trading is its COST',
    r.our_side = 900);

  -- MUTANT: `coalesce(p.amount, 0)` -> `r.amount`, which makes an
  -- unmatched side agree with itself. B has booked nothing at all
  -- against C, so the check has to say 1,080 against nought.
  perform pg_temp.gs_sale(v_a, v_ca, 'A-2', 500, 40, date '2026-04-15');
  select * into r from public.report_group_elimination_check(
    v_a, date '2026-04-01', date '2026-04-30') c
   where c.what = 'Balances owed';
  perform pg_temp.check_eq('a side the other company never booked shows as nil',
    r.our_side, 0);
  perform pg_temp.check_eq('and the whole of it is the difference',
    r.difference, 540);
  perform pg_temp.check_true('and it is certainly not eliminated',
    not r.eliminated);

  -- And nothing is eliminated from the consolidated accounts while the
  -- two sides disagree, which is the rule the whole file turns on.
  perform pg_temp.check_eq('an unreconciled pair is not eliminated',
    (select count(*) from app.group_eliminations(
       v_a, date '2026-03-01', date '2026-03-31')), 0);

  perform pg_temp.sign_out();
  raise notice 'ok   what the check reports when the two sides disagree';
end $$;

-- =====================================================================
-- 4. The consolidated trial balance keeps every account
-- =====================================================================
do $$
declare
  v_boss uuid;
  v_g    uuid;
  v_a    uuid;
  v_b    uuid;
  v_ca   uuid;
  v_cb   uuid;
  v_n    integer;
begin
  perform pg_temp.allow_many_companies();
  v_boss := pg_temp.another_user('gsboss4@example.test');
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Imbangan', v_boss) returning id into v_g;

  v_a := pg_temp.gs_org('Imbangan A Sdn Bhd', v_boss, v_g);
  v_b := pg_temp.gs_org('Imbangan B Sdn Bhd', v_boss, v_g);
  update public.organizations set parent_org_id = v_a where id = v_b;

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-B', 'Imbangan B', 'customer', v_b) returning id into v_ca;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'IC-A', 'Imbangan A', 'supplier', v_a) returning id into v_cb;

  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.gs_sale(v_a, v_ca, 'A-1', 1000, 80, date '2026-03-15');
  perform pg_temp.gs_purchase(v_b, v_cb, 'B-1', 1000, 80, date '2026-03-15');

  -- MUTANT: `left join e on e.code = t.code` -> an inner join. The tax
  -- accounts are not eliminated -- the tax was paid to the Government
  -- and is real -- so an inner join drops them from the consolidated
  -- trial balance entirely, and the statement stops balancing.
  select count(*) into v_n from public.report_group_consolidated_trial_balance(
    v_a, date '2026-03-01', date '2026-03-31');
  perform pg_temp.check_true('every account with a balance is on the report',
    v_n >= 6);
  perform pg_temp.check_true('including the tax nobody eliminates',
    (select count(*) from public.report_group_consolidated_trial_balance(
       v_a, date '2026-03-01', date '2026-03-31') t
      where t.account_subtype::text = 'tax_payable'
        and t.combined_balance <> 0) = 1);
  perform pg_temp.check_eq('and its elimination is nothing',
    (select t.elimination from public.report_group_consolidated_trial_balance(
       v_a, date '2026-03-01', date '2026-03-31') t
      where t.account_subtype::text = 'tax_payable'
        and t.combined_balance <> 0), 0);

  -- MUTANT: `sum(g.adjustment)` -> `max`. One account code can carry an
  -- adjustment from more than one company -- both use the same seeded
  -- chart -- and taking the largest instead of the total leaves the
  -- other company's balance standing.
  perform pg_temp.check_eq('the eliminations still sum to nothing',
    (select coalesce(sum(t.elimination), 0)
       from public.report_group_consolidated_trial_balance(
         v_a, date '2026-03-01', date '2026-03-31') t), 0);
  perform pg_temp.check_eq('and the consolidated column does too',
    (select coalesce(sum(t.consolidated_balance), 0)
       from public.report_group_consolidated_trial_balance(
         v_a, date '2026-03-01', date '2026-03-31') t), 0);

  -- Both companies share one seeded chart, so the receivable and the
  -- payable are eliminated on their own codes and the revenue and cost
  -- on theirs: four adjustments, and not one of them nought.
  perform pg_temp.check_eq('four accounts carry an elimination',
    (select count(*) from public.report_group_consolidated_trial_balance(
       v_a, date '2026-03-01', date '2026-03-31') t
      where t.elimination <> 0), 4);

  perform pg_temp.sign_out();
  raise notice 'ok   the consolidated trial balance keeps every account';
end $$;

-- =====================================================================
-- 5. A third company, and a member of only one of them
-- =====================================================================
--
-- Two companies is the smallest group and it is not enough. With two,
-- "the pair that reconciles" and "any pair" are the same set, and
-- "this account's adjustment" and "the largest adjustment on this
-- account" are the same number. A third company separates them, and a
-- group of three is what a holding company with two trading
-- subsidiaries actually is.
-- =====================================================================
do $$
declare
  v_boss uuid;
  v_only uuid;
  v_g    uuid;
  v_a    uuid;
  v_b    uuid;
  v_c    uuid;
  v_cab  uuid;
  v_cba  uuid;
  v_cac  uuid;
  v_cca  uuid;
  v_rev  text;
begin
  perform pg_temp.allow_many_companies();
  v_boss := pg_temp.another_user('gsboss5@example.test');
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Tiga', v_boss) returning id into v_g;

  v_a := pg_temp.gs_org('Tiga A Sdn Bhd', v_boss, v_g);
  v_b := pg_temp.gs_org('Tiga B Sdn Bhd', v_boss, v_g);
  v_c := pg_temp.gs_org('Tiga C Sdn Bhd', v_boss, v_g);
  update public.organizations set parent_org_id = v_a where id in (v_b, v_c);

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-B', 'Tiga B', 'customer', v_b) returning id into v_cab;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'IC-A', 'Tiga A', 'supplier', v_a) returning id into v_cba;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-C', 'Tiga C', 'customer', v_c) returning id into v_cac;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_c, 'IC-A', 'Tiga A', 'supplier', v_a) returning id into v_cca;

  perform pg_temp.sign_in_as(v_boss);

  -- A to B reconciles: 1,000 both sides.
  perform pg_temp.gs_sale(v_a, v_cab, 'A-B', 1000, 80, date '2026-03-15');
  perform pg_temp.gs_purchase(v_b, v_cba, 'B-A', 1000, 80, date '2026-03-15');

  -- A to C does NOT: A says 400, C has booked 250.
  perform pg_temp.gs_sale(v_a, v_cac, 'A-C', 400, 32, date '2026-03-15');
  perform pg_temp.gs_purchase(v_c, v_cca, 'C-A', 250, 20, date '2026-03-15');

  -- MUTANT: `matched` joined without `m.counterparty = l.counterparty`.
  -- With two companies there is only one counterparty and the join is
  -- the same either way. With three, A's reconciled B-side would carry
  -- A's UNRECONCILED C-side out of the accounts with it -- eliminating
  -- four hundred of revenue that the group really did earn from a
  -- company whose books do not agree.
  --
  -- A's revenue to B is eliminated; A's revenue to C is not. So the
  -- adjustment on the revenue code is 1,000 and not 1,400.
  select code into v_rev from public.accounts where org_id = v_a
   and account_type = 'revenue' and not is_group order by code limit 1;
  perform pg_temp.check_eq('only the reconciled pair is eliminated',
    (select e.adjustment from app.group_eliminations(
       v_a, date '2026-03-01', date '2026-03-31') e
      where e.code = v_rev), 1000);

  perform pg_temp.check_eq('the unreconciled pair is reported instead',
    (select count(*) from public.report_group_elimination_check(
       v_a, date '2026-03-01', date '2026-03-31') c
      where not c.eliminated), 2);
  perform pg_temp.check_eq('and the reconciled one is not',
    (select count(*) from public.report_group_elimination_check(
       v_a, date '2026-03-01', date '2026-03-31') c
      where c.eliminated), 2);

  -- MUTANT: `sum(g.adjustment)` -> `max(g.adjustment)` in the
  -- consolidated trial balance. Both subsidiaries use the same seeded
  -- chart, so the payable code carries an adjustment from B and one
  -- from C -- and taking the larger leaves the smaller company's
  -- balance standing in the consolidated accounts.
  --
  -- Here only B's pair reconciles, so the point is made on the
  -- RECEIVABLE code, which A carries twice: once against B and once
  -- against C, of which one is eliminated.
  perform pg_temp.check_eq('the eliminations still sum to nothing',
    (select coalesce(sum(t.elimination), 0)
       from public.report_group_consolidated_trial_balance(
         v_a, date '2026-03-01', date '2026-03-31') t), 0);

  -- A's revenue against C is still in the consolidated accounts,
  -- because nothing has been proved about it.
  perform pg_temp.check_eq('and the unreconciled revenue survives',
    (select t.consolidated_balance
       from public.report_group_consolidated_trial_balance(
         v_a, date '2026-03-01', date '2026-03-31') t
      where t.code = v_rev), -400);

  perform pg_temp.sign_out();

  -- MUTANT: `app.is_org_member(p_org_id)` dropped from `group_orgs`.
  -- The two membership conditions MASK EACH OTHER for a stranger: one
  -- filters the company asked about, the other filters each company
  -- returned, and somebody in neither is stopped by either. The person
  -- who tells them apart is a member of ONE company in the group -- a
  -- subsidiary's bookkeeper -- who must not be able to read the
  -- group's list from the parent's id, and through it the parent's
  -- ledger.
  v_only := pg_temp.another_user('gsonly@example.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_b, v_only, 'accountant')
  on conflict (org_id, user_id) do update set role = 'accountant';
  perform pg_temp.sign_in_as(v_only);

  perform pg_temp.check_eq('a subsidiary''s bookkeeper sees their own company',
    (select count(*) from app.group_orgs(v_b)), 1);
  perform pg_temp.check_eq('and nothing at all from the parent''s id',
    (select count(*) from app.group_orgs(v_a)), 0);
  perform pg_temp.check_refused('nor the parent''s inter-company check',
    format($q$ select * from public.report_group_elimination_check(%L) $q$, v_a),
    '%not a member%', '42501');
  -- THE PAIR THAT MASKS ITSELF. `app.group_eliminations` groups by
  -- `l.code`, and its only consumer re-groups by `g.code` and sums --
  -- so a mutant widening the inner grouping is undone by the outer sum,
  -- and a mutant weakening the outer sum to `max` is undone by the
  -- inner grouping already yielding one row. Neither is dead; each
  -- hides the other, and the rule that makes both equivalent is that
  -- ONE ACCOUNT CODE GETS ONE ADJUSTMENT. That is what is asserted.
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_eq('one account code carries one adjustment',
    (select count(*) from (
       select e.code from app.group_eliminations(
         v_a, date '2026-03-01', date '2026-03-31') e
        group by e.code having count(*) > 1) s), 0);
  perform pg_temp.check_true('and there are adjustments to count',
    (select count(*) from app.group_eliminations(
       v_a, date '2026-03-01', date '2026-03-31')) > 0);
  perform pg_temp.sign_out();

  raise notice 'ok   a third company, and a member of only one of them';
end $$;

rollback;
