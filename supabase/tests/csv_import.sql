-- =====================================================================
-- iAkauntan :: importing contacts and items
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/csv_import.sql
--
-- The assertion that matters is the one about failure: a file with a
-- bad row writes *nothing*. An import that half-succeeds leaves
-- somebody diffing a spreadsheet against a database to find out which
-- half went in, and re-running it duplicates whatever did.
--
-- After that: the preview and the import agree, because they are the
-- same call; and the validation catches what a real exported file
-- actually contains — thousands separators, a duplicated code, a
-- currency nobody has heard of.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- Row counts, for the assertion that nothing was written.
create or replace function pg_temp.contact_count(p_org uuid)
returns integer language sql as $$
  select count(*)::integer from public.contacts
   where org_id = p_org and deleted_at is null;
$$;

create or replace function pg_temp.item_count(p_org uuid)
returns integer language sql as $$
  select count(*)::integer from public.items
   where org_id = p_org and deleted_at is null;
$$;

-- ---------------------------------------------------------------------
-- A clean file
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Import Sdn Bhd');
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('code', 'C-001', 'name', 'Alpha Trading Sdn Bhd',
      'contact_type', 'customer', 'email', 'ap@alpha.example',
      'credit_limit', '50,000.00', 'city', 'Kuala Lumpur',
      'state_code', '14'),
    jsonb_build_object('code', 'S-001', 'name', 'Beta Supplies Sdn Bhd',
      'contact_type', 'supplier', 'currency', 'MYR'),
    jsonb_build_object('code', 'C-002', 'name', 'Gamma Ltd',
      'contact_type', 'both'));
  v_preview integer;
begin
  -- A preview writes nothing, which is the only reason anybody would
  -- trust it enough to run the real thing afterwards.
  select count(*) into v_preview
    from public.import_contacts(v_org, v_rows, false);
  perform pg_temp.check_eq('the preview reads every row', v_preview, 3);
  perform pg_temp.check_eq('and writes none of them',
    pg_temp.contact_count(v_org), 0);
  perform pg_temp.check_eq('with nothing to complain about',
    (select count(*) from public.import_contacts(v_org, v_rows, false)
      where status <> 'ok'), 0);

  perform public.import_contacts(v_org, v_rows, true);
  perform pg_temp.check_eq('and then all three arrive',
    pg_temp.contact_count(v_org), 3);

  -- The figures have to survive the trip, not just the row count.
  perform pg_temp.check_eq('a thousands separator is a number, not a name',
    (select credit_limit from public.contacts
      where org_id = v_org and code = 'C-001'), 50000);
  perform pg_temp.check_true('and the rest of the row came with it',
    (select contact_type = 'customer' and email = 'ap@alpha.example'
        and city = 'Kuala Lumpur' and state_code = '14'
        and country_code = 'MYS' and currency = 'MYR'
       from public.contacts where org_id = v_org and code = 'C-001'));

  -- Running the same file again is the mistake somebody makes when they
  -- are not sure whether the first run worked.
  begin
    perform public.import_contacts(v_org, v_rows, true);
    raise exception 'FAIL: imported the same file twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a code that is already here is refused';
  end;
  perform pg_temp.check_eq('and there are still only three',
    pg_temp.contact_count(v_org), 3);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- One bad row spoils the file
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Rejected Sdn Bhd');
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('code', 'C-001', 'name', 'Fine Bhd'),
    jsonb_build_object('code', 'C-002', 'name', 'Also Fine Bhd'),
    -- No name.
    jsonb_build_object('code', 'C-003'),
    -- A currency nobody has heard of.
    jsonb_build_object('code', 'C-004', 'name', 'Foreign Bhd',
                       'currency', 'XYZ'),
    -- The same code as row one.
    jsonb_build_object('code', 'c-001', 'name', 'Duplicate Bhd'),
    -- A credit limit that is not a number.
    jsonb_build_object('code', 'C-005', 'name', 'Vague Bhd',
                       'credit_limit', 'about ten thousand'));
