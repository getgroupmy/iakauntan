-- =====================================================================
-- iAkauntan :: 0103 importing contacts and items
--
-- Moving onto this system has meant typing the customer list. A bank
-- statement can be pasted in and nothing else, which is the wrong way
-- round: the statement is the one thing that arrives every month
-- anyway, and the customer and item lists are the ones that arrive once
-- and are enormous.
--
-- Two decisions:
--
-- **Nothing is written until every row is good.** An import that
-- half-succeeds leaves somebody reconciling a spreadsheet against a
-- database to find out which half, and re-running it duplicates
-- whatever did land. So the whole file goes in or none of it does, and
-- a failed run is fixed in the spreadsheet and run again — which is
-- only safe because nothing from the first attempt is there.
--
-- **The same call previews and imports.** `p_commit` false validates
-- every row and writes nothing, returning a verdict per row; true does
-- the identical validation and then inserts. One implementation, so the
-- preview cannot promise something the import then refuses.
--
-- Parsing the file is the client's job — a header row mapped onto these
-- field names — but every rule about what is acceptable is here, where
-- it applies to anything that ever calls it.
--
-- Not included: importing invoices and bills. Bringing open items
-- across mid-year is the other half of a migration and it posts to the
-- ledger, which is a different problem from writing a master file: it
-- needs numbering, tax codes, an opening balance to sit against and a
-- decision about what the other side of the entry is. It should be its
-- own piece of work rather than a flag on this one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reading what a spreadsheet actually contains
-- ---------------------------------------------------------------------

-- Null means "this is not a number", which the caller reports. Empty
-- means the column was left blank, which is nothing rather than wrong.
create or replace function app.import_number(p_text text, p_default numeric default 0)
returns numeric
language plpgsql immutable as $$
begin
  if p_text is null or btrim(p_text) = '' then return p_default; end if;
  -- Spreadsheets export thousands separators and currency symbols
  -- whatever anybody intended.
  return replace(replace(replace(btrim(p_text), ',', ''), 'RM', ''), ' ', '')::numeric;
exception when others then
  return null;
end $$;

create or replace function app.import_boolean(p_text text, p_default boolean)
returns boolean
language sql immutable as $$
  select case
    when p_text is null or btrim(p_text) = '' then p_default
    when lower(btrim(p_text)) in ('y', 'yes', 'true', 't', '1') then true
    when lower(btrim(p_text)) in ('n', 'no', 'false', 'f', '0') then false
    else null
  end;
$$;

create or replace function app.import_text(p_row jsonb, p_key text)
returns text
language sql immutable as $$
  select nullif(btrim(coalesce(p_row ->> p_key, '')), '');
$$;

revoke all on function app.import_number(text, numeric) from public, anon;
revoke all on function app.import_boolean(text, boolean) from public, anon;
revoke all on function app.import_text(jsonb, text) from public, anon;

-- ---------------------------------------------------------------------
-- Contacts
-- ---------------------------------------------------------------------
create or replace function public.import_contacts(
  p_org_id uuid,
  p_rows jsonb,
  p_commit boolean default false)
