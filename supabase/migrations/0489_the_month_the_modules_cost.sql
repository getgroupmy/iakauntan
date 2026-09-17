-- ---------------------------------------------------------------------
-- 0489  The month the modules cost
-- ---------------------------------------------------------------------
-- `platform_modules.monthly_price` has been on screen since 0292 and
-- has never been charged. The only two writers of `platform_invoices`
-- both bill document scanning credit -- a one-off top-up -- and the
-- subscriptions a company holds are billed by nothing at all.
--
-- 0488 made that a promise rather than an omission. Its confirmation
-- says "RM 39.00 a month is added to this company from today", and
-- until now nothing added it. A dialog that says a price and a system
-- that never charges it are not a generous arrangement; they are a
-- product that cannot tell a customer what they owe.
--
-- ### What this bills
--
-- One invoice per company per month, on the first, for the add-ons it
-- held during the month just ended. Core modules are not on it -- they
-- are the product, not an add-on -- and neither are demo tenants,
-- which exist to be looked at.
--
-- **Pro-rated on the first month.** A module switched on on the 20th
-- of a thirty-one day month is charged for twelve days, not
-- thirty-one, because "from today" is what the person agreed to. Every month after that is whole. A module
-- switched off is charged to the day it went off, for the same reason.
--
-- `app.run_daily_jobs` calls it on the first, beside the two month-start
-- steps 0392 already wraps there, so the bill arrives from the same
-- scheduler as everything else rather than from a second one.
--
-- ### What it does not do
--
-- It does not take money. 0292 has the gateways for that and this
-- writes an invoice, which is the honest half: a company can now be
-- told what it owes, which it could not be before. Collecting it is a
-- separate decision and a separate migration.
--
-- ### Mutants
--
-- Run against `supabase/tests/module_subscription.sql`, each named
-- with the assertion that kills it:
--   * core modules billed -- "the product itself is not on the bill";
--   * demo tenants billed -- "a demo company is not invoiced";
--   * the whole month charged for a mid-month start -- "a module
--     switched on on the 20th is charged for twelve days";
--   * a module switched off still charged to the month end -- "and one
--     switched off stops costing that day";
--   * the month billed twice -- "running it again bills nothing new";
--   * a zero total still raising an invoice -- "a company holding no
--     add-ons gets no invoice";
--   * the tax rate ignored -- "the SST on it is the platform's rate";
--   * the timestamps read in the session's time zone -- "switched on
--     after midnight in Kuala Lumpur, it starts that day";
--   * SST charged by an issuer not registered for it -- "and no SST at
--     all when the platform is not registered";
--   * the daily pass not calling it -- "the daily pass on the first
--     raises the bill";
--   * the running total shown to any member -- "a clerk is not shown
--     what the company pays";
--   * only enabled rows counted -- "a module switched off mid-month is
--     still billed for the days it was on";
--   * switching off clearing the dates, as 0488 had it -- the same
--     assertion;
--   * switching on again moving the start date -- "adding a module
--     that is already on does not restart the month".
-- ---------------------------------------------------------------------

-- What a company held, and for how many days of the month.
--
-- Read from `org_modules` rather than from a subscription table this
-- product does not have: `enabled_at` says when it started and
-- `is_enabled`/`expires_at` say whether it is still on, which is
-- everything the arithmetic needs.
create or replace function app.module_days_in_month(
  p_org_id uuid, p_month date)
returns table (module_code text, name text, monthly_price numeric,
               days integer, days_in_month integer, amount numeric)
