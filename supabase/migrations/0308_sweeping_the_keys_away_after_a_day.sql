-- ---------------------------------------------------------------------
-- Sweeping the keys away after a day
--
-- 0307 keeps a claimed idempotency key and its result for 24 hours,
-- which is Rillet's convention and a sensible one: long enough that a
-- client retrying a dropped request finds its answer, short enough that
-- the table does not become a second copy of the ledger.
--
-- The sweep belongs on the daily job rather than on a trigger, because
-- it is housekeeping and nothing waits on it. It is wrapped in its own
-- exception block for the same reason its neighbours are: a table that
-- grows is a nuisance, and it must not be allowed to stop the recurring
-- invoices that run after it.
--
-- The rest of the function is 0252's, carried through unchanged.
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

  -- 0307. A key older than a day is not a retry, it is a new request.
  -- Wrapped like its neighbours: a sweep that cannot run is a table
  -- that grows, and that must not stop the recurring invoices behind it.
  begin
    perform app.sweep_idempotency_keys(now() - interval '24 hours');
  exception when others then
    raise warning 'sweep_idempotency_keys failed: %', sqlerrm;
  end;

  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
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
