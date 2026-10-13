-- =====================================================================
-- iAkauntan :: 0872 an employee reads her own, and not the company's
--
-- `0871` held an `employee` with no access type to HR and payroll
-- through `app.module_access`, which shut every module gate to her. It
-- left the tables no module gate stands in front of, and there are many:
-- their read policies ask `is_org_member` and nothing else, so she still
-- read the chart of accounts, projects, time entries, opportunities and
-- pipelines, stock levels and lots, e-invoices sent and received, SST
-- returns and tax filings, payment terms and methods, email templates and
-- the outbox, report layouts, import batches, the company's MIA
-- credentials, its credit balance and what it has paid the platform --
-- and the member list, everybody's role with it.
--
-- Measured on 13 October 2026, locally, after `0871`, as an `employee`
-- member with no access type, with the role `authenticated`: the 85
-- accounts of the chart, a project, the company's access types and all
-- four members, as the owner sees them.
--
-- Production held no `employee` member on 13 October.
--
-- Answered "an employee reaches only HR", the second step. A
-- restrictive read policy on each of those tables refuses a member whose
-- only standing in the company is `employee` with no access type --
-- `app.is_self_service_only` -- and nobody else: a restrictive policy
-- only ever takes away, so what every other member, a platform admin or
-- a firm member could read before, they read now. On `org_members` she
-- keeps her own row, which is how the app knows who she is.
--
-- Left readable to her, because self-service needs them or because they
-- are the company's frame rather than its records: the company itself,
-- its modules, branches, departments, positions, shifts, holidays,
-- leave and claim types and their settings, appraisal cycles, the
-- onboarding templates `0038` made HR reference, custom field
-- definitions, fiscal years and periods, exchange rates, tax codes, the
-- login page and promotions, the change feed, and her own
-- notifications, to-dos and AI conversations. `payment_batches` and
-- `access_type_modules` are read through a parent shut here.
--
-- `employee_self_service.sql` holds the list, and refuses a table any
-- member can read that is on neither side of it.
-- =====================================================================

-- Status is not asked: a member who is not active is refused by every
-- read policy this stands beside, `is_org_member` being the first.
create or replace function app.is_self_service_only(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select exists (
    select 1 from public.org_members m
     where m.org_id = p_org_id
       and m.user_id = auth.uid()
       and m.role = 'employee'
       and m.access_type_id is null);
$$;

revoke all on function app.is_self_service_only(uuid) from public, anon;
grant execute on function app.is_self_service_only(uuid) to authenticated;

comment on function app.is_self_service_only(uuid) is
  'Whether the caller''s only standing in this company is an employee with no access type -- self-service, her own record, leave, claims and payslips, and none of the company''s records (0871, 0872).';

do $$
declare
  t text;
begin
  foreach t in array array[
    'access_types', 'accounts', 'activities', 'approval_requests',
    'approval_steps', 'bank_accounts', 'billing_rates', 'contact_addresses',
    'contact_persons', 'corp_templates', 'customer_portal_links', 'disbursements',
    'document_downloads', 'document_line_lots', 'document_share_links', 'einvoice_consolidation_items',
    'einvoice_consolidations', 'einvoice_documents', 'einvoice_lines', 'einvoice_submissions',
    'email_outbox', 'email_settings', 'email_templates', 'import_batches',
    'import_rows', 'item_categories', 'mia_credentials', 'number_sequences',
    'opportunities', 'opportunity_stage_history', 'org_ai_settings', 'org_credits',
    'org_mailboxes', 'org_ocr_settings', 'org_subdomains', 'payment_allocations',
    'payment_methods', 'payment_terms', 'pipeline_stages', 'pipelines',
    'platform_payments', 'price_levels', 'projects', 'received_einvoice_lines',
    'received_einvoices', 'recurring_documents', 'report_layout_rows', 'report_layouts',
    'revenue_schedule_periods', 'salespeople', 'sst_returns', 'stock_adjustment_lines',
    'stock_adjustments', 'stock_levels', 'stock_lots', 'stock_movement_lots',
    'support_access', 'tax_detail_requests', 'tax_detail_submissions', 'tax_filings',
    'ticket_share_links', 'time_entries', 'tin_validations', 'withholding_certificates']
  loop
    execute format(
      'create policy staff_records_select on public.%I
         as restrictive for select to authenticated
         using (not app.is_self_service_only(org_id))', t);
  end loop;
end $$;

create policy staff_records_select on public.org_members
  as restrictive for select to authenticated
  using (user_id = auth.uid() or not app.is_self_service_only(org_id));
