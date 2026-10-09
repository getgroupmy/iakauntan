-- =====================================================================
-- iAkauntan :: the asset and the bill it came from
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/capitalisation.sql
--
-- `fixed_assets.purchase_document_id` and `supplier_id` have been
-- columns since `0084` and nothing wrote either. So the register and
-- the ledger were two records of the same money with no way to be
-- compared: a bill line coded to Plant and equipment put 12,500 in
-- 1510, somebody typed 12,000 into the register, and depreciation ran
-- on the smaller figure for five years.
--
-- The assertion that matters is the first: the cost in the register is
-- the figure the ledger was debited, in the account it was debited to,
-- because both come from the same row.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cap_bill(
  p_org uuid, p_no text, p_supplier uuid, p_account uuid,
  p_amount numeric, p_desc text default 'Milling machine',
  p_post boolean default true, p_tax uuid default null,
  p_tax_rate numeric default 0,
  out doc_id uuid, out line_id uuid)
language plpgsql as $$
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', p_no, pg_temp.today(), p_supplier, 'MYR', 1, 'draft')
  returning id into doc_id;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_code_id, tax_rate)
  values (p_org, doc_id, 1, 'item', p_desc, 1, p_amount, p_account,
          p_tax, p_tax_rate)
  returning id into line_id;
  if p_post then perform public.post_purchase_document(doc_id); end if;
end $$;

