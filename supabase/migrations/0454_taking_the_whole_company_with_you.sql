-- ---------------------------------------------------------------------
-- 0454  Taking the whole company with you
-- ---------------------------------------------------------------------
-- 0450 to 0453 answered "who keeps these books" and "who owns this
-- company". They do not answer the third question a business asks
-- before it trusts any of this: **can we leave?**
--
-- Measured, before this: the only export in the schema is
-- `fs_export(filing_id)`, which produces one statutory filing, plus
-- per-screen CSVs written in Dart from whatever a list is showing. A
-- company that wanted its data out had no way to get it.
--
-- That gap has a cost even for people who never use it. A handover
-- inside this system moves one membership row and touches no data --
-- which is the right design, and it is only trustworthy if leaving
-- altogether is also possible. An accountant asked to put forty
-- clients on a platform they cannot get them off is right to say no.
--
-- ### The shape
--
-- Two calls, and the client walks them:
--
--   * `company_export_manifest(org)` -- every table holding this
--     company's data, with a row count and whether it needs paging.
--   * `company_export_page(org, table, after, limit)` -- one page of
--     rows as JSON, with the cursor for the next.
--
-- Driven from `information_schema` rather than from a list somebody
-- typed, so a table added next year is exported without anybody
-- remembering. 258 tables carry `org_id` today; 239 of them have an
-- `id` to page on and the other 19 are one-row-per-company settings
-- that need no paging at all.
--
-- ### What does not come out, and why
--
-- Three kinds of thing are held back, and the distinction matters:
--
--   * **Credentials.** `einvoice_credentials` and
--     `org_ocr_credentials` hold secrets this company gave us to act
--     on its behalf. Handing them back in a JSON file is not a
--     courtesy, it is a leak with a download button.
--   * **The platform's own relationship with the company** --
--     `org_modules`, `org_credits`. What a company bought from us and
--     what its scanning balance stands at are facts about this
--     platform, not about the business. They mean nothing in another
--     system.
--   * **Machinery.** `idempotency_keys` is how a request avoids being
--     applied twice. It is not data.
--
-- Views are excluded structurally: `v_stock_valuation` and
-- `v_lot_balances` are arithmetic over tables that are already in the
-- export, and shipping a derived answer beside its inputs invites
-- somebody to reconcile the two.
--
-- On top of the exclusions, **every row goes through
-- `app.audit_redact`** -- the same rule the audit trail uses, so a
-- column called `invite_token` or `client_secret` leaves as `***`
-- wherever it is. That matters most for the tables that are *not*
-- excluded: `org_members.invite_token` is a live credential sitting in
-- a table nobody would think to hold back.
--
-- ### Who may run it, and the record of them doing it
--
-- Owners and administrators, and every call writes a `record_export`
-- event. A whole-company export is the single largest read anybody can
-- perform here; a copy of it leaving with no record would be the one
-- gap in a security trail that otherwise notes the reading of a
-- payslip.
--
-- ### Mutants
--
-- Seven, restated into a built database and run against
-- `supabase/tests/company_export.sql`. Seven kills, each on a different
-- assertion:
--
--   * the exclusion list dropped -- "credentials are not exportable";
--   * views back in -- "nor a view over what is already there";
--   * `app.audit_redact` dropped from the page -- "but not a live
--     invitation token", which is the one that matters most:
--     `org_members` belongs in the export and carries a working
--     invitation in it;
--   * the `org_id` filter dropped from a page -- "walking the pages
--     sees every row once" read **420 where 84 was expected**: five
--     companies' charts of accounts in one file. That is the whole
--     risk of this feature stated as a number;
--   * the table name no longer matched against the list before it
--     reaches dynamic SQL -- "and asking for one by name is refused";
--   * the manifest open to any member rather than to owners and
--     administrators -- "a clerk cannot take the company away";
--   * `record_export` removed -- "and taking it is written down".
--
-- One assertion had to be rewritten before it could kill anything, and
-- it is the familiar shape: "a one-row-per-company table is not paged"
-- was phrased over the manifest, and a freshly built company has *no*
-- unpaged table populated -- so it passed against an empty result. The
-- test now inserts the row it is talking about.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- What belongs in an export
-- ---------------------------------------------------------------------
create or replace function app.company_export_tables()
returns table (table_name text, key_column text)
language sql stable
set search_path = public, app, pg_temp
as $$
  select c.relname::text,
         case when exists (
           select 1 from pg_attribute a
            where a.attrelid = c.oid and a.attname = 'id'
              and a.attnum > 0 and not a.attisdropped)
         then 'id' end
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'                       -- tables, never views
     and exists (
       select 1 from pg_attribute a
        where a.attrelid = c.oid and a.attname = 'org_id'
          and a.attnum > 0 and not a.attisdropped)
     and c.relname not in (
       -- Secrets this company lent us to act on its behalf.
       'einvoice_credentials', 'org_ocr_credentials',
       -- The platform's relationship with the company, not the
       -- company's own business.
       'org_modules', 'org_credits',
       -- Machinery.
       'idempotency_keys')
   order by 1;