returns table (row_no integer, code text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_bad integer := 0;
  v_code text; v_name text; v_type text; v_currency text;
  v_country text; v_state text; v_limit numeric; v_problem text;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Rows must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There is nothing in the file' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;

    v_code := app.import_text(r, 'code');
    v_name := app.import_text(r, 'name');
    v_type := lower(coalesce(app.import_text(r, 'contact_type'), 'customer'));
    v_currency := upper(coalesce(app.import_text(r, 'currency'), 'MYR'));
    v_country := upper(coalesce(app.import_text(r, 'country_code'), 'MYS'));
    v_state := upper(coalesce(app.import_text(r, 'state_code'), ''));
    v_limit := app.import_number(app.import_text(r, 'credit_limit'));

    if v_code is null then
      v_problem := 'No code. Every contact needs one, and it is what an '
                || 'invoice will refer to.';
    elsif v_name is null then
      v_problem := 'No name.';
    elsif lower(v_code) = any (v_seen) then
      -- Caught here rather than by the unique index, because the index
      -- would fail the whole import on the second occurrence without
      -- saying which two rows clashed.
      v_problem := format('The code %s is in this file more than once.', v_code);
    elsif exists (select 1 from public.contacts c
                   where c.org_id = p_org_id and lower(c.code) = lower(v_code)
                     and c.deleted_at is null) then
      v_problem := format('%s is already a contact here.', v_code);
    elsif v_type not in ('customer', 'supplier', 'both', 'employee', 'other') then
      v_problem := format('"%s" is not a contact type. Use customer, '
                       || 'supplier or both.', v_type);
    elsif not exists (select 1 from public.ref_currencies rc
                       where rc.code = v_currency) then
      v_problem := format('"%s" is not a currency this system knows.', v_currency);
    elsif not exists (select 1 from public.ref_countries rc
                       where rc.code = v_country) then
      v_problem := format('"%s" is not a country code. Malaysia is MYS.', v_country);
    elsif v_state <> '' and not exists (select 1 from public.ref_states rs
                                         where rs.code = v_state) then
      v_problem := format('"%s" is not a Malaysian state code.', v_state);
    elsif v_limit is null then
      v_problem := format('"%s" is not a credit limit.',
                          app.import_text(r, 'credit_limit'));
    end if;

    if v_problem is null then
      v_seen := v_seen || lower(v_code);
    else
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_code, ''),
      'status', case when v_problem is null then 'ok' else 'error' end,
      'message', coalesce(v_problem, ''));
  end loop;

  -- All of it or none of it.
  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, i using errcode = '22023';
  end if;

  if p_commit then
    i := 0;
    for r in select * from jsonb_array_elements(p_rows)
    loop
      i := i + 1;
      insert into public.contacts (
        org_id, code, name, legal_name, contact_type,
        tin, registration_no, sst_registration_no,
        email, phone, mobile, website,
        address_line1, address_line2, address_line3,
        postcode, city, state_code, country_code,
        currency, credit_limit, notes)
      values (
        p_org_id,
        app.import_text(r, 'code'),
        app.import_text(r, 'name'),
        app.import_text(r, 'legal_name'),
        lower(coalesce(app.import_text(r, 'contact_type'), 'customer'))
          ::app.contact_type,
        app.import_text(r, 'tin'),
        app.import_text(r, 'registration_no'),
        app.import_text(r, 'sst_registration_no'),
        app.import_text(r, 'email'),
        app.import_text(r, 'phone'),
        app.import_text(r, 'mobile'),
        app.import_text(r, 'website'),
        app.import_text(r, 'address_line1'),
        app.import_text(r, 'address_line2'),
        app.import_text(r, 'address_line3'),
        app.import_text(r, 'postcode'),
        app.import_text(r, 'city'),
        nullif(upper(coalesce(app.import_text(r, 'state_code'), '')), ''),
        upper(coalesce(app.import_text(r, 'country_code'), 'MYS')),
        upper(coalesce(app.import_text(r, 'currency'), 'MYR')),
        app.import_number(app.import_text(r, 'credit_limit')),
        app.import_text(r, 'notes'));
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status', x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end; $$;

-- ---------------------------------------------------------------------
-- Items
--
-- `classification_code` has a default because MyInvois requires one on
-- every line and nobody migrating from a spreadsheet has it. 022 is the
-- catch-all, and it is better to import with it and correct the ones
-- that matter than to refuse the file.
--
-- The unit defaults to C62, which is what UN/ECE Recommendation 20 —
-- the list MyInvois uses — calls a unit. Not 'UNT', which reads like it
-- ought to work and is not in the table.
-- ---------------------------------------------------------------------
create or replace function public.import_items(
  p_org_id uuid,
  p_rows jsonb,
  p_commit boolean default false)