-- ---------------------------------------------------------------------
-- The register and the ledger, from the same row
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Aset Dari Bil Sdn Bhd');
  v_sup   uuid;
  v_plant uuid;
  v_bill  record;
  v_asset uuid;
  v_row   public.fixed_assets;
  v_tax   uuid;
  v_said  text;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;

  select id into v_plant from public.accounts
   where org_id = v_org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;
  perform pg_temp.check_true('the seeded chart has a fixed asset account',
    v_plant is not null);

  v_bill := pg_temp.cap_bill(v_org, 'BILL-1', v_sup, v_plant, 12500);

  v_asset := public.capitalise_bill_line(
    v_bill.line_id, 'FA-001', null, 'Plant', 'straight_line', 60);

  select * into v_row from public.fixed_assets where id = v_asset;
  -- The figure and the account both come from the line, which is what
  -- makes the two records agree by construction rather than because
  -- two people chose the same thing twice.
  perform pg_temp.check_eq('the cost is what the ledger was debited',
    v_row.cost, 12500);
  perform pg_temp.check_eq('in the account it was debited to',
    v_row.asset_account_id, v_plant);
  perform pg_temp.check_eq('the acquisition date is the bill''s',
    v_row.acquisition_date::text, pg_temp.today()::text);
  perform pg_temp.check_eq('the supplier is the bill''s supplier',
    v_row.supplier_id, v_sup);
  perform pg_temp.check_eq('and the bill is named',
    v_row.purchase_document_id, v_bill.doc_id);
  perform pg_temp.check_eq('down to the line', v_row.purchase_line_id,
    v_bill.line_id);
  perform pg_temp.check_eq('the description becomes the name',
    v_row.name, 'Milling machine');

  -- Tax is not cost where it is recoverable, and the figure the posting
  -- put in the asset account is the net one. A bill of 10,000 plus 6%
  -- capitalised at 10,600 is an asset register that over-states the
  -- balance sheet by the tax the company is getting back.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_org, 'SV6', 'Service tax 6%', '02', 6, 'both')
  returning id into v_tax;
  v_bill := pg_temp.cap_bill(v_org, 'BILL-2', v_sup, v_plant, 10000,
    'Compressor', true, v_tax, 6);
  perform pg_temp.check_eq('the line was taxed',
    (select tax_amount from public.purchase_document_lines
      where id = v_bill.line_id), 600);
  v_asset := public.capitalise_bill_line(v_bill.line_id, 'FA-002', null,
    null, 'straight_line', 60);
  perform pg_temp.check_eq('and the cost is the net, not the gross',
    (select cost from public.fixed_assets where id = v_asset), 10000);

  -- Nothing was posted. The bill's own posting already put the money in
  -- the asset account, and posting again would double the asset.
  perform pg_temp.check_eq('capitalising posts nothing',
    (select count(*) from public.gl_entries
      where org_id = v_org and source_table = 'fixed_assets'), 0);

  -- One line is one lot of money.
  begin
    perform public.capitalise_bill_line(v_bill.line_id, 'FA-003');
    raise exception 'FAIL: one bill line became two assets';
  exception when sqlstate '23505' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a line cannot be capitalised twice',
    v_said like '%depreciated twice%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What will not be capitalised
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Tak Boleh Modal Sdn Bhd');
  v_sup    uuid;
  v_plant  uuid;
  v_repair uuid;
  v_draft  record;
  v_wrong  record;
  v_free   record;
  v_ok     record;
  v_said   text;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;

  select id into v_plant from public.accounts
   where org_id = v_org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;
  select id into v_repair from public.accounts
   where org_id = v_org and account_subtype = 'operating_expense'
     and not is_group order by code limit 1;

  -- A bill nobody has posted.
  v_draft := pg_temp.cap_bill(v_org, 'BILL-D', v_sup, v_plant, 5000,
    'Machine', false);
  begin
    perform public.capitalise_bill_line(v_draft.line_id, 'FA-D');
    raise exception 'FAIL: an unposted bill was capitalised';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the cost has to be in the ledger first',
    v_said like '%has not been posted%');

  -- A line coded to repairs. Putting it in the register is the register
  -- and the ledger disagreeing on purpose.
  v_wrong := pg_temp.cap_bill(v_org, 'BILL-R', v_sup, v_repair, 5000,
    'Servicing');
  begin
    perform public.capitalise_bill_line(v_wrong.line_id, 'FA-R');
    raise exception 'FAIL: an expense line was put in the asset register';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an expense line is refused',
    v_said like '%not a fixed asset account%');
  perform pg_temp.check_true('and the account is named, because the fix '
    'is on the bill', v_said like '%' || (select code from public.accounts
                                           where id = v_repair) || '%');

  -- A line with no account at all.
  v_free := pg_temp.cap_bill(v_org, 'BILL-N', v_sup, null, 5000, 'Thing');
  begin
    perform public.capitalise_bill_line(v_free.line_id, 'FA-N');
    raise exception 'FAIL: a line with no account was capitalised';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a line naming no account has nothing to '
    'reconcile to', v_said like '%names no account%');

  -- A residual worth more than the thing.
  v_ok := pg_temp.cap_bill(v_org, 'BILL-1', v_sup, v_plant, 5000);
  begin
    perform public.capitalise_bill_line(v_ok.line_id, 'FA-1', null, null,
      'straight_line', 60, null, 6000);
    raise exception 'FAIL: a residual above cost was accepted';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a residual cannot exceed the cost',
    v_said like '%more than the%');

  begin
    perform public.capitalise_bill_line(gen_random_uuid(), 'FA-X');
    raise exception 'FAIL: a line that does not exist was capitalised';
  exception when sqlstate 'P0002' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What has been bought and not put in the register
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Belum Daftar Sdn Bhd');
  v_sup    uuid;
  v_plant  uuid;
  v_repair uuid;
  v_one    record;
  v_two    record;
  v_exp    record;
  v_draft  record;
  v_out    uuid := pg_temp.another_user('outsider@cap.test');
  r        record;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;

  select id into v_plant from public.accounts
   where org_id = v_org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;
  select id into v_repair from public.accounts
   where org_id = v_org and account_subtype = 'operating_expense'
     and not is_group order by code limit 1;

  v_one   := pg_temp.cap_bill(v_org, 'BILL-1', v_sup, v_plant, 12500, 'Lathe');
  v_two   := pg_temp.cap_bill(v_org, 'BILL-2', v_sup, v_plant, 8000, 'Press');
  -- Coded to repairs, so it is not an asset purchase and must not be
  -- chased as one.
  v_exp   := pg_temp.cap_bill(v_org, 'BILL-3', v_sup, v_repair, 900,
    'Servicing');
  -- Not posted, so the money is not in the ledger and there is nothing
  -- to reconcile yet.
  v_draft := pg_temp.cap_bill(v_org, 'BILL-4', v_sup, v_plant, 4000,
    'Ordered', false);

  perform pg_temp.check_eq('both asset purchases are outstanding',
    (select count(*) from public.report_uncapitalised_purchases(v_org)), 2);

  select * into r from public.report_uncapitalised_purchases(v_org);
  perform pg_temp.check_eq('the report names the bill', r.doc_no, 'BILL-1');
  perform pg_temp.check_eq('the supplier', r.supplier_name, 'Jentera Sdn Bhd');
  perform pg_temp.check_eq('what it was for', r.description, 'Lathe');
  perform pg_temp.check_eq('and the amount sitting in the account',
    r.amount, 12500);

  perform public.capitalise_bill_line(v_one.line_id, 'FA-1', null, null,
    'straight_line', 60);
  perform pg_temp.check_eq('capitalising one takes it off the list',
    (select count(*) from public.report_uncapitalised_purchases(v_org)), 1);
  perform pg_temp.check_eq('and the one left is the other',
    (select doc_no from public.report_uncapitalised_purchases(v_org)),
    'BILL-2');

  -- As at a date before the second was bought, only what had been
  -- bought by then is outstanding.
  perform pg_temp.check_eq('and the date is honoured',
    (select count(*) from public.report_uncapitalised_purchases(
       v_org, pg_temp.today() - 1)), 0);

  -- A deleted asset puts its line back on the list, because a register
  -- entry that was removed did not happen.
  update public.fixed_assets set deleted_at = now()
   where purchase_line_id = v_one.line_id;
  perform pg_temp.check_eq('a deleted asset puts the line back',
    (select count(*) from public.report_uncapitalised_purchases(v_org)), 2);
  perform pg_temp.check_true('and the line can be capitalised again',
    public.capitalise_bill_line(v_one.line_id, 'FA-1B', null, null,
      'straight_line', 60) is not null);

  perform pg_temp.sign_in_as(v_out);
  perform pg_temp.check_eq('the report is closed to an outsider',
    (select count(*) from public.report_uncapitalised_purchases(v_org)), 0);
  begin
    -- A complete, valid call, so what refuses it is the permission and
    -- not a missing figure the row would have been refused for anyway.
    perform public.capitalise_bill_line(v_two.line_id, 'FA-2', null, null,
      'straight_line', 60);
    raise exception 'FAIL: an outsider capitalised a purchase';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A company that did not buy the module
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tanpa Modul Sdn Bhd',
                    array['accounting', 'purchases']);
  v_sup   uuid;
  v_plant uuid;
  v_bill  record;
  v_said  text;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;
  select id into v_plant from public.accounts
   where org_id = v_org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;

  v_bill := pg_temp.cap_bill(v_org, 'BILL-1', v_sup, v_plant, 5000);
  begin
    perform public.capitalise_bill_line(v_bill.line_id, 'FA-1', null, null,
      'straight_line', 60);
    raise exception 'FAIL: a company without the module made an asset';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the module has to be enabled',
    v_said like '%not enabled%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What the asset takes from the bill, and what from the caller
