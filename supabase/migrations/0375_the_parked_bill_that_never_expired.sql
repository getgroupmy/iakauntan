-- =====================================================================
-- iAkauntan :: 0375 the parked bill that never expired
--
-- `pos_settings.park_expiry_hours` has been a column since `0206`, with
-- a comment saying exactly what it is for — "how long a parked sale
-- survives before it is somebody's problem" — a check constraint holding
-- it between 1 and 720, and a default of 24. Nothing has ever read it.
--
-- So a bill parked and forgotten stays parked. It is not merely clutter:
-- `0206`'s shift close counts parked sales and refuses, and `0361`'s
-- `begin_pos_count` refuses for the same reason. A bill somebody rang up
-- three days ago and walked away from stops the cashier counting their
-- own drawer tonight, and the way out is to void it — which needs the
-- `pos_void` grant, which the cashier does not have. They ring a
-- manager, at closing time, about a bill nobody remembers.
--
-- ---------------------------------------------------------------------
-- What may be cleared, and what may not
--
-- Only a bill nothing has happened to. Specifically:
--
--   * nothing tendered — a part-paid bill is somebody's money, and
--     clearing it loses the record of a payment that was taken;
--   * nothing sent to the kitchen — a line that became food is a real
--     cost, and `0246` made writing one off a manager's decision on
--     purpose;
--   * older than the shop's own `park_expiry_hours`.
--
-- Which leaves exactly the case the setting was written for: keystrokes.
-- Somebody opened a basket, scanned two things, and walked away. The
-- default of 24 hours means nothing a waiter is currently holding is
-- ever in scope.
--
-- The reason recorded is `other` with a note that says what happened and
-- how old the bill was. Not `customer_cancelled`: nobody cancelled
-- anything, and a void reason report is only worth reading if the
-- reasons are true. `pos_void_summary` groups by reason, and one honest
-- "cleared automatically" line is worth more than a hundred false
-- cancellations.
--
-- `voided_by` is left null, which is the truthful answer — no person did
-- this — and the note carries the explanation a human would have given.
--
-- ---------------------------------------------------------------------
-- Where it runs
--
-- Inside `run_daily_jobs`, per organization, wrapped so a failure in one
-- shop does not stop the rest of the nightly work. Hourly would match
-- the setting's unit more closely, and would be wrong: this is a sweep
-- that voids somebody's data, and a nightly cadence means a bill written
-- off at 2am was already stale when the shop shut.
-- =====================================================================

create or replace function app.expire_parked_sales(p_org uuid)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_hours integer;
  v_n     integer := 0;
  r       record;
begin
  select coalesce(s.park_expiry_hours, 24) into v_hours
    from public.pos_settings s where s.org_id = p_org;
  -- A shop with no POS settings row has no till to sweep.
  --
  -- Belt and braces, and the mutation run proved it: with this removed
  -- `make_interval(hours => null)` is null, `created_at < null` is null,
  -- and the loop finds nothing anyway. It stays because arriving at the
  -- right answer through three-valued logic is not the same as saying
  -- it, and the next person to change that query should not have to
  -- work out that a null interval was load-bearing.
  if v_hours is null then
    return 0;
  end if;

  for r in
    select s.id, s.sale_no, s.created_at
      from public.pos_sales s
     where s.org_id = p_org
       and s.status = 'parked'
       and s.created_at < now() - make_interval(hours => v_hours)
       -- Somebody's money.
       and not exists (select 1 from public.pos_tenders t
                        where t.sale_id = s.id)
       -- Something that became food.
       and not exists (select 1 from public.pos_sale_lines l
                        where l.sale_id = s.id
                          and l.sent_to_kitchen_at is not null)
  loop
    update public.pos_sales s set
      status      = 'voided',
      voided_at   = now(),
      void_reason = 'other',
      void_note   = format(
        'Cleared automatically: parked %s hours with nothing tendered and '
        'nothing sent to the kitchen.',
        floor(extract(epoch from (now() - r.created_at)) / 3600)::integer),
      -- Null on purpose. No person did this, and putting a name on it
      -- would make the audit trail say somebody decided.
      voided_by   = null,
      table_id    = null
    where s.id = r.id;
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

revoke all on function app.expire_parked_sales(uuid)
  from public, anon, authenticated;

comment on function app.expire_parked_sales(uuid) is
  'Voids parked bills older than the shop''s park_expiry_hours that '
  'nothing has happened to — nothing tendered, nothing cooked. A '
  'forgotten basket otherwise blocks begin_pos_count and the shift '
  'close, and clearing it needs a grant the cashier does not have.';

-- ---------------------------------------------------------------------
-- And the nightly run drives it
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
