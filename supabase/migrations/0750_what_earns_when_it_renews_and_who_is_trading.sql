-- =====================================================================
-- 0750 :: what earns, when it renews, and who is still trading
--
-- Three answers given on 6 October to questions a mutation sweep of
-- 0739's functions raised (docs/handoff.md, items 15 to 17).
--
-- 1. A debit note earns commission. `report_sales_by_person` counted
--    invoices less credit and refund notes, and left the debit note --
--    the one other document that posts -- out of both. It posts revenue,
--    so with one in the period the report stopped footing to the profit
--    and loss, which its own test says is the point of it.
--
-- 2. A membership renews on the day it was bought. `membership_period`
--    walked one step at a time from the previous period, so the 28th
--    that February clamps the 31st to was carried on for ever. Every
--    period is now the start plus n steps, which is what its comment
--    claimed since 0218.
--
-- 3. A company on `trial` is a company. `set_org_status` (0020) accepts
--    it and the custom-domain code treats it as live, but every daily
--    job read `status = 'active'`, so a trial company's recurring
--    invoices, dunning mail, notifications, sales digest, CRM reminders
--    and leave year all stopped without a word. One definition of
--    "live" now, used by all of them -- EXCEPT the platform's own
--    billing: `bill_the_month` and `chase_platform_invoices` are left
--    reading `active`, deliberately and unchanged, because a trial is
--    the period nobody is billed for.
--
-- Production had no membership subscriptions and no trial company when
-- this was written, so (2) and (3) move nothing that exists. (1)
-- changes what the report says for any company with a debit note.
-- =====================================================================

create or replace function app.org_status_is_live(p_status text)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(p_status, 'active') in ('active', 'trial');
$$;

comment on function app.org_status_is_live(text) is
  'Is a company with this status still trading, for the purpose of the '
  'daily jobs? active and trial are; suspended and archived are not. '
  'NOT used by the platform''s own billing, which bills active only.';

revoke all on function app.org_status_is_live(text) from public, anon, authenticated;

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
           -- 0750. A debit note is an extra charge on a sale and posts
           -- revenue like one, so it is invoiced, and whoever made the
           -- sale is credited with it. Left out, the report stopped
           -- footing to the profit and loss the moment one was raised.
           sum(case when d.doc_type in ('invoice', 'debit_note')
                    then d.total_amount * d.exchange_rate else 0 end) as inv,
           sum(case when d.doc_type in ('credit_note', 'refund_note')
                    then d.total_amount * d.exchange_rate else 0 end) as crd,
           count(*)::integer as docs
      from public.sales_documents d
     where d.org_id = p_org_id
       and d.doc_date between p_from and p_to
       and d.status = 'posted'
       and d.deleted_at is null
       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')
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
  v_n     integer := 0;
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

  -- 0750. Every period is the START plus n steps. The comment here
  -- always said so -- "add n months to the start is the only arithmetic
  -- that keeps the 31st landing on the 30th" -- and the loop below it
  -- added one step to the PREVIOUS period instead. February clamps the
  -- 31st to the 28th, and a walk carries the 28th on for good: a
  -- membership bought on 31 January renewed on the 28th of every month
  -- after. Counting from the start lands on 31 March, 30 April, 31 May.
  -- Still counted rather than divided, because months are not a fixed
  -- length; a membership has tens of periods, not millions.
  while v_start + v_step * (v_n + 1) <= p_on loop
    v_n := v_n + 1;
  end loop;

  period_start := (v_start + v_step * v_n)::date;
  period_end   := (v_start + v_step * (v_n + 1) - interval '1 day')::date;
  return next;
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

  -- 0750. `trial` is a company using the product, so its HR day, its
  -- till sweep, its notifications and its month-start rolls run like
  -- anybody else's.
  for o in select id from public.organizations
            where app.org_status_is_live(status)
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
       and app.org_status_is_live(o.status)  -- 0750: trial too
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
       and app.org_status_is_live(o.status)  -- 0750: trial too
       and d.next_run_date <= p_on
  loop
    v_n := v_n + app.advance_recurring_document(r.id, p_on);
  end loop;

  return v_n;
end; $function$;

-- app.queue_sales_digest
create or replace function app.queue_sales_digest(
  p_on date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  r      record;
  b      record;
  v_body text;
  v_tot  numeric;
  v_bill integer;
  v_open integer;
  v_void integer;
  v_n    integer := 0;
begin
  for r in
    select s.org_id, s.sales_digest_to, s.from_name, s.reply_to, o.name as org
      from public.email_settings s
      join public.organizations o on o.id = s.org_id
     where s.is_enabled
       and coalesce(btrim(s.sales_digest_to), '') <> ''
       and app.org_status_is_live(o.status)  -- 0750: trial too
       and app.has_module(s.org_id, 'pos')
  loop
    v_body := '';
    v_tot  := 0;
    v_bill := 0;
    v_open := 0;
    v_void := 0;

    for b in select * from public.pos_day_board(r.org_id, p_on) loop
      v_body := v_body || rpad(b.outlet_name, 24)
             || lpad(b.bills::text, 5) || ' bills   '
             || lpad(to_char(b.gross, 'FM999G999G990D00'), 12)
             || case when b.voided_bills > 0
                     then '   (' || b.voided_bills || ' written off, '
                          || to_char(b.voided_value, 'FM999G999G990D00') || ')'
                     else '' end
             || E'\n';
      v_tot  := v_tot + b.gross;
      v_bill := v_bill + b.bills;
      v_open := v_open + b.open_bills;
      v_void := v_void + b.voided_bills;
    end loop;

    -- A shop that was shut has nothing to report, and a mail every
    -- Monday saying "nothing happened on Sunday" is how a digest gets
    -- filtered into a folder nobody opens. Written off with no sales
    -- still goes: that is the day worth asking about.
    if v_bill = 0 and v_void = 0 then
      continue;
    end if;

    v_body :=
      r.org || ' — ' || to_char(p_on, 'FMDay DD Mon YYYY') || E'\n\n'
      || v_body
      || E'\n' || rpad('Total', 24) || lpad(v_bill::text, 5) || ' bills   '
      || lpad(to_char(v_tot, 'FM999G999G990D00'), 12) || E'\n'
      || case when v_open > 0
              then E'\n' || v_open || ' bill(s) still open at the time this '
                   || 'was sent.' || E'\n'
              else '' end;

    begin
      insert into public.email_outbox
        (org_id, to_email, subject, body, reply_to, from_name,
         template_code, dedupe_key)
      values (
        r.org_id, btrim(r.sales_digest_to),
        r.org || ' — takings for ' || to_char(p_on, 'FMDD Mon'),
        v_body, r.reply_to, coalesce(r.from_name, r.org),
        'sales_digest',
        'digest:' || r.org_id::text || ':' || p_on::text);
      v_n := v_n + 1;
    exception when unique_violation then
      -- Already queued for that day. The job running twice is not an
      -- error, and a second copy of yesterday would be.
      null;
    end;
  end loop;

  return v_n;
end;
$$;

-- app.queue_all_activity_reminders
create or replace function app.queue_all_activity_reminders()
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare o record;
begin
  for o in select id from public.organizations
            where app.org_status_is_live(status)  -- 0750: trial too
  loop
    begin
      if app.has_module(o.id, 'crm') then
        perform app.queue_activity_reminders(o.id);
      end if;
    exception when others then
      raise warning 'queue_activity_reminders failed for %: %', o.id, sqlerrm;
    end;
  end loop;
end $$;
