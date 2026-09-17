-- ---------------------------------------------------------------------
-- 0497  Tell somebody
-- ---------------------------------------------------------------------
-- LHDN rejects an e-Invoice and nothing says so. A ticket runs past the
-- SLA the customer was promised and nothing says so. A claim sits
-- submitted, waiting on the one person who can approve it, and nothing
-- says so. The financial statements are three weeks from the s.259
-- lodgement date and nothing says so.
--
-- All four are recorded. `einvoice_documents` carries the rejection and
-- its reason; `tickets` carries `resolution_due_at`; `expense_claims`
-- carries `approver_id` and a `submitted` status; `fs_filings` carries
-- the year end that the statutory clock runs from. Every one of them is
-- written and none of it is told to anybody. The only outbound channel
-- in the system is email, and email is for the customer -- for the
-- overdue invoice and the document sent -- not for the person doing the
-- work.
--
-- `docs/gaps-against-akaunting.md` calls this "in-app notification
-- centre", after `Common/Notification.php`.
--
-- ### What changes
--
-- `notifications`, and `app.raise_notifications` walking the four
-- sources once a day from `run_daily_jobs`. A notification addressed to
-- nobody in particular (`user_id` null) is the company's; one with a
-- `user_id` is that person's alone, which is what an approval waiting
-- on a named approver is.
--
-- Nothing new is recorded about the business. This is the same shape as
-- 0495: the gap was a read, not a gap in the data.
--
-- ### Saying it once
--
-- A daily job that re-raises what it raised yesterday is a job that
-- makes its own screen useless within a week. A partial unique index
-- over `(org, whose, kind, source)` where nothing has been dismissed
-- means the second night's pass finds the first night's row and leaves
-- it alone -- and a dismissed one can be raised again, because a ticket
-- that goes overdue a second time is news a second time.
--
-- ### The lodgement date is written once
--
-- The s.258/s.259 arithmetic already lives in `fs_deadlines`, which
-- takes a filing id and refuses a caller who is not a member of the
-- company -- so the nightly job, which is nobody, cannot call it.
-- Rather than write the rule a second time where it could drift, it
-- moves into `app.fs_lodge_by` and `fs_deadlines` is restated to call
-- it. One rule, two callers, and the existing assertions in
-- `supabase/tests/` still hold it.
--
-- ### Mutants
--
-- Run against `supabase/tests/notifications.sql`:
--   * the rejected e-Invoice not raised -- "LHDN refusing an invoice is
--     on the list";
--   * nothing stopping the same thing being raised again the next
--     night -- "and running the job again does not say it twice";
--   * a dismissed notification never raised again -- "but a ticket that
--     goes overdue again is news again";
--   * the approval sent to the whole company rather than to the
--     approver -- "and not somebody else's", which is the assertion
--     from the other side: what makes it the clerk's is that it is not
--     on the owner's screen;
--   * somebody else's notification made readable, by dropping the
--     `user_id` half of the policy -- "and not somebody else's";
--   * marking one read on somebody else's behalf -- "a person can only
--     mark their own as read";
--   * the lodgement date read from the year end alone, ignoring the
--     circulation -- "the lodgement date is the one the statute gives".
--     The filing in the test was circulated early, so the two dates are
--     two months apart and the assertion compares the notice against
--     what `fs_deadlines` says for the same filing;
--   * the e-Invoice read not scoped to its own company -- refused by
--     this migration's own self-check, which counts the four
--     `org_id = p_org` clauses and will not install a pass that has
--     lost one, so it never reaches the suite. "and nothing from
--     another company" would have caught it had it got that far.
-- ---------------------------------------------------------------------

create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,
  -- Null is the company's: anybody who can see the company sees it.
  user_id      uuid references auth.users(id) on delete cascade,
  kind         text not null,
  severity     text not null default 'info'
                 check (severity in ('info', 'warning', 'urgent')),
  title        text not null,
  body         text,
  route        text,
  source_table text,
  source_id    uuid,
  created_at   timestamptz not null default now(),
  read_at      timestamptz,
  dismissed_at timestamptz
);

-- Saying it once. The zero uuid stands in for "the company's", because
-- null in a unique index is distinct from every other null and would
-- let the same company-wide notice be raised every night.
create unique index if not exists notifications_once_idx
  on public.notifications (
    org_id,
    coalesce(user_id, '00000000-0000-0000-0000-000000000000'::uuid),
    kind, source_id)
  where dismissed_at is null and source_id is not null;

create index if not exists notifications_mine_idx
  on public.notifications (org_id, user_id, created_at desc)
  where dismissed_at is null;

comment on table public.notifications is
  'What is waiting for somebody. Raised by app.raise_notifications from '
  'what other tables already record; nothing writes here from a client. '
  'See 0497.';

