-- =====================================================================
-- iAkauntan :: an account a landed cost run names is not closed (0927)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_account_a_landed_cost_run_names_is_not_closed.sql
--
-- `0922` stops an account closing while a document not yet posted
-- names it. A landed cost run was not asked: closed under a draft run,
-- its freight account took the run's credit when the run posted, and
-- carried a balance after it had closed. As the owner with the role
-- `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_lr (
  org uuid, wh uuid, sup uuid, tile uuid, bill uuid, git uuid,
  sea uuid, air uuid, road uuid, rail uuid, post uuid);
grant select on t_lr to authenticated;

-- A freight account of the company's own, filed beside 5400.
create or replace function pg_temp.lr_account(p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select p_org, p_code, p_name, 'expense', 'cost_of_sales', a.parent_id
    from public.accounts a where a.org_id = p_org and a.code = '5400'
  returning id into v;
  return v;
end $$;

-- A draft run over the one bill, one charge of 50 per account given.
create or replace function pg_temp.lr_run(p_org uuid, p_bill uuid, p_accounts uuid[])
returns uuid language sql as $$
  select public.upsert_landed_cost_run(null, p_org, pg_temp.today(),
    jsonb_build_array(jsonb_build_object('bill', p_bill)),
    (select jsonb_agg(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', a)
                      order by n)
       from unnest(p_accounts) with ordinality u(a, n)),
    null);
$$;

do $$
declare r t_lr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Fret Tutup Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['accounting', 'inventory', 'purchases', 'sales']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  r.sea  := pg_temp.lr_account(r.org, '5491', 'Fret Laut');
  r.air  := pg_temp.lr_account(r.org, '5492', 'Fret Udara');
  r.road := pg_temp.lr_account(r.org, '5493', 'Fret Darat');
  r.rail := pg_temp.lr_account(r.org, '5494', 'Fret Kereta Api');
  r.post := pg_temp.lr_account(r.org, '5495', 'Fret Pos');
  select id into r.git from public.accounts where org_id = r.org and code = '1320';

  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'TILE', 'Jubin', 'stock', true, 'C62', 20) returning id into r.tile;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-1', pg_temp.today(), pg_temp.today(), r.sup, 'MYR', 1, 'draft')
  returning id into r.bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code, unit_price, warehouse_id)
  values (r.org, r.bill, 1, 'item', r.tile, 'Jubin', 100, 'C62', 10, r.wh);
  perform public.post_purchase_document(r.bill);

  insert into t_lr select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_lr; v_run uuid; v_no text; v_gone uuid; v_posted uuid; v_entry uuid;
begin
  select * into d from t_lr;

  -- -------------------------------------------------------------------
  -- A draft run holds its charges' accounts open
  -- -------------------------------------------------------------------
  v_run := pg_temp.lr_run(d.org, d.bill, array[d.sea, d.air]);
  select run_no into v_no from public.landed_cost_runs where id = v_run;

  perform pg_temp.check_refused('an account a draft run''s charge names is not closed',
    format('select public.retire_account(%L)', d.sea),
    'Account 5491 is still named by unposted landed cost run ' || v_no || ', and what is posted through that would go on landing in it after it closed. Name another account there first, then close it.',
    '23514');
  perform pg_temp.check_refused('nor one its second charge names',
    format('select public.retire_account(%L)', d.air),
    'Account 5492 is still named by unposted landed cost run ' || v_no || ',%', '23514');
  perform pg_temp.check_eq('and both are still open',
    (select count(*) from public.accounts
      where id in (d.sea, d.air) and is_active and deleted_at is null),
    2::bigint);
  -- The run holds the accounts its charges name, and no others.
  perform pg_temp.check_eq('while it is drafted, an account it does not name still closes',
    public.retire_account(d.post), 'closed');

  -- What the run then posts lands in accounts that are open.
  v_entry := public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq('so the run posts its freight off an open account',
    (select sum(l.credit - l.debit) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.id in (d.sea, d.air) and a.is_active),
    100::numeric);

  -- -------------------------------------------------------------------
  -- One no longer in train does not
  -- -------------------------------------------------------------------
  -- Posted, and the freight journalled back onto it: nothing holds it.
  v_posted := pg_temp.lr_run(d.org, d.bill, array[d.rail]);
  perform public.post_landed_cost_run(v_posted);
  perform public.post_manual_journal(d.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', d.rail, 'debit', 50, 'credit', 0),
      jsonb_build_object('account_id', d.git, 'debit', 0, 'credit', 50)),
    'Pindah fret', 'JV-FR-1');
  perform pg_temp.check_eq('an account a posted run named, emptied by journal, is closed',
    public.retire_account(d.rail), 'closed');

  v_gone := pg_temp.lr_run(d.org, d.bill, array[d.road]);
  perform public.cancel_landed_cost_run(v_gone);
  perform pg_temp.check_eq('and one only a cancelled run names',
    public.retire_account(d.road), 'closed');
end $$;

reset role;

rollback;
