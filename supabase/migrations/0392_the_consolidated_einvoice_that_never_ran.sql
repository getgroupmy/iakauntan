-- =====================================================================
-- iAkauntan :: the consolidated e-Invoice that has never once been
-- raised
--
-- `app.roll_einvoice_consolidation` has been in `0058` since the
-- corporate secretarial commit, and it throws every time it is called:
--
--     and d.status in ('posted', 'partial', 'paid')
--
-- `app.doc_status` has no `paid`. Its members are draft, pending,
-- approved, posted, partial, completed, void, rejected — `completed` is
-- what `app.apply_allocation` writes when a balance reaches nil. So the
-- comparison is an invalid enum literal and the function raises
-- `22P02` before it reads a single row.
--
-- Two things kept that hidden for this long.
--
-- It runs on one day in thirty. `app.run_daily_jobs` calls it only when
-- `extract(day from p_on) = 1`, and every test in this repository calls
-- `run_daily_jobs` with the real current date — so the branch was
-- exercised on whichever day the suite happened to run, which for
-- hundreds of runs was never the first. It surfaced on 1 September 2026
-- and not before.
--
-- And the failure is silent where it matters. `pg_cron` runs the job;
-- nobody reads its output.
--
-- What it costs is not small. Under the LHDN e-Invoice guideline a
-- business must issue a consolidated e-Invoice for the month's sales to
-- buyers who did not ask for one individually, and submit it within
-- seven calendar days after the month ends. This function is the only
-- thing in the system that gathers those sales. It has never gathered
-- any.
--
-- There is a second fault in the same function, found only because
-- fixing the first let execution reach the next line: the insert
-- supplies `due_date`, which a later migration made a generated column.
-- Postgres refuses a non-default value there. Two faults, both fatal,
-- both in a function nothing has successfully run since it was written.
--
-- The third defect is the one worth more than either typo. The loop looks
-- like this:
--
--     begin
--       if app.has_module(o.id, 'pos') then ... end if;
--     exception when others then
--       raise warning 'expire_parked_sales failed for %: %', o.id, sqlerrm;
--     end;
--
--     if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
--       perform app.roll_leave_year(...);
--     end if;
--
--     if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice')
--     then
--       perform app.roll_einvoice_consolidation(...);
--     end if;
--
-- `0375` wrapped the till sweep and wrote the reason in the comment
-- above it — *a shop whose till sweep fails must not stop the leave year
-- and the consolidation for everybody else*. The two steps it names are
-- the two still unwrapped. So the isolation was given to the branches
-- that run daily and withheld from the branches that run once a month,
-- which is exactly the wrong way round: a fault in a branch that runs
-- every day is found the next morning, and a fault in one that runs on
-- the first is found in a year.
--
-- Today it means one organization on the e-Invoice module aborts
-- `run_daily_jobs` for every organization after it in the loop. On the
-- first of January that includes their leave year.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The statuses an invoice can actually be in
--
-- `completed` rather than `paid`, and the same three the rest of the
-- schema uses for "issued and not cancelled": posted, part paid, paid
-- off. A void or rejected invoice is not consolidated, and neither is a
-- draft — nothing has been issued to anybody yet.
-- ---------------------------------------------------------------------
create or replace function app.roll_einvoice_consolidation(
  p_org_id uuid, p_month_start date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_end date := (p_month_start + interval '1 month' - interval '1 day')::date;
  v_id uuid;
  v_count integer;
  v_total numeric;
begin
  if exists (select 1 from public.einvoice_consolidations c
              where c.org_id = p_org_id and c.period_start = p_month_start) then
    return null;
  end if;

  select count(*), coalesce(sum(d.total_amount), 0) into v_count, v_total
    from public.sales_documents d
    left join public.contacts c on c.id = d.contact_id
   where d.org_id = p_org_id
     and d.doc_type = 'invoice'
     and d.status in ('posted', 'partial', 'completed')
     and d.doc_date between p_month_start and v_end
     and not coalesce(d.is_consolidated, false)
     and not exists (select 1 from public.einvoice_documents e
                      where e.source_id = d.id)
     -- A consumer: no TIN to issue an individual e-Invoice against.
     and coalesce(nullif(btrim(c.tin), ''), '') = '';

  if v_count = 0 then return null; end if;

  -- `due_date` is left out on purpose. `0058` supplied it as
  -- `v_end + 7`; a later migration made the column
  -- `generated always as (period_end + 7) stored`, and Postgres refuses
  -- a non-default value in a generated column. That is the *second*
  -- fault in this function, and it is here for the same reason as the
  -- first: nothing has run the function since either was introduced, so
  -- neither has ever been reported. The seven days are unchanged — LHDN
  -- gives seven calendar days after the month end — they are simply
  -- computed by the column that already computes them.
  insert into public.einvoice_consolidations
    (org_id, period_start, period_end, document_count, total_amount,
     status)
  values (p_org_id, p_month_start, v_end, v_count, v_total, 'draft')
  returning id into v_id;

  insert into public.einvoice_consolidation_items
    (org_id, consolidation_id, sales_document_id, amount)
  select p_org_id, v_id, d.id, d.total_amount
    from public.sales_documents d
    left join public.contacts c on c.id = d.contact_id
   where d.org_id = p_org_id
     and d.doc_type = 'invoice'
     and d.status in ('posted', 'partial', 'completed')
     and d.doc_date between p_month_start and v_end
     and not coalesce(d.is_consolidated, false)
     and not exists (select 1 from public.einvoice_documents e
                      where e.source_id = d.id)
     and coalesce(nullif(btrim(c.tin), ''), '') = '';

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- One company's bad month is one company's bad month
--
-- `app.run_daily_jobs` re-issued with the two month-start steps wrapped
-- the way `0375` wrapped the daily ones. Everything else is `0375`'s
-- body unchanged.
--
-- A warning rather than a raise, deliberately and in step with the four
-- handlers already here: the scheduler's job is to get through the list.
-- Anything that stops it stops every organization after the one that
-- broke, and they find out a month later.
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
end; $$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;
revoke all on function app.roll_einvoice_consolidation(uuid, date)
  from public, anon, authenticated;