--
-- The fixtures above collapse most of it: every bill dated today, in
-- ringgit, one line, capitalised without a name, a residual or a
-- method. Here each figure is one only its own source could produce.
-- ---------------------------------------------------------------------
create or replace function pg_temp.cap_dated_bill(
  p_org uuid, p_no text, p_supplier uuid, p_on date, p_currency char(3),
  p_rate numeric, out doc_id uuid)
language plpgsql as $$
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', p_no, p_on, p_supplier, p_currency, p_rate, 'draft')
  returning id into doc_id;
end $$;

do $$
declare
  v_org   uuid := pg_temp.test_org('Aset Dari Mana Sdn Bhd');
  v_sup   uuid;
  v_plant uuid;
  v_doc   uuid;
  v_line  uuid;
  v_free  uuid;
  v_drill uuid;
  v_asset uuid;
  v_row   public.fixed_assets;
begin
  perform pg_temp.open_years(v_org, pg_temp.today() - 40);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;
  select id into v_plant from public.accounts
   where org_id = v_org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;

  -- Bought forty days ago; capitalised today, by name, under a
  -- category, on the reducing balance, with a residual.
  v_doc := pg_temp.cap_dated_bill(v_org, 'BILL-OLD', v_sup,
    pg_temp.today() - 40, 'MYR', 1);
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id)
  values (v_org, v_doc, 1, 'item', 'Forklift', 1, 9000, v_plant)
  returning id into v_line;
  perform public.post_purchase_document(v_doc);

  v_asset := public.capitalise_bill_line(v_line, '  FA-9  ',
    'Forklift, 2.5 tonne', 'Vehicles', 'reducing_balance', null, 20, 900);
  select * into v_row from public.fixed_assets where id = v_asset;
  perform pg_temp.check_eq('acquired on the bill''s date, not the day it '
    'was capitalised', v_row.acquisition_date::text,
    (pg_temp.today() - 40)::text);
  perform pg_temp.check_eq('the asset number is trimmed', v_row.asset_no, 'FA-9');
  perform pg_temp.check_eq('a name given is the name',
    v_row.name, 'Forklift, 2.5 tonne');
  perform pg_temp.check_eq('so is a category', v_row.category, 'Vehicles');
  perform pg_temp.check_eq('and the method', v_row.method, 'reducing_balance');
  perform pg_temp.check_eq('at its rate', v_row.rate_percent, 20);
  perform pg_temp.check_eq('the residual given is kept', v_row.residual_value, 900);
  perform pg_temp.check_eq('and who made it is recorded',
    v_row.created_by, pg_temp.test_user());

  -- Bought in dollars: the register is in the company's own money, at
  -- the bill's rate, which is what the posting put in the account.
  v_doc := pg_temp.cap_dated_bill(v_org, 'BILL-USD', v_sup,
    pg_temp.today(), 'USD', 4.5);
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id)
  values (v_org, v_doc, 1, 'item', 'CNC router', 1, 1000, v_plant)
  returning id into v_line;
  perform public.post_purchase_document(v_doc);
  perform pg_temp.check_eq('the list shows it in ringgit too',
    (select amount from public.report_uncapitalised_purchases(v_org)
      where doc_no = 'BILL-USD'), 4500);
  v_asset := public.capitalise_bill_line(v_line, 'FA-10', null, null,
    'straight_line', 60);
  perform pg_temp.check_eq('a dollar bill is capitalised in ringgit, at '
    'its own rate', (select cost from public.fixed_assets where id = v_asset),
    4500);
  perform pg_temp.check_eq('which is what the ledger was debited',
    (select sum(l.debit - l.credit) from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.account_id = v_plant
       and e.id = (select gl_entry_id from public.purchase_documents
                    where id = v_doc)), 4500);

  -- A free cable on the same bill as the drill: it is coded to plant,
  -- and it is not an asset.
  v_doc := pg_temp.cap_dated_bill(v_org, 'BILL-FREE', v_sup,
    pg_temp.today(), 'MYR', 1);
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id)
  values (v_org, v_doc, 1, 'item', 'Cable, free', 1, 0, v_plant)
  returning id into v_free;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id)
  values (v_org, v_doc, 2, 'item', 'Drill', 1, 500, v_plant)
  returning id into v_drill;
  perform public.post_purchase_document(v_doc);
  perform pg_temp.check_refused('a line worth nothing is not an asset',
    format('select public.capitalise_bill_line(%L, %L, null, null, %L, 60)',
           v_free, 'FA-11', 'straight_line'),
    'A line worth nothing is not an asset.', '23514');

  -- A residual of all of it is not more than the cost: an asset that
  -- is not depreciated, which is a judgement and not an error.
  v_asset := public.capitalise_bill_line(v_drill, 'FA-12', null, null,
    'straight_line', 60, null, 500);
  perform pg_temp.check_eq('a residual equal to the cost is taken',
    (select residual_value from public.fixed_assets where id = v_asset), 500);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A paid bill is still a posted one  (`0780`)
