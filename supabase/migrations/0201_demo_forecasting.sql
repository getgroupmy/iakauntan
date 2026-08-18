-- Forecasting for the demo tenant.
--
-- Two jobs. Turn the module on for Sinar — `demo_rebuild.sql` asserts
-- that no active module is left without a tenant to show it in, and
-- registering one without a demo is how a module ships that nobody can
-- look at. And give it enough of a purchase history that the lead time
-- is measured rather than defaulted.
--
-- ## Why this back-fills purchase orders
--
-- Sinar's books were seeded the way a small business actually works:
-- the supplier invoice is entered and the stock lands with it. No
-- purchase orders, which means `app.measured_lead_time` correctly
-- returns null for every item and every reorder point falls back to
-- the fourteen-day default. The feature works and demonstrates
-- nothing.
--
-- So each existing bill gets the order it would have come from, dated
-- earlier by an amount that varies per supplier, and the bill's lines
-- are pointed back at the order's lines through `source_line_id` —
-- which is the same link the "transfer to the next document" flow
-- creates when a real buyer raises an order and bills against it.
--
-- The orders are `completed`, not open: the stock already arrived, and
-- an open order would be counted as quantity on the way and suppress
-- the very suggestions this is here to show.
--
-- ## Monthly buckets, deliberately
--
-- Sinar sells these items a handful of times a year. In weekly buckets
-- that is fifty-two periods of which five are non-zero, which is an
-- honest forecast of almost nothing and an unreadable chart. Monthly
-- buckets put the signal above the noise. It is a demo setting, chosen
-- for the data that exists rather than to flatter the model.

create or replace function app.demo_forecast_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bill      record;
  v_line      record;
  v_po        uuid;
  v_po_line   uuid;
  v_lead      integer;
  v_seq       integer := 0;
  v_orders    integer := 0;
  v_linked    integer := 0;
  v_run       uuid;
  v_lines     integer;
  v_suggested integer;
  v_measured  integer;
  v_item      uuid;
