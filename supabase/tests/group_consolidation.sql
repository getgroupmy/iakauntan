-- =====================================================================
-- iAkauntan :: consolidation
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/group_consolidation.sql
--
-- One assertion carries this file: **the eliminations sum to zero**.
--
-- Everything else about a consolidation can be wrong in ways an
-- accountant will spot. That one cannot: an elimination set that does
-- not net to zero produces a consolidated trial balance which does not
-- balance, and the difference lands in whichever total somebody happens
-- to read first. 0142 wrote down two plausible implementations that fail
-- exactly this way — dropping lines leaves the tax behind, dropping
-- entries deletes real cash — so the invariant is asserted directly
-- rather than inferred from the figures looking sensible.
--
-- The fixture posts GL entries by hand on both sides, because that is
-- what a group actually has: A's invoice in A's ledger and B's bill in
-- B's, each complete with its own tax line.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cons_org(
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

do $$
declare
  v_boss uuid := pg_temp.another_user('boss@cons.test');
  v_group uuid; v_a uuid; v_b uuid;
  v_ca uuid; v_cb uuid; v_e uuid;
  v_ar uuid; v_rev uuid; v_tax uuid; v_ap uuid; v_exp uuid; v_intax uuid;
  v_sum numeric; v_combined numeric; v_consolidated numeric;
  v_n int; v_refused boolean; v_msg text;
begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Cons', v_boss) returning id into v_group;

  v_a := pg_temp.cons_org('Cons A Sdn Bhd', v_boss, v_group);
  v_b := pg_temp.cons_org('Cons B Sdn Bhd', v_boss, v_group);

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'IC-B', 'Cons B', 'customer', v_b) returning id into v_ca;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'IC-A', 'Cons A', 'supplier', v_a) returning id into v_cb;

  select id into v_ar from public.accounts where org_id = v_a
    and account_subtype = 'accounts_receivable' and not is_group limit 1;
  select id into v_rev from public.accounts where org_id = v_a
    and account_type = 'revenue' and not is_group limit 1;
  select id into v_tax from public.accounts where org_id = v_a
    and account_subtype = 'tax_payable' and not is_group limit 1;
  select id into v_ap from public.accounts where org_id = v_b
    and account_subtype = 'accounts_payable' and not is_group limit 1;
  select id into v_exp from public.accounts where org_id = v_b
    and account_type = 'expense' and not is_group limit 1;
  select id into v_intax from public.accounts where org_id = v_b
    and code = '1410' limit 1;

  -- A management fee: 1,000 plus 80 of service tax, in both ledgers.
  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (v_a, 'A-1', current_date, 'sales_invoice', 'to B',
          1080, 1080, 'posted', now()) returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit, contact_id)
  values (v_a, v_e, 1, v_ar,  1080, 0,    v_ca),
         (v_a, v_e, 2, v_rev, 0,    1000, v_ca),
         (v_a, v_e, 3, v_tax, 0,    80,   null);

  insert into public.gl_entries (org_id, entry_no, entry_date, source,
    description, total_debit, total_credit, status, posted_at)
  values (v_b, 'B-1', current_date, 'purchase_bill', 'from A',
          1080, 1080, 'posted', now()) returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit, contact_id)
  values (v_b, v_e, 1, v_exp,   1000, 0,    v_cb),
         (v_b, v_e, 2, v_intax, 80,   0,    null),
         (v_b, v_e, 3, v_ap,    0,    1080, v_cb);

  perform pg_temp.sign_in_as(v_boss);

  -- ---------------------------------------------------------------
  -- The invariant
  -- ---------------------------------------------------------------
  select round(sum(adjustment), 2), count(*) into v_sum, v_n
    from app.group_eliminations(v_a);

  perform pg_temp.check_true('there are eliminations to make at all — '
    'without this the assertion below passes for a function that returns '
    'nothing', v_n > 0);
  perform pg_temp.check_eq(
    'and they sum to zero, so a consolidated trial balance still balances',
    v_sum, 0);

  -- ---------------------------------------------------------------
  -- And they are the right ones
  -- ---------------------------------------------------------------
  perform pg_temp.check_eq('the receivable comes down by the whole invoice',
    (select e.adjustment from app.group_eliminations(v_a) e
      join public.accounts a on a.code = e.code and a.org_id = v_a
     where a.account_subtype = 'accounts_receivable'), -1080);
  perform pg_temp.check_eq('and the revenue up by the net of tax',
    (select e.adjustment from app.group_eliminations(v_a) e
      join public.accounts a on a.code = e.code and a.org_id = v_a
     where a.account_type = 'revenue'), 1000);

  perform pg_temp.check_true(
    'while the tax on both sides is left alone — A owes Customs and B '
    'paid Customs, and neither is an amount between the two companies',
    not exists (select 1 from app.group_eliminations(v_a) e
                 where e.code in (select code from public.accounts
                                   where id in (v_tax, v_intax))));

  -- ---------------------------------------------------------------
  -- Nothing is recorded about ownership yet
  -- ---------------------------------------------------------------
  v_refused := false; v_msg := '';
  begin
    perform count(*) from public.report_group_consolidated_trial_balance(v_a);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'a consolidation is refused while nobody has said who owns whom: ' || v_msg,
    v_refused and v_msg like '%who owns%');

  -- ---------------------------------------------------------------
  -- Owned, but not wholly
  -- ---------------------------------------------------------------
  perform public.set_group_ownership(v_b, v_a, 60);
  v_refused := false; v_msg := '';
  begin
    perform count(*) from public.report_group_consolidated_trial_balance(v_a);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'and refused for a subsidiary that is not wholly owned, naming it, '
    'because minority interest is not computed: ' || v_msg,
    v_refused and v_msg like '%Cons B%');

  -- ---------------------------------------------------------------
  -- The control: wholly owned, and it runs
  -- ---------------------------------------------------------------
  perform public.set_group_ownership(v_b, v_a, 100);

  select round(sum(t.combined_balance), 2), round(sum(t.consolidated_balance), 2)
    into v_combined, v_consolidated
    from public.report_group_consolidated_trial_balance(v_a) t;

  perform pg_temp.check_true('a wholly owned group consolidates',
    v_combined is not null);
  perform pg_temp.check_eq(
    'and consolidating moves nothing overall, which is the same invariant '
    'seen from the report rather than from the adjustments',
    v_consolidated, v_combined);

  perform pg_temp.check_true('with the receivable actually gone',
    (select t.consolidated_balance
       from public.report_group_consolidated_trial_balance(v_a) t
      where t.account_subtype = 'accounts_receivable') = 0);
  perform pg_temp.check_true('and the combined figure still shown beside it',
    (select t.combined_balance
       from public.report_group_consolidated_trial_balance(v_a) t
      where t.account_subtype = 'accounts_receivable') = 1080);

  -- ---------------------------------------------------------------
  -- When the two sides disagree, nothing is eliminated for that pair
  -- ---------------------------------------------------------------
  update public.gl_lines set debit = 900
   where entry_id = (select id from public.gl_entries
                      where org_id = v_b and entry_no = 'B-1')
     and account_id = v_exp;

  perform pg_temp.check_true(
    'a category whose two sides disagree is not eliminated at all — '
    'eliminating the lesser amount would bury the difference inside the '
    'consolidated figures where nobody would look for it',
    not exists (select 1 from app.group_eliminations(v_a) e
                 join public.accounts a on a.code = e.code and a.org_id = v_b
                where a.account_type = 'expense'));

  select round(sum(adjustment), 2) into v_sum from app.group_eliminations(v_a);
  perform pg_temp.check_eq(
    'and what is still eliminated still sums to zero', coalesce(v_sum, 0), 0);

  perform pg_temp.check_true('the difference is reported rather than hidden',
    exists (select 1 from public.report_group_elimination_check(v_a) c
             where not c.eliminated and c.difference <> 0));
  perform pg_temp.check_true('while the side that does reconcile says so',
    exists (select 1 from public.report_group_elimination_check(v_a) c
             where c.eliminated));
