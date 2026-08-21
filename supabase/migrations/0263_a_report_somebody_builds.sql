-- =====================================================================
-- A report somebody builds, rather than one we wrote
--
-- The module has a dozen reports in it and every one of them answers a
-- question we thought of: the day's takings, where the price went, what
-- the drivers carried. The question a shopkeeper actually has on a
-- Tuesday is "which dishes sell after nine at the Bangsar branch", and
-- nobody is going to ship a migration for it.
--
-- ---------------------------------------------------------------------
-- A saved report is a declaration, not a query
--
-- Nothing a person types reaches the SQL. A report names a source, a
-- list of dimensions and a list of measures, and every one of those
-- names is a key in an allow-list inside `app.pos_report_sql`. A key
-- that is not on the list raises rather than being interpolated, so the
-- worst a malicious report can contain is a word this function does not
-- recognise.
--
-- That is the whole of the safety argument, and it is why this is a
-- builder rather than a SQL box. A SQL box in a multi-tenant database
-- is a way to read somebody else's books.
--
-- ---------------------------------------------------------------------
-- Two sources, because there are two kinds of question
--
-- `sales` is one row per bill and answers "how many, how much, when,
-- who". `lines` is one row per thing sold and answers "what". Every
-- POS question a shop asks is one of those two, and a third source
-- would be a third set of dimensions to keep in step.
--
-- ---------------------------------------------------------------------
-- The period is a word, not a pair of dates
--
-- "This month" saved as the first and last of August is a report that
-- is wrong in September. A saved report stores the word — today, this
-- week, last month — and the dates are worked out when it runs, in the
-- shop's own time. `custom` is the exception and stores the two dates
-- it was given.
-- =====================================================================

do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'pos_report_source') then
    create type app.pos_report_source as enum ('sales', 'lines');
  end if;
end;
$$;

