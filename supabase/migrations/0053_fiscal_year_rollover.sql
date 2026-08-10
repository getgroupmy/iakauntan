-- =====================================================================
-- iAkauntan :: 0053 fiscal years that roll over
--
-- Three problems, one theme: the ledger had no way to reach the next
-- year, and failed quietly rather than saying so.
--
-- 1. create_gl_entry checked the period status only when a period was
--    found. A date outside every fiscal year posted with a null
--    fiscal_period_id — silently escaping period control, so closing a
--    period could never protect it and year-end had nothing to close.
--    Verified before the fix: an entry dated 2027-01-15 posted happily
--    against an organization whose periods stop at 2026-12-31.
--
-- 2. create_fiscal_year with no start date recomputed a year from the
--    organization's year-end month, which collides with the year already
--    there. It now continues from the last year that exists, so "create
--    the next one" is a single safe action, and overlapping years are
--    refused outright — an overlap would give one date two periods and
--    app.period_for_date would pick between them arbitrarily.
--
-- 3. Closing a period is what makes the guard in (1) mean anything, and
--    there was no callable way to do it. set_fiscal_period_status adds
--    one, admin-only, with `locked` deliberately terminal.
-- =====================================================================

create or replace function public.create_gl_entry(
  p_org_id uuid, p_entry_date date, p_source app.journal_source, p_lines jsonb,
  p_description text default null, p_source_table text default null,
  p_source_id uuid default null, p_reference text default null,
  p_currency character default 'MYR', p_exchange_rate numeric default 1)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_entry_id uuid; v_period_id uuid; v_status text; v_line jsonb;
  v_no integer := 0; v_debit numeric(18,2) := 0; v_credit numeric(18,2) := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post to the ledger' using errcode = '42501';
  end if;

  v_period_id := app.period_for_date(p_org_id, p_entry_date);
  if v_period_id is null then
    raise exception
      'No fiscal period covers %. Create the fiscal year before posting to it.',
      p_entry_date using errcode = '23514';
  end if;

  select status into v_status from public.fiscal_periods where id = v_period_id;
  if v_status <> 'open' then
    raise exception 'Fiscal period for % is %', p_entry_date, v_status using errcode = '23514';
  end if;

  insert into public.gl_entries (
    org_id, entry_no, entry_date, fiscal_period_id, source,
    source_table, source_id, description, reference,
    currency, exchange_rate, status, posted_at, posted_by, created_by
  ) values (
    p_org_id, public.next_document_number(p_org_id, 'journal'),
    p_entry_date, v_period_id, p_source, p_source_table, p_source_id,
    p_description, p_reference, p_currency, p_exchange_rate,
    'posted', now(), auth.uid(), auth.uid()
  ) returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into public.gl_lines (
      org_id, entry_id, line_no, account_id, description, debit, credit,
      currency, exchange_rate, contact_id, item_id, tax_code_id, tax_amount,
      project_code, department_code
    ) values (
      p_org_id, v_entry_id, v_no,
      (v_line ->> 'account_id')::uuid, v_line ->> 'description',
      round(coalesce((v_line ->> 'debit')::numeric, 0), 2),
      round(coalesce((v_line ->> 'credit')::numeric, 0), 2),
      p_currency, p_exchange_rate,
      nullif(v_line ->> 'contact_id', '')::uuid,
      nullif(v_line ->> 'item_id', '')::uuid,
      nullif(v_line ->> 'tax_code_id', '')::uuid,
      round(coalesce((v_line ->> 'tax_amount')::numeric, 0), 2),
      v_line ->> 'project_code', v_line ->> 'department_code');
    v_debit := v_debit + round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_credit := v_credit + round(coalesce((v_line ->> 'credit')::numeric, 0), 2);
  end loop;

  if v_debit <> v_credit then
    raise exception 'Journal does not balance: debits %, credits %', v_debit, v_credit
      using errcode = '23514';
  end if;
  return v_entry_id;
end; $$;


create or replace function public.create_fiscal_year(
  p_org_id uuid, p_start_date date default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org public.organizations; v_start date; v_end date; v_fy_id uuid;
  v_last date; v_p_start date; v_p_end date; i integer;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if not found then raise exception 'Organization % not found', p_org_id; end if;
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select max(end_date) into v_last from public.fiscal_years where org_id = p_org_id;

  if p_start_date is not null then
    v_start := p_start_date;
  elsif v_last is not null then
    v_start := (v_last + interval '1 day')::date;
  else
    v_end := (date_trunc('month', make_date(extract(year from current_date)::int,
                v_org.fiscal_year_end_month, 1))
              + interval '1 month' - interval '1 day')::date;
    if v_org.fiscal_year_end_day < 28 then
      v_end := make_date(extract(year from v_end)::int,
                 v_org.fiscal_year_end_month, v_org.fiscal_year_end_day);
    end if;
    if v_end < current_date then v_end := (v_end + interval '1 year')::date; end if;
    v_start := (v_end - interval '1 year' + interval '1 day')::date;
  end if;

  v_end := (v_start + interval '1 year' - interval '1 day')::date;

  if exists (select 1 from public.fiscal_years f
              where f.org_id = p_org_id
                and f.start_date <= v_end and f.end_date >= v_start) then
    raise exception 'A fiscal year already covers % to %', v_start, v_end
      using errcode = '23505';
  end if;

  insert into public.fiscal_years (org_id, name, start_date, end_date)
  values (p_org_id,
          case when extract(year from v_start) = extract(year from v_end)
               then extract(year from v_start)::text
               else extract(year from v_start)::text || '/' ||
                    extract(year from v_end)::text end,
          v_start, v_end)
  returning id into v_fy_id;

  for i in 0 .. 11 loop
    v_p_start := (v_start + (i || ' months')::interval)::date;
    v_p_end := (v_p_start + interval '1 month' - interval '1 day')::date;
    insert into public.fiscal_periods
      (org_id, fiscal_year_id, period_no, name, start_date, end_date)
    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),
            v_p_start, v_p_end);
  end loop;

  return v_fy_id;
end; $$;


create or replace function public.set_fiscal_period_status(
  p_period_id uuid, p_status text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_period public.fiscal_periods;
begin
  select * into v_period from public.fiscal_periods where id = p_period_id;
  if v_period.id is null then
    raise exception 'Fiscal period not found' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_period.org_id) then
    raise exception 'Only an owner or admin may open or close a period'
      using errcode = '42501';
  end if;
  if p_status not in ('open', 'closed', 'locked') then
    raise exception 'Unknown period status %', p_status using errcode = '22023';
  end if;
  -- Locked is deliberately terminal: it is what year-end sign-off means.
  if v_period.status = 'locked' and p_status <> 'locked' then
    raise exception 'A locked period cannot be reopened' using errcode = '22023';
  end if;

  update public.fiscal_periods set status = p_status where id = p_period_id;
end; $$;

do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;
