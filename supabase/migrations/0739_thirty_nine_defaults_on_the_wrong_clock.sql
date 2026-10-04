-- ---------------------------------------------------------------------
-- 0739  Thirty-nine defaults on the wrong clock
--
-- `current_date` is the SESSION's date. The database is hosted in UTC.
-- `app.today()` is the product's date -- Kuala Lumpur, UTC+8. **From
-- 16:00 UTC the two are different days, every single day, for eight
-- hours**, which in Malaysia is midnight to eight in the morning.
--
-- Thirty-nine functions default a date argument to `current_date`, so
-- for those eight hours every one of them answers about yesterday:
--
-- | | what it does for eight hours a day |
-- | --- | --- |
-- | `report_trial_balance`, `report_balance_sheet`, `report_profit_loss`, `report_profit_loss_by_dimension` | the window ends yesterday, so today's postings are missing from the accounts |
-- | the four group reports and `app.group_eliminations`, `app.group_intercompany_lines` | the same, consolidated, and `report_group_trial_balance` came back EMPTY in the measurement below |
-- | `report_ar_aging`, `report_ap_aging`, `report_collections`, `strata_arrears` | everything is a day younger than it is, so a bucket boundary moves |
-- | `report_asset_movements`, `report_stock_card`, `report_sales_by_person`, `pos_day_sheet` | a day of movement is simply absent |
-- | `create_bank_transfer`, `transfer_between_matters`, `remit_withholding`, `fs_lodge` | **the money is stamped yesterday**, and for a lodgement that is a filing date |
-- | `run_depreciation`, `revalue_foreign_balances`, `depreciation_preview`, `fx_revaluation_preview` | the charge is computed to yesterday, so a month-end run on the 1st before 8am closes the wrong month |
-- | `exchange_rate_for`, `exchange_rate_board` | **yesterday's rate**, applied to today's document |
-- | `app.run_daily_jobs` and the four it calls | the nightly sweep processes the wrong day |
-- | `app.membership_period`, `app.expire_carried_leave`, `app.bill_the_month`, `app.chase_platform_invoices`, `app.queue_overdue_reminders`, `app.raise_notifications` | a period boundary, an expiry and a chase, all a day out |
--
-- ## How it was found, which is the part worth keeping
--
-- Not by reading. The test suite moved onto the product's clock on
-- 4 October (`5bfc3141`), and the swept suite was then run with
-- `PGTZ='Etc/GMT+12'` -- a session a day behind Kuala Lumpur ALL day,
-- which is exactly what CI and this hosted database see from 16:00 UTC.
-- Two files failed that nothing in the tests explained:
--
--     FAIL the combined trial balance balances: expected 0, got <NULL>
--     FAIL there are eliminations to make at all
--
-- `report_group_trial_balance(p_org_id, p_from date DEFAULT NULL,
-- p_to date DEFAULT CURRENT_DATE)`. The test posted entries on the
-- Malaysian day and asked for the default window, which ended on the
-- session's day -- the day before. Every entry fell outside it and the
-- trial balance came back empty.
--
-- **The tests were wrong about the clock for as long as the product was,
-- so they agreed with each other and neither was tested.** Putting the
-- suite on the product's clock is what made the product's clock visible.
--
-- ## Why a default and not a coalesce
--
-- `app.today()` goes in the signature, so the arity and every caller are
-- unchanged and a caller that passes a date is unaffected. Postgres
-- evaluates an argument default at CALL time in the caller's context, so
-- it is schema-qualified -- `app.today()`, never bare `today()` -- and
-- the caller needs EXECUTE on it. `authenticated` has it; `anon` does
-- not, and **no function in this list is callable by `anon`**, which was
-- checked before this was written rather than hoped for.
--
-- Three functions mention `current_date` only in a comment explaining
-- why they already use `app.today()` -- `draft_bill_from_received_einvoice`,
-- `module_dashboard` and `report_with_layout`. They are untouched, and
-- their comments are why this class was already known to be real.
--
-- Nothing else changes: the bodies are restated verbatim from
-- `pg_get_functiondef`, and not one of the thirty-nine uses
-- `current_date` anywhere but in that default.
-- ---------------------------------------------------------------------

