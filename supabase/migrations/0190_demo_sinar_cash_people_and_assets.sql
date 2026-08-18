-- Sinar gets a bank account, staff and things it owns.
--
-- `0187` gave Sinar a year of trading. What it did not give it was any
-- cash: the company had no bank account at all, so every invoice sat
-- unpaid, every bill sat unsettled, the aging reports had one bucket,
-- and bank reconciliation opened on nothing. It also had no employees
-- and owned nothing, which left the payroll engine and the fixed asset
-- register — two of the larger things this product does — with no data
-- to show.
--
-- ## Why capital comes first
--
-- Sinar bought 481,334.40 of stock in eight months and invoiced
-- 235,116.00. A company cannot do that out of receipts; it does it out
-- of paid-up capital. So the seed opens with a share issue, which is
-- both what actually happens and what makes the year end on a positive
-- bank balance rather than an overdraft nobody arranged.
--
-- ## Settled, but not all of it
--
-- Invoices older than 45 days are receipted and bills older than 60 days
-- are paid. The rest stay open on purpose: an aging report where every
-- balance is current tells you nothing, and one where everything is
-- settled is a blank screen. Both buckets need something in them.
--
-- ## The bank balance is read from the ledger, not accumulated
--
-- `post_receipt` and `post_purchase_payment` each move
-- `bank_accounts.current_balance` themselves, but a journal that touches
-- 1120 directly — the capital, an asset bought for cash, a salary run —
-- does not. Rather than have every caller remember to adjust it and
-- drift the first time one forgets, `app.demo_sync_bank_balance()` sets
-- the column from the general ledger once everything has posted. The
-- ledger is the authority; the column is a cache.
--
-- ## Assets are bought inside the year
--
-- Sinar's only fiscal year is the current one, so an asset acquired
-- earlier would either fail to post or dump every prior month's
-- depreciation into one catch-up charge and misstate the year. Each
-- asset is acquired during the year, its cost posted to the ledger — a
-- register showing plant the balance sheet has never heard of is worse
-- than an empty one — and then depreciated month by month, which is the
-- shape the depreciation schedule screen exists to show.
--
-- ## Payroll runs all the way to the bank
--
-- `post_payroll_run()` credits net pay to 2145 and stops, which is
-- correct: the transfer is a separate act. But a demo that stops there
-- shows seven months of wages owing to people who were paid, so the seed
-- makes the payment too, and remits EPF, SOCSO, EIS and PCB by the
-- fifteenth of the following month — the statutory deadline, so months
-- whose deadline has not arrived stay outstanding rather than being
-- settled early.
--
-- Note that this seed needs `0189`. Without account 2145 in the chart,
-- `post_payroll_run()` raises on the first run and none of this works.

