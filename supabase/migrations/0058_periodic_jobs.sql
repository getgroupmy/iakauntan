-- =====================================================================
-- iAkauntan :: 0058 the periodic work nothing was driving
--
-- Three things had schema and no runner at all, and pg_cron was not even
-- installed: leave carry-forward, recurring journals, and the e-Invoice
-- B2C consolidation deadline.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Leave: open next year's balances and carry what may be carried
-- ---------------------------------------------------------------------
create or replace function app.leave_entitlement(
  p_leave_type public.leave_types, p_hire_date date, p_year integer)
returns numeric
language sql stable
set search_path = public, pg_temp as $$
  select case
    when not p_leave_type.scales_with_service then p_leave_type.default_days
    else coalesce(
      (select b.days from public.leave_entitlement_bands b
        where b.leave_type_id = p_leave_type.id
          and b.service_years_from <= greatest(
                p_year - extract(year from p_hire_date)::integer, 0)
          and (b.service_years_to is null or b.service_years_to >= greatest(
                p_year - extract(year from p_hire_date)::integer, 0))
        order by b.service_years_from desc limit 1),
      p_leave_type.default_days)
  end;
$$;

create or replace function app.roll_leave_year(p_org_id uuid, p_year integer)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_type public.leave_types;
  v_emp  record;
  v_prev record;
  v_carry numeric;
  v_n integer := 0;
begin
  for v_type in
    select * from public.leave_types
     where org_id = p_org_id and is_active
  loop
    for v_emp in
      select e.id, e.hire_date from public.employees e
       where e.org_id = p_org_id
         and e.employment_status not in ('resigned', 'terminated')
    loop
      select * into v_prev from public.leave_balances b
       where b.employee_id = v_emp.id and b.leave_type_id = v_type.id
         and b.leave_year = p_year - 1;

      -- What is left over, capped by the type's own limit. A type with
      -- no limit set carries nothing: silently rolling everything
      -- forward is how leave liability grows unnoticed.
      v_carry := least(
        greatest(coalesce(v_prev.entitled_days, 0)
               + coalesce(v_prev.carried_forward, 0)
               + coalesce(v_prev.adjustment_days, 0)
               - coalesce(v_prev.taken_days, 0), 0),
        coalesce(v_type.max_carry_forward, 0));

      insert into public.leave_balances
        (org_id, employee_id, leave_type_id, leave_year,
         entitled_days, carried_forward)
      values (p_org_id, v_emp.id, v_type.id, p_year,
              app.leave_entitlement(v_type, v_emp.hire_date, p_year), v_carry)
      on conflict (employee_id, leave_type_id, leave_year) do nothing;

      if found then v_n := v_n + 1; end if;
    end loop;
  end loop;
  return v_n;
end; $$;

-- ---------------------------------------------------------------------
-- Recurring journals
-- ---------------------------------------------------------------------
create or replace function app.advance_schedule(
  p_from date, p_frequency text, p_interval integer)
returns date
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select (p_from + (greatest(coalesce(p_interval, 1), 1) || ' ' ||
    case p_frequency
      when 'daily' then 'days' when 'weekly' then 'weeks'
      when 'monthly' then 'months' when 'quarterly' then 'quarters'
      when 'yearly' then 'years' else 'months' end)::interval)::date;
$$;

-- A journal that cannot post must not stop the others, but it must not
-- fail silently either: without somewhere to put the reason, the run
-- returns a smaller number and nobody knows why the rent stopped
-- posting.
alter table public.recurring_journals
  add column if not exists last_error text,
  add column if not exists last_error_at timestamptz;

create or replace function app.run_recurring_journals(p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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
               r.next_run_date, r.frequency, r.interval_count),
             last_error = null,
             last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      -- next_run_date is left alone, so it is retried once whatever is
      -- in the way — a closed period, a missing fiscal year — is cleared.
      update public.recurring_journals
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
      raise warning 'recurring journal % (%) skipped: %', r.name, r.id, sqlerrm;
    end;
  end loop;
  return v_n;
end; $$;

-- ---------------------------------------------------------------------
-- The B2C consolidated e-Invoice
--
-- LHDN allows receipts to consumers to be reported as one consolidated
-- invoice, due within seven days of the month end. This gathers the
-- month and starts the clock; submitting it is still the edge
-- function's job, which needs credentials a cron job does not hold.
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
     and d.status in ('posted', 'partial', 'paid')
     and d.doc_date between p_month_start and v_end
     and not coalesce(d.is_consolidated, false)
     and not exists (select 1 from public.einvoice_documents e
                      where e.source_id = d.id)
     -- A consumer: no TIN to issue an individual e-Invoice against.
     and coalesce(nullif(btrim(c.tin), ''), '') = '';

  if v_count = 0 then return null; end if;

  insert into public.einvoice_consolidations
    (org_id, period_start, period_end, document_count, total_amount,
     status, due_date)
  values (p_org_id, p_month_start, v_end, v_count, v_total,
          'draft', v_end + 7)
  returning id into v_id;

  insert into public.einvoice_consolidation_items
    (org_id, consolidation_id, sales_document_id, amount)
  select p_org_id, v_id, d.id, d.total_amount
    from public.sales_documents d
    left join public.contacts c on c.id = d.contact_id
   where d.org_id = p_org_id
     and d.doc_type = 'invoice'
     and d.status in ('posted', 'partial', 'paid')
     and d.doc_date between p_month_start and v_end
     and not coalesce(d.is_consolidated, false)
     and not exists (select 1 from public.einvoice_documents e
                      where e.source_id = d.id)
     and coalesce(nullif(btrim(c.tin), ''), '') = '';

  return v_id;
end; $$;

-- ---------------------------------------------------------------------
-- What the scheduler calls
-- ---------------------------------------------------------------------
create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare o record;
begin
  perform app.run_recurring_journals(p_on);

  for o in select id from public.organizations where coalesce(status, 'active') = 'active'
  loop
    -- New year: open the balances before anybody tries to book leave
    -- against a year that does not exist.
    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    -- The consolidation is due seven days after the month ends, so it
    -- is gathered on the first of the following month.
    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end; $$;

-- These are the scheduler's, not the API's.
revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;
revoke all on function app.roll_leave_year(uuid, integer) from public, anon;
revoke all on function app.run_recurring_journals(date) from public, anon;
revoke all on function app.roll_einvoice_consolidation(uuid, date) from public, anon;
grant execute on function app.run_recurring_journals(date) to service_role;