language sql stable
set search_path = public, app, pg_temp as $$
  with bounds as (
    select date_trunc('month', p_month)::date as first_day,
           (date_trunc('month', p_month) + interval '1 month'
              - interval '1 day')::date as last_day
  ),
  held as (
    select om.module_code, m.name, m.monthly_price,
           -- The day it started counting for this month: the later of
           -- the month's first day and the day it was switched on.
           --
           -- `app.malaysian_day` and not `::date`, which reads the
           -- session's time zone -- UTC on this server. A module
           -- switched on at two in the morning in Kuala Lumpur is
           -- stamped the previous day in UTC, and the customer would be
           -- billed for a day before the one they agreed to. It is one
           -- ringgit and a quarter, and it is the platform's own
           -- invoice being wrong about its own start date.
           greatest(b.first_day,
                    coalesce(app.malaysian_day(om.enabled_at), b.first_day))
             as from_day,
           -- And the day it stopped: the earlier of the month's last
           -- day and the day before it lapsed. A module still on runs
           -- to the month end.
           least(b.last_day,
                 coalesce(app.malaysian_day(om.expires_at) - 1, b.last_day))
             as to_day
      from public.org_modules om
      join public.platform_modules m on m.code = om.module_code
     cross join bounds b
     where om.org_id = p_org_id
       -- Still on, or off with a date on when it went off. Not
       -- `om.is_enabled` alone, which is what a subscription table
       -- would never do: 0488 switches a module off by clearing the
       -- flag, and the row then says nothing about the twenty-five
       -- days it was on before the 26th. A company could hold an
       -- add-on for all but the last day of every month and be billed
       -- for none of them.
       and (om.is_enabled or om.expires_at is not null)
       and m.is_active
       -- The product itself is not an add-on.
       and not m.is_core
       and m.monthly_price > 0
       -- Switched on after this month ended: not this month's bill.
       and coalesce(app.malaysian_day(om.enabled_at), b.first_day)
             <= b.last_day
  )
  select h.module_code, h.name, h.monthly_price,
         (h.to_day - h.from_day + 1)::integer,
         (b.last_day - b.first_day + 1)::integer,
         round(h.monthly_price
               * (h.to_day - h.from_day + 1)
               / (b.last_day - b.first_day + 1), 2)
    from held h cross join bounds b
   where h.to_day >= h.from_day
   order by h.name;
$$;

comment on function app.module_days_in_month(uuid, date) is
  'What a company held in a month and what each add-on costs it, '
  'pro-rated by the days it was actually on. See 0489.';

