-- Every change reaching every screen that shows it
--
-- `0117` gave the app live updates and gave them to ten tables: the
-- sales and purchase documents, the money against them, contacts, items,
-- expenses and the ledger. `0124` added the claim tables and `0204` the
-- entitlements. Thirteen, out of two hundred and seventy-three tables
-- that carry an `org_id`.
--
-- Everything else is not live and nothing says so. A storeman receives a
-- transfer and the warehouse screen open on the next desk still shows it
-- in transit. A manager approves leave and the roster does not move. A
-- waiter voids a line and the other till keeps the old total. Each of
-- those is somebody deciding from a screen that is quietly out of date,
-- and the only cure anybody has found is to reload the page — which is
-- the complaint `0117` was written to end, still true everywhere it did
-- not reach.
--
-- ---------------------------------------------------------------------
-- Why not simply publish the other two hundred and sixty
--
-- Because the client would then hold two hundred and seventy-three
-- subscriptions, one per table, and the list would have to be kept in
-- step by hand in two places for ever — `0117`'s own header already
-- warns that a name in the publication and not in the app subscribes to
-- nothing, and a name in the app and not in the publication is sent
-- changes nobody reads, and that neither says so.
--
-- So this inverts it. ONE table carries the news:
--
--   * a statement-level trigger on every org-scoped table appends
--     (org_id, table_name) to `live_changes`;
--   * `live_changes` is the only table the app subscribes to;
--   * the app reads the table name out of the row and refreshes what
--     shows that table.
--
-- Adding a table to the feed is then a trigger, written where the rest
-- of the rules are, and not a second edit to a list in Dart.
--
-- ---------------------------------------------------------------------
-- Append-only, and why it is not an upsert
--
-- One row per (org, table), touched in place, would be a smaller table
-- and a worse one: two transactions writing the same table for the same
-- company would queue behind one row, and two transactions writing the
-- same two tables in opposite orders would deadlock on it. Posting a
-- document writes the document, its lines and a journal entry — exactly
-- the shape that deadlocks.
--
-- Appending never blocks. The rows are rubbish within seconds of being
-- written, and the nightly pass throws away anything older than an hour.
--
-- ---------------------------------------------------------------------
-- What this does and does not disclose
--
-- A row here is a company id and a TABLE NAME. No column of the row that
-- changed, no id, no amount — the app is told to re-read, and the
-- re-read goes through the same RLS as any other.
--
-- `0117` deliberately left out the tables holding a secret or another
-- person's private business, and that judgement stands. A table name is
-- a smaller thing than a row, but "payroll_runs changed at 4:07pm" is
-- still something a clerk should not be told, so the feed is gated by
-- the same guards the tables themselves use:
--
--   * the credential tables — only an administrator sees they moved;
--   * the payroll and payslip tables — only somebody who may run
--     payroll;
--   * everything else — any member of the company, which is already who
--     may read the table.
--
-- `app.live_change_audience` is that classification, in one place, so it
-- can be asserted rather than described.

-- ---------------------------------------------------------------------
-- The feed
-- ---------------------------------------------------------------------
-- No foreign key to `organizations`, deliberately, and the demo
-- teardown is what proved it: deleting a company cascades into its two
-- hundred and seventy-three tables, every one of those deletes fires
-- its trigger, and every one of those notices names a company that is
-- in the act of ceasing to exist. A foreign key turns the whole
-- teardown into one long refusal.
--
-- Nothing is lost by leaving it out. This is a notice board, not a
-- record: a row is read off the socket within a second of being written
-- and is rubbish after that. Notices for a company that has gone are
-- delivered to nobody -- the policy below still asks for membership of
-- an organization that no longer has members -- and the hourly prune
-- takes them.
create table if not exists public.live_changes (
  id bigint generated always as identity primary key,
  org_id uuid not null,
  table_name text not null,
  changed_at timestamptz not null default now()
);

comment on table public.live_changes is
  'Append-only notice that a table changed, so the app can re-read it. '
  'Carries a company and a table name and nothing else, and no foreign '
  'key -- see the header. Pruned hourly by app.run_daily_jobs; nothing '
  'reads it but the realtime socket.';

create index if not exists live_changes_pruning
  on public.live_changes (changed_at);

alter table public.live_changes enable row level security;

