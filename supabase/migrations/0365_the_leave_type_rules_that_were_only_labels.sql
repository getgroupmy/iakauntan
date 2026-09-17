-- =====================================================================
-- iAkauntan :: 0365 the leave type's rules, which were only labels
--
-- `leave_types` carries `allow_half_day` and
-- `carry_forward_expiry_months`. Both have existed since `0027` and
-- neither has ever been read.
--
-- ---------------------------------------------------------------------
-- Half a day
--
-- `submit_leave_request` takes `p_is_half_day` and writes it straight
-- onto the row. It already reads the leave type — it needs the name for
-- its refusal message — and never looks at this column, so a company
-- that says its unpaid leave is whole days only gets half days anyway.
-- Nothing refuses and nothing warns; the balance simply moves by 0.5.
--
-- ---------------------------------------------------------------------
-- Leave carried into a year it was never used in
--
-- The second is the one with a figure attached. `roll_leave_year` moves
-- what is left over into the new year, capped by the type's
-- `max_carry_forward`, and `0058` says exactly why the cap is there:
-- "silently rolling everything forward is how leave liability grows
-- unnoticed". The cap stops the roll being unbounded in one year. It
-- does nothing about the next one, and nothing about days that were
-- meant to lapse in March.
--
-- So a company with "carry five days, use them by the end of March"
-- carried five days and kept them, and its leave liability — a real
-- number in the accounts — was overstated by every unused carried day
-- of every employee, indefinitely.
--
-- ---------------------------------------------------------------------
-- Which days were used, since the balance does not say
--
-- `leave_balances` has one `taken_days`, not one per source, so
-- "were those three days the carried ones or this year's?" cannot be
-- answered from the row. The convention that answers it is the ordinary
-- one and the one that favours the employee: carried days go first,
-- because they are the ones with an expiry on them.
--
-- Which makes the arithmetic exactly `least(taken_days,
-- carried_forward)` — what survives expiry is what was actually used
-- out of the carry, and the rest lapses. Idempotent by construction: a
-- second run finds `carried_forward` already at or below `taken_days`
-- and changes nothing.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Half a day, where the type allows one
-- ---------------------------------------------------------------------
create or replace function app.enforce_half_day_rule()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_type public.leave_types;
begin
  if not coalesce(new.is_half_day, false) then
    return new;
  end if;

  select * into v_type from public.leave_types where id = new.leave_type_id;
  if v_type.id is not null and not coalesce(v_type.allow_half_day, true) then
    raise exception
      '% is taken in whole days. Ask for the day, or for a different '
      'kind of leave.', v_type.name
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists enforce_half_day_rule on public.leave_requests;
create trigger enforce_half_day_rule
  before insert or update on public.leave_requests
  for each row execute function app.enforce_half_day_rule();

revoke all on function app.enforce_half_day_rule()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- And the carried days that were meant to lapse
-- ---------------------------------------------------------------------
create or replace function app.expire_carried_leave(
  p_org uuid, p_on date default current_date)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
end $$;

revoke all on function app.expire_carried_leave(uuid, date)
  from public, anon, authenticated;

comment on function app.expire_carried_leave(uuid, date) is
  'Lapses carried-forward leave that was not used within the type''s '
  'carry_forward_expiry_months. Carried days are treated as used first, '
  'which is the ordinary convention and the one that favours the '
  'employee, so what survives is least(taken_days, carried_forward).';

-- ---------------------------------------------------------------------
-- Driven from the nightly run
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

    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end;
$$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;