revoke all on function app.module_days_in_month(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The invoice
-- ---------------------------------------------------------------------
create or replace function app.bill_org_modules(
  p_org_id uuid, p_month date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org      public.organizations;
  v_issuer   jsonb;
  v_prefix   text;
  v_seq      integer;
  v_no       text;
  v_rate     numeric(6, 3) := 0;
  v_sub      numeric;
  v_tax      numeric(18, 2) := 0;
  v_lines    text;
  v_id       uuid;
  v_first    date := date_trunc('month', p_month)::date;
  v_note     text;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if v_org.id is null then
    return null;
  end if;
  -- A demo tenant exists to be looked at, not to be billed.
  if v_org.is_demo then
    return null;
  end if;

  -- Once per company per month. The note carries the period, which is
  -- what makes a second run find the first one rather than write
  -- another.
  v_note := 'modules:' || to_char(v_first, 'YYYY-MM');
  select id into v_id from public.platform_invoices
   where org_id = p_org_id and notes = v_note;
  if v_id is not null then
    return v_id;
  end if;

  select sum(d.amount),
         string_agg(d.name || ' -- ' || d.days || '/' || d.days_in_month
                    || ' days', chr(10) order by d.name)
    into v_sub, v_lines
    from app.module_days_in_month(p_org_id, v_first) d;

  -- Nothing held is not a bill for nothing; it is no bill.
  if coalesce(v_sub, 0) <= 0 then
    return null;
  end if;

  -- Read the same way 0421 reads it, from the same row. There is no
  -- accessor function for this setting; the one this first reached for
  -- does not exist, and a plpgsql body does not resolve its calls until
  -- it runs, so the migration applied and the first invoice would have
  -- been the one to find out.
  select value into v_issuer from public.platform_settings
   where key = 'platform_issuer';
  v_issuer := coalesce(v_issuer, '{}'::jsonb);

  -- SST is charged when the issuer is registered for it, and not
  -- otherwise. A rate left in the settings by a company that has since
  -- deregistered is not a licence to keep charging it, and 0421 already
  -- reads it this way -- two platform invoices for the same month that
  -- disagreed on tax would be the platform's own problem to explain.
  if coalesce((v_issuer ->> 'sst_registered')::boolean, false) then
    v_rate := coalesce((v_issuer ->> 'sst_rate')::numeric, 0);
  end if;
  v_tax := round(v_sub * v_rate / 100, 2);

  -- One number at a time, as 0421 has it: the monthly run and an
  -- administrator's top-up can land in the same second.
  perform pg_advisory_xact_lock(hashtext('platform_invoice_no'));
  v_prefix := coalesce(nullif(v_issuer ->> 'invoice_prefix', ''), 'KH');
  select coalesce(max(substring(i.invoice_no from '[0-9]+$')::integer), 0) + 1
    into v_seq
    from public.platform_invoices i
   where i.invoice_no like v_prefix || '-' || to_char(v_first, 'YYYY') || '-%';
  v_no := format('%s-%s-%s', v_prefix, to_char(v_first, 'YYYY'),
                 lpad(v_seq::text, 4, '0'));

  insert into public.platform_invoices (
    invoice_no, org_id, issue_date, currency,
    issuer_name, issuer_registration_no, issuer_old_registration_no,
    issuer_sst_no, issuer_address,
    bill_to_name, bill_to_registration_no, bill_to_tin, bill_to_address,
    description, subtotal, tax_rate, tax_amount, total_amount, notes)
  values (
    v_no, p_org_id, (v_first + interval '1 month')::date, 'MYR',
    coalesce(v_issuer ->> 'name', 'Kabeer Holdings Sdn Bhd'),
    v_issuer ->> 'registration_no',
    v_issuer ->> 'old_registration_no',
    nullif(v_issuer ->> 'sst_no', ''),
    nullif(v_issuer ->> 'address', ''),
    v_org.name, v_org.registration_no, v_org.tin, v_org.address_line1,
    -- FM, because `to_char(..., 'Month')` blank-pads the name to nine
    -- characters and the invoice would read "Modules for January
    -- 2026" with three spaces in the middle of it.
    'Modules for ' || to_char(v_first, 'FMMonth YYYY') || chr(10) || v_lines,
    v_sub, v_rate, v_tax, v_sub + v_tax, v_note)
  returning id into v_id;

  return v_id;
end $$;

comment on function app.bill_org_modules(uuid, date) is
  'One invoice per company per month for the add-ons it held, '
  'pro-rated by days. Idempotent: a second run for the same month '
  'returns the invoice the first one wrote. See 0489.';

revoke all on function app.bill_org_modules(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Run on the first, for the month that just ended
-- ---------------------------------------------------------------------
create or replace function app.bill_the_month(p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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
end $$;

revoke all on function app.bill_the_month(date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Switching off has to leave a date behind
-- ---------------------------------------------------------------------
-- 0488 writes `enabled_at = null, expires_at = null` when a module is
-- switched off, which loses the only two facts the arithmetic above
-- needs. Restated from the built definition, with three changes and
-- nothing else touched:
--
--   * switching off stamps `expires_at` instead of clearing it, and
--     keeps `enabled_at`, so the part-month is still billable;
--   * switching on a module that is already on keeps the original
--     `enabled_at` rather than moving it to today -- otherwise
--     pressing Add twice on the 28th makes the first twenty-seven days
--     disappear;
--   * switching on one that was off starts it today, which is what the
--     confirmation says.
create or replace function public.set_own_module(
  p_org_id uuid, p_module_code text, p_enabled boolean default true)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_name text;
  v_core boolean;
begin
  -- Committing the company to a monthly charge is an owner's or an
  -- admin's decision, which is the line `can_admin` already draws.
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may change the modules'
      using errcode = '42501';
  end if;

  select m.name, m.is_core into v_name, v_core
    from public.platform_modules m
   where m.code = p_module_code and m.is_active;
  if v_name is null then
    raise exception 'There is no such module for sale' using errcode = 'P0002';
  end if;
  if v_core then
    raise exception '% is part of the product and is always on', v_name
      using errcode = '22023';
  end if;

  insert into public.org_modules
    (org_id, module_code, is_enabled, enabled_at, enabled_by, expires_at,
     notes)
  values (p_org_id, p_module_code, p_enabled,
          case when p_enabled then now() else null end,
          auth.uid(), case when p_enabled then null else now() end,
          'Switched on by the company. See 0488.')
  on conflict (org_id, module_code) do update
    set is_enabled = excluded.is_enabled,
        enabled_at = case
                       when not excluded.is_enabled
                         then public.org_modules.enabled_at
                       when public.org_modules.is_enabled
                        and public.org_modules.enabled_at is not null
                         then public.org_modules.enabled_at
                       else now()
                     end,
        enabled_by = excluded.enabled_by,
        -- A module that had lapsed and is switched on again is on:
        -- leaving the old expiry would grant something that reads as
        -- held and behaves as absent. Switched off, the expiry is the
        -- day the charge stops.
        expires_at = case when excluded.is_enabled then null else now() end,
        notes      = excluded.notes;
end $$;

comment on function public.set_own_module(uuid, text, boolean) is
  'A company switches one of the paid add-ons on or off for itself. '
  'Switching off stamps the day the charge stops rather than clearing '
  'the dates. See 0488, 0489.';

revoke all on function public.set_own_module(uuid, text, boolean)
  from public, anon;
grant execute on function public.set_own_module(uuid, text, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- What the company can see of it
-- ---------------------------------------------------------------------
-- The invoice arrives on the first. Between the first and the next
-- first, an owner who switched something on has agreed to a price and
-- can see nothing at all -- which is the same gap 0488 left, moved a
-- month later. This is the running total: what is on, since when, and
-- what it has cost so far this month.
--
-- `platform_invoices` is already readable by an administrator of the
-- company it names, so the invoices themselves need nothing new. This
-- is only the month in progress, which no row yet exists for.
create or replace function public.module_charges(
  p_org_id uuid, p_month date default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, app.today()))::date;
  v_rows  jsonb;
  v_sub   numeric;
begin
  -- What the company is being charged is an administrator's business,
  -- not every member's. `can_admin` and not `is_org_member`: the price
  -- list is public, what this company pays is not.
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator may see what the company is billed'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'module_code',   d.module_code,
           'name',          d.name,
           'monthly_price', d.monthly_price,
           'days',          d.days,
           'days_in_month', d.days_in_month,
           'amount',        d.amount)
           order by d.name), '[]'::jsonb),
         coalesce(sum(d.amount), 0)
    into v_rows, v_sub
    from app.module_days_in_month(p_org_id, v_month) d;

  return jsonb_build_object(
    'month', v_month, 'lines', v_rows, 'subtotal', v_sub);
end $$;

comment on function public.module_charges(uuid, date) is
  'What the add-ons a company holds have cost it so far this month, '
  'line by line and pro-rated by days. See 0489.';

revoke all on function public.module_charges(uuid, date) from public, anon;
grant execute on function public.module_charges(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- The daily pass calls it
-- ---------------------------------------------------------------------
-- Restated from the built definition rather than from 0392, which is
-- where it was last written: a function reassembled from the migration
-- that reads like its source is a function that silently loses whatever
-- a later migration added. The body below is byte-identical to
-- `pg_get_functiondef` on a database migrated to 0488, plus the one
-- block at the end.
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
end; $$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if has_function_privilege('authenticated', 'app.bill_org_modules(uuid, date)',
                            'execute') then
    raise exception '0489: a tenant can invoice itself';
  end if;
  if position('is_core' in pg_get_functiondef(
       'app.module_days_in_month(uuid, date)'::regprocedure)) = 0 then
    raise exception '0489: the product itself would be billed as an add-on';
  end if;
  if position('is_demo' in pg_get_functiondef(
       'app.bill_org_modules(uuid, date)'::regprocedure)) = 0 then
    raise exception '0489: demo tenants would be invoiced';
  end if;
  if position('expires_at = case when excluded.is_enabled' in
       pg_get_functiondef(
         'public.set_own_module(uuid, text, boolean)'::regprocedure)) = 0 then
    raise exception '0489: switching a module off leaves no date behind';
  end if;
  if not has_function_privilege('authenticated',
       'public.set_own_module(uuid, text, boolean)', 'execute') then
    raise exception '0489: a company can no longer change its own modules';
  end if;
  if not has_function_privilege('authenticated',
       'public.module_charges(uuid, date)', 'execute') then
    raise exception '0489: the company cannot see what it is being charged';
  end if;
  if position('bill_the_month' in pg_get_functiondef(
       'app.run_daily_jobs(date)'::regprocedure)) = 0 then
    raise exception '0489: nothing calls the billing run';
  end if;
  -- The restatement above is the whole function, so anything 0392 and
  -- its predecessors put in it that is missing here was dropped on the
  -- floor. Two of the cheapest to name, one from each end of it.
  if position('roll_einvoice_consolidation' in pg_get_functiondef(
       'app.run_daily_jobs(date)'::regprocedure)) = 0
     or position('sweep_idempotency_keys' in pg_get_functiondef(
       'app.run_daily_jobs(date)'::regprocedure)) = 0 then
    raise exception '0489: the daily pass lost a step it already had';
  end if;
end $do$;