--
-- Paying a bill moves its status to 'partial', then 'completed'. The
-- cost stays in the asset account, so the line stays on the list and
-- can be capitalised. A bill with no journal, or one that is void, is
-- neither.
-- ---------------------------------------------------------------------
create or replace function pg_temp.cap_pay(
  p_org uuid, p_supplier uuid, p_no text, p_bill uuid, p_amount numeric)
returns void language plpgsql as $$
declare v_id uuid;
begin
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (p_org, p_no, pg_temp.today(), p_supplier, p_amount, p_amount,
          'MYR', 1, pg_temp.a_bank_account(p_org))
  returning id into v_id;
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  values (p_org, v_id, p_bill, p_amount);
  perform public.post_purchase_payment(v_id);
end $$;

do $$
declare
  v_org   uuid := pg_temp.test_org('Bil Berbayar Sdn Bhd');
  v_sup   uuid;
  v_plant uuid;
  v_paid  record;
  v_part  record;
  v_void  record;
  v_wait  record;
  v_asset uuid;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Jentera Sdn Bhd', 'supplier') returning id into v_sup;
  select id into v_plant from public.accounts
   where org_id = v_org and account_subtype = 'fixed_asset'
     and not is_group order by code limit 1;

  v_paid := pg_temp.cap_bill(v_org, 'BILL-1', v_sup, v_plant, 12500, 'Lathe');
  v_part := pg_temp.cap_bill(v_org, 'BILL-2', v_sup, v_plant, 8000, 'Press');
  v_void := pg_temp.cap_bill(v_org, 'BILL-3', v_sup, v_plant, 4000, 'Saw');
  v_wait := pg_temp.cap_bill(v_org, 'BILL-4', v_sup, v_plant, 3000, 'Grinder',
    false);

  perform pg_temp.cap_pay(v_org, v_sup, 'PV-1', v_paid.doc_id, 12500);
  perform pg_temp.cap_pay(v_org, v_sup, 'PV-2', v_part.doc_id, 3000);
  -- No function voids a bill; the row stands for one that was. And one
  -- waiting for approval, which has no journal yet.
  update public.purchase_documents set status = 'void' where id = v_void.doc_id;
  update public.purchase_documents set status = 'pending' where id = v_wait.doc_id;

  perform pg_temp.check_eq('paying in full makes it completed',
    (select status::text from public.purchase_documents
      where id = v_paid.doc_id), 'completed');
  perform pg_temp.check_eq('and in part, partial',
    (select status::text from public.purchase_documents
      where id = v_part.doc_id), 'partial');
  perform pg_temp.check_eq('the paid and the part-paid are still on the list',
    (select string_agg(doc_no, ',' order by doc_no)
       from public.report_uncapitalised_purchases(v_org)), 'BILL-1,BILL-2');

  v_asset := public.capitalise_bill_line(v_paid.line_id, 'FA-1', null, null,
    'straight_line', 60);
  perform pg_temp.check_eq('a paid bill is capitalised, at its cost',
    (select cost from public.fixed_assets where id = v_asset), 12500);
  v_asset := public.capitalise_bill_line(v_part.line_id, 'FA-2', null, null,
    'straight_line', 60);
  perform pg_temp.check_eq('and a part-paid one',
    (select cost from public.fixed_assets where id = v_asset), 8000);

  perform pg_temp.check_refused('a void bill is not',
    format('select public.capitalise_bill_line(%L, %L, null, null, %L, 60)',
           v_void.line_id, 'FA-3', 'straight_line'),
    'BILL-3 has not been posted. An asset whose cost is not in the ledger '
    'is one the register can never be reconciled to it.', '23514');
  perform pg_temp.check_refused('nor one waiting for approval',
    format('select public.capitalise_bill_line(%L, %L, null, null, %L, 60)',
           v_wait.line_id, 'FA-4', 'straight_line'),
    'BILL-4 has not been posted. An asset whose cost is not in the ledger '
    'is one the register can never be reconciled to it.', '23514');
  perform pg_temp.check_eq('and the list is empty, with those two not on it',
    (select count(*)::integer
       from public.report_uncapitalised_purchases(v_org)), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('capitalising is closed to anon',
    not has_function_privilege('anon',
      'public.capitalise_bill_line(uuid, text, text, text, text, integer, '
      'numeric, numeric)', 'execute'));
  perform pg_temp.check_true('and the reconciliation',
    not has_function_privilege('anon',
      'public.report_uncapitalised_purchases(uuid, date)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may capitalise',
    has_function_privilege('authenticated',
      'public.capitalise_bill_line(uuid, text, text, text, text, integer, '
      'numeric, numeric)', 'execute'));
end $$;

rollback;