returns table (row_no integer, code text, status text, message text)
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_bad integer := 0;
  v_code text; v_name text; v_kind text; v_uom text; v_class text;
  v_currency text; v_price numeric; v_cost numeric; v_reorder numeric;
  v_track boolean; v_problem text;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Rows must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'There is nothing in the file' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows)
  loop
    i := i + 1;
    v_problem := null;

    v_code := app.import_text(r, 'code');
    v_name := app.import_text(r, 'name');
    v_kind := lower(coalesce(app.import_text(r, 'item_type'), 'stock'));
    v_uom := upper(coalesce(app.import_text(r, 'uom_code'), 'C62'));
    v_class := coalesce(app.import_text(r, 'classification_code'), '022');
    v_currency := upper(coalesce(app.import_text(r, 'currency'), 'MYR'));
    v_price := app.import_number(app.import_text(r, 'unit_price'));
    v_cost := app.import_number(app.import_text(r, 'cost_price'));
    v_reorder := app.import_number(app.import_text(r, 'reorder_level'));
    -- A service is not stock, so the sensible default follows the type
    -- rather than being the same for everything.
    v_track := app.import_boolean(app.import_text(r, 'track_inventory'),
                                  v_kind = 'stock');

    if v_code is null then
      v_problem := 'No code.';
    elsif v_name is null then
      v_problem := 'No name.';
    elsif lower(v_code) = any (v_seen) then
      v_problem := format('The code %s is in this file more than once.', v_code);
    elsif exists (select 1 from public.items it
                   where it.org_id = p_org_id and lower(it.code) = lower(v_code)
                     and it.deleted_at is null) then
      v_problem := format('%s is already an item here.', v_code);
    elsif v_kind not in ('stock', 'service', 'non_stock', 'bundle', 'fixed_asset') then
      v_problem := format('"%s" is not an item type. Use stock, service or '
                       || 'non_stock.', v_kind);
    elsif not exists (select 1 from public.ref_uom_codes ru
                       where ru.code = v_uom) then
      v_problem := format('"%s" is not a unit of measure this system knows.', v_uom);
    elsif not exists (select 1 from public.ref_classification_codes rk
                       where rk.code = v_class) then
      v_problem := format('"%s" is not a MyInvois classification code.', v_class);
    elsif not exists (select 1 from public.ref_currencies rc
                       where rc.code = v_currency) then
      v_problem := format('"%s" is not a currency this system knows.', v_currency);
    elsif v_price is null then
      v_problem := format('"%s" is not a price.', app.import_text(r, 'unit_price'));
    elsif v_cost is null then
      v_problem := format('"%s" is not a cost.', app.import_text(r, 'cost_price'));
    elsif v_reorder is null then
      v_problem := format('"%s" is not a reorder level.',
                          app.import_text(r, 'reorder_level'));
    elsif v_track is null then
      v_problem := format('"%s" is not a yes or a no.',
                          app.import_text(r, 'track_inventory'));
    -- Stock that is not tracked has no cost and no quantity, which is
    -- what `non_stock` is for. Letting it through gives an item that
    -- posts to inventory and never moves.
    elsif v_kind = 'service' and v_track then
      v_problem := 'A service cannot be stock-tracked. Leave '
                || 'track_inventory blank or say no.';
    end if;

    if v_problem is null then
      v_seen := v_seen || lower(v_code);
    else
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_code, ''),
      'status', case when v_problem is null then 'ok' else 'error' end,
      'message', coalesce(v_problem, ''));
  end loop;

  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, i using errcode = '22023';
  end if;

  if p_commit then
    for r in select * from jsonb_array_elements(p_rows)
    loop
      insert into public.items (
        org_id, code, name, description, item_type, barcode,
        uom_code, classification_code,
        unit_price, cost_price, currency,
        track_inventory, reorder_level, reorder_quantity)
      values (
        p_org_id,
        app.import_text(r, 'code'),
        app.import_text(r, 'name'),
        app.import_text(r, 'description'),
        lower(coalesce(app.import_text(r, 'item_type'), 'stock')),
        app.import_text(r, 'barcode'),
        upper(coalesce(app.import_text(r, 'uom_code'), 'C62')),
        coalesce(app.import_text(r, 'classification_code'), '022'),
        app.import_number(app.import_text(r, 'unit_price')),
        app.import_number(app.import_text(r, 'cost_price')),
        upper(coalesce(app.import_text(r, 'currency'), 'MYR')),
        app.import_boolean(app.import_text(r, 'track_inventory'),
          lower(coalesce(app.import_text(r, 'item_type'), 'stock')) = 'stock'),
        app.import_number(app.import_text(r, 'reorder_level')),
        app.import_number(app.import_text(r, 'reorder_quantity')));
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status', x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end; $$;

revoke all on function public.import_contacts(uuid, jsonb, boolean) from public, anon;
revoke all on function public.import_items(uuid, jsonb, boolean) from public, anon;
grant execute on function public.import_contacts(uuid, jsonb, boolean) to authenticated;
grant execute on function public.import_items(uuid, jsonb, boolean) to authenticated;