begin
  perform pg_temp.check_eq('four rows are wrong',
    (select count(*) from public.import_contacts(v_org, v_rows, false)
      where status = 'error'), 4);

  -- Each one says which row and why, because "import failed" sends
  -- somebody back to a spreadsheet with no idea where to look.
  perform pg_temp.check_true('the row with no name says so',
    (select message like '%No name%' from public.import_contacts(v_org, v_rows, false)
      where row_no = 3));
  -- Quoted as the row actually spelled it, which is the point: the
  -- clash is with C-001 two rows up and somebody has to see both.
  perform pg_temp.check_true('the duplicate names the code',
    (select message ilike '%c-001%' and message like '%more than once%'
       from public.import_contacts(v_org, v_rows, false) where row_no = 5));
  perform pg_temp.check_true('and the currency is quoted back',
    (select message like '%XYZ%'
       from public.import_contacts(v_org, v_rows, false) where row_no = 4));

  -- The assertion this file exists for.
  begin
    perform public.import_contacts(v_org, v_rows, true);
    raise exception 'FAIL: imported a file with bad rows in it';
  exception when sqlstate '22023' then
    raise notice 'ok   a file with a bad row is refused whole';
  end;
  perform pg_temp.check_eq('and not one of the good rows was written',
    pg_temp.contact_count(v_org), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Stocked Sdn Bhd');
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('code', 'ITEM-1', 'name', 'Widget',
      'unit_price', '12.50', 'cost_price', '8.00', 'reorder_level', '25'),
    jsonb_build_object('code', 'SVC-1', 'name', 'Consulting',
      'item_type', 'service', 'unit_price', '1,200'),
    jsonb_build_object('code', 'ITEM-2', 'name', 'Boxed widget',
      'uom_code', 'BX', 'unit_price', 'RM 40.00'));
begin
  perform public.import_items(v_org, v_rows, true);
  perform pg_temp.check_eq('three items', pg_temp.item_count(v_org), 3);

  perform pg_temp.check_true('a plain item is stock, and tracked',
    (select item_type = 'stock' and track_inventory and unit_price = 12.50
        and cost_price = 8 and reorder_level = 25 and uom_code = 'C62'
       from public.items where org_id = v_org and code = 'ITEM-1'));

  -- The default follows the type rather than being the same for
  -- everything: a service that tracks inventory is an item that posts
  -- to stock and never moves.
  perform pg_temp.check_true('a service is not',
    (select item_type = 'service' and not track_inventory and unit_price = 1200
       from public.items where org_id = v_org and code = 'SVC-1'));

  perform pg_temp.check_true('a currency symbol is not part of the price',
    (select unit_price = 40 and uom_code = 'BX'
       from public.items where org_id = v_org and code = 'ITEM-2'));

  -- MyInvois needs a classification on every line and nobody migrating
  -- from a spreadsheet has one, so there is a catch-all rather than a
  -- refusal.
  perform pg_temp.check_true('every item can go on an e-Invoice',
    not exists (select 1 from public.items
                 where org_id = v_org and classification_code is null));

  perform pg_temp.sign_out();
end $$;

do $$
declare
  v_org uuid := pg_temp.test_org('Bad Items Sdn Bhd');
  v_rows jsonb := jsonb_build_array(
    jsonb_build_object('code', 'A', 'name', 'Fine'),
    jsonb_build_object('code', 'B', 'name', 'Odd unit', 'uom_code', 'FURLONG'),
    jsonb_build_object('code', 'C', 'name', 'Odd type', 'item_type', 'widget'),
    jsonb_build_object('code', 'D', 'name', 'Tracked service',
      'item_type', 'service', 'track_inventory', 'yes'),
    jsonb_build_object('code', 'E', 'name', 'Vague price',
      'unit_price', 'ask us'));
begin
  perform pg_temp.check_eq('four of the five are wrong',
    (select count(*) from public.import_items(v_org, v_rows, false)
      where status = 'error'), 4);
  perform pg_temp.check_true('including the service somebody stock-tracked',
    (select message like '%service%'
       from public.import_items(v_org, v_rows, false) where row_no = 4));

  begin
    perform public.import_items(v_org, v_rows, true);
    raise exception 'FAIL: imported a file with bad rows in it';
  exception when sqlstate '22023' then
    raise notice 'ok   the item file is refused whole too';
  end;
  perform pg_temp.check_eq('and nothing was written',
    pg_temp.item_count(v_org), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- An empty file is a mistake worth naming
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := pg_temp.test_org('Empty Sdn Bhd');
begin
  begin
    perform public.import_contacts(v_org, '[]'::jsonb, false);
    raise exception 'FAIL: accepted an empty file';
  exception when sqlstate '22023' then
    raise notice 'ok   an empty file is refused rather than reported as done';
  end;
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who can bulk-load a customer list
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a stranger cannot import anything',
    not has_function_privilege('anon',
      'public.import_contacts(uuid, jsonb, boolean)', 'execute')
    and not has_function_privilege('anon',
      'public.import_items(uuid, jsonb, boolean)', 'execute'));
  perform pg_temp.check_true('a member can',
    has_function_privilege('authenticated',
      'public.import_contacts(uuid, jsonb, boolean)', 'execute')
    and has_function_privilege('authenticated',
      'public.import_items(uuid, jsonb, boolean)', 'execute'));

  -- Nobody signed in is nobody who may write.
  perform pg_temp.sign_out();
  begin
    perform public.import_contacts(gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('code', 'X', 'name', 'Y')), false);
    raise exception 'FAIL: imported with nobody signed in';
  exception when sqlstate '42501' then
    raise notice 'ok   an import needs somebody who may write';
  end;
end $$;

rollback;