-- ---------------------------------------------------------------------
-- The bank balance, taken from the ledger
-- ---------------------------------------------------------------------
create or replace function app.demo_sync_bank_balance(p_org uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_bal numeric(18,2);
begin
  select coalesce(sum(l.debit - l.credit), 0) into v_bal
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.bank_accounts b on b.account_id = l.account_id
   where e.org_id = p_org and e.status = 'posted' and b.org_id = p_org;

  update public.bank_accounts set current_balance = v_bal where org_id = p_org;
  return v_bal;
end $$;

-- ---------------------------------------------------------------------
-- Cash: an account, the capital that started it, and settlement
-- ---------------------------------------------------------------------
create or replace function app.demo_sinar_bank(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bank_gl  uuid;
  v_capital  uuid;
  v_bank     uuid;
  v_doc      record;
  v_id       uuid;
  v_date     date;
  v_receipts integer := 0;
  v_payments integer := 0;
  v_in       numeric(18,2) := 0;
  v_out      numeric(18,2) := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_bank_gl from public.accounts where org_id = p_org and code = '1120';
  select id into v_capital from public.accounts where org_id = p_org and code = '3100';

  insert into public.bank_accounts (org_id, account_id, name, bank_name, bank_code,
                                    account_number, account_type, currency,
                                    opening_balance, current_balance, is_default)
  values (p_org, v_bank_gl, 'Maybank Current Account', 'Malayan Banking Berhad',
          'MBBEMYKL', '514233880011', 'current', 'MYR', 0, 0, true)
  on conflict do nothing;
  select id into v_bank from public.bank_accounts
   where org_id = p_org and account_number = '514233880011';

  perform public.create_gl_entry(
    p_org, date_trunc('year', current_date)::date + 1, 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank_gl,
        'description', 'Paid-up capital', 'debit', 700000, 'credit', 0),
      jsonb_build_object('account_id', v_capital,
        'description', 'Paid-up capital', 'debit', 0, 'credit', 700000)),
    'Issue of ordinary shares — paid-up capital', null, null, 'SC-2026-01');

  for v_doc in select d.id, d.doc_no, d.contact_id, d.doc_date, d.total_amount
                 from public.sales_documents d
                where d.org_id = p_org and d.doc_type = 'invoice'
                  and d.status = 'posted'
                  and d.doc_date <= current_date - 45
                order by d.doc_date, d.doc_no loop
    v_date := least(v_doc.doc_date + 21, current_date);

    insert into public.receipts (org_id, receipt_no, receipt_date, contact_id,
                                 payment_mode_code, bank_account_id, reference,
                                 currency, exchange_rate, amount, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'receipt'), v_date,
            v_doc.contact_id, '03', v_bank, 'Settlement of ' || v_doc.doc_no,
            'MYR', 1, v_doc.total_amount, p_owner)
    returning id into v_id;

    insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
    values (p_org, v_id, v_doc.id, v_doc.total_amount);

    perform public.post_receipt(v_id);
    v_receipts := v_receipts + 1;
    v_in := v_in + v_doc.total_amount;
  end loop;

  for v_doc in select d.id, d.doc_no, d.contact_id, d.doc_date, d.total_amount
                 from public.purchase_documents d
                where d.org_id = p_org and d.doc_type = 'bill'
                  and d.status = 'posted'
                  and d.doc_date <= current_date - 60
                order by d.doc_date, d.doc_no loop
    v_date := least(v_doc.doc_date + 35, current_date);

    insert into public.purchase_payments (org_id, payment_no, payment_date, contact_id,
                                          payment_mode_code, bank_account_id, reference,
                                          currency, exchange_rate, amount, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'payment'), v_date,
            v_doc.contact_id, '03', v_bank, 'Settlement of ' || v_doc.doc_no,
            'MYR', 1, v_doc.total_amount, p_owner)
    returning id into v_id;

    insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
    values (p_org, v_id, v_doc.id, v_doc.total_amount);

    perform public.post_purchase_payment(v_id);
    v_payments := v_payments + 1;
    v_out := v_out + v_doc.total_amount;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar cash: %s receipts (%s) and %s supplier payments (%s).',
                v_receipts, v_in, v_payments, v_out);
end $$;

-- ---------------------------------------------------------------------
-- Things the company owns, and the depreciation that follows
-- ---------------------------------------------------------------------
create or replace function app.demo_sinar_assets(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_ppe    uuid;
  v_veh    uuid;
  v_accum  uuid;
  v_exp    uuid;
  v_bank   uuid;
  v_a      record;
  v_month  date;
  v_end    date;
  v_runs   integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_ppe   from public.accounts where org_id = p_org and code = '1510';
  select id into v_veh   from public.accounts where org_id = p_org and code = '1520';
  select id into v_accum from public.accounts where org_id = p_org and code = '1590';
  select id into v_exp   from public.accounts where org_id = p_org and code = '6400';
  select id into v_bank  from public.accounts where org_id = p_org and code = '1120';

  insert into public.fixed_assets
    (org_id, asset_no, name, description, category, asset_account_id,
     accumulated_account_id, expense_account_id, acquisition_date, cost,
     residual_value, method, useful_life_months, location, created_by)
  values
    (p_org,'FA-001','Delivery van (WXY 4412)','Nissan NV200 panel van',
     'Motor vehicles', v_veh, v_accum, v_exp,
     date_trunc('year', current_date)::date + 24, 96000, 12000,
     'straight_line', 60, 'Petaling Jaya', p_owner),
    (p_org,'FA-002','Warehouse racking','Six bays of pallet racking',
     'Plant and equipment', v_ppe, v_accum, v_exp,
     date_trunc('year', current_date)::date + 52, 38500, 0,
     'straight_line', 120, 'Petaling Jaya', p_owner),
    (p_org,'FA-003','Server and network cabinet','Rack, switch and UPS',
     'Office equipment', v_ppe, v_accum, v_exp,
     date_trunc('year', current_date)::date + 96, 27400, 2000,
     'straight_line', 48, 'Petaling Jaya', p_owner),
    (p_org,'FA-004','Office fit-out','Partitions, desks and lighting',
     'Furniture and fittings', v_ppe, v_accum, v_exp,
     date_trunc('year', current_date)::date + 140, 61200, 0,
     'straight_line', 120, 'Petaling Jaya', p_owner)
  on conflict (org_id, asset_no) do nothing;

  for v_a in select asset_no, name, asset_account_id, acquisition_date, cost
               from public.fixed_assets fa
              where fa.org_id = p_org and fa.deleted_at is null
                and not exists (select 1 from public.gl_entries e
                                 where e.org_id = p_org
                                   and e.reference = 'ACQ-' || fa.asset_no)
              order by fa.asset_no loop
    perform public.create_gl_entry(
      p_org, v_a.acquisition_date, 'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_a.asset_account_id,
          'description', v_a.name, 'debit', v_a.cost, 'credit', 0),
        jsonb_build_object('account_id', v_bank,
          'description', v_a.name, 'debit', 0, 'credit', v_a.cost)),
      'Acquisition of ' || v_a.name, null, null, 'ACQ-' || v_a.asset_no);
  end loop;

  v_month := date_trunc('year', current_date)::date;
  while v_month < date_trunc('month', current_date)::date loop
    v_end := (v_month + interval '1 month')::date - 1;
    if public.run_depreciation(p_org, v_end) is not null then
      v_runs := v_runs + 1;
    end if;
    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar assets: %s assets costing %s, %s monthly depreciation runs.',
                (select count(*) from public.fixed_assets where org_id = p_org),
                (select coalesce(sum(cost),0) from public.fixed_assets where org_id = p_org),
                v_runs);
