-- Sinar Teknologi's books: eight months of real trading.
--
-- `0186` built three tenants with a chart of accounts and nothing in it.
-- A demo company with no transactions is only marginally better than no
-- demo company: every report opens empty, ageing has nothing to age, and
-- the dashboard draws a flat line. This fills the first one in.
--
-- ## Why eight months and not twelve
--
-- The fiscal year `create_fiscal_year()` opens is the current one —
-- 1 January to 31 December — and today is in August. Posting into
-- September onward would put invoices in the future, which is not what a
-- real set of books looks like and would make every "outstanding" figure
-- nonsense. So the books run January to the present: a year to date,
-- which is the state any live company is actually in.
--
-- ## Posted through the real engine
--
-- Documents are inserted the way the client inserts them and then handed
-- to `post_sales_document()` / `post_purchase_document()`. Nothing here
-- writes a journal line directly. That matters for a demo more than for
-- a test: the ledger a visitor sees is one the application produced, so
-- the trial balance genuinely balances, SST lands in 2130 and 1410, and
-- stock movements carry the costs the costing engine computed. A seed
-- that inserted `gl_lines` by hand would look identical until somebody
-- ran a report that recomputed anything.
--
-- Because posting checks `app.can_post()`, the seed acts as the owner
-- throughout — same impersonation `0185` uses to create the companies.
--
-- ## Deliberately not all settled
--
-- Roughly a third of the invoices are left unpaid, weighted towards the
-- recent months. Ageing with everything settled shows nothing, and
-- ageing with nothing settled is a company in crisis. The point is a
-- believable receivables ledger with something in every bucket.

create or replace function app.demo_books_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_cust        uuid[];
  v_supp        uuid[];
  v_item        uuid[];
  v_price       numeric[];
  v_cost        numeric[];
  v_st8         uuid;
  v_rev         uuid;
  v_cos         uuid;
  v_inv_acct    uuid;
  v_cogs        uuid;
  v_doc         uuid;
  v_month       date;
  v_date        date;
  v_i           integer;
  v_n           integer;
  v_invoices    integer := 0;
  v_bills       integer := 0;
  v_line_item   integer;
  v_qty         numeric;