-- app.bill_the_month
CREATE OR REPLACE FUNCTION app.bill_the_month(p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_month date := (date_trunc('month', p_on) - interval '1 month')::date;
  v_n     integer := 0;
  o       record;
begin
  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active' and not is_demo
  loop
    if app.bill_org_modules(o.id, v_month) is not null then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $function$;

-- app.chase_platform_invoices
CREATE OR REPLACE FUNCTION app.chase_platform_invoices(p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_days  integer[];
  v_issuer jsonb;
  r       record;
  v_n     integer := 0;
begin
  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  select coalesce(
    array(select jsonb_array_elements_text(
                   coalesce(v_issuer, '{}'::jsonb) -> 'reminder_days')::integer),
    array[]::integer[])
    into v_days;
  if array_length(v_days, 1) is null then
    v_days := array[7, 14, 30];
  end if;

  for r in
    select i.id, (p_on - i.issue_date) as age
      from public.platform_invoices i
      join public.organizations o on o.id = i.org_id
     where i.status = 'issued'
       and not o.is_demo
       and coalesce(o.status, 'active') = 'active'
       and (p_on - i.issue_date) = any (v_days)
  loop
    -- The day is in the key, so the 7th and the 14th are two mails and
    -- a scheduler that runs twice on the 7th is one.
    if app.queue_platform_mail(
         r.id, 'platform_invoice_reminder',
         'platform-reminder:' || r.id::text || ':' || r.age::text,
         r.age) is not null then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end $function$;

-- app.expire_carried_leave
CREATE OR REPLACE FUNCTION app.expire_carried_leave(p_org uuid, p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_n integer;
begin
  with due as (
    select b.id,
           least(coalesce(b.taken_days, 0), coalesce(b.carried_forward, 0))
             as keep
      from public.leave_balances b
      join public.leave_types t on t.id = b.leave_type_id
     where b.org_id = p_org
       and t.is_active
       and coalesce(t.carry_forward_expiry_months, 0) > 0
       -- On or after the anniversary of the year's start. A year's
       -- carry expires within that year and not in some later one, so
       -- balances for a year already gone are left where they are: what
       -- is done with a closed year is a correction somebody makes on
       -- purpose, not a sweep.
       and b.leave_year = extract(year from p_on)::integer
       and p_on >= (make_date(b.leave_year, 1, 1)
                    + make_interval(months => t.carry_forward_expiry_months))
       and coalesce(b.carried_forward, 0)
           > least(coalesce(b.taken_days, 0), coalesce(b.carried_forward, 0))
  )
  update public.leave_balances b
     set carried_forward = due.keep
    from due
   where b.id = due.id;
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- app.group_eliminations
CREATE OR REPLACE FUNCTION app.group_eliminations(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(code text, adjustment numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with lines as (select * from app.group_intercompany_lines(p_org_id, p_from, p_to)),
  totals as (
    select l.org_id, l.counterparty, l.category, sum(l.amount) as amount
      from lines l group by l.org_id, l.counterparty, l.category),
  -- A pair reconciles when the two sides agree exactly. Only then is
  -- anything eliminated: see the header.
  matched as (
    select t.org_id, t.counterparty, t.category
      from totals t
      join totals o
        on o.org_id = t.counterparty and o.counterparty = t.org_id
       and o.category = case t.category
             when 'receivable' then 'payable'
             when 'payable'    then 'receivable'
             when 'revenue'    then 'expense'
             else 'revenue' end
     where round(t.amount - o.amount, 2) = 0)
  select l.code,
         round(sum(l.amount * case l.category
           when 'receivable' then -1   -- an asset comes down
           when 'payable'    then  1   -- a liability comes up toward zero
           when 'revenue'    then  1   -- revenue comes up toward zero
           else                   -1   -- a cost comes down
         end), 2)
    from lines l
    join matched m
      on m.org_id = l.org_id and m.counterparty = l.counterparty
     and m.category = l.category
   group by l.code;
$function$;

-- app.group_intercompany_lines
CREATE OR REPLACE FUNCTION app.group_intercompany_lines(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(org_id uuid, counterparty uuid, category text, code text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g)
  select l.org_id,
         c.linked_org_id,
         case
           when a.account_subtype = 'accounts_receivable' then 'receivable'
           when a.account_subtype = 'accounts_payable'    then 'payable'
           when a.account_type    = 'revenue'             then 'revenue'
           when a.account_type    = 'expense'             then 'expense'
         end,
         a.code,
         -- A magnitude, whichever side of the ledger it sits on. The
         -- direction is implied by the category and applied when the
         -- adjustment is built.
         round(sum(case
           when a.account_subtype = 'accounts_receivable' then l.debit - l.credit
           when a.account_subtype = 'accounts_payable'    then l.credit - l.debit
           when a.account_type    = 'revenue'             then l.credit - l.debit
           when a.account_type    = 'expense'             then l.debit - l.credit
         end), 2)
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.contacts c on c.id = l.contact_id
    join public.accounts a on a.id = l.account_id
   where l.org_id in (select org_id from orgs)
     and c.linked_org_id in (select org_id from orgs)
     and c.linked_org_id <> l.org_id
     and e.status = 'posted'
     and e.entry_date <= p_to
     and (p_from is null or e.entry_date >= p_from)
     and (a.account_subtype in ('accounts_receivable', 'accounts_payable')
          or a.account_type in ('revenue', 'expense'))
   group by l.org_id, c.linked_org_id, 3, a.code
  having round(sum(case
           when a.account_subtype = 'accounts_receivable' then l.debit - l.credit
           when a.account_subtype = 'accounts_payable'    then l.credit - l.debit
           when a.account_type    = 'revenue'             then l.credit - l.debit
           when a.account_type    = 'expense'             then l.debit - l.credit
         end), 2) <> 0;
$function$;

-- app.membership_period
CREATE OR REPLACE FUNCTION app.membership_period(p_subscription uuid, p_on date DEFAULT app.today())
 RETURNS TABLE(period_start date, period_end date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_start date;
  v_period text;
  v_step  interval;
  v_from  date;
begin
  select s.started_on, m.period into v_start, v_period
    from public.pos_membership_subscriptions s
    join public.pos_memberships m on m.id = s.membership_id
   where s.id = p_subscription;
  if v_start is null then
    return;
  end if;

  v_step := case v_period
              when 'weekly'    then interval '7 days'
              when 'monthly'   then interval '1 month'
              when 'quarterly' then interval '3 months'
              else                  interval '1 year'
            end;

  -- Walked rather than computed, because months are not a fixed length
  -- and "add n months to the start" is the only arithmetic that keeps
  -- the 31st landing on the 30th in the way `date + interval` already
  -- decides. A membership has tens of periods, not millions.
  v_from := v_start;
  while v_from + v_step <= p_on loop
    v_from := (v_from + v_step)::date;
  end loop;

  period_start := v_from;
  period_end   := (v_from + v_step - interval '1 day')::date;
  return next;
end;
$function$;

-- app.queue_overdue_reminders
CREATE OR REPLACE FUNCTION app.queue_overdue_reminders(p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select d.id, d.org_id, (p_on - d.due_date) as days_over
      from public.sales_documents d
      join public.email_settings s on s.org_id = d.org_id
      join public.organizations o on o.id = d.org_id
     where s.is_enabled
       and array_length(s.reminder_days, 1) is not null
       and coalesce(o.status, 'active') = 'active'
       and d.deleted_at is null
       and d.doc_type = 'invoice'
       and d.status in ('posted', 'partial')
       and d.balance_amount > 0
       and d.due_date is not null
       and d.balance_amount >= s.reminder_min_amount
       and (p_on - d.due_date) = any (s.reminder_days)
  loop
    if app.queue_document_email(
         r.id, 'invoice_reminder',
         'reminder:' || r.id::text || ':' || r.days_over::text) is not null then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end; $function$;

-- app.raise_notifications
CREATE OR REPLACE FUNCTION app.raise_notifications(p_org uuid, p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r     record;
  v_new integer := 0;
begin
  -- LHDN would not take it. The most urgent thing in the system: an
  -- invoice the tax authority has refused is not an invoice yet.
  for r in select e.id, e.internal_doc_no, e.status, e.rejection_reason,
                  e.error_message
             from public.einvoice_documents e
            where e.org_id = p_org
              and e.status in ('invalid', 'rejected', 'failed')
  loop
    if app.notify(p_org, null, 'einvoice_rejected',
         'LHDN would not accept ' || coalesce(r.internal_doc_no, 'an invoice'),
         coalesce(r.rejection_reason, r.error_message,
                  'Submitted and returned ' || r.status || '.'),
         'urgent', '/einvoice', 'einvoice_documents', r.id) then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Past the time the customer was promised. Addressed to whoever it
  -- is assigned to, and to the company when it is assigned to nobody --
  -- which is itself the reason it is late.
  for r in select t.id, t.ticket_no, t.subject, t.assignee_id,
                  t.resolution_due_at
             from public.tickets t
            where t.org_id = p_org
              and t.resolution_due_at < now()
              and t.status not in ('resolved', 'closed', 'cancelled')
  loop
    if app.notify(p_org, r.assignee_id, 'ticket_overdue',
         'Ticket ' || r.ticket_no || ' is past its SLA',
         r.subject, 'warning', '/tickets', 'tickets', r.id) then
      v_new := v_new + 1;
    end if;
  end loop;

  -- Waiting on one person, so it goes to that person. Sending it to
  -- everybody would make it nobody's, which is what it is now.
  for r in select c.id, c.claim_no, c.title, c.approver_id, c.total_amount
             from public.expense_claims c
            where c.org_id = p_org
              and c.status = 'submitted'
              and c.approver_id is not null
  loop
    if app.notify(p_org, r.approver_id, 'claim_to_approve',
         'Claim ' || r.claim_no || ' is waiting for you',
         coalesce(r.title, '') || ' · ' ||
           to_char(r.total_amount, 'FM999G999G990D00'),
         'info', '/hr/claims', 'expense_claims', r.id) then
      v_new := v_new + 1;
    end if;
  end loop;

  -- The statutory one. Thirty days out is when it stops being next
  -- quarter's problem, and a filing already past its date is urgent
  -- because the penalty is running.
  for r in select f.id, f.fy_end,
                  app.fs_lodge_by(f.fy_end, f.circulated_on) as lodge_by
             from public.fs_filings f
            where f.org_id = p_org
              and f.lodged_on is null
  loop
    if r.lodge_by - p_on <= 30 then
      if app.notify(p_org, null, 'fs_lodgement_due',
           'Financial statements to ' || to_char(r.fy_end, 'DD Mon YYYY') ||
             ' must be lodged by ' || to_char(r.lodge_by, 'DD Mon YYYY'),
           'CA 2016 s.259. ' ||
             case when r.lodge_by < p_on
                  then 'That date has passed.'
                  else (r.lodge_by - p_on) || ' days left.' end,
           case when r.lodge_by < p_on then 'urgent' else 'warning' end,
           '/financial-statements', 'fs_filings', r.id) then
        v_new := v_new + 1;
      end if;
    end if;
  end loop;

  return v_new;
end;
$function$;

-- app.run_daily_jobs
CREATE OR REPLACE FUNCTION app.run_daily_jobs(p_on date DEFAULT app.today())
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare o record;
begin
  perform app.run_recurring_journals(p_on);
  perform app.run_recurring_documents(p_on);
  perform app.queue_overdue_reminders(p_on);

  begin
    perform public.chat_expire_calls();
  exception when others then
    raise warning 'chat_expire_calls failed: %', sqlerrm;
  end;

  begin
    perform public.prune_device_tokens();
  exception when others then
    raise warning 'prune_device_tokens failed: %', sqlerrm;
  end;

  begin
    perform app.queue_sales_digest(p_on - 1);
  exception when others then
    raise warning 'queue_sales_digest failed: %', sqlerrm;
  end;

  begin
    perform app.sweep_idempotency_keys(now() - interval '24 hours');
  exception when others then
    raise warning 'sweep_idempotency_keys failed: %', sqlerrm;
  end;

  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
    begin
      if app.has_module(o.id, 'hr') then
        perform app.close_attendance_day(o.id, p_on - 1);
        perform app.expire_carried_leave(o.id, p_on);
      end if;
    exception when others then
      raise warning 'HR daily pass failed for %: %', o.id, sqlerrm;
    end;

    -- 0375. Wrapped like the rest: a shop whose till sweep fails must
    -- not stop the leave year and the consolidation for everybody else.
    begin
      if app.has_module(o.id, 'pos') then
        perform app.expire_parked_sales(o.id);
      end if;
    exception when others then
      raise warning 'expire_parked_sales failed for %: %', o.id, sqlerrm;
    end;

    -- 0497. What is waiting for somebody, gathered from what the rest
    -- of the system already records.
    begin
      perform app.raise_notifications(o.id, p_on);
    exception when others then
      raise warning 'raise_notifications failed for %: %', o.id, sqlerrm;
    end;

    -- The two that run on the first of the month, wrapped at last.
    -- `0375`'s comment above the till sweep names exactly these two as
    -- the things a failure elsewhere must not stop, and they were the
    -- two left bare — so the isolation went to the branches that run
    -- daily and not to the branches that run once a month, which is the
    -- wrong way round. A fault in a daily branch is found the next
    -- morning; a fault in a January branch is found in a year.
    begin
      if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
        perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
      end if;
    exception when others then
      raise warning 'roll_leave_year failed for %: %', o.id, sqlerrm;
    end;

    begin
      if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
        perform app.roll_einvoice_consolidation(
          o.id, (p_on - interval '1 month')::date);
      end if;
    exception when others then
      raise warning 'roll_einvoice_consolidation failed for %: %',
        o.id, sqlerrm;
    end;
  end loop;

  -- 0489. On the first, the month that just ended is billed. Outside
  -- the loop above because `bill_the_month` walks the companies itself,
  -- and wrapped like everything else here: a company whose invoice
  -- cannot be written must not stop the ones after it, and must not
  -- take the daily pass down with it either.
  begin
    if extract(day from p_on) = 1 then
      perform app.bill_the_month(p_on);
    end if;
  exception when others then
    raise warning 'bill_the_month failed: %', sqlerrm;
  end;

  -- 0491. Every day, not just the first: a bill raised on the 1st is
  -- chased on the 8th, the 15th and the 31st, and none of those is a
  -- first of the month.
  begin
    perform app.chase_platform_invoices(p_on);
  exception when others then
    raise warning 'chase_platform_invoices failed: %', sqlerrm;
  end;

  -- 0547. The live feed is rubbish within seconds of being written: it
  -- exists to be pushed down a socket, and nothing reads the table
  -- afterwards. An hour is generous -- it is there so a client that
  -- reconnects mid-morning is not looking at an empty table and
  -- wondering, and because a row that is deleted before the socket has
  -- carried it is a refresh nobody gets.
  begin
    delete from public.live_changes
     where changed_at < now() - interval '1 hour';
  exception when others then
    raise warning 'prune live_changes failed: %', sqlerrm;
  end;
end; $function$;

-- app.run_recurring_documents
CREATE OR REPLACE FUNCTION app.run_recurring_documents(p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select d.id from public.recurring_documents d
      join public.organizations o on o.id = d.org_id
     where d.is_active
       and coalesce(o.status, 'active') = 'active'
       and d.next_run_date <= p_on
  loop
    v_n := v_n + app.advance_recurring_document(r.id, p_on);
  end loop;

  return v_n;
end; $function$;

-- app.run_recurring_journals
CREATE OR REPLACE FUNCTION app.run_recurring_journals(p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r public.recurring_journals;
  v_n integer := 0;
begin
  for r in
    select * from public.recurring_journals
     where is_active
       and next_run_date is not null
       and next_run_date <= p_on
       and (end_date is null or next_run_date <= end_date)
  loop
    begin
      if r.auto_post then
        perform app.create_gl_entry_internal(
          p_org_id       => r.org_id,
          p_entry_date   => r.next_run_date,
          p_source       => 'recurring'::app.journal_source,
          p_lines        => r.template -> 'lines',
          p_description  => coalesce(r.description, r.name),
          p_source_table => 'recurring_journals',
          p_source_id    => r.id,
          p_reference    => r.name);
      end if;

      update public.recurring_journals
         set last_run_date = r.next_run_date,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count, r.start_date),
             last_error = null,
             last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      -- next_run_date is left alone, so it is retried once whatever is
      -- wrong has been put right.
      update public.recurring_journals
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
    end;
  end loop;
  return v_n;
end;
$function$;

-- public.create_bank_transfer
CREATE OR REPLACE FUNCTION public.create_bank_transfer(p_from_account_id uuid, p_to_account_id uuid, p_amount_sent numeric, p_transfer_date date DEFAULT app.today(), p_amount_received numeric DEFAULT NULL::numeric, p_bank_charges numeric DEFAULT 0, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  f public.bank_accounts;
  t public.bank_accounts;
  v_base char(3);
  v_charges numeric(18, 2) := round(coalesce(p_bank_charges, 0), 2);
  v_sent numeric(18, 2) := round(p_amount_sent, 2);
  v_received numeric(18, 2);
  v_from_rate numeric(18, 8);
  v_to_rate numeric(18, 8);
  v_diff numeric(18, 2);
  v_id uuid;
begin
  select * into f from public.bank_accounts where id = p_from_account_id;
  if not found then
    raise exception 'No such bank account to send from' using errcode = 'P0002';
  end if;
  select * into t from public.bank_accounts where id = p_to_account_id;
  if not found then
    raise exception 'No such bank account to send to' using errcode = 'P0002';
  end if;

  if not app.can_post(f.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  -- Two companies' bank accounts in one journal would breach the
  -- boundary every other part of this system is built around.
  if f.org_id <> t.org_id then
    raise exception 'Those accounts belong to different organizations'
      using errcode = '42501';
  end if;
  if f.id = t.id then
    raise exception 'That is the same account at both ends'
      using errcode = '22023';
  end if;
  if v_sent <= 0 then
    raise exception 'A transfer needs an amount' using errcode = '22023';
  end if;

  select base_currency into v_base from public.organizations where id = f.org_id;
  v_from_rate := case when f.currency = coalesce(v_base, 'MYR') then 1
    else app.exchange_rate_for(f.org_id, f.currency, p_transfer_date) end;
  v_to_rate := case when t.currency = coalesce(v_base, 'MYR') then 1
    else app.exchange_rate_for(f.org_id, t.currency, p_transfer_date) end;

  if v_from_rate is null or v_to_rate is null then
    raise exception
      'No exchange rate for % on %. Add one before moving money between '
      'accounts in different currencies.',
      case when v_from_rate is null then f.currency else t.currency end,
      p_transfer_date using errcode = '22023';
  end if;

  -- Same currency and nobody said otherwise: what arrives is what left,
  -- less the fee. Across currencies there is nothing to assume, and
  -- guessing would be inventing a rate.
  v_received := round(coalesce(p_amount_received,
    case when f.currency = t.currency then v_sent - v_charges else null end), 2);
  if v_received is null then
    raise exception
      'Say how much arrived in %: the accounts are in different currencies',
      t.currency using errcode = '22023';
  end if;
  if v_received <= 0 then
    raise exception 'Nothing arrived at the other end' using errcode = '22023';
  end if;

  v_diff := round(v_sent * v_from_rate, 2)
          - round(v_received * v_to_rate, 2)
          - round(v_charges * v_from_rate, 2);

  -- In one currency the three figures are arithmetic, not judgement, so
  -- a residual is a typo rather than an exchange difference.
  if f.currency = t.currency and v_diff <> 0 then
    raise exception
      'Sent %, received % and % in charges do not add up — % is left over',
      v_sent, v_received, v_charges, v_diff using errcode = '22023';
  end if;

  insert into public.bank_transfers
    (org_id, transfer_no, transfer_date, from_account_id, to_account_id,
     amount_sent, amount_received, bank_charges, from_rate, to_rate,
     fx_difference, reference, notes, created_by)
  values (
    f.org_id, public.next_document_number(f.org_id, 'bank_transfer'),
    p_transfer_date, f.id, t.id,
    v_sent, v_received, v_charges, v_from_rate, v_to_rate, v_diff,
    p_reference, p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end; $function$;

-- public.depreciation_preview
CREATE OR REPLACE FUNCTION public.depreciation_preview(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(asset_id uuid, asset_no text, name text, cost numeric, accumulated numeric, charge numeric, net_book_value numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select a.id, a.asset_no, a.name, a.cost, a.accumulated_depreciation,
         greatest(app.accumulated_depreciation_at(a, p_as_at)
                  - a.accumulated_depreciation, 0),
         a.cost - greatest(app.accumulated_depreciation_at(a, p_as_at),
                           a.accumulated_depreciation)
    from public.fixed_assets a
   where a.org_id = p_org_id and a.deleted_at is null
     and a.status = 'active'
     and a.acquisition_date <= p_as_at
   order by a.asset_no;
end;
$function$;

-- public.exchange_rate_board
CREATE OR REPLACE FUNCTION public.exchange_rate_board(p_org_id uuid, p_on_date date DEFAULT app.today())
 RETURNS TABLE(currency character, name text, rate numeric, rate_date date, source text, is_own boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_base character(3);
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  v_base := app.base_currency(p_org_id);

  return query
  select c.code, c.name, e.rate, e.rate_date, e.source, e.org_id is not null
    from public.ref_currencies c
    left join lateral (
      select x.rate, x.rate_date, x.source, x.org_id
        from public.exchange_rates x
       where (x.org_id = p_org_id or x.org_id is null)
         and x.from_currency = c.code
         and x.to_currency = v_base
         and x.rate_date <= p_on_date
       order by x.rate_date desc, (x.org_id is not null) desc
       limit 1) e on true
   where c.is_active and c.code <> v_base
   order by c.code;
end;
$function$;

-- public.exchange_rate_for
CREATE OR REPLACE FUNCTION public.exchange_rate_for(p_org_id uuid, p_currency character, p_on_date date DEFAULT app.today())
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  return app.exchange_rate_for(p_org_id, p_currency, p_on_date);
end;
$function$;

-- public.fs_lodge
CREATE OR REPLACE FUNCTION public.fs_lodge(p_filing_id uuid, p_reference text, p_lodged_on date DEFAULT app.today())
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then
    raise exception 'You may not lodge these accounts' using errcode = '42501';
  end if;
  if f.status <> 'frozen' then
    raise exception
      'Freeze the accounts before recording the lodgement — what was '
      'filed has to be a fixed set of figures.' using errcode = '22023';
  end if;
  if coalesce(trim(p_reference), '') = '' then
    raise exception 'Record the MBRS reference mPortal gave you'
      using errcode = '22023';
  end if;
  if f.circulated_on is null then
    raise exception
      'Record when the accounts went to the members first. Section 259 '
      'lodges the circulated accounts within thirty days of circulating '
      'them, and a lodgement with no circulation behind it is measured '
      'against a clock that never started.' using errcode = '22023';
  end if;

  perform set_config('app.fs_writing', 'on', true);
  update public.fs_filings
     set status = 'lodged', lodged_on = p_lodged_on,
         mbrs_reference = trim(p_reference)
   where id = p_filing_id;
  perform set_config('app.fs_writing', 'off', true);
end $function$;

-- public.fx_revaluation_preview
CREATE OR REPLACE FUNCTION public.fx_revaluation_preview(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(currency character, closing_rate numeric, documents integer, booked numeric, restated numeric, difference numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_base character(3);
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;
  v_base := app.base_currency(p_org_id);

  return query
  with open_items as (
    select d.currency, d.balance_amount as amount,
           coalesce(d.exchange_rate, 1) as rate
      from public.sales_documents d
     where d.org_id = p_org_id and d.currency <> v_base
       and d.balance_amount <> 0 and d.doc_date <= p_as_at
       and d.deleted_at is null and d.gl_entry_id is not null
       and d.status <> 'void'
    union all
    select d.currency, -d.balance_amount, coalesce(d.exchange_rate, 1)
      from public.purchase_documents d
     where d.org_id = p_org_id and d.currency <> v_base
       and d.balance_amount <> 0 and d.doc_date <= p_as_at
       and d.deleted_at is null and d.gl_entry_id is not null
       and d.status <> 'void'
  )
  select o.currency,
         app.exchange_rate_for(p_org_id, o.currency, p_as_at),
         count(*)::integer,
         round(sum(o.amount * o.rate), 2),
         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at)), 2),
         round(sum(o.amount * app.exchange_rate_for(p_org_id, o.currency, p_as_at))
             - sum(o.amount * o.rate), 2)
    from open_items o
   group by o.currency
   order by o.currency;
end;
$function$;

-- public.pos_day_sheet
CREATE OR REPLACE FUNCTION public.pos_day_sheet(p_outlet uuid, p_date date DEFAULT app.today())
 RETURNS TABLE(provider_id uuid, provider text, booking_id uuid, starts_at timestamp with time zone, ends_at timestamp with time zone, minutes integer, status app.pos_booking_status, customer text, description text, price numeric, sale_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select p.id, p.name, b.id, b.starts_at, b.ends_at,
         (extract(epoch from (b.ends_at - b.starts_at)) / 60)::integer,
         b.status, coalesce(c.name, 'Walk-in'), b.description, b.price, b.sale_id
    from public.pos_service_providers p
    left join public.pos_bookings b
      on b.provider_id = p.id
     and (b.starts_at at time zone 'Asia/Kuala_Lumpur')::date = p_date
    left join public.contacts c on c.id = b.contact_id
   where p.outlet_id = p_outlet
     and p.is_active
     and app.can_read_module(p.org_id, 'pos')
   order by p.name, b.starts_at;
$function$;

-- public.remit_withholding
CREATE OR REPLACE FUNCTION public.remit_withholding(p_id uuid, p_paid_on date DEFAULT app.today(), p_bank_account_id uuid DEFAULT NULL::uuid, p_reference text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  c public.withholding_certificates;
  v_bank uuid;
  v_wht uuid;
  v_base numeric(18, 2);
  v_entry uuid;
begin
  select * into c from public.withholding_certificates where id = p_id;
  if not found then
    raise exception 'Certificate % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(c.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if c.gl_entry_id is null then
    raise exception 'Post the certificate before remitting it'
      using errcode = '22023';
  end if;
  if c.remitted_on is not null then
    raise exception 'Certificate % was already remitted on %',
      c.certificate_no, c.remitted_on using errcode = '22023';
  end if;

  if p_bank_account_id is not null
     and not exists (select 1 from public.bank_accounts b
                      where b.id = p_bank_account_id and b.org_id = c.org_id)
  then
    raise exception 'That bank account belongs to another organization'
      using errcode = '42501';
  end if;

  -- A remittance that named no account used to be credited to 1120
  -- Bank Accounts -- the heading the real accounts hang under -- which
  -- moved no bank balance and showed on no reconciliation. This
  -- function's own comment already named that harm while doing it: it
  -- documented refusing ANOTHER COMPANY's account because "falling back
  -- to the default cash account would post the entry anyway and leave
  -- nobody any the wiser", and then fell back for a missing one.
  --
  -- `0506` read this function and left it alone, correctly, for the
  -- cross-tenant guard above. Its header's "neither needed changing"
  -- was about that guard and said nothing about the fallback; it was
  -- read as a verdict on the whole function, which is how this survived
  -- `0728`.
  if p_bank_account_id is null then
    raise exception
      'Say which account the remittance was paid from. Without one there '
      'is no bank balance to move and nothing for a reconciliation to '
      'match.' using errcode = '23514';
  end if;

  select a.id into v_bank from public.bank_accounts b
    join public.accounts a on a.id = b.account_id
   where b.id = p_bank_account_id and b.org_id = c.org_id;
  if v_bank is null then
    raise exception 'That account is not on this company''s chart.'
      using errcode = 'P0002';
  end if;

  v_wht := app.withholding_account(c.org_id);
  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);

  v_entry := public.create_gl_entry(
    c.org_id, p_paid_on, 'withholding'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', v_wht,
        'description', 'Remitted ' || c.section || ' ' || c.certificate_no,
        'debit', v_base, 'credit', 0),
      jsonb_build_object(
        'account_id', v_bank,
        'description', 'Remitted ' || c.certificate_no,
        'debit', 0, 'credit', v_base)),
    'Withholding remittance ' || c.certificate_no,
    'withholding_certificates', c.id,
    coalesce(p_reference, c.form_code));

  update public.bank_accounts
     set current_balance = current_balance - v_base
   where id = p_bank_account_id
     and org_id = c.org_id;

  update public.withholding_certificates
     set remitted_on = p_paid_on, remittance_ref = p_reference,
         remittance_gl_entry_id = v_entry, status = 'completed'
   where id = p_id;

  return v_entry;
end; $function$;

-- public.report_ap_aging
CREATE OR REPLACE FUNCTION public.report_ap_aging(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, doc_kind text, document_id uuid, doc_no text, doc_date date, due_date date, currency character, outstanding numeric, base_outstanding numeric, days_overdue integer, aging_bucket text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with allocations as (
    select a.bill_id, a.payment_id, a.amount, a.discount_amount
      from public.payment_allocations a
      join public.purchase_documents b on b.id = a.bill_id
       and b.gl_entry_id is not null and b.deleted_at is null
       and b.status <> 'void' and b.doc_date <= p_as_at
      left join public.purchase_payments p on p.id = a.payment_id
       and p.gl_entry_id is not null and p.deleted_at is null
       and p.status <> 'void'
      left join public.sales_documents cn on cn.id = a.credit_note_id
       and cn.gl_entry_id is not null and cn.deleted_at is null
       and cn.status <> 'void'
      left join public.withholding_certificates w on w.id = a.withholding_id
       and w.gl_entry_id is not null and w.deleted_at is null
       and w.status <> 'void'
     where a.org_id = p_org_id
       and coalesce(p.payment_date, cn.doc_date, w.cert_date) <= p_as_at
  ),
  documents as (
    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,
           d.doc_no, d.doc_date, d.due_date, d.currency,
           coalesce(d.exchange_rate, 1) as rate,
           case when d.doc_type = 'purchase_credit_note' then -1 else 1 end
           * (d.total_amount - case
               when d.doc_type in ('bill', 'purchase_debit_note') then
                 coalesce((select sum(al.amount + al.discount_amount)
                             from allocations al where al.bill_id = d.id), 0)
               else 0 end) as outstanding
      from public.purchase_documents d
     where d.org_id = p_org_id
       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
       and d.doc_date <= p_as_at
    union all
    select p.contact_id, 'payment', p.id, p.payment_no,
           p.payment_date, null::date, p.currency,
           coalesce(p.exchange_rate, 1),
           -(p.amount - coalesce((select sum(al.amount) from allocations al
                                   where al.payment_id = p.id), 0))
      from public.purchase_payments p
     where p.org_id = p_org_id
       and p.gl_entry_id is not null
       and p.status <> 'void'
       and p.deleted_at is null
       and p.payment_date <= p_as_at
  )
  select d.contact_id, c.code, c.name,
         d.doc_kind, d.document_id, d.doc_no, d.doc_date, d.due_date,
         d.currency,
         round(d.outstanding, 2),
         round(d.outstanding * d.rate, 2),
         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,
         case
           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'
           else 'over_90'
         end
    from documents d
    join public.contacts c on c.id = d.contact_id
   where round(d.outstanding, 2) <> 0
     and app.is_org_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$function$;

-- public.report_ar_aging
CREATE OR REPLACE FUNCTION public.report_ar_aging(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, doc_kind text, document_id uuid, doc_no text, doc_date date, due_date date, currency character, outstanding numeric, base_outstanding numeric, days_overdue integer, aging_bucket text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with allocations as (
    -- Only allocations whose two ends were both in the ledger by the
    -- as-at date. `discount_amount` is carried because the settlement
    -- trigger treats it as settling the invoice; nothing in the app
    -- writes it today, and if something ever does it will need a
    -- journal of its own before it can be trusted here.
    select a.invoice_id, a.receipt_id, a.credit_note_id,
           a.amount, a.discount_amount
      from public.payment_allocations a
      join public.sales_documents inv on inv.id = a.invoice_id
       and inv.gl_entry_id is not null and inv.deleted_at is null
       and inv.status <> 'void' and inv.doc_date <= p_as_at
      left join public.receipts r on r.id = a.receipt_id
       and r.gl_entry_id is not null and r.deleted_at is null
       and r.status <> 'void'
      left join public.sales_documents cn on cn.id = a.credit_note_id
       and cn.gl_entry_id is not null and cn.deleted_at is null
       and cn.status <> 'void'
     where a.org_id = p_org_id
       and coalesce(r.receipt_date, cn.doc_date) <= p_as_at
  ),
  -- Documents that moved the receivable: invoices and debit notes add
  -- to it, credit notes and refund notes take away.
  documents as (
    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,
           d.doc_no, d.doc_date, d.due_date, d.currency,
           coalesce(d.exchange_rate, 1) as rate,
           case when d.doc_type in ('credit_note', 'refund_note')
                then -1 else 1 end
           * (d.total_amount - case
               when d.doc_type = 'credit_note' then
                 -- A credit note keeps its own full total in
                 -- `balance_amount` however much of it has been used,
                 -- so what is left has to be worked out here.
                 coalesce((select sum(al.amount) from allocations al
                            where al.credit_note_id = d.id), 0)
               when d.doc_type in ('invoice', 'debit_note') then
                 coalesce((select sum(al.amount + al.discount_amount)
                             from allocations al
                            where al.invoice_id = d.id), 0)
               -- A refund note has no way to be allocated against
               -- anything, so it stands until it is reversed.
               else 0 end) as outstanding
      from public.sales_documents d
     where d.org_id = p_org_id
       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')
       and d.gl_entry_id is not null
       and d.status <> 'void'
       and d.deleted_at is null
       and d.doc_date <= p_as_at
    union all
    -- Cash received and not yet applied to anything. The receipt
    -- credited the receivable on the day it was banked whether or not
    -- anybody has matched it since, so it belongs on the listing.
    select r.contact_id, 'receipt', r.id, r.receipt_no,
           r.receipt_date, null::date, r.currency,
           coalesce(r.exchange_rate, 1),
           -(r.amount - coalesce((select sum(al.amount) from allocations al
                                   where al.receipt_id = r.id), 0))
      from public.receipts r
     where r.org_id = p_org_id
       and r.gl_entry_id is not null
       and r.status <> 'void'
       and r.deleted_at is null
       and r.receipt_date <= p_as_at
  )
  select d.contact_id, c.code, c.name,
         d.doc_kind, d.document_id, d.doc_no, d.doc_date, d.due_date,
         d.currency,
         round(d.outstanding, 2),
         round(d.outstanding * d.rate, 2),
         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,
         case
           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'
           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'
           else 'over_90'
         end
    from documents d
    join public.contacts c on c.id = d.contact_id
   where round(d.outstanding, 2) <> 0
     and app.is_org_member(p_org_id)
   order by c.name, d.doc_date, d.doc_no;
$function$;

-- public.report_asset_movements
CREATE OR REPLACE FUNCTION public.report_asset_movements(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(category text, assets integer, cost_opening numeric, additions numeric, disposals_cost numeric, cost_closing numeric, accum_opening numeric, charge numeric, disposals_accum numeric, accum_closing numeric, net_book_value numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from date := coalesce(p_from, date '0001-01-01');
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Insufficient privileges to read the ledger'
      using errcode = '42501';
  end if;

  return query
  with asset as (
    select fa.id, coalesce(nullif(trim(fa.category), ''), 'Uncategorised')
             as category,
           fa.cost, fa.accumulated_depreciation,
           -- On the books at the start of the period, and at the end.
           (fa.acquisition_date < v_from
            and (fa.disposal_date is null or fa.disposal_date >= v_from))
             as was_held,
           (fa.acquisition_date <= p_to
            and (fa.disposal_date is null or fa.disposal_date > p_to))
             as still_held,
           (fa.acquisition_date >= v_from and fa.acquisition_date <= p_to)
             as came_in,
           (fa.disposal_date is not null
            and fa.disposal_date >= v_from and fa.disposal_date <= p_to)
             as went_out,
           -- Per asset, so the outer query is plain sums. What was
           -- charged during the period, what had been charged before it
           -- opened, and what has been charged by the time it closed.
           (select coalesce(sum(e.amount), 0)
              from public.depreciation_entries e
              join public.depreciation_runs r on r.id = e.run_id
             where e.asset_id = fa.id
               and r.run_date >= v_from and r.run_date <= p_to)
             as period_charge,
           app.accumulated_charged_at(fa.id, v_from - 1) as accum_before,
           app.accumulated_charged_at(fa.id, p_to) as accum_after
      from public.fixed_assets fa
     where fa.org_id = p_org_id and fa.deleted_at is null
       and fa.acquisition_date <= p_to
       -- Gone before the period opened: it belongs to an earlier note,
       -- and listing it here would put a row of nils under its category.
       and (fa.disposal_date is null or fa.disposal_date >= v_from))
  select a.category,
         (count(*) filter (where a.still_held))::integer,
         coalesce(sum(a.cost) filter (where a.was_held), 0),
         coalesce(sum(a.cost) filter (where a.came_in), 0),
         coalesce(sum(a.cost) filter (where a.went_out), 0),
         coalesce(sum(a.cost) filter (where a.still_held), 0),
         coalesce(sum(a.accum_before) filter (where a.was_held), 0),
         coalesce(sum(a.period_charge), 0),
         -- What left with the asset. Frozen on the row by the disposal,
         -- which is also the last thing it charged.
         coalesce(sum(a.accumulated_depreciation) filter (where a.went_out), 0),
         coalesce(sum(a.accum_after) filter (where a.still_held), 0),
         coalesce(sum(a.cost) filter (where a.still_held), 0)
           - coalesce(sum(a.accum_after) filter (where a.still_held), 0)
    from asset a
   group by a.category
   order by a.category;
end $function$;

-- public.report_balance_sheet
CREATE OR REPLACE FUNCTION public.report_balance_sheet(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(sum(
           -- e.id is null when the journal did not satisfy the join
           -- conditions (draft, void, or after the cut-off date).
           case when e.id is null then 0
                when a.account_type in ('asset', 'expense')
                then l.debit - l.credit
                else l.credit - l.debit end), 0) + a.opening_balance, 2) as balance
    from public.accounts a
    left join public.gl_lines l on l.account_id = a.id
    left join public.gl_entries e on e.id = l.entry_id
         and e.status = 'posted' and e.entry_date <= p_as_at
   where a.org_id = p_org_id
     and a.deleted_at is null
     and not a.is_group
     and a.account_type in ('asset', 'liability', 'equity')
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance
   order by a.code;
$function$;

-- public.report_collections
CREATE OR REPLACE FUNCTION public.report_collections(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(contact_id uuid, contact_code text, contact_name text, outstanding numeric, oldest_days integer, invoices integer, last_attempt_on date, last_outcome app.collection_outcome, last_notes text, promise_date date, promise_amount numeric, promise_broken boolean, assigned_to uuid, assigned_name text, never_chased boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  if not (app.can_read_ledger(p_org_id) or app.can_write(p_org_id)) then
    raise exception 'You may not read the sales ledger'
      using errcode = '42501';
  end if;

  return query
  with owed as (
    select a.contact_id, a.contact_code, a.contact_name,
           sum(a.base_outstanding) as outstanding,
           max(a.days_overdue) as oldest_days,
           count(*)::integer as invoices
      from public.report_ar_aging(p_org_id, p_as_at) a
     where a.doc_kind = 'invoice'
       and a.base_outstanding > 0
     group by 1, 2, 3
  ),
  latest as (
    -- The most recent attempt per customer. `distinct on` rather than a
    -- window function because only one row per customer is wanted and
    -- this is the shape Postgres can answer straight off the index.
    select distinct on (c.contact_id)
           c.contact_id, c.attempted_on, c.outcome, c.notes, c.assigned_to
      from public.collection_attempts c
     where c.org_id = p_org_id and c.attempted_on <= p_as_at
     order by c.contact_id, c.attempted_on desc, c.created_at desc
  ),
  promised as (
    -- The live promise: the furthest-out date anybody has given that has
    -- not yet been superseded by a later attempt. Taking the *latest*
    -- promise rather than the earliest is deliberate — a customer who
    -- rang back to move Friday to the following Tuesday has one promise,
    -- for Tuesday, and chasing them on Friday is chasing a promise they
    -- already renegotiated.
    select distinct on (c.contact_id)
           c.contact_id, c.promise_date, c.promise_amount
      from public.collection_attempts c
     where c.org_id = p_org_id
       and c.promise_date is not null
       and c.attempted_on <= p_as_at
     order by c.contact_id, c.attempted_on desc, c.created_at desc
  )
  select o.contact_id, o.contact_code, o.contact_name,
         o.outstanding, o.oldest_days, o.invoices,
         l.attempted_on, l.outcome, l.notes,
         p.promise_date, p.promise_amount,
         -- Broken: the day came and went and they still owe something.
         -- This row only exists because they owe something, so the
         -- second half of that is already true.
         (p.promise_date is not null and p.promise_date < p_as_at),
         l.assigned_to,
         (select coalesce(pr.full_name, pr.email)
            from public.profiles pr where pr.id = l.assigned_to),
         (l.contact_id is null)
    from owed o
    left join latest l on l.contact_id = o.contact_id
    left join promised p on p.contact_id = o.contact_id
   order by
     -- Broken promises first, then never chased, then oldest debt. A
     -- worklist that opens on the thing most likely to be lost.
     (p.promise_date is not null and p.promise_date < p_as_at) desc,
     (l.contact_id is null) desc,
     o.oldest_days desc;
end $function$;

-- public.report_group_consolidated_trial_balance
CREATE OR REPLACE FUNCTION public.report_group_consolidated_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(code text, name text, account_type app.account_type, account_subtype app.account_subtype, companies integer, combined_balance numeric, elimination numeric, consolidated_balance numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_partial text;
  v_unowned text;
  v_parent  text;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  -- Anything short of wholly owned needs minority interest, and this
  -- does not compute one. Named rather than refused in general, because
  -- "cannot consolidate" is not an answer somebody can act on.
  select string_agg(o.name || ' (' || o.owned_percent || '%)', ', ')
    into v_partial
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.owned_percent is not null
     and o.owned_percent < 100;

  if v_partial is not null then
    raise exception
      'These companies are not wholly owned: %. Consolidating them needs '
      'minority interest, which is not built — the group''s share of '
      'their profit and net assets would have to be split out, and this '
      'report would understate it silently.', v_partial
      using errcode = '22000';
  end if;

  -- Standing in a subsidiary. Answered before the unowned test below,
  -- which would otherwise report the parent as having no owner — true,
  -- and not a problem, and not something anybody can fix.
  select p.name into v_parent
    from public.organizations o
    join public.organizations p on p.id = o.parent_org_id
   where o.id = p_org_id;

  if v_parent is not null then
    raise exception
      'Consolidated accounts are prepared by the parent, and this company '
      'is owned by %. Switch to it and run the report there. The combined '
      'trial balance and the inter-company check work from here.', v_parent
      using errcode = '22000';
  end if;

  select string_agg(o.name, ', ') into v_unowned
    from app.group_orgs(p_org_id) g
    join public.organizations o on o.id = g.org_id
   where o.id <> p_org_id and o.parent_org_id is null;

  if v_unowned is not null then
    raise exception
      'Nobody has recorded who owns %. A consolidation cannot be produced '
      'without it: whether the whole of a subsidiary belongs to the group '
      'is the question minority interest turns on. Record it in Settings.',
      v_unowned
      using errcode = '22000';
  end if;

  return query
  with e as (
    select g.code, sum(g.adjustment) as adjustment
      from app.group_eliminations(p_org_id, p_from, p_to) g
     group by g.code)
  select t.code, t.name, t.account_type, t.account_subtype, t.companies,
         t.closing_balance,
         coalesce(e.adjustment, 0),
         round(t.closing_balance + coalesce(e.adjustment, 0), 2)
    from public.report_group_trial_balance(p_org_id, p_from, p_to) t
    left join e on e.code = t.code
   order by t.code;
end; $function$;

-- public.report_group_elimination_check
CREATE OR REPLACE FUNCTION public.report_group_elimination_check(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(from_org text, to_org text, what text, their_side numeric, our_side numeric, difference numeric, eliminated boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  return query
  with lines as (select * from app.group_intercompany_lines(p_org_id, p_from, p_to)),
  totals as (
    select l.org_id, l.counterparty, l.category, sum(l.amount) as amount
      from lines l group by l.org_id, l.counterparty, l.category),
  pairs as (
    select r.org_id as a, r.counterparty as b,
           'Balances owed'::text as what,
           r.amount as a_side,
           coalesce(p.amount, 0) as b_side
      from totals r
      left join totals p
        on p.org_id = r.counterparty and p.counterparty = r.org_id
       and p.category = 'payable'
     where r.category = 'receivable'
    union all
    select s.org_id, s.counterparty, 'Trading'::text,
           s.amount, coalesce(x.amount, 0)
      from totals s
      left join totals x
        on x.org_id = s.counterparty and x.counterparty = s.org_id
       and x.category = 'expense'
     where s.category = 'revenue')
  select seller.name, buyer.name, pairs.what,
         pairs.a_side, pairs.b_side,
         round(pairs.a_side - pairs.b_side, 2),
         round(pairs.a_side - pairs.b_side, 2) = 0
    from pairs
    join public.organizations seller on seller.id = pairs.a
    join public.organizations buyer  on buyer.id  = pairs.b
   order by seller.name, buyer.name, pairs.what;
end; $function$;

-- public.report_group_intercompany
CREATE OR REPLACE FUNCTION public.report_group_intercompany(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(from_org_id uuid, from_org text, to_org_id uuid, to_org text, contact_id uuid, contact_name text, receivable numeric, payable numeric, revenue numeric, expense numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  return query
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),
  lines as (
    select l.org_id, c.linked_org_id, c.id as contact_id, c.name as contact_name,
           a.account_type, a.account_subtype, l.debit, l.credit
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      join public.contacts c on c.id = l.contact_id
      join public.accounts a on a.id = l.account_id
     where l.org_id in (select org_id from orgs)
       and c.linked_org_id in (select org_id from orgs)
       and e.status = 'posted'
       and e.entry_date <= p_to
       and (p_from is null or e.entry_date >= p_from))
  select l.org_id, mine.name, l.linked_org_id, theirs.name,
         l.contact_id, l.contact_name,
         round(sum(case when l.account_subtype = 'accounts_receivable'
                        then l.debit - l.credit else 0 end), 2),
         round(sum(case when l.account_subtype = 'accounts_payable'
                        then l.credit - l.debit else 0 end), 2),
         round(sum(case when l.account_type = 'revenue'
                        then l.credit - l.debit else 0 end), 2),
         round(sum(case when l.account_type = 'expense'
                        then l.debit - l.credit else 0 end), 2)
    from lines l
    join public.organizations mine on mine.id = l.org_id
    join public.organizations theirs on theirs.id = l.linked_org_id
   group by l.org_id, mine.name, l.linked_org_id, theirs.name,
            l.contact_id, l.contact_name
  having sum(abs(l.debit)) + sum(abs(l.credit)) <> 0
   order by mine.name, theirs.name;
end; $function$;

-- public.report_group_trial_balance
CREATE OR REPLACE FUNCTION public.report_group_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(code text, name text, account_type app.account_type, account_subtype app.account_subtype, companies integer, opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_currencies text[];
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  select array_agg(distinct g.base_currency)
    into v_currencies
    from app.group_orgs(p_org_id) g;

  if v_currencies is null then
    raise exception 'This company is not in a group'
      using errcode = '42501';
  end if;

  if array_length(v_currencies, 1) > 1 then
    raise exception
      'The companies in this group keep their books in different '
      'currencies (%). Adding them together would produce a number that '
      'is not money. Translating them properly is not built yet.',
      array_to_string(v_currencies, ', ')
      using errcode = '22000';
  end if;

  return query
  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),
  per_company as (
    select t.code, t.name, t.account_type, t.account_subtype,
           t.opening_balance, t.debit, t.credit, t.closing_balance
      from orgs o
      cross join lateral public.report_trial_balance(o.org_id, p_from, p_to) t)
  select p.code,
         -- The name from whichever company uses that code; they are the
         -- same seeded chart, and where they are not, one of them has to
         -- win and it may as well be the first alphabetically.
         min(p.name),
         min(p.account_type),
         min(p.account_subtype),
         count(*)::integer,
         round(sum(p.opening_balance), 2),
         round(sum(p.debit), 2),
         round(sum(p.credit), 2),
         round(sum(p.closing_balance), 2)
    from per_company p
   group by p.code
  having sum(abs(p.opening_balance)) + sum(p.debit) + sum(p.credit) <> 0
   order by p.code;
end; $function$;

-- public.report_profit_loss
CREATE OR REPLACE FUNCTION public.report_profit_loss(p_org_id uuid, p_from date, p_to date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2) as amount
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id
     and e.status = 'posted'
     and e.entry_date between p_from and p_to
     and a.account_type in ('revenue', 'expense')
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$function$;

-- public.report_profit_loss_by_dimension
CREATE OR REPLACE FUNCTION public.report_profit_loss_by_dimension(p_org_id uuid, p_from date, p_to date DEFAULT app.today(), p_project_code text DEFAULT NULL::text, p_department_code text DEFAULT NULL::text)
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(sum(case when a.account_type = 'revenue'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2) as amount
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org_id
     and e.status = 'posted'
     and e.entry_date between p_from and p_to
     and a.account_type in ('revenue', 'expense')
     and (p_project_code is null or l.project_code = p_project_code)
     and (p_department_code is null or l.department_code = p_department_code)
     and app.is_org_member(p_org_id)
   group by a.id, a.code, a.name, a.account_type, a.account_subtype
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$function$;

-- public.report_sales_by_person
CREATE OR REPLACE FUNCTION public.report_sales_by_person(p_org_id uuid, p_from date, p_to date DEFAULT app.today())
 RETURNS TABLE(salesperson_id uuid, code text, name text, is_active boolean, invoiced numeric, credited numeric, net_sales numeric, documents integer, commission_rate numeric, commission numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.can_read_ledger(p_org_id) then
    raise exception 'Not allowed to read the ledger of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  with sold as (
    select d.salesperson_id as person,
           sum(case when d.doc_type = 'invoice'
                    then d.total_amount * d.exchange_rate else 0 end) as inv,
           sum(case when d.doc_type in ('credit_note', 'refund_note')
                    then d.total_amount * d.exchange_rate else 0 end) as crd,
           count(*)::integer as docs
      from public.sales_documents d
     where d.org_id = p_org_id
       and d.doc_date between p_from and p_to
       and d.status = 'posted'
       and d.deleted_at is null
       and d.doc_type in ('invoice', 'credit_note', 'refund_note')
     group by d.salesperson_id)
  select s.id, s.code, s.name, s.is_active,
         coalesce(sold.inv, 0),
         coalesce(sold.crd, 0),
         coalesce(sold.inv, 0) - coalesce(sold.crd, 0),
         coalesce(sold.docs, 0),
         s.commission_rate,
         case when s.commission_rate is null then null
              else round((coalesce(sold.inv, 0) - coalesce(sold.crd, 0))
                         * s.commission_rate / 100, 2) end
    from public.salespeople s
    left join sold on sold.person = s.id
   where s.org_id = p_org_id

  union all

  -- The unattributed line, and it is the point of the report rather than
  -- a tidy-up. A business that thinks it is tracking commission needs to
  -- see the sales nobody was credited with, because that is the number
  -- an argument will be about.
  select null::uuid, null, 'Not attributed', true,
         coalesce(sold.inv, 0),
         coalesce(sold.crd, 0),
         coalesce(sold.inv, 0) - coalesce(sold.crd, 0),
         coalesce(sold.docs, 0),
         null::numeric, null::numeric
    from sold
   where sold.person is null

   order by 7 desc nulls last, 3;
end;
$function$;

-- public.report_stock_card
CREATE OR REPLACE FUNCTION public.report_stock_card(p_org_id uuid, p_item_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today(), p_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(movement_date date, movement_no text, movement_type app.stock_movement_type, warehouse text, reference text, quantity numeric, unit_cost numeric, total_cost numeric, balance_quantity numeric, balance_value numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_open_qty   numeric := 0;
  v_open_value numeric := 0;
begin
  -- Stock is not the ledger, and a storekeeper who may not read the
  -- general ledger still has to be able to answer for a shelf. Membership
  -- is the same bar `stock_movements` itself sets for select.
  if not app.is_org_member(p_org_id) then
    raise exception 'You are not a member of this company'
      using errcode = '42501';
  end if;

  if p_from is not null then
    select coalesce(sum(m.quantity), 0), coalesce(sum(m.total_cost), 0)
      into v_open_qty, v_open_value
      from public.stock_movements m
     where m.org_id = p_org_id and m.item_id = p_item_id
       and m.movement_date < p_from
       and (p_warehouse_id is null or m.warehouse_id = p_warehouse_id);
  end if;

  return query
  with moved as (
    select m.movement_date, m.movement_no, m.movement_type,
           w.name as warehouse,
           -- What the movement came from, so the card answers "why"
           -- rather than only "when". The source tables are the ones
           -- that write movements; anything else falls back to the note.
           coalesce(
             (select d.doc_no from public.sales_documents d
               where m.source_table = 'sales_documents' and d.id = m.source_id),
             (select d.doc_no from public.purchase_documents d
               where m.source_table = 'purchase_documents' and d.id = m.source_id),
             (select a.adjustment_no from public.stock_adjustments a
               where m.source_table = 'stock_adjustments' and a.id = m.source_id),
             m.notes) as reference,
           m.quantity, m.unit_cost, m.total_cost, m.id
      from public.stock_movements m
      join public.warehouses w on w.id = m.warehouse_id
     where m.org_id = p_org_id and m.item_id = p_item_id
       and m.movement_date <= p_to
       and (p_from is null or m.movement_date >= p_from)
       and (p_warehouse_id is null or m.warehouse_id = p_warehouse_id))
  select x.movement_date, x.movement_no, x.movement_type, x.warehouse,
         x.reference, x.quantity, x.unit_cost, x.total_cost,
         x.balance_quantity, x.balance_value
    from (
    -- The line the range starts from. Omitted when there is no range and
    -- when nothing came before it, because a brought-forward of nil at
    -- the top of a card that begins at the beginning is noise.
    select p_from, null::text, null::app.stock_movement_type, null::text,
           'Brought forward'::text,
           null::numeric, null::numeric, null::numeric,
           round(v_open_qty, 4), round(v_open_value, 2),
           null::uuid, 0
     where p_from is not null and (v_open_qty <> 0 or v_open_value <> 0)
    union all
    select d.movement_date, d.movement_no, d.movement_type, d.warehouse,
           d.reference, d.quantity, d.unit_cost, d.total_cost,
           round(v_open_qty + sum(d.quantity) over w, 4),
           round(v_open_value + sum(d.total_cost) over w, 2),
           d.id, 1
      from moved d
    window w as (order by d.movement_date, d.movement_no, d.id
                 rows between unbounded preceding and current row)
  ) x (movement_date, movement_no, movement_type, warehouse, reference,
       quantity, unit_cost, total_cost, balance_quantity, balance_value,
       id, ord)
   order by x.ord, x.movement_date, x.movement_no, x.id;
end $function$;

-- public.report_trial_balance
CREATE OR REPLACE FUNCTION public.report_trial_balance(p_org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT app.today())
 RETURNS TABLE(account_id uuid, code text, name text, account_type app.account_type, account_subtype app.account_subtype, opening_balance numeric, debit numeric, credit numeric, closing_balance numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  with movements as (
    select l.account_id,
           -- With no start date every posted line is inside the period,
           -- so there is nothing to carry forward as an opening balance.
           sum(case when p_from is not null and e.entry_date < p_from
                    then l.debit - l.credit else 0 end) as opening,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.debit else 0 end) as dr,
           sum(case when p_from is null or e.entry_date >= p_from
                    then l.credit else 0 end) as cr
      from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
     where l.org_id = p_org_id
       and e.status = 'posted'
       and e.entry_date <= p_to
     group by l.account_id)
  select a.id, a.code, a.name, a.account_type, a.account_subtype,
         round(coalesce(m.opening, 0) + case when a.account_type in ('asset','expense')
               then a.opening_balance else -a.opening_balance end, 2),
         round(coalesce(m.dr, 0), 2),
         round(coalesce(m.cr, 0), 2),
         round(coalesce(m.opening, 0) + coalesce(m.dr, 0) - coalesce(m.cr, 0)
               + case when a.account_type in ('asset','expense')
                      then a.opening_balance else -a.opening_balance end, 2)
    from public.accounts a
    left join movements m on m.account_id = a.id
   where a.org_id = p_org_id
     and a.deleted_at is null
     and not a.is_group
     and app.is_org_member(p_org_id)
   order by a.code;
$function$;

-- public.revalue_foreign_balances
CREATE OR REPLACE FUNCTION public.revalue_foreign_balances(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_base     character(3);
  v_prior    uuid;
  v_entries  jsonb := '[]'::jsonb;
  v_gain     numeric(18, 2) := 0;
  v_loss     numeric(18, 2) := 0;
  v_entry_id uuid;
  r          record;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  v_base := app.base_currency(p_org_id);

  -- Undo the standing revaluation first, dated the same day, so this run
  -- measures from the booked rates rather than from the last estimate.
  select e.id into v_prior
    from public.gl_entries e
   where e.org_id = p_org_id and e.source = 'fx_revaluation'
     and e.status = 'posted' and e.is_reversal = false
     and not exists (select 1 from public.gl_entries x
                      where x.reversed_entry_id = e.id and x.status = 'posted')
   order by e.entry_date desc, e.created_at desc
   limit 1;

  if v_prior is not null then
    perform public.reverse_gl_entry(v_prior, p_as_at);
  end if;

  -- Receivables, then payables, grouped by the account and contact they
  -- sit against so the subledger still agrees with the nominal after
  -- the adjustment.
  for r in
    with items as (
      select coalesce(c.receivable_account_id,
               (select id from public.accounts
                 where org_id = p_org_id and code = '1210')) as account_id,
             d.contact_id, d.currency,
             d.balance_amount as amount, coalesce(d.exchange_rate, 1) as rate
        from public.sales_documents d
        join public.contacts c on c.id = d.contact_id
       where d.org_id = p_org_id and d.currency <> v_base
         and d.balance_amount <> 0 and d.doc_date <= p_as_at
         and d.deleted_at is null and d.gl_entry_id is not null
         and d.status <> 'void'
      union all
      select coalesce(c.payable_account_id,
               (select id from public.accounts
                 where org_id = p_org_id and code = '2110')),
             d.contact_id, d.currency,
             -d.balance_amount, coalesce(d.exchange_rate, 1)
        from public.purchase_documents d
        join public.contacts c on c.id = d.contact_id
       where d.org_id = p_org_id and d.currency <> v_base
         and d.balance_amount <> 0 and d.doc_date <= p_as_at
         and d.deleted_at is null and d.gl_entry_id is not null
         and d.status <> 'void'
    )
    select i.account_id, i.contact_id, i.currency,
           round(sum(i.amount * app.exchange_rate_for(p_org_id, i.currency, p_as_at))
               - sum(i.amount * i.rate), 2) as diff
      from items i
     group by i.account_id, i.contact_id, i.currency
    having round(sum(i.amount * app.exchange_rate_for(p_org_id, i.currency, p_as_at))
              - sum(i.amount * i.rate), 2) <> 0
  loop
    -- The sign carries the meaning and does not need a second rule:
    -- amounts were signed positive for receivables and negative for
    -- payables above, so a positive difference is always more asset or
    -- less liability, which is always a gain.
    if r.diff > 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id', r.account_id,
        'description', 'Revaluation of ' || r.currency || ' balance',
        'debit', r.diff, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
        'contact_id', r.contact_id);
      v_gain := v_gain + r.diff;
    else
      v_entries := v_entries || jsonb_build_object(
        'account_id', r.account_id,
        'description', 'Revaluation of ' || r.currency || ' balance',
        'debit', 0, 'credit', -r.diff, 'fc_debit', 0, 'fc_credit', 0,
        'contact_id', r.contact_id);
      v_loss := v_loss + (-r.diff);
    end if;
  end loop;

  if v_gain = 0 and v_loss = 0 then
    return null;
  end if;

  -- Gains and losses are stated separately rather than netted. A year
  -- with RM 80,000 of each is not the same year as one with neither,
  -- and netting to zero would say it was.
  if v_gain <> 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(p_org_id, true),
      'description', 'Unrealised exchange gain at ' || p_as_at,
      'debit', 0, 'credit', v_gain, 'fc_debit', 0, 'fc_credit', 0);
  end if;
  if v_loss <> 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.fx_account(p_org_id, false),
      'description', 'Unrealised exchange loss at ' || p_as_at,
      'debit', v_loss, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);
  end if;

  v_entry_id := app.create_gl_entry_internal(
    p_org_id, p_as_at, 'fx_revaluation'::app.journal_source, v_entries,
    'Revaluation of foreign balances at ' || p_as_at,
    null, null, null, v_base, 1);

  return v_entry_id;
end;
$function$;

-- public.run_depreciation
CREATE OR REPLACE FUNCTION public.run_depreciation(p_org_id uuid, p_as_at date DEFAULT app.today())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_run_id    uuid;
  v_entry_id  uuid;
  v_entries   jsonb := '[]'::jsonb;
  v_total     numeric(18, 2) := 0;
  v_default_expense uuid;
  v_default_accum   uuid;
  a           public.fixed_assets;
  v_charge    numeric(18, 2);
  v_target    numeric(18, 2);
  r           record;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  select id into v_default_expense from public.accounts
   where org_id = p_org_id and code = '6400';
  select id into v_default_accum from public.accounts
   where org_id = p_org_id and code = '1590';

  insert into public.depreciation_runs (org_id, run_date, posted_by)
  values (p_org_id, p_as_at, auth.uid()) returning id into v_run_id;

  for a in
    select * from public.fixed_assets
     where org_id = p_org_id and deleted_at is null
       and status = 'active' and acquisition_date <= p_as_at
     order by asset_no
  loop
    v_target := app.accumulated_depreciation_at(a, p_as_at);
    v_charge := round(v_target - a.accumulated_depreciation, 2);
    if v_charge <= 0 then continue; end if;

    insert into public.depreciation_entries
      (org_id, run_id, asset_id, amount, opening_accumulated, closing_accumulated)
    values (p_org_id, v_run_id, a.id, v_charge, a.accumulated_depreciation, v_target);

    update public.fixed_assets
       set accumulated_depreciation = v_target,
           depreciated_to = p_as_at,
           status = case when v_target >= a.cost - a.residual_value
                         then 'fully_depreciated' else 'active' end,
           updated_at = now()
     where id = a.id;

    v_total := v_total + v_charge;
  end loop;

  if v_total = 0 then
    delete from public.depreciation_runs where id = v_run_id;
    return null;
  end if;

  -- Grouped after the fact so each side of the journal names the account
  -- it actually belongs to, whether the asset carried its own or fell
  -- back to the chart.
  for r in
    -- Aliased `fa`, not `a`: the loop variable above is already `a` and
    -- plpgsql resolves the name to the variable, leaving `a.id` ambiguous
    -- against the join.
    select coalesce(fa.expense_account_id, v_default_expense) as expense_id,
           coalesce(fa.accumulated_account_id, v_default_accum) as accum_id,
           sum(e.amount) as amount
      from public.depreciation_entries e
      join public.fixed_assets fa on fa.id = e.asset_id
     where e.run_id = v_run_id
     group by 1, 2
  loop
    if r.expense_id is null or r.accum_id is null then
      raise exception
        'No depreciation expense (6400) or accumulated depreciation (1590) '
        'account in the chart. Add them, or name accounts on the asset.'
        using errcode = 'P0002';
    end if;
    v_entries := v_entries
      || jsonb_build_object('account_id', r.expense_id,
           'description', 'Depreciation to ' || p_as_at,
           'debit', r.amount, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0)
      || jsonb_build_object('account_id', r.accum_id,
           'description', 'Depreciation to ' || p_as_at,
           'debit', 0, 'credit', r.amount, 'fc_debit', 0, 'fc_credit', 0);
  end loop;

  v_entry_id := app.create_gl_entry_internal(
    p_org_id, p_as_at, 'depreciation'::app.journal_source, v_entries,
    'Depreciation to ' || p_as_at, 'depreciation_runs', v_run_id, null,
    app.base_currency(p_org_id), 1);

  update public.depreciation_runs
     set gl_entry_id = v_entry_id, total_amount = v_total
   where id = v_run_id;

  return v_run_id;
end;
$function$;

-- public.run_recurring_documents_for
CREATE OR REPLACE FUNCTION public.run_recurring_documents_for(p_org_id uuid, p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r record;
  v_n integer := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  for r in
    select id from public.recurring_documents
     where org_id = p_org_id and is_active and next_run_date <= p_on
  loop
    v_n := v_n + app.advance_recurring_document(r.id, p_on);
  end loop;

  return v_n;
end; $function$;

-- public.run_recurring_journals_for
CREATE OR REPLACE FUNCTION public.run_recurring_journals_for(p_org_id uuid, p_on date DEFAULT app.today())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r public.recurring_journals;
  v_n integer := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  -- Deliberately not `app.run_recurring_journals`: that one walks every
  -- organization in the database, and a signed-in user may only post in
  -- their own. Same body, one org.
  for r in
    select * from public.recurring_journals
     where org_id = p_org_id and is_active
       and next_run_date is not null and next_run_date <= p_on
       and (end_date is null or next_run_date <= end_date)
  loop
    begin
      if r.auto_post then
        perform app.create_gl_entry_internal(
          p_org_id       => r.org_id,
          p_entry_date   => r.next_run_date,
          p_source       => 'recurring'::app.journal_source,
          p_lines        => r.template -> 'lines',
          p_description  => coalesce(r.description, r.name),
          p_source_table => 'recurring_journals',
          p_source_id    => r.id,
          p_reference    => r.name);
      end if;

      update public.recurring_journals
         set last_run_date = r.next_run_date,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count, r.start_date),
             last_error = null, last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      update public.recurring_journals
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
    end;
  end loop;

  return v_n;
end;
$function$;

-- public.strata_arrears
CREATE OR REPLACE FUNCTION public.strata_arrears(p_scheme_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(unit_id uuid, unit_no text, owner_name text, invoice_id uuid, doc_no text, due_date date, outstanding numeric, days_overdue integer, late_interest numeric, total_due numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.is_org_member(s.org_id)
     or not app.has_module(s.org_id, 'property_strata') then
    raise exception 'Not your scheme' using errcode = '42501';
  end if;

  r := app.strata_rate_on(p_scheme_id, p_as_at);

  return query
    select u.id, u.unit_no, c.name, d.id, d.doc_no, d.due_date,
           d.balance_amount,
           greatest(0, (p_as_at - d.due_date))::integer,
           app.strata_late_interest(d.balance_amount, d.due_date, p_as_at,
                                    coalesce(r.late_interest_percent, 0)),
           d.balance_amount
             + app.strata_late_interest(d.balance_amount, d.due_date, p_as_at,
                                        coalesce(r.late_interest_percent, 0))
      from public.strata_charge_lines l
      join public.strata_charge_runs run on run.id = l.run_id
      join public.property_units u on u.id = l.unit_id
      join public.sales_documents d on d.id = l.invoice_id
      left join public.contacts c on c.id = u.owner_contact_id
     where run.scheme_id = p_scheme_id
       and d.status not in ('void', 'draft')
       and d.balance_amount > 0
       and d.deleted_at is null
     order by u.unit_no, d.due_date;
end $function$;

-- public.transfer_between_matters
CREATE OR REPLACE FUNCTION public.transfer_between_matters(p_from uuid, p_to uuid, p_amount numeric, p_date date DEFAULT app.today(), p_description text DEFAULT NULL::text)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from   public.matters;
  v_to     public.matters;
  v_bank   uuid;
  v_held   numeric;
  v_out    uuid;
  v_in     uuid;
  v_note   text;
  v_from_client text;
  v_to_client   text;
begin
  select * into v_from from public.matters
   where id = p_from and deleted_at is null;
  if not found then
    raise exception 'No such matter to move money from.' using errcode = 'P0002';
  end if;
  select * into v_to from public.matters
   where id = p_to and deleted_at is null and org_id = v_from.org_id;
  if not found then
    raise exception 'No such matter to move money to.' using errcode = 'P0002';
  end if;

  if not app.has_module(v_from.org_id, 'legal') then
    raise exception 'This company does not hold the legal module.'
      using errcode = '42501';
  end if;
  if not app.can_post(v_from.org_id) then
    raise exception 'Insufficient privileges to move client money'
      using errcode = '42501';
  end if;

  if p_from = p_to then
    raise exception 'A matter cannot transfer to itself.' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A transfer needs an amount greater than nothing.'
      using errcode = '22023';
  end if;

  -- The statutory refusal, naming both clients. Somebody who picked the
  -- wrong row from a list of open matters needs to see which row.
  if v_from.client_id <> v_to.client_id then
    select name into v_from_client from public.contacts where id = v_from.client_id;
    select name into v_to_client   from public.contacts where id = v_to.client_id;
    raise exception
      'Matter % is %''s and matter % is %''s. Money held for one client '
      'may not be applied for another, so this transfer is refused.',
      v_from.matter_no, coalesce(v_from_client, 'another client'),
      v_to.matter_no,   coalesce(v_to_client, 'somebody else')
      using errcode = '23514';
  end if;

  -- Checked here as well as by 0021's deferred trigger, and the mutation
  -- run that removed this showed it is not the belt-and-braces it looks
  -- like. `assert_client_funds` is `deferrable initially deferred`, so
  -- inside a transaction that does several things it does not fire until
  -- commit — by which point the caller has done more work on the
  -- strength of a transfer that is about to be rejected. The trigger is
  -- the control and this is the refusal, and it names the matter and the
  -- figure rather than the overdraft that would have resulted.
  select coalesce(sum(t.amount), 0) into v_held
    from public.client_account_transactions t
   where t.matter_id = p_from and t.status <> 'void';
  if v_held < p_amount then
    raise exception
      'Matter % holds only %. There is not % to move.',
      v_from.matter_no,
      to_char(v_held, 'FM999999990.00'), to_char(p_amount, 'FM999999990.00')
      using errcode = '23514';
  end if;

  select id into v_bank from public.bank_accounts
   where org_id = v_from.org_id and is_client_account and is_active
   order by is_default desc limit 1;
  if v_bank is null then
    raise exception
      'No client account configured. Run the legal setup first.'
      using errcode = 'P0002';
  end if;

  v_note := coalesce(nullif(btrim(p_description), ''), 'Transfer between matters');

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, created_by)
  values
    (v_from.org_id, p_from,
     app.next_document_number_internal(v_from.org_id, 'client_txn'),
     p_date, 'transfer_out', v_bank, -p_amount,
     v_note || ' — to ' || v_to.matter_no, v_to.matter_no, auth.uid())
  returning id into v_out;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, reference, created_by)
  values
    (v_from.org_id, p_to,
     app.next_document_number_internal(v_from.org_id, 'client_txn'),
     p_date, 'transfer_in', v_bank, p_amount,
     v_note || ' — from ' || v_from.matter_no, v_from.matter_no, auth.uid())
  returning id into v_in;

  -- Posted in the order the money moves. Both entries are the same two
  -- accounts with the signs reversed, so the client bank and the
  -- client-monies-held liability finish where they started: nothing
  -- left the bank, and what moved is which matter it is held against.
  perform public.post_client_transaction(v_out);
  perform public.post_client_transaction(v_in);

  return array[v_out, v_in];
end $function$;

