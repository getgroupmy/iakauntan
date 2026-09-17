-- =====================================================================
-- iAkauntan :: 0609 the goods arrived and nobody wrote it down
--
-- A goods received note receives no goods. Measured, not inferred:
--
--   PO -> Bill          : 1 movement(s), 10.0000 received
--   PO -> GRN -> Bill   : 0 movement(s), 0 received
--
-- The same ten units, bought two ways, and one way never reaches the
-- shelf. The bill still posts -- the supplier is still owed, the input
-- tax is still claimed -- so nothing looks wrong anywhere except the
-- stock figure, which is simply short.
--
-- ---------------------------------------------------------------------
-- How it happened
--
-- `app.post_purchase_document_internal` has carried this since `0013`:
--
--     -- Receive stock unless a goods-received note already did.
--     if not exists (
--       select 1 from public.purchase_documents d
--        where d.id = v_doc.parent_id and d.doc_type = 'goods_received'
--     ) then
--
-- The comment is not wrong about what it intends. It is wrong about the
-- world: nothing anywhere has ever received stock on a goods received
-- note. There is no `post_goods_received`, no trigger, and the only
-- three statements in the whole schema that write a `purchase_receipt`
-- movement are the three successive restatements of this same function
-- -- `0013`, `0097`, `0270` -- each of them skipping for the same
-- reason.
--
-- So the skip has been unconditionally correct about the first half of
-- its sentence and unconditionally wrong about the second, for as long
-- as the document type has existed. It was invisible while the GRN had
-- no row in `docTypes` and could not be reached from the app; the
-- screen is what made it reachable, not what broke it.
--
-- ---------------------------------------------------------------------
-- What a goods received note is for
--
-- The goods are here and the bill is not. That is a real position and
-- it has a real name: goods received not invoiced. The company owes for
-- them, the stock is on the shelf, and nobody has priced it yet.
--
-- So the GRN both receives the stock AND posts, which is a change of
-- kind rather than degree -- `docTypes` has it as `posts: false`:
--
--     goods received note   Dr Inventory        Cr 2118 GRNI
--     supplier's bill       Dr 2118 GRNI        Cr Accounts Payable
--                           Dr Input tax
--
-- and the two net to exactly what the direct path posts today, which is
-- the assertion `goods_received.sql` makes: buy the same thing both
-- ways and every account ends on the same figure.
--
-- Leaving the GRN unposted and merely writing the stock movement was
-- the smaller change and it is not available: this schema is perpetual
-- -- `track_inventory` items capitalise into `1310` rather than
-- expensing -- so stock that exists with no ledger entry behind it is a
-- balance sheet that does not agree with the stock valuation report for
-- as long as the bill takes to arrive, which is the whole point of the
-- document.
--
-- ---------------------------------------------------------------------
-- The skip becomes a fact rather than a proxy
--
-- `parent is a goods_received` was standing in for `the stock is
-- already here`. They are not the same: a bill raised from a DRAFT GRN
-- skipped too, and that GRN had received nothing either. So the bill
-- now asks the question it means -- are there already movements from
-- that parent document -- and receives the stock itself when there are
-- not. A company that has been transferring through draft notes gets
-- the right answer from the next bill without anybody noticing the
-- difference.
--
-- ---------------------------------------------------------------------
-- Nothing is backfilled
--
-- Stock that was never received cannot be received now at a date
-- nobody chose: the movement would land on today, value at today's
-- rate, and walk into a closed period. A company that has used the GRN
-- path has a stock count to do, and `docs/goods-received.md` says so.
-- What this migration guarantees is that it does not get worse.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Somewhere to put it
--
-- `2118`, in the payables block where a reader looking for it would
-- look. Not `2115`, which reads better and is taken: three test
-- fixtures already use that code for a related-party payable of their
-- own, and a seeded chart that collides with them turns one migration
-- into four. Re-seeding is the backfill: the
-- seed has been `on conflict do nothing` and re-entrant since `0071`,
-- so calling it again adds the one missing row and touches nothing
-- else -- including accounts a company added itself, which are not in
-- `_coa`. Same argument as `0189`, same one code path.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.seed_chart_of_accounts(p_org_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row record;
begin
  -- Dropped first because `on commit drop` only fires at COMMIT: two
  -- organizations seeded inside one transaction — which is what the
  -- test suite does — would otherwise collide on the second call.
  drop table if exists _coa;
  create temp table _coa (
    code text, name text, atype text, asubtype text,
    is_group boolean, parent_code text, sort_order int
  ) on commit drop;

  insert into _coa values
    -- Assets
    ('1000','ASSETS','asset','current_asset',true,null,1000),
    ('1100','Current Assets','asset','current_asset',true,'1000',1100),
    ('1110','Cash in Hand','asset','cash',false,'1100',1110),
    ('1120','Bank Accounts','asset','bank',false,'1100',1120),
    ('1130','Petty Cash','asset','cash',false,'1100',1130),
    ('1200','Trade and Other Receivables','asset','current_asset',true,'1100',1200),
    ('1210','Accounts Receivable','asset','accounts_receivable',false,'1200',1210),
    ('1220','Other Receivables','asset','current_asset',false,'1200',1220),
    ('1230','Deposits and Prepayments','asset','current_asset',false,'1200',1230),
    ('1240','Amount Due from Directors','asset','current_asset',false,'1200',1240),
    ('1300','Inventories','asset','inventory',true,'1100',1300),
    ('1310','Inventory','asset','inventory',false,'1300',1310),
    ('1320','Goods in Transit','asset','inventory',false,'1300',1320),
    ('1400','Tax Assets','asset','current_asset',true,'1100',1400),
    ('1410','SST Input Tax','asset','current_asset',false,'1400',1410),
    ('1500','Non-Current Assets','asset','fixed_asset',true,'1000',1500),
    ('1510','Property, Plant and Equipment','asset','fixed_asset',false,'1500',1510),
    ('1520','Motor Vehicles','asset','fixed_asset',false,'1500',1520),
    ('1530','Office Equipment','asset','fixed_asset',false,'1500',1530),
    ('1540','Furniture and Fittings','asset','fixed_asset',false,'1500',1540),
    ('1550','Computer Equipment','asset','fixed_asset',false,'1500',1550),
    ('1590','Accumulated Depreciation','asset','accumulated_depreciation',false,'1500',1590),
    -- Liabilities
    ('2000','LIABILITIES','liability','current_liability',true,null,2000),
    ('2100','Current Liabilities','liability','current_liability',true,'2000',2100),
    ('2110','Accounts Payable','liability','accounts_payable',false,'2100',2110),
    -- 0609. Where the money sits between the goods arriving and the
    -- supplier's bill arriving. Dr Inventory / Cr here on the goods
    -- received note; Dr here / Cr Accounts Payable on the bill.
    -- 2118 rather than 2115: that code is taken by test fixtures.
    ('2118','Goods Received Not Invoiced','liability','current_liability',false,'2100',2118),
    ('2120','Other Payables and Accruals','liability','current_liability',false,'2100',2120),
    ('2130','SST Output Tax','liability','tax_payable',false,'2100',2130),
    ('2140','Income Tax Payable','liability','tax_payable',false,'2100',2140),
    ('2145','Net Salaries Payable','liability','current_liability',false,'2100',2145),
    ('2150','EPF Payable','liability','current_liability',false,'2100',2150),
    ('2160','SOCSO Payable','liability','current_liability',false,'2100',2160),
    ('2170','EIS Payable','liability','current_liability',false,'2100',2170),
    ('2180','PCB / MTD Payable','liability','current_liability',false,'2100',2180),
    ('2185','Zakat Payable','liability','current_liability',false,'2100',2185),
    ('2190','Amount Due to Directors','liability','current_liability',false,'2100',2190),
    ('2195','HRD Corp Levy Payable','liability','current_liability',false,'2100',2195),
    ('2200','Non-Current Liabilities','liability','long_term_liability',true,'2000',2200),
    ('2210','Term Loans','liability','long_term_liability',false,'2200',2210),
    ('2220','Hire Purchase Payable','liability','long_term_liability',false,'2200',2220),
    -- Equity
    ('3000','EQUITY','equity','share_capital',true,null,3000),
    ('3100','Share Capital','equity','share_capital',false,'3000',3100),
    ('3200','Retained Earnings','equity','retained_earnings',false,'3000',3200),
    ('3300','Current Year Earnings','equity','retained_earnings',false,'3000',3300),
    ('3400','Drawings','equity','drawings',false,'3000',3400),
    -- Revenue
    ('4000','REVENUE','revenue','sales',true,null,4000),
    ('4100','Sales','revenue','sales',false,'4000',4100),
    ('4200','Service Income','revenue','sales',false,'4000',4200),
    ('4250','Service Charge','revenue','sales',false,'4000',4250),
    ('4300','Sales Returns and Discounts','revenue','sales',false,'4000',4300),
    ('4900','Other Income','revenue','other_income',false,'4000',4900),
    ('4910','Interest Income','revenue','other_income',false,'4000',4910),
    ('4920','Foreign Exchange Gain','revenue','other_income',false,'4000',4920),
    ('4990','Rounding Adjustment','revenue','other_income',false,'4000',4990),
    -- Cost of sales
    ('5000','COST OF SALES','expense','cost_of_sales',true,null,5000),
    ('5100','Purchases','expense','cost_of_sales',false,'5000',5100),
    ('5200','Cost of Goods Sold','expense','cost_of_sales',false,'5000',5200),
    ('5300','Direct Labour','expense','cost_of_sales',false,'5000',5300),
    ('5400','Freight and Import Duty','expense','cost_of_sales',false,'5000',5400),
    ('5900','Inventory Adjustment','expense','cost_of_sales',false,'5000',5900),
    -- Expenses
    ('6000','EXPENSES','expense','operating_expense',true,null,6000),
    ('6100','Salaries and Wages','expense','payroll_expense',false,'6000',6100),
    ('6110','EPF Contribution','expense','payroll_expense',false,'6000',6110),
    ('6120','SOCSO Contribution','expense','payroll_expense',false,'6000',6120),
    ('6130','EIS Contribution','expense','payroll_expense',false,'6000',6130),
    ('6140','Staff Welfare','expense','payroll_expense',false,'6000',6140),
    ('6150','HRD Corp Levy','expense','payroll_expense',false,'6000',6150),
    ('6200','Rental','expense','operating_expense',false,'6000',6200),
    ('6210','Utilities','expense','operating_expense',false,'6000',6210),
    ('6220','Telephone and Internet','expense','operating_expense',false,'6000',6220),
    ('6230','Printing and Stationery','expense','operating_expense',false,'6000',6230),
    ('6240','Repair and Maintenance','expense','operating_expense',false,'6000',6240),
    ('6250','Transport and Travelling','expense','operating_expense',false,'6000',6250),
    ('6260','Entertainment','expense','operating_expense',false,'6000',6260),
    ('6270','Advertising and Marketing','expense','operating_expense',false,'6000',6270),
    ('6280','Professional Fees','expense','operating_expense',false,'6000',6280),
    ('6290','Insurance','expense','operating_expense',false,'6000',6290),
    ('6295','Licence and Permit','expense','operating_expense',false,'6000',6295),
    ('6300','Bank Charges','expense','finance_cost',false,'6000',6300),
    ('6310','Interest Expense','expense','finance_cost',false,'6000',6310),
    ('6400','Depreciation','expense','depreciation_expense',false,'6000',6400),
    ('6500','Foreign Exchange Loss','expense','other_expense',false,'6000',6500),
    ('6600','Bad Debts Written Off','expense','other_expense',false,'6000',6600),
    ('6900','Other Expenses','expense','other_expense',false,'6000',6900),
    ('6990','Income Tax Expense','expense','tax_expense',false,'6000',6990);

  for v_row in select * from _coa order by sort_order loop
    insert into public.accounts (
      org_id, code, name, account_type, account_subtype,
      is_group, is_system, sort_order
    ) values (
      p_org_id, v_row.code, v_row.name,
      v_row.atype::app.account_type, v_row.asubtype::app.account_subtype,
      v_row.is_group, true, v_row.sort_order
    ) on conflict (org_id, code) do nothing;
  end loop;

  -- Second pass: wire up the parent hierarchy now that every row exists.
  update public.accounts a
     set parent_id = p.id
    from _coa c
    join public.accounts p on p.org_id = p_org_id and p.code = c.parent_code
   where a.org_id = p_org_id
     and a.code = c.code
     and c.parent_code is not null;
end;
$function$

;

do $do$
declare v_org uuid; v_n integer := 0;
begin
  for v_org in select id from public.organizations order by created_at loop
    perform app.seed_chart_of_accounts(v_org);
    v_n := v_n + 1;
  end loop;
  raise notice 'chart re-seeded for % organization(s)', v_n;
end $do$;

-- ---------------------------------------------------------------------
-- A journal source that says what it is
--
-- `journal_source` has twenty-two members and none of them is a
-- receiving note. `purchase_bill` would be a lie -- no bill exists yet,
-- which is the entire point of the entry -- and `stock_movement` is
-- true but says nothing about why.
--
-- Added rather than borrowed, and added in its own statement so the new
-- value is never USED in the transaction that creates it: Postgres
-- refuses that, and the functions below only name it at run time.
-- ---------------------------------------------------------------------
alter type app.journal_source add value if not exists 'goods_received';

-- ---------------------------------------------------------------------
-- Receiving the goods
--
-- Stock lines only. A service line on a receiving note is somebody
-- filling in the wrong document: nothing arrived, nothing goes on a
-- shelf, and capitalising it into inventory would be worse than
-- ignoring it. The bill expenses those exactly as it does today.
--
-- The stock movement is the same expression the bill has used since
-- `0270`, down to `base_quantity`: two cartons of twenty-four is
-- forty-eight pieces onto the shelf, and RM 480 for them is RM 10 a
-- piece.
-- ---------------------------------------------------------------------
create or replace function app.post_goods_received_internal(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $function$
declare
  v_doc       public.purchase_documents;
  v_line      record;
  v_entries   jsonb := '[]'::jsonb;
  v_grni      uuid;
  v_inv_acct  uuid;
  v_entry_id  uuid;
  v_amount    numeric(18, 2);
  v_total     numeric(18, 2) := 0;
  v_rate      numeric(18, 8);
  v_n         integer;
begin
  select * into v_doc from public.purchase_documents where id = p_id;
  if not found then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if v_doc.doc_type <> 'goods_received' then
    raise exception '% is not a goods received note', v_doc.doc_no
      using errcode = '22023';
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no
      using errcode = '22023';
  end if;

  v_rate := coalesce(v_doc.exchange_rate, 1);

  select id into v_grni from public.accounts
   where org_id = v_doc.org_id and code = '2118';
  if v_grni is null then
    raise exception 'Receiving goods needs account 2118, Goods Received '
                    'Not Invoiced. Add it to the chart of accounts.'
      using errcode = 'P0002';
  end if;

  for v_line in
    select l.*, i.track_inventory, i.inventory_account_id
      from public.purchase_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_id
       and l.line_type = 'item'
       and i.track_inventory
     order by l.line_no
  loop
    v_inv_acct := coalesce(v_line.inventory_account_id,
      (select id from public.accounts
        where org_id = v_doc.org_id and code = '1310'));

    v_amount := round(v_line.line_subtotal * v_rate, 2);
    if v_amount <> 0 then
      v_total := v_total + v_amount;
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_inv_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code
      );
    end if;
  end loop;

  -- Nothing on a shelf and nothing to accrue. A receiving note of pure
  -- service lines is refused rather than posted empty: an entry with no
  -- lines is not a record of anything, and somebody has filled in the
  -- wrong document.
  if v_total = 0 then
    raise exception 'Nothing on % is stock, so there is nothing to '
                    'receive. A service belongs on the bill.', v_doc.doc_no
      using errcode = '22023';
  end if;

  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_grni,
    'description', 'Goods received, not yet invoiced',
    'debit',       0,
    'credit',      v_total,
    'contact_id',  v_doc.contact_id
  );

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date, 'goods_received'::app.journal_source,
    v_entries,
    'goods_received ' || v_doc.doc_no,
    'purchase_documents', v_doc.id,
    coalesce(v_doc.supplier_doc_no, v_doc.reference),
    v_doc.currency, v_rate);

  insert into public.stock_movements (
    org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
    quantity, unit_cost, source_table, source_id, source_line_id,
    gl_entry_id, created_by)
  select v_doc.org_id,
         app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
         v_doc.doc_date,
         'purchase_receipt'::app.stock_movement_type,
         l.item_id,
         coalesce(l.warehouse_id, (select id from public.warehouses
                                    where org_id = v_doc.org_id
                                      and is_default limit 1)),
         coalesce(l.base_quantity, l.quantity),
         case when coalesce(l.base_quantity, l.quantity) = 0 then 0
              else round(l.line_subtotal * v_rate
                         / coalesce(l.base_quantity, l.quantity), 6) end,
         'purchase_documents', v_doc.id, l.id, v_entry_id, auth.uid()
    from public.purchase_document_lines l
    join public.items i on i.id = l.item_id
   where l.document_id = p_id
     and l.line_type = 'item'
     and i.track_inventory
     and l.quantity > 0;

  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Nothing on % has a quantity to receive', v_doc.doc_no
      using errcode = '22023';
  end if;

  update public.purchase_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  return v_entry_id;