$$;

-- ---------------------------------------------------------------------
-- The manifest
-- ---------------------------------------------------------------------
create or replace function public.company_export_manifest(p_org_id uuid)
returns table (table_name text, row_count bigint, paged boolean)
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  r record;
  v_n bigint;
begin
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an owner or administrator may export the company'
      using errcode = '42501';
  end if;

  perform public.record_export(p_org_id, 'company', 'manifest');

  for r in select t.table_name, t.key_column
             from app.company_export_tables() t loop
    execute format('select count(*) from public.%I where org_id = $1',
                   r.table_name)
      into v_n using p_org_id;
    if v_n > 0 then
      table_name := r.table_name;
      row_count  := v_n;
      paged      := r.key_column is not null;
      return next;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- One page of it
-- ---------------------------------------------------------------------
create or replace function public.company_export_page(
  p_org_id uuid,
  p_table  text,
  p_after  text default null,
  p_limit  integer default 1000)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_key  text;
  v_ok   boolean;
  v_rows jsonb;
  v_next text;
  v_lim  integer := least(greatest(coalesce(p_limit, 1000), 1), 5000);
begin
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an owner or administrator may export the company'
      using errcode = '42501';
  end if;

  -- The table name reaches dynamic SQL, so it is matched against the
  -- list rather than quoted and hoped for. A name that is not in the
  -- export is not a table as far as this function is concerned --
  -- including the three that are deliberately held back.
  select true, t.key_column into v_ok, v_key
    from app.company_export_tables() t
   where t.table_name = p_table;

  if not coalesce(v_ok, false) then
    raise exception 'No such table in the export: %', p_table
      using errcode = '42P01';
  end if;

  perform public.record_export(p_org_id, 'company', p_table);

  if v_key is null then
    -- One row per company. Nothing to page.
    execute format(
      'select coalesce(jsonb_agg(app.audit_redact(to_jsonb(t))), ''[]''::jsonb)
         from public.%I t where t.org_id = $1', p_table)
      into v_rows using p_org_id;
    return jsonb_build_object('rows', v_rows, 'next', null);
  end if;

  execute format(
    'select coalesce(jsonb_agg(app.audit_redact(to_jsonb(t))
                               order by t.id), ''[]''::jsonb),
            max(t.id::text)
       from (select * from public.%I x
              where x.org_id = $1
                and ($2 is null or x.id::text > $2)
              order by x.id
              limit $3) t', p_table)
    into v_rows, v_next using p_org_id, p_after, v_lim;

  return jsonb_build_object(
    'rows', v_rows,
    -- Null when the page came back short: there is nothing after it.
    'next', case when jsonb_array_length(v_rows) < v_lim then null
                 else v_next end);
end;
$$;

revoke all on function public.company_export_manifest(uuid) from public;
revoke all on function public.company_export_page(uuid, text, text, integer)
  from public;
grant execute on function public.company_export_manifest(uuid)
  to authenticated;
grant execute on function public.company_export_page(uuid, text, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_page text := pg_get_functiondef(to_regprocedure(
    'public.company_export_page(uuid, text, text, integer)'));
  v_tabs text := pg_get_functiondef(
    to_regprocedure('app.company_export_tables()'));
begin
  if position('app.audit_redact' in v_page) = 0 then
    raise exception '0454: the export ships secrets in the clear';
  end if;

  if position('No such table in the export' in v_page) = 0 then
    raise exception '0454: a table name reaches dynamic SQL unchecked';
  end if;

  if position('''einvoice_credentials''' in v_tabs) = 0 then
    raise exception '0454: credentials are inside the export';
  end if;

  if position('c.relkind = ''r''' in v_tabs) = 0 then
    raise exception '0454: derived views ship beside their own inputs';
  end if;

  -- The list is computed, not typed. A table added next year is
  -- exported without anybody remembering it exists.
  if position('information_schema' in v_tabs) > 0
     and position('pg_class' in v_tabs) = 0 then
    raise exception '0454: the export list went stale-able';
  end if;
end
$do$;

comment on function public.company_export_manifest(uuid) is
  'Every table holding this company''s data, with a row count. The '
  'first half of taking a company out of this system altogether -- '
  'the other half is company_export_page. See 0454.';
