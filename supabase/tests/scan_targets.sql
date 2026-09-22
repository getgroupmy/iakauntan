-- =====================================================================
-- iAkauntan :: where a scanned paper goes, and what it fills
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_targets.sql
--
-- `0681`. A kind of document now points at a module and an action, and
-- the fields the reader is asked for are the REAL COLUMNS of the table
-- that action writes -- discovered from `information_schema`, ticked in
-- the console, and sent to the AI with the document.
--
-- The assertion that matters most is the one that keeps the list
-- honest: a tick on a column that does not exist. Nothing downstream
-- would ever complain about one. The reader would be asked for that
-- field on every scan for ever, would answer null or invent something,
-- and the only symptom would be a bookkeeper wondering why one box
-- never fills in.
--
-- The others are about not lying to the model: a target with no fields
-- is a choice it can make and then have nothing to fill, and a stale
-- `destination` is a scan that opens the wrong screen.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.make_platform_admin(p_user uuid)
returns void language sql as $$
  insert into public.platform_admins (user_id) values (p_user)
  on conflict do nothing;
$$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_other uuid;
  v_n     integer;
  v_row   record;
  v_out   jsonb;
begin
  perform pg_temp.make_platform_admin(v_owner);
  perform pg_temp.sign_in_as(v_owner);

  -- -------------------------------------------------------------------
  -- Discovered, not typed
  --
  -- The columns come out of `information_schema` for the table the
  -- target names. A list somebody typed goes stale the first time a
  -- column is renamed, and goes stale silently.
  -- -------------------------------------------------------------------
  select count(*) into v_n
    from public.scan_target_columns('purchases', 'bill');
  perform pg_temp.check_true(
    'a target offers the real columns of its table', v_n > 5);

  perform pg_temp.check_true(
    'and every one of them is a column that table actually has',
    not exists (
      select 1 from public.scan_target_columns('purchases', 'bill') c
       where c.still_there
         and not exists (
           select 1 from information_schema.columns ic
            where ic.table_schema = 'public'
              and ic.table_name = 'purchase_documents'
              and ic.column_name = c.column_name)));

  -- Plumbing a reader cannot supply. Asking for `org_id` would spend
  -- tokens inviting a model to invent a uuid.
  perform pg_temp.check_true(
    'the audit and tenancy columns are not on offer',
    not exists (
      select 1 from public.scan_target_columns('purchases', 'bill')
       where column_name in ('id', 'org_id', 'created_at', 'created_by',
                             'updated_at', 'updated_by')));

  -- But a foreign key IS, and is marked. `contact_id` cannot be read
  -- off a bill -- what is printed is a NAME -- and it is the honest
  -- place to hang "the supplier as printed, matched to a contact".
  -- Hiding it would leave the one field every bill has no way of
  -- being asked for.
  perform pg_temp.check_true(
    'a foreign key is offered, and says it is one',
    exists (select 1 from public.scan_target_columns('purchases', 'bill')
             where column_name = 'contact_id' and is_foreign));

  -- A target that names no real table offers nothing rather than
  -- offering a lie.
  select count(*) into v_n
    from public.scan_target_columns('purchases', 'no_such_action');
  perform pg_temp.check_eq('an unknown target offers nothing', v_n, 0);

  -- -------------------------------------------------------------------
  -- The tick, and the honesty check on it
  -- -------------------------------------------------------------------
  perform public.set_scan_target_fields('purchases', 'bill', jsonb_build_array(
    jsonb_build_object('column_name', 'doc_no',
                       'description', 'The supplier''s own bill number.',
                       'sort_order', 10),
    jsonb_build_object('column_name', 'doc_date',
                       'description', 'The date printed on it.',
                       'sort_order', 20)));

  select * into v_row from public.scan_target_columns('purchases', 'bill')
   where column_name = 'doc_no';
  perform pg_temp.check_true('a ticked column says it is ticked',
    v_row.is_asked);
  perform pg_temp.check_eq('and carries the sentence it is asked with',
    v_row.description, 'The supplier''s own bill number.');

  -- The one that nothing downstream would ever catch.
  perform pg_temp.check_refused(
    'a tick on a column that does not exist is refused',
    'select public.set_scan_target_fields(''purchases'', ''bill'', ' ||
      '''[{"column_name": "supplier_name_that_is_not_a_column"}]''::jsonb)',
    '%has no column called%', '23514');

  -- And the refusal left the good set alone, rather than half-applying
  -- it -- the delete and the insert are one statement's worth of work
  -- inside one function, and a partial apply would be a configuration
  -- nobody asked for.
  select count(*) into v_n from public.scan_target_fields
   where module_code = 'purchases' and action = 'bill';
  perform pg_temp.check_eq('and changed nothing', v_n, 2);

  -- Replaces, does not merge. The console sends what is ticked, and a
  -- merge would make unticking impossible.
  perform public.set_scan_target_fields('purchases', 'bill', jsonb_build_array(
    jsonb_build_object('column_name', 'doc_no')));
  select count(*) into v_n from public.scan_target_fields
   where module_code = 'purchases' and action = 'bill';
  perform pg_temp.check_eq('unticking a field removes it', v_n, 1);

  -- -------------------------------------------------------------------
  -- A ticked column that has since been dropped
  --
  -- It comes back with `still_there` false rather than vanishing, so
  -- an operator sees what happened instead of wondering where the
  -- configuration went.
  -- -------------------------------------------------------------------
  insert into public.scan_target_fields (module_code, action, column_name)
  values ('purchases', 'bill', 'a_column_from_last_year');
  select * into v_row from public.scan_target_columns('purchases', 'bill')
   where column_name = 'a_column_from_last_year';
  perform pg_temp.check_true('a vanished column is shown, not hidden',
    v_row.is_asked and not v_row.still_there);
  delete from public.scan_target_fields
   where column_name = 'a_column_from_last_year';

  -- -------------------------------------------------------------------
  -- What goes to the reader
  -- -------------------------------------------------------------------
  v_out := public.scan_extraction_targets();
  perform pg_temp.check_true(
    'the configured target is sent, by module and action',
    exists (select 1 from jsonb_array_elements(v_out) t
             where t ->> 'key' = 'purchases.bill'));
  perform pg_temp.check_true(
    'with the field ticked for it',
    exists (select 1 from jsonb_array_elements(v_out) t,
                        jsonb_array_elements(t -> 'fields') f
             where t ->> 'key' = 'purchases.bill'
               and f ->> 'name' = 'doc_no'));

  -- A target nobody has configured is NOT sent. It would be a choice
  -- the model can make and then have nothing to fill, which reads to a
  -- bookkeeper as the scan having understood the document and lost it.
  perform pg_temp.check_true(
    'a target with no fields is not offered to the reader',
    not exists (select 1 from jsonb_array_elements(v_out) t
                 where t ->> 'key' = 'contacts.contact'));

  -- The kinds of paper that land there travel with it: they are the
  -- operator's own words, and they are what a model matches a
  -- letterhead against.
  perform public.set_scan_kind_target('bill', 'purchases', 'bill');
  v_out := public.scan_extraction_targets();
  perform pg_temp.check_true(
    'and the kinds that land there travel with it',
    exists (select 1 from jsonb_array_elements(v_out) t,
                        jsonb_array_elements_text(t -> 'kinds') k
             where t ->> 'key' = 'purchases.bill'
               and k like '%bill%'));

  -- -------------------------------------------------------------------
  -- The screen and the fields cannot disagree
  --
  -- `destination` is what the app routes on and `0614` published it.
  -- Pointing a kind at a target moves it, so nobody has to edit two
  -- fields and get them to match.
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq(
    'pointing a kind at a target moves the screen it opens',
    (select destination from public.scan_document_kinds where code = 'bill'),
    'purchase_document');

  perform public.set_scan_kind_target('bill', 'accounting', 'expense');
  perform pg_temp.check_eq(
    'and moving the target moves the screen with it',
    (select destination from public.scan_document_kinds where code = 'bill'),
    'expense');

  perform pg_temp.check_refused(
    'half a target is not a target',
    'select public.set_scan_kind_target(''bill'', ''purchases'', null)',
    '%module AND an action%', '23514');

  perform pg_temp.check_refused(
    'and a target that does not exist is refused',
    'select public.set_scan_kind_target(''bill'', ''purchases'', ''flying'')',
    '%No such target%', '23514');

  -- -------------------------------------------------------------------
  -- Nobody but a platform administrator
  -- -------------------------------------------------------------------
  v_other := pg_temp.another_user('outsider@example.test');
  perform pg_temp.sign_in_as(v_other);

  select count(*) into v_n
    from public.scan_target_columns('purchases', 'bill');
  perform pg_temp.check_eq(
    'a stranger is shown no columns of anybody''s table', v_n, 0);

  perform pg_temp.check_refused(
    'and cannot tick one',
    'select public.set_scan_target_fields(''purchases'', ''bill'', ''[]''::jsonb)',
    '%Platform administrator%', '42501');

  perform pg_temp.check_refused(
    'nor point a kind anywhere',
    'select public.set_scan_kind_target(''bill'', ''purchases'', ''bill'')',
    '%platform administrator%', '42501');

  -- The two tables are readable -- they are a list of screens, not a
  -- secret, and the tenant's own settings card names them -- and
  -- writable by nobody. Every write is a SECURITY DEFINER function
  -- that checks for itself.
  perform pg_temp.check_true(
    'the tables are readable and nobody writes them directly',
    has_table_privilege('authenticated', 'public.scan_targets', 'select')
      and not has_table_privilege('authenticated', 'public.scan_targets',
                                  'insert')
      and not has_table_privilege('authenticated', 'public.scan_target_fields',
                                  'update')
      and not has_table_privilege('anon', 'public.scan_targets', 'select'));

  raise notice 'scan_targets: all assertions passed';
end;
$$;

rollback;
