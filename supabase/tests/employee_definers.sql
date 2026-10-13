-- =====================================================================
-- iAkauntan :: the company's reports are its staff's (0873, 0874, 0875)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/employee_definers.sql
--
-- A definer reads past every policy, so `0871` and `0872` did not reach
-- the functions that answer any member: an employee with no access type
-- called `report_revenue_trend`, `document_numbering` and
-- `contact_duplicates` and was answered as the owner is, and
-- `stock_on_hand` gave her the stock and what it cost. They ask
-- `app.is_staff_member` now, and refuse her as each refused a stranger.
-- Asked with the role `authenticated`, as the app asks.
--
-- The last block names every definer that asks `is_org_member`: left
-- open to her on purpose, or refusing her by something narrower before
-- it reads. Any other fails it, and so does a name that has stopped
-- being true.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_df (org uuid, staff uuid, viewer uuid, outsider uuid,
  customer uuid, item uuid, invoice_ref uuid, claim uuid);
grant select on t_df to authenticated;

do $$
declare r t_df;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org    := pg_temp.test_org('Laporan Staf Sdn Bhd', array['hr', 'payroll']);
  r.staff  := pg_temp.another_user('staf@laporan.test');
  r.viewer := pg_temp.another_user('lihat@laporan.test');
  -- Somebody with no place in the company at all.
  r.outsider := pg_temp.another_user('orang@luar.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.staff, 'employee', 'active'),
         (r.org, r.viewer, 'viewer', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pelanggan Besar', 'customer')
  returning id into r.customer;
  -- Forty on hand at 2.50, put there the way every movement arrives.
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  insert into public.items (org_id, code, name, item_type, track_inventory,
                            uom_code, unit_price, cost_price)
  values (r.org, 'ITM-1', 'Widget', 'stock', true, 'C62', 20, 2.50)
  returning id into r.item;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
     quantity, unit_cost)
  values (r.org, 'OPEN-1', date '2026-01-01', 'opening_balance', r.item,
          app.default_warehouse(r.org), 40, 2.50);
  -- Her own claim, with its receipt; and a scan on an invoice.
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E1', 'Staf Biasa', r.staff, pg_temp.today());
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, total_amount)
  values (r.org, 'CLM-DF-1',
          (select id from public.employees where org_id = r.org and user_id = r.staff),
          pg_temp.today(), 'Parking', 12.00)
  returning id into r.claim;
  r.invoice_ref := gen_random_uuid();
  insert into public.attachments (org_id, entity_table, entity_id, file_name, storage_path)
  values (r.org, 'expense_claims', r.claim, 'resit.jpg',
          r.org || '/expense_claims/' || r.claim || '/resit.jpg'),
         (r.org, 'sales_documents', r.invoice_ref, 'invoice-scan.pdf',
          r.org || '/sales_documents/' || r.invoice_ref || '/invoice-scan.pdf');
  -- A draft invoice for the dashboard to count, and a project.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, total_amount, base_total_amount)
  values (r.org, 'invoice', 'INV-DRAFT-1', r.customer, 5000, 5000);
  insert into public.projects (org_id, code, name, budget_amount)
  values (r.org, 'P-1', 'Projek Rahsia', 80000);
  insert into t_df select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The employee: nothing of the company's, each refusing in its own way
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select staff from t_df));
set local role authenticated;

do $$
declare d t_df;
begin
  select * into d from t_df;
  perform pg_temp.check_eq('a report answers an employee with nothing',
    (select count(*) from public.report_revenue_trend(d.org, 6))::int, 0);
  perform pg_temp.check_refused('the numbering refuses her',
    format('select * from public.document_numbering(%L)', d.org),
    '%Not a member of organization%', '42501');
  perform pg_temp.check_refused('so do the duplicate contacts',
    format('select * from public.contact_duplicates(%L)', d.org),
    '%Not a member of that company%', '42501');
  perform pg_temp.check_refused('and a customer''s credit',
    format('select * from public.customer_credit_status(%L)', d.customer),
    '%Not a member of organization%', '42501');
  perform pg_temp.check_refused('and the stock on hand (0874)',
    format('select * from public.stock_on_hand(%L)', d.org),
    '%Not a member of organization%', '42501');
  perform pg_temp.check_eq('and the member list (0875)',
    (select count(*) from public.org_team(d.org))::int, 0);
  perform pg_temp.check_refused('she cannot advance the invoice numbers',
    format('select public.next_document_number(%L, %L)', d.org, 'invoice'),
    '%Not a member of organization%', '42501');
  perform pg_temp.check_true('and still numbers her own claim and her leave',
    public.next_document_number(d.org, 'expense_claim') like 'EXP-%'
    and public.next_document_number(d.org, 'leave_request') is not null);
  perform pg_temp.check_refused('the dashboard refuses her (0876)',
    format('select public.dashboard_summary(%L)', d.org),
    '%Not a member of this organization%', '42501');
  perform pg_temp.check_refused('so does the project budget report',
    format('select * from public.report_project_budget(%L)', d.org),
    '%Not your company%', '42501');
  perform pg_temp.check_refused('and the assistant',
    format('select public.ai_ask(%L, %L, null)', d.org, 'Berapa untung kita?'),
    '%Not a member of that company%', '42501');
  perform pg_temp.check_eq('she lists the receipt on her claim, and not the scan on an invoice',
    (select count(*) from public.attachments_of(d.org, 'expense_claims', d.claim)) || ' / '
      || (select count(*) from public.attachments_of(d.org, 'sales_documents', d.invoice_ref)),
    '1 / 0');