end $$;

-- ---------------------------------------------------------------------
-- Staff, and a payroll that reaches the bank
-- ---------------------------------------------------------------------
create or replace function app.demo_sinar_payroll(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bank    uuid;
  v_net     uuid;
  v_epf     uuid;
  v_socso   uuid;
  v_eis     uuid;
  v_pcb     uuid;
  v_month   date;
  v_end     date;
  v_period  uuid;
  v_run     uuid;
  v_r       record;
  v_due     date;
  v_lines   jsonb;
  v_total   numeric(18,2);
  v_runs    integer := 0;
  v_paid    integer := 0;
  v_remits  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_bank  from public.accounts where org_id = p_org and code = '1120';
  select id into v_net   from public.accounts where org_id = p_org and code = '2145';
  select id into v_epf   from public.accounts where org_id = p_org and code = '2150';
  select id into v_socso from public.accounts where org_id = p_org and code = '2160';
  select id into v_eis   from public.accounts where org_id = p_org and code = '2170';
  select id into v_pcb   from public.accounts where org_id = p_org and code = '2180';

  insert into public.employees
    (org_id, employee_no, full_name, email, nric, nationality, residency_status,
     date_of_birth, gender, marital_status, spouse_is_working,
     employment_type, employment_status, hire_date, confirmation_date,
     pay_frequency, basic_salary, bank_name, bank_account_no, bank_account_holder,
     epf_no, socso_no, income_tax_no, city, state_code, created_by)
  values
    (p_org,'EMP-001','Aisyah binti Rahman','aisyah@sinartek.demo','880412-14-5210','MY','citizen',
     date '1988-04-12','F','married',true,'full_time','active',
     date '2021-02-01', date '2021-08-01','monthly', 9500,
     'Maybank','114422335566','Aisyah binti Rahman','E1140221','S8804125','SG10245678901',
     'Petaling Jaya','10', p_owner),
    (p_org,'EMP-002','Wong Mei Ling','meiling@sinartek.demo','930817-10-5388','MY','citizen',
     date '1993-08-17','F','single',false,'full_time','active',
     date '2022-06-15', date '2022-12-15','monthly', 5200,
     'CIMB Bank','800455119922','Wong Mei Ling','E1220615','S9308175','SG10245678902',
     'Shah Alam','10', p_owner),
    (p_org,'EMP-003','Ravi a/l Subramaniam','ravi@sinartek.demo','900225-08-5471','MY','citizen',
     date '1990-02-25','M','married',false,'full_time','active',
     date '2023-01-09', date '2023-07-09','monthly', 4300,
     'Public Bank','331299887744','Ravi a/l Subramaniam','E1230109','S9002255','SG10245678903',
     'Klang','10', p_owner),
    (p_org,'EMP-004','Muhammad Faiz bin Osman','faiz@sinartek.demo','990703-14-5029','MY','citizen',
     date '1999-07-03','M','single',false,'full_time','active',
     date '2024-03-04', date '2024-09-04','monthly', 2900,
     'Bank Islam','770011223344','Muhammad Faiz bin Osman','E1240304','S9907035','SG10245678904',
     'Petaling Jaya','10', p_owner)
  on conflict (org_id, employee_no) do nothing;

  v_month := date_trunc('year', current_date)::date;
  while v_month < date_trunc('month', current_date)::date loop
    v_end := (v_month + interval '1 month')::date - 1;

    insert into public.pay_periods (org_id, code, period_start, period_end,
                                    pay_date, frequency)
    values (p_org, to_char(v_month, 'YYYY-MM'), v_month, v_end, v_end, 'monthly')
    on conflict (org_id, code) do nothing;
    select id into v_period from public.pay_periods
     where org_id = p_org and code = to_char(v_month, 'YYYY-MM');

    if not exists (select 1 from public.payroll_runs
                    where org_id = p_org and period_id = v_period) then
      v_run := public.create_payroll_run(
        p_org, v_period, 'Monthly payroll — ' || to_char(v_month, 'Mon YYYY'));
      perform public.calculate_payroll_run(v_run);
      perform public.post_payroll_run(v_run);
      perform public.mark_payroll_paid(v_run);
      v_runs := v_runs + 1;

      select * into v_r from public.payroll_runs where id = v_run;

      -- Staff are actually paid. post_payroll_run credits net pay to
      -- 2145 and stops there, which is right — the bank transfer is a
      -- separate act — but a demo that never makes it leaves four
      -- months of wages owing to people who were paid.
      if v_r.total_net > 0 then
        perform public.create_gl_entry(
          p_org, v_end, 'manual'::app.journal_source,
          jsonb_build_array(
            jsonb_build_object('account_id', v_net,
              'description', 'Net salaries paid', 'debit', v_r.total_net, 'credit', 0),
            jsonb_build_object('account_id', v_bank,
              'description', 'Net salaries paid', 'debit', 0, 'credit', v_r.total_net)),
          'Salary payment — ' || to_char(v_month, 'Mon YYYY'),
          null, null, 'SAL-' || to_char(v_month, 'YYYYMM'));
        v_paid := v_paid + 1;
      end if;

      -- EPF, SOCSO, EIS and PCB are remitted by the fifteenth of the
      -- following month. Months whose deadline has not arrived stay
      -- outstanding, which is what the statutory payables screen is for.
      v_due := (v_month + interval '1 month')::date + 14;
      if v_due <= current_date then
        v_lines := '[]'::jsonb;
        v_total := 0;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_epf, 'description', 'EPF remitted',
          'debit', v_r.total_epf_employee + v_r.total_epf_employer, 'credit', 0));
        v_total := v_total + v_r.total_epf_employee + v_r.total_epf_employer;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_socso, 'description', 'SOCSO remitted',
          'debit', v_r.total_socso_employee + v_r.total_socso_employer, 'credit', 0));
        v_total := v_total + v_r.total_socso_employee + v_r.total_socso_employer;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_eis, 'description', 'EIS remitted',
          'debit', v_r.total_eis_employee + v_r.total_eis_employer, 'credit', 0));
        v_total := v_total + v_r.total_eis_employee + v_r.total_eis_employer;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_pcb, 'description', 'PCB / MTD remitted',
          'debit', v_r.total_pcb, 'credit', 0));
        v_total := v_total + v_r.total_pcb;

        if v_total > 0 then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_bank, 'description', 'Statutory remittance',
            'debit', 0, 'credit', v_total));
          perform public.create_gl_entry(
            p_org, v_due, 'manual'::app.journal_source, v_lines,
            'Statutory remittance for ' || to_char(v_month, 'Mon YYYY'),
            null, null, 'STAT-' || to_char(v_month, 'YYYYMM'));
          v_remits := v_remits + 1;
        end if;
      end if;
    end if;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar payroll: %s employees, %s runs posted and paid, '
                '%s salary payments, %s statutory remittances.',
                (select count(*) from public.employees where org_id = p_org),
                v_runs, v_paid, v_remits);
end $$;

-- ---------------------------------------------------------------------
-- One call still rebuilds the whole demo
-- ---------------------------------------------------------------------
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
  v_cash text; v_assets text; v_pay text;
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
  v_books  := app.demo_books_sinar(v_sinar, v_demo);
  v_cash   := app.demo_sinar_bank(v_sinar, v_demo);
  v_assets := app.demo_sinar_assets(v_sinar, v_demo);
  v_pay    := app.demo_sinar_payroll(v_sinar, v_demo);
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

  return format('%s Rebuilt 3 tenants, 5 logins. %s %s %s %s %s %s',
                v_removed, v_books, v_cash, v_assets, v_pay,
                v_books_a, v_books_h);
end $$;

revoke all on function app.demo_sync_bank_balance(uuid)   from public, anon, authenticated;
revoke all on function app.demo_sinar_bank(uuid, uuid)    from public, anon, authenticated;
revoke all on function app.demo_sinar_assets(uuid, uuid)  from public, anon, authenticated;
revoke all on function app.demo_sinar_payroll(uuid, uuid) from public, anon, authenticated;