-- ---------------------------------------------------------------------
-- Row level security
--
-- Read only, and only what is addressed to you or to the company. There
-- is no write policy at all: a notification is raised by the system and
-- marked read through a function, so a client that could insert one
-- could put words on somebody else's screen.
-- ---------------------------------------------------------------------
alter table public.notifications enable row level security;

create policy notifications_select on public.notifications
  for select to authenticated
  using (app.is_org_member(org_id)
         and (user_id is null or user_id = auth.uid()));


-- Supabase's own default privileges hand `anon` every new table in
-- `public`. 0165's event trigger strips that from functions and not
-- from tables, so a new table is readable by a stranger from the moment
-- it exists unless this line is here. Taken away before anything is
-- granted -- and see 0413, which does the same for
-- `sales_gateway_payments`.
revoke all on public.notifications from anon, authenticated, public;
grant select on public.notifications to authenticated;

-- ---------------------------------------------------------------------
-- The statutory date, in one place
--
-- Lifted out of `fs_deadlines` so the nightly job can reach it. The
-- rule is CA 2016 s.258 (circulated within six months of the year end)
-- and s.259 (lodged within thirty days of circulation) -- and thirty
-- days from what actually happened where it has, because a company
-- that circulated early owes its lodgement early.
-- ---------------------------------------------------------------------
create or replace function app.fs_lodge_by(
  p_fy_end date, p_circulated_on date)
returns date
language sql immutable
set search_path = public, app, pg_temp as $$
  select coalesce(p_circulated_on,
                  (p_fy_end + interval '6 months')::date) + 30;
$$;

comment on function app.fs_lodge_by(date, date) is
  'CA 2016 s.258 and s.259: when the financial statements must be '
  'lodged. Written once, called by fs_deadlines and by the nightly '
  'notification pass. See 0497.';