begin
  -- Act as the owner before anything guarded is called.
  --
  -- The seeder that runs immediately before this one signs out on its
  -- way out — `set_config('request.jwt.claims', '', true)` — so this
  -- function starts with no caller at all. `app.module_access` returns
  -- 'none' the moment `auth.uid()` is null, so `run_inventory_forecast`
  -- refused with "not permitted", which reads like a permissions bug in
  -- the module and is nothing of the sort.
  --
  -- The tell was in this function's own signature: it took `p_owner`
  -- and never used it.
  perform app.demo_act_as(p_owner);

  perform app.demo_modules(p_org, array['forecasting']);

  insert into public.forecast_settings (
    org_id, bucket, horizon_buckets, history_days, default_method,
    default_window, service_level, default_lead_time_days, min_periods)
  values (p_org, 'month', 3, 365, 'moving_average', 3, 0.9500, 14, 3)
  on conflict (org_id) do update
     set bucket = excluded.bucket,
         horizon_buckets = excluded.horizon_buckets,
         default_method = excluded.default_method,
         default_window = excluded.default_window,
         min_periods = excluded.min_periods;

  -- --------------------------------------------------------------
  -- The order each bill would have come from
  -- --------------------------------------------------------------
  for v_bill in
    select d.id, d.doc_date, d.contact_id, d.currency
      from public.purchase_documents d
     where d.org_id = p_org
       and d.doc_type = 'bill'
       and exists (select 1 from public.stock_movements m
                    where m.org_id = p_org
                      and m.movement_type = 'purchase_receipt'
                      and m.source_id = d.id)
     order by d.doc_date
  loop
    v_seq := v_seq + 1;

    -- Between five and twelve days, walked deterministically rather
    -- than randomly so the demo tells the same story every rebuild and
    -- the median is a number somebody can check by hand.
    v_lead := 5 + (v_seq * 3) % 8;

    insert into public.purchase_documents
      (org_id, doc_type, doc_no, contact_id, doc_date, expected_date,
       currency, status)
    values
      (p_org, 'purchase_order', 'PO-DEMO-' || lpad(v_seq::text, 4, '0'),
       v_bill.contact_id, v_bill.doc_date - v_lead,
       v_bill.doc_date, coalesce(v_bill.currency, 'MYR'), 'completed')
    returning id into v_po;
    v_orders := v_orders + 1;

    for v_line in
      select l.id, l.line_no, l.item_id, l.description, l.quantity,
             l.uom_code, l.unit_price, l.warehouse_id
        from public.purchase_document_lines l
       where l.document_id = v_bill.id
         and l.item_id is not null
       order by l.line_no
    loop
      insert into public.purchase_document_lines
        (org_id, document_id, line_no, line_type, item_id, description,
         quantity, quantity_received, uom_code, unit_price, warehouse_id)
      values
        (p_org, v_po, v_line.line_no, 'item', v_line.item_id, v_line.description,
         v_line.quantity, v_line.quantity, v_line.uom_code, v_line.unit_price,
         v_line.warehouse_id)
      returning id into v_po_line;

      -- The link the lead time is measured along.
      update public.purchase_document_lines
         set source_line_id = v_po_line
       where id = v_line.id;
      v_linked := v_linked + 1;
    end loop;
  end loop;

  -- --------------------------------------------------------------
  -- One item buys in cartons, so the rounding is visible
  -- --------------------------------------------------------------
  select i.id into v_item
    from public.items i
   where i.org_id = p_org and i.track_inventory and i.is_active
   order by i.code
   limit 1;

  if v_item is not null then
    insert into public.item_forecast_params
      (org_id, item_id, min_order_quantity, order_multiple, notes)
    values
      (p_org, v_item, 6, 6,
       'Ships in cartons of six, minimum one carton — so a suggestion of '
       'seven becomes twelve rather than being rounded down by whoever '
       'types the order')
    on conflict do nothing;
  end if;

  -- --------------------------------------------------------------
  -- And run one, so the screen has something to open on
  -- --------------------------------------------------------------
  v_run := public.run_inventory_forecast(p_org);

  select count(*),
         count(*) filter (where suggested_qty > 0),
         count(*) filter (where lead_time_source = 'measured')
    into v_lines, v_suggested, v_measured
    from public.forecast_lines where run_id = v_run;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Sinar forecasting: %s back-dated orders linked to %s bill line(s), '
    '%s item(s) forecast, %s to order, %s on a measured lead time.',
    v_orders, v_linked, v_lines, v_suggested, v_measured);
end;
$$;

revoke all on function app.demo_forecast_sinar(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Into the rebuild
-- ---------------------------------------------------------------------
--
-- Restated in full rather than patched, because a `create or replace`
-- that only somebody's memory says matches the previous body is how a
-- rebuild quietly loses a tenant. The only additions are the
-- forecasting call and its place in the summary.
create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed text; v_demo uuid; v_clerk uuid; v_auditor uuid;
  v_secretary uuid; v_property uuid;
  v_sinar uuid; v_amanah uuid; v_harta uuid;
  v_books text; v_books_a text; v_books_h text;
  v_cash text; v_assets text; v_pay text; v_desk text; v_fc text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.com',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.com',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.com',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.com', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.com',  'Tan Chee Keong');

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
  v_books  := app.demo_books_sinar(v_sinar, v_demo);
  v_cash   := app.demo_sinar_bank(v_sinar, v_demo);
  v_assets := app.demo_sinar_assets(v_sinar, v_demo);
  v_pay    := app.demo_sinar_payroll(v_sinar, v_demo);
  v_desk   := app.demo_tickets_sinar(v_sinar, v_demo);
  -- After the books and the bills, because it reads both.
  v_fc     := app.demo_forecast_sinar(v_sinar, v_demo);
  perform app.demo_sync_bank_balance(v_sinar);

  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat']);
  v_books_a := app.demo_books_amanah(v_amanah, v_secretary);

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
  v_books_h := app.demo_books_harta(v_harta, v_property);

  perform set_config('request.jwt.claims', '', true);

  return format('%s Rebuilt 3 tenants, 5 logins. %s %s %s %s %s %s %s %s',
                v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
                v_books_a, v_books_h);
end;
$$;
