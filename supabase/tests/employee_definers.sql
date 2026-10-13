-- =====================================================================
-- iAkauntan :: the company's reports are its staff's (0873, 0874, 0875)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/employee_definers.sql
--
-- A definer reads past every policy, so `0871` and `0872` did not reach
-- the functions that answer any member: an employee with no access type
-- called `report_revenue_trend`, `document_numbering` and
-- `contact_duplicates` and was answered as the owner is. They ask
-- `app.is_staff_member` now, and refuse her as each refused a stranger.
-- Asked with the role `authenticated`, as the app asks.
--
-- The last block keeps two lists: the definers left open to her on
-- purpose, and those not yet done. Any other definer that asks
-- `is_org_member` and nothing narrower fails it, and so does a name on
-- either list that has stopped being true.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_df (org uuid, staff uuid, viewer uuid, outsider uuid,
  customer uuid);
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
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Every definer that answers any member is on one side of the line
-- ---------------------------------------------------------------------
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
  -- Not yet done: stock and lots (`0874`), and the corporate, property
  -- and people functions (`0875`). This list only shrinks.
  v_todo text[] := array[
    'ai_tool_catalogue', 'approval_state', 'attachments_of',
    'chat_links_for', 'corp_issued_capital', 'corp_register_of_members',
    'corp_template_placeholders', 'corp_upcoming_filings',
    'custom_field_lookup_options', 'document_lot_problems',
    'document_scan_totals', 'fs_deadlines', 'line_lots', 'mo_shortages',
    'next_document_number', 'org_team', 'property_statutory_due',
    'rent_preview', 'report_expiring_stock', 'report_fs_deadlines',
    'report_lot_balances', 'report_statutory_charges',
    'report_stock_card', 'report_timesheet', 'scan_inbox',
    'stock_on_hand', 'strata_arrears', 'strata_charge_preview',
    'suggest_lots', 'trace_lot'];
begin
  perform pg_temp.check_eq('no definer answers any member unless it is named here',
    coalesce((
      select string_agg(p.proname, ', ' order by p.proname)
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
       where p.prosecdef
         and has_function_privilege('authenticated', p.oid, 'execute')
         and p.prosrc ~ 'is_org_member'
         and p.prosrc !~ '(can_read_module|can_write_module|module_access|can_read_ledger|can_write\(|can_post|can_admin|can_manage_hr|can_run_payroll|is_platform_admin|has_permission|my_employee_id|can_read_client_money|is_self_service_only|is_staff_member)'
         and p.proname <> all (v_open || v_todo)), 'none'),
    'none');
  perform pg_temp.check_eq('and every name here is still one that answers any member',
    coalesce((
      select string_agg(x, ', ' order by x)
        from unnest(v_open || v_todo) x
       where not exists (
         select 1 from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
          where p.proname = x and p.prosecdef
            and p.prosrc ~ 'is_org_member'
            and p.prosrc !~ '(can_read_module|can_write_module|module_access|can_read_ledger|can_write\(|can_post|can_admin|can_manage_hr|can_run_payroll|is_platform_admin|has_permission|my_employee_id|can_read_client_money|is_self_service_only|is_staff_member)')), 'none'),
    'none');
end $$;

rollback;
