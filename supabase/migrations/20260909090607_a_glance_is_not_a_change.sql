-- security_events and payslip_access_log are read-receipts: they are written by
-- read paths (audit_trail -> note_read -> record_security_event; audit_list_payslips /
-- audit_view_payslip -> payslip_access_log). Feeding them into live_changes (0547)
-- made every screen that reads them refresh, read again, and write again — an
-- endless reload. A glance is not a change; these two tables no longer wake screens.

drop trigger if exists live_change_insert on public.security_events;
drop trigger if exists live_change_update on public.security_events;
drop trigger if exists live_change_delete on public.security_events;

drop trigger if exists live_change_insert on public.payslip_access_log;
drop trigger if exists live_change_update on public.payslip_access_log;
drop trigger if exists live_change_delete on public.payslip_access_log;