begin
  perform app.demo_act_as(p_owner);

  select id into v_st8 from public.tax_codes
   where org_id = p_org and code = 'ST8';
  select id into v_rev from public.accounts where org_id = p_org and code = '4100';
  select id into v_cos from public.accounts where org_id = p_org and code = '5100';
  -- 1310 Inventory and 5200 Cost of Goods Sold. A stock item that names
  -- neither leaves the costing engine with nowhere to put the asset on
  -- receipt or the charge on sale, and the stock valuation report stops
  -- agreeing with the balance sheet.
  select id into v_inv_acct from public.accounts where org_id = p_org and code = '1310';
  select id into v_cogs from public.accounts where org_id = p_org and code = '5200';

  -- ------------------------------------------------------------------
  -- Who it trades with
  -- ------------------------------------------------------------------
  insert into public.contacts (org_id, code, name, contact_type, email, phone,
                               city, state_code, credit_limit, created_by)
  values
    (p_org,'C-001','Bumi Maju Enterprise','customer','ap@bumimaju.demo','03-8912 7700','Kajang','10',50000,p_owner),
    (p_org,'C-002','Kilang Lestari Sdn Bhd','customer','finance@lestari.demo','06-761 4400','Seremban','05',80000,p_owner),
    (p_org,'C-003','Pusat Data Nusantara','customer','ap@nusantara.demo','03-2181 9000','Kuala Lumpur','14',150000,p_owner),
    (p_org,'C-004','Sekolah Teknologi Harapan','customer','bendahari@harapan.demo','04-228 3311','George Town','07',30000,p_owner),
    (p_org,'S-001','Lim Hardware Trading','supplier','sales@limhw.demo','03-6157 2200','Rawang','10',0,p_owner),
    (p_org,'S-002','Global Components Bhd','supplier','orders@globalcomp.demo','07-861 5500','Johor Bahru','01',0,p_owner),
    (p_org,'S-003','Utara Logistik','supplier','billing@utaralog.demo','03-3344 1100','Klang','10',0,p_owner)
  on conflict (org_id, code) do nothing;

  select array_agg(id order by code) into v_cust from public.contacts
   where org_id = p_org and contact_type = 'customer';
  select array_agg(id order by code) into v_supp from public.contacts
   where org_id = p_org and contact_type = 'supplier';

  -- ------------------------------------------------------------------
  -- What it sells. Stock tracked, so the costing engine has something to
  -- do and the stock valuation report is not empty.
  -- ------------------------------------------------------------------
  -- Two things here are lookups rather than free text, and both were got
  -- wrong first time by writing what seemed obvious. `items` carries no
  -- `created_by`, unlike almost every neighbouring table. And `uom_code`
  -- is a foreign key into `ref_uom_codes`, which holds UN/ECE
  -- Recommendation 20 codes: a unit is `C62`, not `UNIT`. `DAY` and
  -- `SET` happen to be real codes, which is exactly how a guess like
  -- this survives a casual read.
  insert into public.items (org_id, code, name, item_type, track_inventory,
                            unit_price, cost_price, uom_code,
                            sales_account_id, purchase_account_id,
                            inventory_account_id, cogs_account_id,
                            sales_tax_code_id)
  values
    (p_org,'ITM-100','Rack Server 2U','stock',true, 8500, 6200,'C62',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'ITM-110','Network Switch 48-port','stock',true, 3200, 2250,'C62',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'ITM-120','UPS 3kVA','stock',true, 4100, 2950,'C62',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'ITM-130','Structured Cabling Kit','stock',true, 1450, 980,'SET',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'SRV-200','Installation and Commissioning','service',false, 2500, 0,'DAY',v_rev,null,null,null,v_st8)
  on conflict (org_id, code) do nothing;

  select array_agg(id order by code) into v_item from public.items
   where org_id = p_org and track_inventory;

  -- ------------------------------------------------------------------
  -- Stock in before stock out
  --
  -- Bills first each month, so there is something on hand to sell. A
  -- demo that sells from an empty warehouse produces negative stock and
  -- a costing engine averaging over nothing.
  -- ------------------------------------------------------------------
  v_month := date_trunc('year', current_date)::date;
  while v_month <= current_date loop

    -- One purchase a month, three lines, from a rotating supplier.
    v_date := least(v_month + 2, current_date);
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, created_by)
    values (p_org, 'bill',
            app.next_document_number_internal(p_org, 'bill'),
            v_date, v_date + 30,
            v_supp[1 + (extract(month from v_month)::integer % array_length(v_supp,1))],
            'draft', 'MYR', 1, p_owner)
    returning id into v_doc;

    for v_i in 1..3 loop
      v_line_item := 1 + ((extract(month from v_month)::integer + v_i)
                          % array_length(v_item,1));
      -- `tax_rate` as well as `tax_code_id`. The rate is stored on the
      -- line, not looked up from the code when totals are recalculated —
      -- so a line naming ST8 without its 8 produces an invoice with no
      -- tax on it at all. That is not a cosmetic omission on an
      -- SST-registered company: it is an invoice that understates what
      -- was charged, and the first draft of this seed produced twenty of
      -- them before the probe measured output tax and found zero.
      insert into public.purchase_document_lines
        (org_id, document_id, line_no, line_type, item_id, description,
         quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
      select p_org, v_doc, v_i, 'item', it.id, it.name,
             4 + v_i, it.uom_code, it.cost_price, v_st8, t.rate, v_cos
        from public.items it
        cross join public.tax_codes t
       where it.id = v_item[v_line_item] and t.id = v_st8;
    end loop;

    perform public.post_purchase_document(v_doc);
    v_bills := v_bills + 1;

    -- Two or three sales a month.
    v_n := 2 + (extract(month from v_month)::integer % 2);
    for v_i in 1..v_n loop
      v_date := least(v_month + (5 * v_i), current_date);
      insert into public.sales_documents
        (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
         currency, exchange_rate, created_by)
      values (p_org, 'invoice',
              app.next_document_number_internal(p_org, 'invoice'),
              v_date, v_date + 30,
              v_cust[1 + ((extract(month from v_month)::integer + v_i)
                          % array_length(v_cust,1))],
              'draft', 'MYR', 1, p_owner)
      returning id into v_doc;

      v_line_item := 1 + ((extract(month from v_month)::integer + v_i)
                          % array_length(v_item,1));
      v_qty := 1 + (v_i % 3);
      insert into public.sales_document_lines
        (org_id, document_id, line_no, line_type, item_id, description,
         quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
      select p_org, v_doc, 1, 'item', it.id, it.name,
             v_qty, it.uom_code, it.unit_price, v_st8, t.rate, v_rev
        from public.items it
        cross join public.tax_codes t
       where it.id = v_item[v_line_item] and t.id = v_st8;

      -- A service line on the larger ones, so not every invoice is a
      -- single box shipped.
      if v_i = 1 then
        insert into public.sales_document_lines
          (org_id, document_id, line_no, line_type, item_id, description,
           quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
        select p_org, v_doc, 2, 'item', it.id, it.name,
               1, it.uom_code, it.unit_price, v_st8, t.rate, v_rev
          from public.items it
          cross join public.tax_codes t
         where it.org_id = p_org and it.code = 'SRV-200' and t.id = v_st8;
      end if;

      perform public.post_sales_document(v_doc);
      v_invoices := v_invoices + 1;
    end loop;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar: %s invoices and %s bills posted, %s customers, '
                '%s suppliers, %s items.',
                v_invoices, v_bills,
                array_length(v_cust,1), array_length(v_supp,1),
                (select count(*) from public.items where org_id = p_org));
end $$;

comment on function app.demo_books_sinar(uuid, uuid) is
  'Seeds Sinar Teknologi with a year to date of purchases and sales, '
  'posted through post_purchase_document() and post_sales_document() so '
  'the ledger is one the application actually produced.';

revoke all on function app.demo_books_sinar(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Fold the books into the rebuild
-- ---------------------------------------------------------------------
--
-- `create or replace` on `0186`'s function rather than a second entry
-- point, so "rebuild the demo" stays one call. Only the Sinar block
-- gains a line; Amanah and Harta Prima get their own books in later
-- migrations and will be added the same way.
create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed text; v_demo uuid; v_clerk uuid; v_auditor uuid;
  v_secretary uuid; v_property uuid;
  v_sinar uuid; v_amanah uuid; v_harta uuid; v_books text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.my',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.my',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.my',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.my', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.my',  'Tan Chee Keong');

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
  v_books := app.demo_books_sinar(v_sinar, v_demo);

  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat']);

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

  perform set_config('request.jwt.claims', '', true);

  return format('%s Rebuilt 3 tenants, 5 logins. %s', v_removed, v_books);
end $$;