end;
$function$;

create or replace function public.post_goods_received(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $function$
declare v_org uuid;
begin
  select org_id into v_org from public.purchase_documents where id = p_id;
  if v_org is null then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  return app.post_goods_received_internal(p_id);
end;
$function$;

comment on function public.post_goods_received(uuid) is
  'Receives the stock on a goods received note and accrues what is owed '
  'for it: Dr Inventory, Cr 2118 Goods Received Not Invoiced. The bill '
  'clears 2118 when it arrives. 0609.';

revoke all on function public.post_goods_received(uuid) from public, anon;
grant execute on function public.post_goods_received(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- And the bill, which stops capitalising stock that is already on the
-- shelf and starts clearing what the receiving note accrued
--
-- Restated from `0270` with three changes, each marked `0609` in the
-- body: the local that says whether a POSTED receiving note came
-- first, the item-line account that follows from it, and the skip --
-- which now asks whether the movements exist rather than whether the
-- parent was the sort of document that should have made them.
-- ---------------------------------------------------------------------
create or replace function app.post_purchase_document_internal(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc         public.purchase_documents;
  v_line        record;
  v_entries     jsonb := '[]'::jsonb;
  v_sign        integer;
  v_ap_account  uuid;
  v_tax_account uuid;
  v_exp_acct    uuid;
  v_entry_id    uuid;
  v_amount      numeric(18, 2);
  v_rate        numeric(18, 8);
  -- 0609. Whether a posted goods received note already put this stock
  -- on the shelf and accrued what is owed for it. When it did, the
  -- bill's item lines clear that accrual instead of capitalising the
  -- stock a second time.
  v_from_grn    boolean;
  v_grni        uuid;
  v_received    integer;
begin
  select * into v_doc from public.purchase_documents where id = p_id;
  if not found then
    raise exception 'Purchase document % not found', p_id;
  end if;
  if v_doc.doc_type not in ('bill', 'purchase_credit_note', 'purchase_debit_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  -- 0609. A POSTED goods received note, not merely a goods received
  -- note: the old test was a proxy for "the stock is already here" and
  -- a draft one is not. Until 0609 nothing ever posted one, so this was
  -- false for every bill that has ever been raised through a receiving
  -- note -- and the skip below still fired, which is how ten units
  -- bought that way arrived nowhere.
  v_from_grn := exists (
    select 1 from public.purchase_documents d
     where d.id = v_doc.parent_id
       and d.doc_type = 'goods_received'
       and d.gl_entry_id is not null);

  if v_from_grn then
    select id into v_grni from public.accounts
     where org_id = v_doc.org_id and code = '2118';
    if v_grni is null then
      raise exception 'Billing goods received on % needs account 2118, '
                      'Goods Received Not Invoiced. Add it to the chart '
                      'of accounts.', v_doc.doc_no
        using errcode = 'P0002';
    end if;
  end if;

  select coalesce(c.payable_account_id,
                  (select id from public.accounts where org_id = v_doc.org_id and code = '2110'))
    into v_ap_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '1410';

  -- Payable: credit for a bill.
  v_amount := round(-v_sign * v_doc.total_amount * v_rate, 2);
  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_ap_account,
    'description', v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'debit',       greatest(v_amount, 0),
    'credit',      greatest(-v_amount, 0),
    'contact_id',  v_doc.contact_id
  );

  for v_line in
    select l.*, i.track_inventory, i.inventory_account_id, i.purchase_account_id
      from public.purchase_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_id and l.line_type = 'item'
     order by l.line_no
  loop
    -- Stock items capitalise into inventory; everything else expenses.
    --
    -- 0609: unless the goods received note already capitalised them, in
    -- which case this clears the accrual it raised instead. The two
    -- entries together are exactly what the direct path posts, and
    -- `goods_received.sql` asserts that by buying the same thing both
    -- ways and comparing every account.
    --
    -- Where the bill's price differs from the receiving note's -- a
    -- line edited after transfer, a supplier who charged more than the
    -- order said -- the difference stays in 2118 rather than being
    -- silently absorbed. That is a purchase price variance and it is
    -- meant to be visible; an accountant clears it deliberately.
    if v_line.track_inventory then
      v_exp_acct := case when v_from_grn then v_grni else
        coalesce(v_line.inventory_account_id,
          (select id from public.accounts where org_id = v_doc.org_id and code = '1310'))
      end;
    else
      v_exp_acct := app.resolve_account(
        v_doc.org_id, v_line.account_id, v_line.item_id, 'purchase_account_id', '5100');
    end if;

    v_amount := round(v_sign * v_line.line_subtotal * v_rate, 2);
    if v_amount <> 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_exp_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'tax_code_id', v_line.tax_code_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code
      );
    end if;
  end loop;

  if coalesce(v_doc.tax_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.tax_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_tax_account,
      'description', 'SST input tax',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0),
      'tax_amount',  abs(v_amount)
    );
  end if;

  if coalesce(v_doc.shipping_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.shipping_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),
      'description', 'Freight and handling',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  if coalesce(v_doc.rounding_amount, 0) <> 0 then
    v_amount := round(v_sign * v_doc.rounding_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4990'),
      'description', 'Rounding adjustment',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date,
    case when v_sign = -1 then 'purchase_credit_note'::app.journal_source
         else 'purchase_bill'::app.journal_source end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'purchase_documents', v_doc.id,
    coalesce(v_doc.supplier_doc_no, v_doc.reference),
    v_doc.currency, v_rate
  );

  -- Receive stock unless a goods received note already did.
  --
  -- 0609. This asked whether the parent was a receiving note, which was
  -- standing in for whether the stock was already here. They are not
  -- the same thing and were never the same thing: nothing received
  -- stock on a receiving note until 0609, so the answer was always
  -- "skip" and the stock was always missing. It now asks the question
  -- it means, of the movements themselves, so a bill raised from a
  -- draft note -- or from a note posted before this migration and left
  -- without movements -- receives the goods here instead of nowhere.
  --
  -- The `doc_type` half stays, and dropping it was wrong: a purchase
  -- credit note raised by `credit_purchase_bill` carries the BILL as
  -- its parent, and that bill has movements. Asking only "does the
  -- parent have movements" made every return skip its own outward
  -- movement -- twenty bags credited and a hundred still on the shelf,
  -- which is what `bill_credit.sql` said when this was written the
  -- short way.
  select count(*) into v_received
    from public.stock_movements m
    join public.purchase_documents d
      on d.id = m.source_id and d.doc_type = 'goods_received'
   where m.source_table = 'purchase_documents'
     and d.id = v_doc.parent_id;

  if v_received = 0 then
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
    )
    select v_doc.org_id,
           app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'purchase_receipt' else 'purchase_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           -- Both in the item's own unit. Two cartons of twenty-four
           -- is forty-eight pieces onto the shelf, and RM 480 for them
           -- is RM 10 a piece -- not RM 240, which is what dividing by
           -- the carton count would have made it. 0270.
           v_sign * coalesce(l.base_quantity, l.quantity),
           case when coalesce(l.base_quantity, l.quantity) = 0 then 0
                else round(l.line_subtotal * v_rate
                           / coalesce(l.base_quantity, l.quantity), 6) end,
           'purchase_documents', v_doc.id, l.id, v_entry_id, auth.uid()
      from public.purchase_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_id
       and l.line_type = 'item'
       and i.track_inventory
       and l.quantity > 0;
  end if;

  update public.purchase_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  return v_entry_id;
end;
$function$

;