-- Restated from the built definition so it uses the rule above rather
-- than repeating it.
create or replace function public.fs_deadlines(p_filing_id uuid)
returns table(circulate_by date, lodge_by date, outside_limit date,
              circulated_on date, lodged_on date, days_left integer,
              is_late boolean, basis text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_public boolean;
  v_circulate date;
  v_lodge date;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  select o.entity_type = 'bhd' into v_public
    from public.organizations o where o.id = f.org_id;

  v_circulate := (f.fy_end + interval '6 months')::date;

  -- Thirty days from what actually happened, falling back to thirty days
  -- from the deadline when it has not happened yet. The rule itself is
  -- in `app.fs_lodge_by`, which the nightly notification pass also
  -- calls -- see 0497.
  v_lodge := app.fs_lodge_by(f.fy_end, f.circulated_on);

  return query select
    v_circulate,
    v_lodge,
    (v_circulate + 30)::date,
    f.circulated_on,
    f.lodged_on,
    (v_lodge - app.today())::integer,
    f.lodged_on is null and app.today() > v_lodge,
    case when coalesce(v_public, false)
      then 'CA 2016 s.340 — laid at the AGM within six months of the year '
           'end — and s.259, lodged within thirty days of that meeting.'
      else 'CA 2016 s.258 — circulated to members within six months of the '
           'year end — and s.259, lodged within thirty days of circulation.'
    end;
end $$;

-- ---------------------------------------------------------------------
-- Raising one
-- ---------------------------------------------------------------------
create or replace function app.notify(
  p_org uuid, p_user uuid, p_kind text, p_title text,
  p_body text default null, p_severity text default 'info',
  p_route text default null, p_source_table text default null,
  p_source_id uuid default null)
returns boolean
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  insert into public.notifications
    (org_id, user_id, kind, severity, title, body, route,
     source_table, source_id)
  values (p_org, p_user, p_kind, p_severity, p_title, p_body, p_route,
          p_source_table, p_source_id);
  return true;
exception when unique_violation then
  -- Already on the list and not yet dismissed. Saying it again would
  -- only bury what is new underneath what is not.
  return false;
end;
$$;

-- ---------------------------------------------------------------------
-- The nightly pass
--
-- Four sources, each already written by the part of the system that
-- owns it. Every one is scoped to the company it is raising for: an
-- unscoped read here would put one company's rejected invoice on
-- another company's bell.
-- ---------------------------------------------------------------------
create or replace function app.raise_notifications(
  p_org uuid, p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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
$$;

-- ---------------------------------------------------------------------
-- Reading and clearing
-- ---------------------------------------------------------------------
create or replace function public.my_notifications(
  p_org uuid default null, p_include_read boolean default false)
returns table(id uuid, kind text, severity text, title text, body text,
              route text, source_table text, source_id uuid,
              created_at timestamptz, read_at timestamptz)
language sql stable
set search_path = public, app, pg_temp as $$
  select n.id, n.kind, n.severity, n.title, n.body, n.route,
         n.source_table, n.source_id, n.created_at, n.read_at
    from public.notifications n
   where n.dismissed_at is null
     and (p_org is null or n.org_id = p_org)
     and (p_include_read or n.read_at is null)
   order by n.created_at desc
   limit 200;
$$;

comment on function public.my_notifications(uuid, boolean) is
  'What is waiting for the caller, in one company or in all of them. '
  'Security invoker: the row level policy is what decides whose it is. '
  'See 0497.';

create or replace function public.unread_notifications(
  p_org uuid default null)
returns integer
language sql stable
set search_path = public, app, pg_temp as $$
  select count(*)::integer from public.notifications n
   where n.dismissed_at is null and n.read_at is null
     and (p_org is null or n.org_id = p_org);
$$;

-- Marking one read is a write, so it is definer -- and therefore has to
-- say whose it is itself, which the policy above would otherwise have
-- done for it.
create or replace function public.mark_notification_read(p_id uuid)
returns boolean
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  update public.notifications n
     set read_at = coalesce(n.read_at, now())
   where n.id = p_id
     and app.is_org_member(n.org_id)
     and (n.user_id is null or n.user_id = auth.uid());
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

create or replace function public.dismiss_notification(p_id uuid)
returns boolean
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  update public.notifications n
     set dismissed_at = now(), read_at = coalesce(n.read_at, now())
   where n.id = p_id
     and app.is_org_member(n.org_id)
     and (n.user_id is null or n.user_id = auth.uid());
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

create or replace function public.mark_all_notifications_read(p_org uuid)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  if not app.is_org_member(p_org) then
    raise exception 'Not your company' using errcode = '42501';
  end if;
  update public.notifications n
     set read_at = now()
   where n.org_id = p_org
     and n.dismissed_at is null
     and n.read_at is null
     and (n.user_id is null or n.user_id = auth.uid());
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.my_notifications(uuid, boolean)
  from public, anon;
revoke all on function public.unread_notifications(uuid) from public, anon;
revoke all on function public.mark_notification_read(uuid) from public, anon;
revoke all on function public.dismiss_notification(uuid) from public, anon;
revoke all on function public.mark_all_notifications_read(uuid)
  from public, anon;
grant execute on function public.my_notifications(uuid, boolean)
  to authenticated;
grant execute on function public.unread_notifications(uuid) to authenticated;
grant execute on function public.mark_notification_read(uuid)
  to authenticated;
grant execute on function public.dismiss_notification(uuid) to authenticated;
grant execute on function public.mark_all_notifications_read(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Into the nightly pass
--
-- Restated from the built definition. Wrapped like everything else in
-- there: a company whose bell cannot be rung must not stop the leave
-- year, the consolidation and the billing for everybody after it.
-- ---------------------------------------------------------------------
create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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
end; $$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_raise text := pg_get_functiondef(
    'app.raise_notifications(uuid, date)'::regprocedure);
  v_daily text := pg_get_functiondef(
    'app.run_daily_jobs(date)'::regprocedure);
  v_fs    text := pg_get_functiondef(
    'public.fs_deadlines(uuid)'::regprocedure);
begin
  -- All four sources, and each one scoped to the company being raised.
  if position('einvoice_documents' in v_raise) = 0
     or position('tickets' in v_raise) = 0
     or position('expense_claims' in v_raise) = 0
     or position('fs_filings' in v_raise) = 0 then
    raise exception '0497: the nightly pass is not reading everything';
  end if;
  if (length(v_raise) -
      length(replace(v_raise, 'org_id = p_org', ''))) / 14 < 4 then
    raise exception '0497: a source is not scoped to its own company';
  end if;
  -- The statutory rule, written once.
  if position('app.fs_lodge_by' in v_fs) = 0
     or position('fs_lodge_by' in v_raise) = 0 then
    raise exception '0497: the lodgement date is computed twice';
  end if;
  if position('raise_notifications' in v_daily) = 0 then
    raise exception '0497: nothing runs the nightly pass';
  end if;
  -- The two rules that keep one person's bell theirs.
  if not exists (select 1 from pg_policies
                  where tablename = 'notifications'
                    and policyname = 'notifications_select') then
    raise exception '0497: notifications are not behind a policy';
  end if;
  if exists (select 1 from pg_policies
              where tablename = 'notifications' and cmd <> 'SELECT') then
    raise exception '0497: a client can write a notification';
  end if;
  if has_table_privilege('authenticated', 'public.notifications', 'insert')
     or has_table_privilege('anon', 'public.notifications', 'select') then
    raise exception '0497: the notifications table is too open';
  end if;
  if has_function_privilege('anon',
       'public.my_notifications(uuid, boolean)', 'execute') then
    raise exception '0497: a stranger can read a company''s notifications';
  end if;
end $do$;