-- ---------------------------------------------------------------------
-- Who is told what moved
-- ---------------------------------------------------------------------
create or replace function app.live_change_audience(p_table text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    -- Keys and gateway secrets. That they changed is an administrator's
    -- business.
    when p_table in (
      'einvoice_credentials',
      'org_ocr_credentials',
      'ai_provider_credentials',
      'org_payment_gateways'
    ) then 'admin'
    -- One employee's pay is not the office's, which is the line `0117`
    -- drew and this keeps.
    when p_table in (
      'payslips',
      'payslip_lines',
      'payslip_access_log',
      'payslip_access_requests',
      'payroll_runs',
      'payroll_ytd',
      'payroll_settings',
      'pay_periods',
      'salary_components',
      'employee_salary_components',
      'employee_ytd_opening',
      'employee_tax_reliefs',
      'employee_dependants',
      'employee_documents'
    ) then 'payroll'
    else 'member'
  end;
$$;

comment on function app.live_change_audience(text) is
  'Who may be told that this table changed: admin, payroll, or any '
  'member. Asserted in supabase/tests/live_change_feed.sql.';

-- The policy below calls it, and a policy is evaluated as the role
-- doing the reading. Without this every select on the feed is
-- "permission denied for function live_change_audience", which reads
-- like a bug in the app and is a missing grant.
grant execute on function app.live_change_audience(text) to authenticated;

drop policy if exists live_changes_select on public.live_changes;
create policy live_changes_select on public.live_changes
  for select to authenticated
  using (
    app.is_org_member(org_id)
    and case app.live_change_audience(table_name)
          when 'admin' then app.can_admin(org_id)
          when 'payroll' then app.can_run_payroll(org_id)
          else true
        end
  );

-- No insert, update or delete policy, deliberately. The trigger below
-- is SECURITY DEFINER and is the only writer; a client that could
-- append here could make every other client refetch on command.
revoke all on table public.live_changes from anon, authenticated;
grant select on table public.live_changes to authenticated;

-- ---------------------------------------------------------------------
-- The trigger
--
-- Statement level, over the transition table, so a run that writes four
-- hundred payslip lines appends ONE row and not four hundred. `distinct`
-- matters for the same reason and for a second one: a statement touching
-- two companies' rows should say so once each.
-- ---------------------------------------------------------------------
create or replace function app.note_live_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.live_changes (org_id, table_name)
    select distinct n.org_id, tg_table_name
      from new_rows n where n.org_id is not null;
  elsif tg_op = 'DELETE' then
    insert into public.live_changes (org_id, table_name)
    select distinct o.org_id, tg_table_name
      from old_rows o where o.org_id is not null;
  else
    insert into public.live_changes (org_id, table_name)
    select distinct s.org_id, tg_table_name
      from (
        select org_id from new_rows
        union
        select org_id from old_rows
      ) s
     where s.org_id is not null;
  end if;
  return null;
end;
$$;

-- The organization's own row is the exception `0117` also had to make:
-- it is identified by its primary key, and a trigger reading `org_id`
-- off it would find no such column.
create or replace function app.note_live_change_org()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    -- A deleted company has nobody left to tell, and the hourly prune
    -- takes what its own tables appended on the way out.
    return null;
  end if;
  insert into public.live_changes (org_id, table_name)
  select distinct n.id, 'organizations' from new_rows n;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- Hung on everything that carries an org_id
--
-- Three triggers per table rather than one, because a transition table
-- is declared per operation: an INSERT statement has no OLD TABLE and a
-- DELETE has no NEW TABLE, and a single trigger naming both is refused.
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
begin
  for v_table in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and c.relname <> 'live_changes'
       and exists (
         select 1 from information_schema.columns col
          where col.table_schema = 'public'
            and col.table_name = c.relname
            and col.column_name = 'org_id'
       )
     order by c.relname
  loop
    execute format(
      'drop trigger if exists live_change_insert on public.%I', v_table);
    execute format(
      'create trigger live_change_insert after insert on public.%I '
      'referencing new table as new_rows '
      'for each statement execute function app.note_live_change()',
      v_table);

    execute format(
      'drop trigger if exists live_change_update on public.%I', v_table);
    execute format(
      'create trigger live_change_update after update on public.%I '
      'referencing new table as new_rows old table as old_rows '
      'for each statement execute function app.note_live_change()',
      v_table);

    execute format(
      'drop trigger if exists live_change_delete on public.%I', v_table);
    execute format(
      'create trigger live_change_delete after delete on public.%I '
      'referencing old table as old_rows '
      'for each statement execute function app.note_live_change()',
      v_table);
  end loop;
end $$;

drop trigger if exists live_change_insert on public.organizations;
create trigger live_change_insert after insert on public.organizations
  referencing new table as new_rows
  for each statement execute function app.note_live_change_org();

drop trigger if exists live_change_update on public.organizations;
create trigger live_change_update after update on public.organizations
  referencing new table as new_rows
  for each statement execute function app.note_live_change_org();

-- ---------------------------------------------------------------------
-- Published
--
-- Replica identity stays default. Realtime carries the whole new row on
-- an insert, which is all this table ever sees, and the full-row setting
-- `0117` needed was for deletes it had to apply RLS to.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c on c.oid = pr.prrelid
      join pg_namespace n on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime'
       and n.nspname = 'public'
       and c.relname = 'live_changes'
  ) then
    alter publication supabase_realtime add table public.live_changes;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Throwing the feed away again
--
-- Restated from the built definition, which is how everything else has
-- been added to the nightly pass. Wrapped like the rest: a delete that
-- cannot run must not stop the leave year, the consolidation and the
-- billing behind it.
-- ---------------------------------------------------------------------
create or replace function app.run_daily_jobs(p_on date default current_date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $$
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
end; $$;
