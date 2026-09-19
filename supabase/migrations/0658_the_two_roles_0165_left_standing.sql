-- =====================================================================
-- iAkauntan :: the two roles 0165 left standing
--
-- `0165` revokes EXECUTE from PUBLIC and from `anon` on every function
-- created in `public` or `app`, and says of the other two roles: "A
-- grant to `authenticated` survives, which is what makes this safe to
-- leave on" -- on the belief, stated as verified, that Supabase's own
-- default privilege for functions names `anon, authenticated,
-- service_role` together, so stripping `anon` by hand was the only gap
-- to close.
--
-- `0618` said that belief was a misreading: a fresh `supabase start`
-- shows a new function in `public` as `{postgres=X/postgres}`, nothing
-- more, so there is no default to strip and the thirteen functions that
-- looked unreachable were real gaps, not a stub artefact. Eight
-- migrations of evidence since said 0618 was right about a FRESH
-- project and wrong about THIS one:
--
--   * `0621`'s apply-time check found `set_sst_registration` executable
--     by `service_role` on the hosted project though no migration ever
--     granted it, and dropped the assertion rather than explain it.
--   * `0657` dropped and recreated `public.push_targets`, revoked it
--     `from public` alone, and asked whether `authenticated` could
--     still call it. The hosted project answered yes and the migration
--     refused itself, four times, before `895ae59` wrote all three
--     roles out by name.
--
-- A dropped function takes its ACL with it, so a function that began
-- life with an EXECUTE grant no statement in either fix wrote is
-- explained by exactly one thing: `alter default privileges ... grant
-- ... on functions to authenticated, service_role` is still in force on
-- THIS project, left over from however it was provisioned, and neither
-- `0165`'s event trigger nor the run of migrations since ever revoked
-- it. `supabase/tests/_local_stack.sql` has carried the open question
-- since `c2d2d15` reverted a guess at modelling it; this migration is
-- the look at the hosted project that note said the question needed,
-- taken the only way this repository can take it -- from inside a
-- migration, at apply time, against the database the guess was about.
--
-- ---------------------------------------------------------------------
-- What changes, and why two different shapes
--
-- 1. The default itself, so a function created after this one carries
--    neither grant and no later migration has to remember. This is
--    `0498`'s fix for tables, for functions: `alter default privileges
--    ... revoke`. It touches nothing that already exists -- a default
--    privilege only ever governs what is created after it changes.
--
-- 2. `authenticated`, retroactively: named as a short list of
--    EXCEPTIONS, not swept. Of the roughly seven hundred functions in
--    `public`, `authenticated` is meant to hold the great majority --
--    it is the app's own RPC surface. The twenty-two below are the ones
--    it is not meant to hold: edge-function entry points revoked `from
--    public` (and sometimes `from anon`) but never, in the migration
--    that created them, `from authenticated` too, plus the three
--    `function_grants.sql` already names as unreachable on purpose.
--    Listing exceptions keeps this migration the size of the mistake;
--    sweeping and re-granting seven hundred would not be safer, only
--    longer, and every extra line would be one more place to mistype a
--    signature and silently lock a screen out of its own RPC.
--
-- 3. `service_role`, retroactively: swept, the way `0498` swept `anon`
--    on tables. Of the same roughly seven hundred, `service_role` is
--    meant to hold a named minority -- the edge functions' own entry
--    points and the RPCs `platform_*` and similar administrative
--    surfaces call with the service key. Revoking every function's
--    `service_role` grant and re-stating the ones that are meant to
--    survive is the shorter list here, and it is exhaustive by
--    construction: nothing keeps a leaked default grant by accident,
--    because nothing keeps ANY grant except what this migration writes
--    back.
--
-- Both retroactive lists were read off THIS repository's own local
-- stack -- which has never modelled either default privilege and so
-- has never been able to hold a grant that no `grant execute` statement
-- put there -- rather than off the hosted project, which cannot be
-- told apart from itself this way. The self-checks below are what
-- confirm the two now agree.
--
-- ---------------------------------------------------------------------
-- What does NOT change
--
-- `0165`'s event trigger is left alone. Extending it to strip
-- `authenticated` on every `CREATE FUNCTION` would fire on every future
-- `create or replace` too, including a replace of one of the roughly
-- seven hundred functions that already legitimately hold the grant --
-- postgres preserves a function's ACL across `create or replace`, the
-- event trigger does not know that, and it would silently revoke the
-- grant back off on the next unrelated edit to any of them. The default
-- privilege below has no such reach: it governs only a function's FIRST
-- creation, which is the shape of the actual leak.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The default, so this does not have to be paid for again
-- ---------------------------------------------------------------------
alter default privileges for role postgres in schema public
  revoke execute on functions from authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. `authenticated`, by exception
--
-- Every one of these is already revoked `from public` (some also `from
-- anon`) by the migration that created it; none was ever revoked `from
-- authenticated` by name, which is the gap a leaked default fills
-- silently. `chat_expire_calls`, `prune_device_tokens` and
-- `ticket_sla_sweep` are the three `function_grants.sql` already names
-- as unreachable on purpose -- included here because the same default
-- would otherwise have handed them to `authenticated` too.
-- ---------------------------------------------------------------------
do $do$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.ai_call_config(uuid)',
    'public.begin_gateway_payment(uuid,text,text,text,uuid)',
    'public.begin_shared_payment(text,text,text,text)',
    'public.chat_expire_calls()',
    'public.create_gl_entry(uuid,date,app.journal_source,jsonb,text,text,'
      || 'uuid,text,character,numeric)',
    'public.einvoice_consolidations_due(integer)',
    'public.forget_device_token(text)',
    'public.ingest_exchange_rates(jsonb,text,character)',
    'public.ocr_finish(uuid,text,jsonb,text)',
    'public.prune_device_tokens(interval)',
    'public.push_targets(uuid,uuid)',
    'public.receive_email(text,text,text,text,text,text,text,text)',
    'public.record_bank_feed_run(uuid,boolean,integer,integer,text,text)',
    'public.record_inbound_attachment(uuid,text,text,bigint,text)',
    'public.record_terminal_punch(uuid,text,timestamptz,text)',
    'public.scheduler_prepare_consolidated_einvoice(uuid)',
    'public.settle_gateway_payment(text,text,boolean,numeric,jsonb)',
    'public.settle_shared_payment(text,text,boolean,numeric,jsonb)',
    'public.ssm_search_cache_purge()',
    'public.ssm_session_try_lock(integer)',
    'public.terminal_secret_matches(uuid,text)',
    'public.ticket_sla_sweep(uuid)'
  ] loop
    execute format('revoke execute on function %s from authenticated', v_fn);
  end loop;
end
$do$;

-- ---------------------------------------------------------------------
-- 3. `service_role`, swept and re-stated
--
-- First the sweep, blind to which grants were written by a migration
-- and which were the leaked default -- that distinction is exactly what
-- cannot be read back from the hosted project's own ACL, which is why
-- this does not try. Then the list that survives it, read off this
-- repository's own local stack, which has never been able to hold a
-- grant that was not written.
-- ---------------------------------------------------------------------
do $do$
declare
  v_fn text;
begin
  for v_fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and not exists (
         select 1 from pg_depend d
          where d.objid = p.oid and d.classid = 'pg_proc'::regclass
            and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from service_role', v_fn);
  end loop;
end
$do$;

grant execute on function public.accept_invitation(text) to service_role;
grant execute on function public.activate_report_layout(uuid) to service_role;
grant execute on function public.ai_call_config(uuid) to service_role;
grant execute on function public.allocate_credit_note(uuid,uuid,numeric)
  to service_role;
grant execute on function public.am_i_platform_admin() to service_role;
grant execute on function public.apply_tax_submission(uuid) to service_role;
grant execute on function public.archive_payment_method(uuid) to service_role;
grant execute on function public.archive_report_layout(uuid) to service_role;
grant execute on function public.audit_list_payslips(uuid,uuid) to service_role;
grant execute on function public.audit_view_payslip(uuid) to service_role;
grant execute on function public.begin_gateway_payment(uuid,text,text,text,uuid)
  to service_role;
grant execute on function public.begin_shared_payment(text,text,text,text)
  to service_role;
grant execute on function public.calculate_payroll_run(uuid) to service_role;
grant execute on function public.clock_in(
  uuid,app.clock_method,numeric,numeric,text,text,text,uuid) to service_role;
grant execute on function public.clock_out(
  uuid,app.clock_method,numeric,numeric,text,text,text,uuid) to service_role;
grant execute on function public.corp_create_signing_link(uuid,integer,text)
  to service_role;
grant execute on function public.corp_generate_document(uuid,text,jsonb,text)
  to service_role;
grant execute on function public.corp_issued_capital(uuid) to service_role;
grant execute on function public.corp_open_filing(uuid,text,date) to service_role;
grant execute on function public.corp_open_signing_link(text) to service_role;
grant execute on function public.corp_register_of_members(uuid) to service_role;
grant execute on function public.corp_request_signatures(
  uuid,uuid[],text[],date,text) to service_role;
grant execute on function public.corp_sign_document(uuid,text) to service_role;
grant execute on function public.corp_sign_with_link(text,text) to service_role;
grant execute on function public.corp_signature_state(uuid) to service_role;
grant execute on function public.corp_template_placeholders(uuid,text)
  to service_role;
grant execute on function public.corp_upcoming_filings(uuid,integer)
  to service_role;
grant execute on function public.corp_update_document(uuid,text,text)
  to service_role;
grant execute on function public.create_fiscal_year(uuid,date) to service_role;
grant execute on function public.create_gl_entry(uuid,date,app.journal_source,
  jsonb,text,text,uuid,text,character,numeric) to service_role;
grant execute on function public.create_layout_from_builtin(
  uuid,app.report_kind,text) to service_role;
grant execute on function public.create_payroll_run(uuid,uuid,text)
  to service_role;
grant execute on function public.dashboard_summary(uuid,date,date)
  to service_role;
grant execute on function public.decide_expense_claim(uuid,boolean,text,numeric)
  to service_role;
grant execute on function public.decide_leave_request(uuid,boolean,text)
  to service_role;
grant execute on function public.decide_payslip_access(uuid,boolean,text,integer)
  to service_role;
grant execute on function public.dismiss_tax_submission(uuid) to service_role;
grant execute on function public.document_lot_problems(uuid,text)
  to service_role;
grant execute on function public.duplicate_purchase_documents(
  uuid,text,text,date,numeric,uuid) to service_role;
grant execute on function public.einvoice_consolidations_due(integer)
  to service_role;
grant execute on function public.employee_directory(uuid) to service_role;
grant execute on function public.ensure_pay_period(uuid,integer,integer)
  to service_role;
grant execute on function public.exchange_rate_board(uuid,date) to service_role;
grant execute on function public.forget_device_token(text) to service_role;
grant execute on function public.import_journals(uuid,jsonb,boolean)
  to service_role;
grant execute on function public.import_purchase_transactions(
  uuid,jsonb,boolean) to service_role;
grant execute on function public.import_sales_transactions(uuid,jsonb,boolean)
  to service_role;
grant execute on function public.ingest_exchange_rates(jsonb,text,character)
  to service_role;
grant execute on function public.knock_off(uuid,jsonb) to service_role;
grant execute on function public.layout_rows(uuid) to service_role;
grant execute on function public.line_lots(text,uuid) to service_role;
grant execute on function public.mark_payroll_paid(uuid) to service_role;
grant execute on function public.may_use_workspace(text) to service_role;
grant execute on function public.my_organizations() to service_role;
grant execute on function public.my_payslip_access(uuid) to service_role;
grant execute on function public.next_document_number(uuid,text)
  to service_role;
grant execute on function public.ocr_finish(uuid,text,jsonb,text)
  to service_role;
grant execute on function public.ocr_status(uuid) to service_role;
grant execute on function public.open_items(uuid) to service_role;
grant execute on function public.open_tax_detail_request(text) to service_role;
grant execute on function public.payment_methods_for(uuid) to service_role;
grant execute on function public.payroll_payment_instruction(uuid)
  to service_role;
grant execute on function public.pending_tax_submissions(uuid) to service_role;
grant execute on function public.platform_audit_trail(text,integer)
  to service_role;
grant execute on function public.platform_security_log(timestamptz,integer)
  to service_role;
grant execute on function public.platform_set_module(uuid,text,boolean)
  to service_role;
grant execute on function public.platform_set_org_status(uuid,text)
  to service_role;
grant execute on function public.platform_stats() to service_role;
grant execute on function public.platform_update_setting(text,jsonb)
  to service_role;
grant execute on function public.post_client_transaction(uuid) to service_role;
grant execute on function public.post_expense(uuid) to service_role;
grant execute on function public.post_expense_claim(uuid,uuid) to service_role;
grant execute on function public.post_payroll_run(uuid) to service_role;
grant execute on function public.post_purchase_document(uuid) to service_role;
grant execute on function public.post_purchase_payment(uuid) to service_role;
grant execute on function public.post_receipt(uuid) to service_role;
grant execute on function public.post_sales_document(uuid) to service_role;
grant execute on function public.prepare_einvoice(uuid) to service_role;
grant execute on function public.push_targets(uuid,uuid) to service_role;
grant execute on function public.receive_email(
  text,text,text,text,text,text,text,text) to service_role;
grant execute on function public.record_bank_feed_run(
  uuid,boolean,integer,integer,text,text) to service_role;
grant execute on function public.record_inbound_attachment(
  uuid,text,text,bigint,text) to service_role;
grant execute on function public.record_terminal_punch(
  uuid,text,timestamptz,text) to service_role;
grant execute on function public.report_balance_sheet(uuid,date)
  to service_role;
grant execute on function public.report_expiring_stock(uuid,integer)
  to service_role;
grant execute on function public.report_layouts_for(uuid,app.report_kind)
  to service_role;
grant execute on function public.report_lot_balances(uuid,uuid,uuid)
  to service_role;
grant execute on function public.report_matter_summary(uuid) to service_role;
grant execute on function public.report_profit_loss(uuid,date,date)
  to service_role;
grant execute on function public.report_revenue_trend(uuid,integer)
  to service_role;
grant execute on function public.report_sales_by_person(uuid,date,date)
  to service_role;
grant execute on function public.report_sst_summary(uuid,date,date)
  to service_role;
grant execute on function public.report_trial_balance(uuid,date,date)
  to service_role;
grant execute on function public.report_with_layout(
  uuid,app.report_kind,date,date,uuid,text,text) to service_role;
grant execute on function public.request_payslip_access(
  uuid,text,date,date,uuid,uuid) to service_role;
grant execute on function public.request_tax_details(uuid,integer,text)
  to service_role;
grant execute on function public.reverse_gl_entry(uuid,date) to service_role;
grant execute on function public.revoke_payslip_access(uuid,text)
  to service_role;
grant execute on function public.revoke_tax_detail_request(uuid)
  to service_role;
grant execute on function public.save_layout_rows(uuid,jsonb) to service_role;
grant execute on function public.save_payment_method(
  uuid,text,uuid,text,uuid,uuid,numeric,numeric,boolean,boolean,integer,text)
  to service_role;
grant execute on function public.scheduler_prepare_consolidated_einvoice(uuid)
  to service_role;
grant execute on function public.set_fiscal_period_status(uuid,text)
  to service_role;
grant execute on function public.set_line_lots(text,uuid,jsonb)
  to service_role;
grant execute on function public.settle_gateway_payment(
  text,text,boolean,numeric,jsonb) to service_role;
grant execute on function public.settle_shared_payment(
  text,text,boolean,numeric,jsonb) to service_role;
grant execute on function public.setup_legal_module(uuid) to service_role;
grant execute on function public.ssm_search_cache_purge() to service_role;
grant execute on function public.ssm_session_try_lock(integer) to service_role;
grant execute on function public.submit_tax_details(text,jsonb) to service_role;
grant execute on function public.suggest_lots(uuid,uuid,numeric)
  to service_role;
grant execute on function public.suggested_charge(uuid,numeric)
  to service_role;
grant execute on function public.terminal_secret_matches(uuid,text)
  to service_role;
grant execute on function public.trace_lot(uuid,uuid) to service_role;
grant execute on function public.void_sales_document(uuid,text)
  to service_role;
grant execute on function public.workspace_module_refusal(text)
  to service_role;

-- ---------------------------------------------------------------------
-- Self-check
--
-- Three things, each of which failing means this migration is the one
-- that got it wrong: the default is gone, `authenticated` still holds
-- everything except the twenty-two, and `service_role` holds exactly
-- the list just written back -- read the same way the two lists above
-- were, so a mismatch here is the same mismatch a hosted-vs-local diff
-- would have shown before this migration existed.
-- ---------------------------------------------------------------------
do $do$
declare
  v_left text;
begin
  -- The default privilege itself: a function created right now, inside
  -- this transaction, must not carry either grant.
  create function public.zz_0658_probe() returns integer
    language sql as 'select 1';
  if has_function_privilege('authenticated', 'public.zz_0658_probe()',
       'execute')
     or has_function_privilege('service_role', 'public.zz_0658_probe()',
       'execute') then
    raise exception
      '0658: a function created after the default privilege change '
      'still carries it';
  end if;
  drop function public.zz_0658_probe();

  -- The twenty-two: none may be executable by authenticated.
  select string_agg(v.v_fn, ', ') into v_left
    from unnest(array[
      'public.ai_call_config(uuid)',
      'public.begin_gateway_payment(uuid,text,text,text,uuid)',
      'public.begin_shared_payment(text,text,text,text)',
      'public.chat_expire_calls()',
      'public.create_gl_entry(uuid,date,app.journal_source,jsonb,text,text,'
        || 'uuid,text,character,numeric)',
      'public.einvoice_consolidations_due(integer)',
      'public.forget_device_token(text)',
      'public.ingest_exchange_rates(jsonb,text,character)',
      'public.ocr_finish(uuid,text,jsonb,text)',
      'public.prune_device_tokens(interval)',
      'public.push_targets(uuid,uuid)',
      'public.receive_email(text,text,text,text,text,text,text,text)',
      'public.record_bank_feed_run(uuid,boolean,integer,integer,text,text)',
      'public.record_inbound_attachment(uuid,text,text,bigint,text)',
      'public.record_terminal_punch(uuid,text,timestamptz,text)',
      'public.scheduler_prepare_consolidated_einvoice(uuid)',
      'public.settle_gateway_payment(text,text,boolean,numeric,jsonb)',
      'public.settle_shared_payment(text,text,boolean,numeric,jsonb)',
      'public.ssm_search_cache_purge()',
      'public.ssm_session_try_lock(integer)',
      'public.terminal_secret_matches(uuid,text)',
      'public.ticket_sla_sweep(uuid)'
    ]) as v(v_fn)
   where has_function_privilege('authenticated', v.v_fn, 'execute');
  if v_left is not null then
    raise exception
      '0658: still executable by authenticated: %', v_left;
  end if;

  -- `service_role`: exactly the list just granted, on every function in
  -- `public` that is not an extension's own.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname)
    into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid and d.classid = 'pg_proc'::regclass
          and d.deptype = 'e')
     and has_function_privilege('service_role', p.oid, 'execute')
     and p.oid::regprocedure::text not in (
       'accept_invitation(text)', 'activate_report_layout(uuid)',
       'ai_call_config(uuid)', 'allocate_credit_note(uuid,uuid,numeric)',
       'am_i_platform_admin()', 'apply_tax_submission(uuid)',
       'archive_payment_method(uuid)', 'archive_report_layout(uuid)',
       'audit_list_payslips(uuid,uuid)', 'audit_view_payslip(uuid)',
       'begin_gateway_payment(uuid,text,text,text,uuid)',
       'begin_shared_payment(text,text,text,text)',
       'calculate_payroll_run(uuid)',
       'clock_in(uuid,app.clock_method,numeric,numeric,text,text,text,uuid)',
       'clock_out(uuid,app.clock_method,numeric,numeric,text,text,text,uuid)',
       'corp_create_signing_link(uuid,integer,text)',
       'corp_generate_document(uuid,text,jsonb,text)',
       'corp_issued_capital(uuid)', 'corp_open_filing(uuid,text,date)',
       'corp_open_signing_link(text)', 'corp_register_of_members(uuid)',
       'corp_request_signatures(uuid,uuid[],text[],date,text)',
       'corp_sign_document(uuid,text)', 'corp_sign_with_link(text,text)',
       'corp_signature_state(uuid)',
       'corp_template_placeholders(uuid,text)',
       'corp_upcoming_filings(uuid,integer)',
       'corp_update_document(uuid,text,text)',
       'create_fiscal_year(uuid,date)',
       'create_gl_entry(uuid,date,app.journal_source,jsonb,text,text,uuid,'
         || 'text,character,numeric)',
       'create_layout_from_builtin(uuid,app.report_kind,text)',
       'create_payroll_run(uuid,uuid,text)',
       'dashboard_summary(uuid,date,date)',
       'decide_expense_claim(uuid,boolean,text,numeric)',
       'decide_leave_request(uuid,boolean,text)',
       'decide_payslip_access(uuid,boolean,text,integer)',
       'dismiss_tax_submission(uuid)', 'document_lot_problems(uuid,text)',
       'duplicate_purchase_documents(uuid,text,text,date,numeric,uuid)',
       'einvoice_consolidations_due(integer)', 'employee_directory(uuid)',
       'ensure_pay_period(uuid,integer,integer)',
       'exchange_rate_board(uuid,date)', 'forget_device_token(text)',
       'import_journals(uuid,jsonb,boolean)',
       'import_purchase_transactions(uuid,jsonb,boolean)',
       'import_sales_transactions(uuid,jsonb,boolean)',
       'ingest_exchange_rates(jsonb,text,character)', 'knock_off(uuid,jsonb)',
       'layout_rows(uuid)', 'line_lots(text,uuid)',
       'mark_payroll_paid(uuid)', 'may_use_workspace(text)',
       'my_organizations()', 'my_payslip_access(uuid)',
       'next_document_number(uuid,text)', 'ocr_finish(uuid,text,jsonb,text)',
       'ocr_status(uuid)', 'open_items(uuid)',
       'open_tax_detail_request(text)', 'payment_methods_for(uuid)',
       'payroll_payment_instruction(uuid)', 'pending_tax_submissions(uuid)',
       'platform_audit_trail(text,integer)',
       'platform_security_log(timestamp with time zone,integer)',
       'platform_set_module(uuid,text,boolean)',
       'platform_set_org_status(uuid,text)', 'platform_stats()',
       'platform_update_setting(text,jsonb)',
       'post_client_transaction(uuid)', 'post_expense(uuid)',
       'post_expense_claim(uuid,uuid)', 'post_payroll_run(uuid)',
       'post_purchase_document(uuid)', 'post_purchase_payment(uuid)',
       'post_receipt(uuid)', 'post_sales_document(uuid)',
       'prepare_einvoice(uuid)', 'push_targets(uuid,uuid)',
       'receive_email(text,text,text,text,text,text,text,text)',
       'record_bank_feed_run(uuid,boolean,integer,integer,text,text)',
       'record_inbound_attachment(uuid,text,text,bigint,text)',
       'record_terminal_punch(uuid,text,timestamp with time zone,text)',
       'report_balance_sheet(uuid,date)',
       'report_expiring_stock(uuid,integer)',
       'report_layouts_for(uuid,app.report_kind)',
       'report_lot_balances(uuid,uuid,uuid)', 'report_matter_summary(uuid)',
       'report_profit_loss(uuid,date,date)',
       'report_revenue_trend(uuid,integer)',
       'report_sales_by_person(uuid,date,date)',
       'report_sst_summary(uuid,date,date)',
       'report_trial_balance(uuid,date,date)',
       'report_with_layout(uuid,app.report_kind,date,date,uuid,text,text)',
       'request_payslip_access(uuid,text,date,date,uuid,uuid)',
       'request_tax_details(uuid,integer,text)',
       'reverse_gl_entry(uuid,date)', 'revoke_payslip_access(uuid,text)',
       'revoke_tax_detail_request(uuid)', 'save_layout_rows(uuid,jsonb)',
       'save_payment_method(uuid,text,uuid,text,uuid,uuid,numeric,numeric,'
         || 'boolean,boolean,integer,text)',
       'scheduler_prepare_consolidated_einvoice(uuid)',
       'set_fiscal_period_status(uuid,text)', 'set_line_lots(text,uuid,jsonb)',
       'settle_gateway_payment(text,text,boolean,numeric,jsonb)',
       'settle_shared_payment(text,text,boolean,numeric,jsonb)',
       'setup_legal_module(uuid)', 'ssm_search_cache_purge()',
       'ssm_session_try_lock(integer)', 'submit_tax_details(text,jsonb)',
       'suggest_lots(uuid,uuid,numeric)', 'suggested_charge(uuid,numeric)',
       'terminal_secret_matches(uuid,text)', 'trace_lot(uuid,uuid)',
       'void_sales_document(uuid,text)', 'workspace_module_refusal(text)');
  if v_left is not null then
    raise exception
      '0658: service_role holds a grant the sweep did not write back: %',
      v_left;
  end if;
end
$do$;
