-- =====================================================================
-- iAkauntan :: 0812 a leave balance is adjusted with a reason
--
-- `leave_balances` holds each employee's year of each kind of leave:
-- entitled, carried forward, adjustment, taken and pending days.
-- `submit_leave_request` refuses leave beyond what is left; it and
-- `decide_leave_request` keep the pending and taken counters;
-- `roll_leave_year` and `expire_carried_leave` set the entitlement and
-- the carry-forward. `adjustment_days` has been in the balance
-- arithmetic since `0037` and nothing has ever written it, so the only
-- way HR could adjust a balance was to write the table -- through
-- `leave_balances_write`, an `ALL` policy asking `app.can_manage_hr`,
-- which let every other column be written the same way.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: eight days entitled and all eight taken; a ninth
-- refused -- "Only 0.00 day(s) of Annual leave remain". `taken_days`
-- set back to nought by hand, and eight more filed and approved:
-- sixteen paid days on an entitlement of eight, and a balance that
-- says eight were taken.
--
-- Answered "a function with a reason". `adjust_leave_balance` adds a
-- number of days, more or fewer, to a balance's `adjustment_days` --
-- HR only, a reason required -- and keeps who, when, how many and why
-- in `leave_balance_adjustments`, which clients read and do not write.
-- And `leave_balances` becomes read-only to clients, as `0804` and
-- `0806` to `0811` made their tables: the grants are revoked and the
-- write policy dropped. Reading stays, by `leave_balances_select`.
--
-- Production held twelve balances, none adjusted, and no leave request,
-- on 11 October.
-- =====================================================================

create table public.leave_balance_adjustments (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations (id) on delete cascade,
  employee_id    uuid not null,
  leave_type_id  uuid not null,
  leave_year     integer not null,
  days           numeric(6, 2) not null check (days <> 0),
  reason         text not null check (btrim(reason) <> ''),
  adjusted_by    uuid references auth.users (id),
  created_at     timestamptz not null default now(),
  constraint leave_balance_adjustments_employee_same_org
    foreign key (org_id, employee_id) references public.employees (org_id, id)
    on delete cascade,
  constraint leave_balance_adjustments_leave_type_same_org
    foreign key (org_id, leave_type_id) references public.leave_types (org_id, id)
    on delete cascade
);

create index on public.leave_balance_adjustments (employee_id, leave_type_id, leave_year);

alter table public.leave_balance_adjustments enable row level security;

-- Who may read a balance may read how it was adjusted.
create policy leave_balance_adjustments_select on public.leave_balance_adjustments
  for select to authenticated
  using (app.can_manage_hr(org_id)
         or employee_id = app.my_employee_id(org_id)
         or app.manages_employee(employee_id));

revoke all on public.leave_balance_adjustments from public, anon, authenticated;
grant select on public.leave_balance_adjustments to authenticated;

-- On the realtime feed, as every table with an `org_id` is
-- (`live_change_feed.sql`, which caught it): a balance screen open
-- while HR adjusts it should show why without being reloaded.
create trigger live_change_insert after insert on public.leave_balance_adjustments
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.leave_balance_adjustments
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.leave_balance_adjustments
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

comment on table public.leave_balance_adjustments is
  'Each adjustment HR has made to a leave balance: how many days, more '
  'or fewer, who made it, when and why. WRITTEN ONLY BY FUNCTION -- '
  'adjust_leave_balance. 0812.';

create or replace function public.adjust_leave_balance(
  p_employee_id   uuid,
  p_leave_type_id uuid,
  p_leave_year    integer,
  p_days          numeric,
  p_reason        text)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org  uuid;
  v_days numeric(6, 2) := round(coalesce(p_days, 0), 2);
  v_left numeric;
begin
  select org_id into v_org from public.employees where id = p_employee_id;
  if v_org is null then
    raise exception 'No such employee.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_org) then
    raise exception 'Only HR may adjust a leave balance.'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.leave_types t
                  where t.id = p_leave_type_id and t.org_id = v_org) then
    raise exception 'That kind of leave is not one of this company''s.'
      using errcode = '23503';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception
      'Say why the balance is being adjusted. It goes on the record beside '
      'the change, where the employee will see it.'
      using errcode = '23514';
  end if;
  if v_days = 0 then
    raise exception 'An adjustment of no days adjusts nothing.'
      using errcode = '23514';
  end if;

  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, adjustment_days)
  values (v_org, p_employee_id, p_leave_type_id, p_leave_year, v_days)
  on conflict (employee_id, leave_type_id, leave_year) do update
     set adjustment_days = public.leave_balances.adjustment_days + excluded.adjustment_days,
         updated_at = now();

  insert into public.leave_balance_adjustments
    (org_id, employee_id, leave_type_id, leave_year, days, reason, adjusted_by)
  values (v_org, p_employee_id, p_leave_type_id, p_leave_year, v_days,
          btrim(p_reason), auth.uid());

  select coalesce(b.entitled_days, 0) + coalesce(b.carried_forward, 0)
         + coalesce(b.adjustment_days, 0) - coalesce(b.taken_days, 0)
         - coalesce(b.pending_days, 0)
    into v_left
    from public.leave_balances b
   where b.employee_id = p_employee_id
     and b.leave_type_id = p_leave_type_id
     and b.leave_year = p_leave_year;

  return v_left;
end $$;

revoke all on function public.adjust_leave_balance(uuid, uuid, integer, numeric, text)
  from public, anon;
grant execute on function public.adjust_leave_balance(uuid, uuid, integer, numeric, text)
  to authenticated, service_role;

comment on function public.adjust_leave_balance(uuid, uuid, integer, numeric, text) is
  'Adds days, more or fewer, to an employee''s leave balance for a year, '
  'and records who did it and why in leave_balance_adjustments. HR only; '
  'a reason is required. Returns the days left. 0812.';

revoke insert, update, delete on public.leave_balances from authenticated, anon;
drop policy if exists leave_balances_write on public.leave_balances;

comment on table public.leave_balances is
  'Each employee''s year of each kind of leave. WRITTEN ONLY BY FUNCTION '
  '-- 0812 revoked insert, update and delete from clients and dropped the '
  'write policy: the leave year roll and carry-forward expiry set the '
  'entitlement, a request and its decision hold and take days, and HR '
  'adjusts a balance through adjust_leave_balance, which records why.';