create table if not exists public.pos_reports (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,

  name       text not null check (btrim(name) <> ''),
  source     app.pos_report_source not null default 'sales',

  -- What the rows are cut by, in the order the columns appear. Order is
  -- the point of a report, so this is an array rather than a set.
  dimensions text[] not null default '{}',
  -- What is added up. At least one, or the report is a list of headings.
  measures   text[] not null default '{gross}'
    check (cardinality(measures) > 0),

  -- A word, resolved when it runs. See the header.
  period     text not null default 'this_month',
  starts_on  date,
  ends_on    date,

  -- Narrowed to these, or to all of them when empty.
  outlet_ids  uuid[] not null default '{}',
  channels    text[] not null default '{}',

  sort_by    text,
  sort_desc  boolean not null default true,
  row_limit  integer not null default 200
    check (row_limit between 1 and 5000),

  -- A report somebody built for themselves, or one the company keeps.
  is_shared  boolean not null default true,

  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists pos_reports_org_idx on public.pos_reports (org_id);

comment on table public.pos_reports is
  'A report a shop built: a source, some dimensions, some measures and a period. Every one of those is a key in an allow-list — nothing a person types reaches the SQL.';
comment on column public.pos_reports.period is
  'A word rather than a pair of dates. "This month" saved as the first and last of August is a report that is wrong in September.';

-- ---------------------------------------------------------------------
-- What a period means today
-- ---------------------------------------------------------------------
create or replace function app.pos_report_period(
  p_period text,
  p_from   date default null,
  p_to     date default null)
returns table (from_date date, to_date date)
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  case coalesce(p_period, 'this_month')
    when 'today' then
      from_date := v_today; to_date := v_today;
    when 'yesterday' then
      from_date := v_today - 1; to_date := v_today - 1;
    when 'last_7' then
      from_date := v_today - 6; to_date := v_today;
    when 'last_30' then
      from_date := v_today - 29; to_date := v_today;
    when 'this_week' then
      -- Monday, because a Malaysian trading week starts on one and
      -- `date_trunc('week')` agrees.
      from_date := date_trunc('week', v_today)::date;
      to_date := v_today;
    when 'this_month' then
      from_date := date_trunc('month', v_today)::date; to_date := v_today;
    when 'last_month' then
      from_date := date_trunc('month', v_today - interval '1 month')::date;
      to_date := (date_trunc('month', v_today) - interval '1 day')::date;
    when 'this_year' then
      from_date := date_trunc('year', v_today)::date; to_date := v_today;
    when 'custom' then
      from_date := coalesce(p_from, v_today);
      to_date := coalesce(p_to, v_today);
    else
      raise exception 'That is not a period this report knows: %', p_period
        using errcode = '23514';
  end case;
  return next;
end;
$$;

revoke all on function app.pos_report_period(text, date, date) from public, anon;
grant execute on function app.pos_report_period(text, date, date) to authenticated;

comment on function app.pos_report_period(text, date, date) is
  'The two dates a period word means today, in Asia/Kuala_Lumpur. Resolved when the report runs, never when it was saved.';

-- ---------------------------------------------------------------------
-- The allow-list
-- ---------------------------------------------------------------------
--
-- One function returns the SQL fragment for a key, or raises. This is
-- the whole of the safety argument: a key that is not here is not a
-- fragment, so nothing a person typed can become SQL.
create or replace function app.pos_report_dimension(
  p_source app.pos_report_source,
  p_key    text)
returns text
language plpgsql
immutable
set search_path = public, app, pg_temp
as $$
begin
  -- Shared by both sources: everything hanging off the sale.
  case p_key
    when 'day' then
      return 'to_char((s.completed_at at time zone ''Asia/Kuala_Lumpur'')::date, ''YYYY-MM-DD'')';
    when 'month' then
      return 'to_char(s.completed_at at time zone ''Asia/Kuala_Lumpur'', ''YYYY-MM'')';
    when 'weekday' then
      return 'to_char(s.completed_at at time zone ''Asia/Kuala_Lumpur'', ''Dy'')';
    when 'hour' then
      return 'to_char(s.completed_at at time zone ''Asia/Kuala_Lumpur'', ''HH24'') || '':00''';
    when 'outlet' then
      return 'o.name';
    when 'register' then
      return 'coalesce(r.name, r.code)';
    when 'cashier' then
      return 'coalesce(pr.full_name, ''Not recorded'')';
    when 'channel' then
      return 'replace(coalesce(s.order_channel::text, ''walk in''), ''_'', '' '')';
    when 'customer' then
      return 'coalesce(c.name, s.guest_name, ''Walk-in'')';
    else null;
  end case;

  if p_source = 'sales' then
    case p_key
      when 'table' then return 'coalesce(t.code, ''No table'')';
      else null;
    end case;
  else
    case p_key
      when 'item' then return 'l.description';
      when 'category' then return 'coalesce(ic.name, ''Uncategorised'')';
      else null;
    end case;
  end if;

  raise exception 'That is not something this report can group by: %', p_key
    using errcode = '23514';
end;
$$;

create or replace function app.pos_report_measure(
  p_source app.pos_report_source,
  p_key    text)
returns text
language plpgsql
immutable
set search_path = public, app, pg_temp
as $$
begin
  if p_source = 'sales' then
    case p_key
      when 'bills'    then return 'count(*)::numeric';
      when 'gross'    then return 'round(sum(s.total_amount), 2)';
      when 'net'      then return 'round(sum(s.subtotal), 2)';
      when 'tax'      then return 'round(sum(s.tax_amount), 2)';
      when 'discount' then return 'round(sum(coalesce(s.discount_amount, 0) + coalesce(s.bill_discount, 0) + coalesce(s.promo_discount, 0) + coalesce(s.loyalty_discount, 0)), 2)';
      when 'delivery' then return 'round(sum(coalesce(s.delivery_fee, 0)), 2)';
      when 'covers'   then return 'sum(coalesce(s.covers, 0))::numeric';
      when 'average_bill' then
        return 'round(sum(s.total_amount) / nullif(count(*), 0), 2)';
      else null;
    end case;
  else
    case p_key
      when 'quantity' then return 'round(sum(l.quantity), 3)';
      when 'gross'    then return 'round(sum(l.line_total), 2)';
      when 'net'      then return 'round(sum(l.line_subtotal), 2)';
      when 'tax'      then return 'round(sum(l.tax_amount), 2)';
      when 'discount' then return 'round(sum(coalesce(l.discount_amount, 0)), 2)';
      when 'lines'    then return 'count(*)::numeric';
      else null;
    end case;
  end if;

  raise exception 'That is not something this report can add up: %', p_key
    using errcode = '23514';
end;
$$;

-- The words a person reads at the top of a column. Kept beside the
-- fragments so a new dimension cannot be added without one.
create or replace function app.pos_report_label(p_key text)
returns text
language sql
immutable
set search_path = public, app, pg_temp
as $$
  select case p_key
    when 'day' then 'Day'
    when 'month' then 'Month'
    when 'weekday' then 'Weekday'
    when 'hour' then 'Hour'
    when 'outlet' then 'Outlet'
    when 'register' then 'Till'
    when 'cashier' then 'Served by'
    when 'channel' then 'How it arrived'
    when 'customer' then 'Customer'
    when 'table' then 'Table'
    when 'item' then 'Item'
    when 'category' then 'Category'
    when 'bills' then 'Bills'
    when 'gross' then 'Takings'
    when 'net' then 'Before tax'
    when 'tax' then 'Tax'
    when 'discount' then 'Off the bill'
    when 'delivery' then 'Delivery'
    when 'covers' then 'Covers'
    when 'average_bill' then 'Average bill'
    when 'quantity' then 'Quantity'
    when 'lines' then 'Lines'
    else p_key
  end;
$$;

revoke all on function app.pos_report_dimension(app.pos_report_source, text)
  from public, anon;
revoke all on function app.pos_report_measure(app.pos_report_source, text)
  from public, anon;
grant execute on function app.pos_report_dimension(app.pos_report_source, text)
  to authenticated;
grant execute on function app.pos_report_measure(app.pos_report_source, text)
  to authenticated;
grant execute on function app.pos_report_label(text) to authenticated;

-- ---------------------------------------------------------------------
-- Assembling the query
-- ---------------------------------------------------------------------
--
-- Every fragment comes from the two functions above. The only values
-- that reach the query are bound as parameters — the org, the two dates
-- and the two filter arrays — so the string this builds is made
-- entirely of words this file wrote.
create or replace function app.pos_report_sql(p_report public.pos_reports)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_dims  text := '';
  v_vals  text := '';
  v_group text := '';
  v_order text;
  v_key   text;
  v_i     integer := 0;
  v_from  text;
begin
  foreach v_key in array coalesce(p_report.dimensions, '{}') loop
    v_i := v_i + 1;
    v_dims := v_dims || case when v_i > 1 then ', ' else '' end
      || 'coalesce((' || app.pos_report_dimension(p_report.source, v_key)
      || ')::text, ''—'')';
    v_group := v_group || case when v_i > 1 then ', ' else '' end || v_i::text;
  end loop;
  if v_i = 0 then
    -- A report with no dimensions is one number, which is a perfectly
    -- good report: "what did we take this month".
    v_dims := '''All''';
    v_group := '1';
  end if;

  v_i := 0;
  foreach v_key in array p_report.measures loop
    v_i := v_i + 1;
    v_vals := v_vals || case when v_i > 1 then ', ' else '' end
      || 'coalesce(' || app.pos_report_measure(p_report.source, v_key) || ', 0)';
  end loop;

  -- Sorted by a measure when one is named, else by the first column,
  -- which is what somebody reading a report by day expects.
  if p_report.sort_by is not null
     and p_report.sort_by = any (p_report.measures) then
    v_order := 'order by ' || app.pos_report_measure(p_report.source, p_report.sort_by)
      || case when p_report.sort_desc then ' desc' else ' asc' end;
  else
    v_order := 'order by 1' || case when p_report.sort_desc then ' desc' else ' asc' end;
  end if;

  if p_report.source = 'sales' then
    v_from := '
      from public.pos_sales s
      join public.pos_outlets o on o.id = s.outlet_id
      left join public.pos_registers r on r.id = s.register_id
      left join public.profiles pr on pr.id = s.sold_by
      left join public.contacts c on c.id = s.contact_id
      left join public.pos_tables t on t.id = s.table_id';
  else
    v_from := '
      from public.pos_sale_lines l
      join public.pos_sales s on s.id = l.sale_id
      join public.pos_outlets o on o.id = s.outlet_id
      left join public.pos_registers r on r.id = s.register_id
      left join public.profiles pr on pr.id = s.sold_by
      left join public.contacts c on c.id = s.contact_id
      left join public.items i on i.id = l.item_id
      left join public.item_categories ic on ic.id = i.category_id';
  end if;

  return
    'select array[' || v_dims || ']::text[], array[' || v_vals || ']::numeric[]'
    || v_from
    || '
     where s.org_id = $1
       and s.status = ''completed''
       and (s.completed_at at time zone ''Asia/Kuala_Lumpur'')::date
             between $2 and $3
       and ($4 = ''{}''::uuid[] or s.outlet_id = any ($4))
       and ($5 = ''{}''::text[] or s.order_channel::text = any ($5))
     group by ' || v_group || ' ' || v_order || ' limit $6';
end;
$$;

revoke all on function app.pos_report_sql(public.pos_reports) from public, anon;

comment on function app.pos_report_sql(public.pos_reports) is
  'Assembles one report''s query out of allow-listed fragments. The only values that reach it are bound parameters; every word is one this file wrote.';

-- ---------------------------------------------------------------------
-- Running it
-- ---------------------------------------------------------------------
create or replace function public.run_pos_report(
  p_report uuid,
  p_from   date default null,
  p_to     date default null)
returns table (dims text[], vals numeric[])
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rep public.pos_reports;
  v_p   record;
begin
  select * into v_rep from public.pos_reports where id = p_report;
  if v_rep.id is null then
    raise exception 'No such report.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_rep.org_id, 'pos') then
    raise exception 'not permitted to read this shop' using errcode = '42501';
  end if;
  -- A report somebody built for themselves stays theirs. Sharing it is
  -- a decision, and an unshared one is not readable by the rest of the
  -- company even though the numbers in it would be.
  if not v_rep.is_shared and v_rep.created_by is distinct from auth.uid() then
    raise exception 'That report belongs to somebody else.'
      using errcode = '42501';
  end if;

  -- The dates the caller passed win only for a custom period; a report
  -- saved as "last month" means last month whoever opens it.
  select * into v_p from app.pos_report_period(
    v_rep.period,
    coalesce(p_from, v_rep.starts_on),
    coalesce(p_to, v_rep.ends_on));

  return query execute app.pos_report_sql(v_rep)
    using v_rep.org_id, v_p.from_date, v_p.to_date,
          v_rep.outlet_ids, v_rep.channels, v_rep.row_limit;
end;
$$;

grant execute on function public.run_pos_report(uuid, date, date) to authenticated;

comment on function public.run_pos_report(uuid, date, date) is
  'Runs a saved report and returns one row per group: the dimension values as text, the measures as numbers, both in the order the report declared.';

-- ---------------------------------------------------------------------
-- What its columns are called, and what it is asking
-- ---------------------------------------------------------------------
create or replace function public.pos_report_headers(p_report uuid)
returns table (
  name        text,
  source      app.pos_report_source,
  dim_labels  text[],
  val_labels  text[],
  from_date   date,
  to_date     date)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rep public.pos_reports;
  v_p   record;
begin
  select * into v_rep from public.pos_reports where id = p_report;
  if v_rep.id is null then
    raise exception 'No such report.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_rep.org_id, 'pos') then
    raise exception 'not permitted to read this shop' using errcode = '42501';
  end if;

  select * into v_p from app.pos_report_period(
    v_rep.period, v_rep.starts_on, v_rep.ends_on);

  name := v_rep.name;
  source := v_rep.source;
  dim_labels := case
    when cardinality(v_rep.dimensions) = 0 then array['Everything']
    else (select array_agg(app.pos_report_label(d) order by i)
            from unnest(v_rep.dimensions) with ordinality u(d, i))
  end;
  val_labels := (select array_agg(app.pos_report_label(m) order by i)
                   from unnest(v_rep.measures) with ordinality u(m, i));
  from_date := v_p.from_date;
  to_date := v_p.to_date;
  return next;
end;
$$;

grant execute on function public.pos_report_headers(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What can be asked at all
-- ---------------------------------------------------------------------
--
-- The screen offers exactly what the allow-list accepts, from the same
-- place, so a dimension can never appear in the picker without the SQL
-- knowing it.
create or replace function public.pos_report_fields(
  p_source app.pos_report_source default 'sales')
returns table (kind text, key text, label text)
language sql
stable
set search_path = public, app, pg_temp
as $$
  select 'dimension', k,  app.pos_report_label(k)
    from unnest(case when p_source = 'sales'
                then array['day','month','weekday','hour','outlet','register',
                           'cashier','channel','customer','table']
                else array['day','month','weekday','hour','outlet','register',
                           'cashier','channel','customer','item','category']
                end) k
  union all
  select 'measure', k, app.pos_report_label(k)
    from unnest(case when p_source = 'sales'
                then array['bills','gross','net','tax','discount','delivery',
                           'covers','average_bill']
                else array['quantity','gross','net','tax','discount','lines']
                end) k;
$$;

grant execute on function public.pos_report_fields(app.pos_report_source)
  to authenticated;

comment on function public.pos_report_fields(app.pos_report_source) is
  'What this source can be cut by and what it can add up. The picker and the SQL read the same list, so a column can never be offered that the query does not know.';

-- ---------------------------------------------------------------------
-- Keeping the reports
-- ---------------------------------------------------------------------
--
-- The keys are checked here as well as when the report runs, so a
-- report that cannot run cannot be saved. Finding out at save time is
-- the difference between a typo and a broken report somebody relies on.
create or replace function public.upsert_pos_report(
  p_org        uuid,
  p_name       text,
  p_source     app.pos_report_source default 'sales',
  p_dimensions text[] default '{}',
  p_measures   text[] default '{gross}',
  p_period     text default 'this_month',
  p_from       date default null,
  p_to         date default null,
  p_outlets    uuid[] default '{}',
  p_channels   text[] default '{}',
  p_sort_by    text default null,
  p_sort_desc  boolean default true,
  p_limit      integer default 200,
  p_shared     boolean default true,
  p_id         uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_key text;
  v_id  uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to build reports for this shop'
      using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A report needs a name somebody will recognise.'
      using errcode = '23514';
  end if;
  if coalesce(cardinality(p_measures), 0) = 0 then
    raise exception
      'A report with nothing added up is a list of headings.'
      using errcode = '23514';
  end if;

  -- Every key, through the same functions the query uses. A key that
  -- does not resolve raises there and raises here.
  foreach v_key in array coalesce(p_dimensions, '{}') loop
    perform app.pos_report_dimension(p_source, v_key);
  end loop;
  foreach v_key in array p_measures loop
    perform app.pos_report_measure(p_source, v_key);
  end loop;
  perform app.pos_report_period(p_period, p_from, p_to);

  if p_id is null then
    insert into public.pos_reports (
      org_id, name, source, dimensions, measures, period, starts_on, ends_on,
      outlet_ids, channels, sort_by, sort_desc, row_limit, is_shared, created_by)
    values (
      p_org, btrim(p_name), p_source, coalesce(p_dimensions, '{}'), p_measures,
      p_period, p_from, p_to, coalesce(p_outlets, '{}'),
      coalesce(p_channels, '{}'), p_sort_by, coalesce(p_sort_desc, true),
      coalesce(p_limit, 200), coalesce(p_shared, true), auth.uid())
    returning id into v_id;
  else
    update public.pos_reports r
       set name = btrim(p_name),
           source = p_source,
           dimensions = coalesce(p_dimensions, '{}'),
           measures = p_measures,
           period = p_period,
           starts_on = p_from,
           ends_on = p_to,
           outlet_ids = coalesce(p_outlets, '{}'),
           channels = coalesce(p_channels, '{}'),
           sort_by = p_sort_by,
           sort_desc = coalesce(p_sort_desc, true),
           row_limit = coalesce(p_limit, 200),
           is_shared = coalesce(p_shared, true),
           updated_at = now()
     where r.id = p_id and r.org_id = p_org
    returning r.id into v_id;
    if v_id is null then
      raise exception 'No such report.' using errcode = 'P0002';
    end if;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_report(
  uuid, text, app.pos_report_source, text[], text[], text, date, date,
  uuid[], text[], text, boolean, integer, boolean, uuid) from public, anon;
grant execute on function public.upsert_pos_report(
  uuid, text, app.pos_report_source, text[], text[], text, date, date,
  uuid[], text[], text, boolean, integer, boolean, uuid) to authenticated;

comment on function public.upsert_pos_report(
  uuid, text, app.pos_report_source, text[], text[], text, date, date,
  uuid[], text[], text, boolean, integer, boolean, uuid) is
  'Saves a built report, checking every key through the same allow-list the query uses — so a report that cannot run cannot be saved.';

create or replace function public.delete_pos_report(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rep public.pos_reports;
begin
  select * into v_rep from public.pos_reports where id = p_id;
  if v_rep.id is null then
    raise exception 'No such report.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_rep.org_id, 'pos') then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  -- Deleted rather than retired, and this is the one place in the
  -- module where that is right: a report is a question, not a record of
  -- anything that happened. Nothing points at it and no history is lost.
  delete from public.pos_reports where id = p_id;
end;
$$;

revoke all on function public.delete_pos_report(uuid) from public, anon;
grant execute on function public.delete_pos_report(uuid) to authenticated;

create or replace function public.pos_reports_list(p_org uuid)
returns table (
  id         uuid,
  name       text,
  source     app.pos_report_source,
  dimensions text[],
  measures   text[],
  period     text,
  starts_on  date,
  ends_on    date,
  outlet_ids uuid[],
  channels   text[],
  sort_by    text,
  sort_desc  boolean,
  row_limit  integer,
  is_shared  boolean,
  mine       boolean,
  -- The same words the column headings use, so a list of reports reads
  -- in the language the picker offered rather than in the keys the
  -- query stores.
  dim_labels text[],
  val_labels text[])
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select r.id, r.name, r.source, r.dimensions, r.measures, r.period,
         r.starts_on, r.ends_on, r.outlet_ids, r.channels, r.sort_by,
         r.sort_desc, r.row_limit, r.is_shared,
         r.created_by is not distinct from auth.uid(),
         (select coalesce(array_agg(app.pos_report_label(d) order by i), '{}')
            from unnest(r.dimensions) with ordinality u(d, i)),
         (select coalesce(array_agg(app.pos_report_label(m) order by i), '{}')
            from unnest(r.measures) with ordinality u(m, i))
    from public.pos_reports r
   where r.org_id = p_org
     and app.can_read_module(p_org, 'pos')
     and (r.is_shared or r.created_by is not distinct from auth.uid())
   order by r.name;
$$;

grant execute on function public.pos_reports_list(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_reports enable row level security;

create policy pos_reports_read on public.pos_reports for select
  to authenticated using (
    app.can_read_module(org_id, 'pos')
    and (is_shared or created_by is not distinct from auth.uid()));

-- No write policy: every key is checked through the allow-list on the
-- way in, and a client that could insert here directly could save a
-- report naming a column the query would then refuse.
grant select on public.pos_reports to authenticated;