end $$;

reset role;

-- Nor is a stranger answered, as before: staff are members first.
select pg_temp.sign_in_as((select outsider from t_df));
set local role authenticated;

do $$
declare d t_df;
begin
  select * into d from t_df;
  perform pg_temp.check_eq('somebody outside the company is answered with nothing too',
    (select count(*) from public.report_revenue_trend(d.org, 6))::int, 0);
  perform pg_temp.check_refused('and takes no claim number of its, either',
    format('select public.next_document_number(%L, %L)', d.org, 'expense_claim'),
    '%Not a member of organization%', '42501');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- A View Only member is answered as the owner is
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select viewer from t_df));
set local role authenticated;

do $$
declare d t_df;
begin
  select * into d from t_df;
  perform pg_temp.check_eq('a View Only member still has the trend, the numbering, the duplicates and the credit',
    (select count(*) from public.report_revenue_trend(d.org, 6)) || ' / '
      || ((select count(*) from public.document_numbering(d.org)) > 0)::text || ' / '
      || (select count(*) from public.contact_duplicates(d.org)) || ' / '
      || (select count(*) from public.customer_credit_status(d.customer)),
    '6 / true / 1 / 1');
  perform pg_temp.check_eq('and the forty on hand at 2.50',
    (select quantity::numeric(12,2) || ' / ' || value from public.stock_on_hand(d.org)),
    '40.00 / 100.00');
  perform pg_temp.check_true('and the member list, and the invoice numbers',
    (select count(*) from public.org_team(d.org)) = 3
    and public.next_document_number(d.org, 'invoice') like 'INV-%');
  -- 0875: `attachments_of` asks what the table and the bucket ask, and
  -- a View Only member could list an invoice's files and open none.
  perform pg_temp.check_eq('and the dashboard and the project budget (0876)',
    (public.dashboard_summary(d.org) ->> 'draft_invoices') || ' / '
      || (select count(*) from public.report_project_budget(d.org)),
    '1 / 1');
  perform pg_temp.check_eq('and lists no file it could not open',
    (select count(*) from public.attachments_of(d.org, 'sales_documents', d.invoice_ref))::int, 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Every definer that asks `is_org_member` is accounted for
-- ---------------------------------------------------------------------
-- Until `0876` this looked for a definer that asks `is_org_member` and
-- nothing narrower anywhere in its body -- and so missed four that ask
-- something narrower for one figure and give the rest to anybody. It
-- names them all now: every definer `authenticated` may call that asks
-- `is_org_member` at all is either left open to her on purpose or
-- refuses her by something narrower before it reads. A new one is
-- neither until somebody says which.
do $$
declare
  -- Hers, or the app's: her approvals and notifications, the rates a
  -- claim is converted at, the modules the shell draws, the company's
  -- name, the people directory, and the logging of what she downloads
  -- or is refused.
  v_open text[] := array[
    'claims_awaiting_my_approval', 'corp_display_name',
    'decide_approval', 'dismiss_notification', 'employee_directory',
    'exchange_rate_board', 'exchange_rate_for', 'log_document_download',
    'mark_all_notifications_read', 'mark_notification_read',
    'my_approvals', 'org_module_surface', 'record_export',
    'report_denied', 'report_feedback'];
  -- Ask `is_org_member` and then something she is not: a ledger
  -- reader, a reader of client money, an auditor, an admin, a platform
  -- admin, the owner of the conversation; or, for
  -- `next_document_number`, staff unless it is her claim's or her
  -- leave's number.
  v_narrower text[] := array[
    'ai_answer', 'ai_conversation', 'ai_conversations_for', 'ai_status',
    'audit_list_payslips', 'audit_view_payslip',
    'bank_reconciliation_status', 'capital_allowance_schedule',
    'depreciation_preview', 'fs_audit_exemption', 'fs_export',
    'fs_prepare', 'link_group_contact', 'matter_client_balance',
    'may_use_workspace', 'module_dashboard', 'my_group_companies',
    'my_module_access', 'next_document_number', 'org_support_access',
    'report_collections', 'report_deferred_revenue',
    'report_group_consolidated_trial_balance',
    'report_group_elimination_check', 'report_group_intercompany',
    'report_group_trial_balance', 'report_with_layout',
    'request_payslip_access', 'set_group_ownership',
    'sub_account_refusal', 'suggest_bank_matches', 'tax_computation',
    'tax_computation_individual', 'tax_computation_lines',
    'tax_estimate_exposure', 'tax_estimate_schedule',
    'tax_partnership_allocation', 'tax_partnership_summary'];
begin
  perform pg_temp.check_eq('every definer that asks is_org_member is named here',
    coalesce((
      select string_agg(distinct p.proname, ', ' order by p.proname)
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
       where p.prosecdef
         and has_function_privilege('authenticated', p.oid, 'execute')
         and p.prosrc ~ 'app\.is_org_member\('
         and p.proname <> all (v_open || v_narrower)), 'none'),
    'none');
  perform pg_temp.check_eq('and every name here still does',
    coalesce((
      select string_agg(x, ', ' order by x)
        from unnest(v_open || v_narrower) x
       where not exists (
         select 1 from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
          where p.proname = x and p.prosecdef
            and p.prosrc ~ 'app\.is_org_member\(')), 'none'),
    'none');
end $$;

rollback;