end $$;

-- ---------------------------------------------------------------------
-- Recording ownership
-- ---------------------------------------------------------------------
do $$
declare
  v_boss  uuid := pg_temp.another_user('boss2@cons.test');
  v_other uuid := pg_temp.another_user('other2@cons.test');
  v_group uuid; v_a uuid; v_b uuid; v_c uuid; v_hidden uuid;
  v_refused boolean; v_role text;
begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Cons Dua', v_boss) returning id into v_group;
  v_a      := pg_temp.cons_org('Own A Sdn Bhd', v_boss, v_group);
  v_b      := pg_temp.cons_org('Own B Sdn Bhd', v_boss, v_group);
  v_c      := pg_temp.cons_org('Own C Sdn Bhd', v_boss, v_group);
  v_hidden := pg_temp.cons_org('Own Hidden Sdn Bhd', v_other, v_group);

  perform pg_temp.sign_in_as(v_boss);

  v_refused := false;
  begin perform public.set_group_ownership(v_b, v_b, 100);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('a company cannot own itself', v_refused);

  v_refused := false;
  begin perform public.set_group_ownership(v_b, v_hidden, 100);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'and cannot be owned by a group company you are not in — otherwise '
    'this becomes a way to discover which companies exist', v_refused);

  v_refused := false;
  begin perform public.set_group_ownership(v_b, v_a, 0);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('and nought percent is not ownership', v_refused);

  -- The control for all three.
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.set_group_ownership(v_b, v_a, 100);
  end;
  reset role;
  perform pg_temp.check_true('recording ran as a client, not a superuser',
    v_role = 'authenticated');
  perform pg_temp.check_true('while an ordinary parent records',
    (select parent_org_id = v_a and owned_percent = 100
       from public.organizations where id = v_b));

  -- A chain, which is a real structure and not one this consolidates.
  v_refused := false;
  begin perform public.set_group_ownership(v_c, v_b, 100);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'a chain of holdings is refused rather than consolidated wrongly',
    v_refused);

  -- And it can be taken back off.
  perform public.set_group_ownership(v_b, null, null);
  perform pg_temp.check_true('ownership can be cleared again',
    (select parent_org_id is null and owned_percent is null
       from public.organizations where id = v_b));
end $$;

rollback;
