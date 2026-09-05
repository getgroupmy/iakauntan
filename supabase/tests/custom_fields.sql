-- =====================================================================
-- iAkauntan :: a field a company named for itself
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/custom_fields.sql
--
-- Eleven tables have carried `custom_fields jsonb` since 0003 and
-- nothing ever wrote one. 0542 gives them definitions, a name somebody
-- chose, and a rule enforced where rules are enforced in this product.
--
-- THE ASSERTION THAT MATTERS MOST IS THE LOOKUP ACROSS THE WALL. jsonb
-- has no foreign keys. Without the guard, a company could store another
-- company's contact id in a field it invented and read the name back
-- through its own picker — 0512's fault, in a column 0512 could not
-- have known about because the company had not made it yet.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- 1. The registry describes tables that are really there
-- ---------------------------------------------------------------------
do $$
begin
  -- A carrier without the column is a trigger that will fail on the
  -- first write, and a carrier without the trigger is a column nothing
  -- checks. Both halves, for all eleven.
  perform pg_temp.check_eq('every carrier has somewhere to put a value',
    (select count(*) from public.custom_field_entities e
      where e.can_carry
        and not exists (select 1 from information_schema.columns c
                         where c.table_schema = 'public'
                           and c.table_name = e.table_name
                           and c.column_name = 'custom_fields')), 0);
  perform pg_temp.check_eq('and a guard standing over it',
    (select count(*) from public.custom_field_entities e
      where e.can_carry
        and not exists (select 1 from pg_trigger t
                         where t.tgrelid = ('public.' || e.table_name)::regclass
                           and t.tgname = 'custom_fields_are_the_ones_defined')), 0);
  perform pg_temp.check_true('and there are the eleven that carry one',
    (select count(*) from public.custom_field_entities where can_carry) = 11);

  -- The guard builds SQL out of `table_name`, `label_column` and
  -- `deleted_column`. A row naming a column that does not exist is a
  -- lookup that raises at the moment somebody fills a form in.
  perform pg_temp.check_eq('every entity names a table that exists',
    (select count(*) from public.custom_field_entities e
      where to_regclass('public.' || e.table_name) is null), 0);
  perform pg_temp.check_eq('and a label column on it',
    (select count(*) from public.custom_field_entities e
      where not exists (select 1 from information_schema.columns c
                         where c.table_schema = 'public'
                           and c.table_name = e.table_name
                           and c.column_name = e.label_column)), 0);
  perform pg_temp.check_eq('and where it names a deleted column, that too',
    (select count(*) from public.custom_field_entities e
      where e.deleted_column is not null
        and not exists (select 1 from information_schema.columns c
                         where c.table_schema = 'public'
                           and c.table_name = e.table_name
                           and c.column_name = e.deleted_column)), 0);

  -- Everything a lookup may point at is held to one company, or the
  -- guard's `org_id` check has nothing to stand on.
  perform pg_temp.check_eq('every target belongs to a company',
    (select count(*) from public.custom_field_entities e
      where e.can_target
        and not exists (select 1 from information_schema.columns c
                         where c.table_schema = 'public'
                           and c.table_name = e.table_name
                           and c.column_name = 'org_id')), 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. Naming one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Medan Sendiri Sdn Bhd');
  v_id  uuid;
begin
  -- The key comes off the label, and the label is what a person reads.
  v_id := public.upsert_custom_field(v_org, 'contact', 'Cost centre');
  perform pg_temp.check_eq('a field is stored under a key made from its name',
    (select key from public.custom_fields_def where id = v_id), 'cost_centre');
  perform pg_temp.check_eq('and keeps the name it was given',
    (select label from public.custom_fields_def where id = v_id), 'Cost centre');

  -- Renaming changes the label and not the key, because every value
  -- already written is stored beneath the key.
  perform public.upsert_custom_field(v_org, 'contact', 'Cost centre (2026)',
                                     'cost_centre');
  perform pg_temp.check_eq('a rename moves the label',
    (select label from public.custom_fields_def where id = v_id),
    'Cost centre (2026)');
  perform pg_temp.check_eq('and leaves the key where the values are',
    (select key from public.custom_fields_def where id = v_id), 'cost_centre');
  perform pg_temp.check_eq('and does not make a second field',
    (select count(*) from public.custom_fields_def
      where org_id = v_org and entity = 'contact'), 1);

  perform pg_temp.check_refused('a name of punctuation alone',
    format($q$select public.upsert_custom_field(%L, 'contact', '???')$q$, v_org),
    'A name of punctuation alone%', '23514');
  perform pg_temp.check_refused('a name of nothing at all',
    format($q$select public.upsert_custom_field(%L, 'contact', '   ')$q$, v_org),
    'A field needs a name somebody can read.%', '23514');
  perform pg_temp.check_refused('a field on something that cannot carry one',
    format($q$select public.upsert_custom_field(%L, 'account', 'Anything')$q$,
           v_org),
    'A custom field cannot be added to a account.%', '23514');
  perform pg_temp.check_refused('a kind of field there is no such thing as',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Colour', null, 'rainbow')$q$, v_org),
    'There is no such kind of field as rainbow.%', '23514');
  perform pg_temp.check_refused('a list with nothing to choose from',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Region', null, 'select')$q$, v_org),
    'A field somebody chooses from needs something to choose.%', '23514');
  perform pg_temp.check_refused('choices on a field nobody chooses from',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Note', null, 'text', false, '["a","b"]'::jsonb)$q$,
           v_org),
    'Only a field somebody chooses from has choices.%', '23514');
  perform pg_temp.check_refused('a lookup pointing at nothing this product keeps',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Planet', null, 'lookup', false, null, 'planet')$q$,
           v_org),
    'A lookup points at a record this product keeps.%', '23514');
  perform pg_temp.check_refused('a lookup pointing at a line of a document',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'A line', null, 'lookup', false, null,
             'sales_document_line')$q$, v_org),
    'A lookup points at a record this product keeps.%', '23514');
  perform pg_temp.check_refused('a target on a field that is not a lookup',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Note two', null, 'text', false, null, 'item')$q$,
           v_org),
    'Only a lookup points at another record.%', '23514');
  perform pg_temp.check_refused('a smallest larger than the largest',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Score', null, 'number', false, null, null, null,
             10, 5)$q$, v_org),
    'The smallest allowed is larger than the largest.%', '23514');
end $$;

-- ---------------------------------------------------------------------
-- 3. What may go in one
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Isi Medan Sdn Bhd');
  v_c    uuid;
begin
  perform public.upsert_custom_field(v_org, 'contact', 'Cost centre');
  perform public.upsert_custom_field(v_org, 'contact', 'Credit score', null,
                                     'number', false, null, null, null, 0, 100);
  perform public.upsert_custom_field(v_org, 'contact', 'Reviewed on', null,
                                     'date');
  perform public.upsert_custom_field(v_org, 'contact', 'On hold', null,
                                     'boolean');
  perform public.upsert_custom_field(v_org, 'contact', 'Region', null,
                                     'select', false,
                                     '["North","South","East"]'::jsonb);
  perform public.upsert_custom_field(v_org, 'contact', 'Short note', null,
                                     'text', false, null, null, null, null,
                                     null, 10);

  insert into public.contacts (org_id, code, name, contact_type, custom_fields)
  values (v_org, 'C-1', 'Pelanggan Satu', 'customer', jsonb_build_object(
            'cost_centre', 'KL-01',
            'credit_score', 72,
            'reviewed_on', '2026-03-01',
            'on_hold', false,
            'region', 'North'))
  returning id into v_c;
  perform pg_temp.check_eq('a filled-in field is stored as it was written',
    (select custom_fields ->> 'cost_centre' from public.contacts where id = v_c),
    'KL-01');
  perform pg_temp.check_eq('a number stays a number',
    (select (custom_fields ->> 'credit_score')::numeric
       from public.contacts where id = v_c), 72);

  -- A key nobody defined is a typo that would sit there for ever.
  perform pg_temp.check_refused('a field this company never made',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"favourite_colour":"blue"}'::jsonb
             where id = %L$q$, v_c),
    'favourite_colour is not a field on a contact for this company.%',
    '23514');

  perform pg_temp.check_refused('words where a number belongs',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"credit_score":"seventy"}'::jsonb
             where id = %L$q$, v_c),
    'Credit score is a number.%', '22023');
  perform pg_temp.check_refused('a number below the smallest allowed',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"credit_score":-1}'::jsonb where id = %L$q$, v_c),
    'Credit score cannot be less than 0.%', '23514');
  perform pg_temp.check_refused('and above the largest',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"credit_score":101}'::jsonb where id = %L$q$, v_c),
    'Credit score cannot be more than 100.%', '23514');
  perform pg_temp.check_refused('a date that is not one',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"reviewed_on":"the third of March"}'::jsonb
             where id = %L$q$, v_c),
    'Reviewed on is a date.%', '22007');
  perform pg_temp.check_refused('a yes-or-no answered in words',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"on_hold":"yes"}'::jsonb where id = %L$q$, v_c),
    'On hold is yes or no.%', '22023');
  perform pg_temp.check_refused('a choice that is not on the list',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"region":"West"}'::jsonb where id = %L$q$, v_c),
    '"West" is not one of the choices for Region.%', '23514');
  perform pg_temp.check_refused('more characters than the field allows',
    format($q$update public.contacts set custom_fields =
             custom_fields || '{"short_note":"far too many characters"}'::jsonb
             where id = %L$q$, v_c),
    'Short note is longer than the 10 characters allowed.%', '22001');

  -- A blank is a blank however it is written, and an optional field
  -- takes one.
  update public.contacts set custom_fields =
    custom_fields || '{"cost_centre":"", "region":null}'::jsonb where id = v_c;
  perform pg_temp.check_true('an optional field may be left empty',
    (select custom_fields ->> 'cost_centre' from public.contacts
      where id = v_c) = '');
end $$;

-- ---------------------------------------------------------------------
-- 4. The lookup, and the wall between two companies
-- ---------------------------------------------------------------------
do $$
declare
  v_a    uuid := pg_temp.test_org('Rujuk Kami Sdn Bhd');
  v_b    uuid := pg_temp.test_org('Rujuk Mereka Sdn Bhd');
  v_supp uuid;
  v_gone uuid;
  v_thei uuid;
  v_wh   uuid;
  v_item uuid;
  v_n    integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_a, 'S-1', 'Pembekal Kami', 'supplier') returning id into v_supp;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_a, 'S-2', 'Pembekal Lama', 'supplier') returning id into v_gone;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_b, 'S-9', 'Pembekal Mereka', 'supplier') returning id into v_thei;
  insert into public.warehouses (org_id, code, name)
  values (v_a, 'GUDANG', 'Gudang utama') returning id into v_wh;

  perform public.upsert_custom_field(v_a, 'item', 'Warranty provider', null,
                                     'lookup', false, null, 'contact');
  perform public.upsert_custom_field(v_a, 'item', 'Kept at', null,
                                     'lookup', false, null, 'warehouse');

  -- Its own company's record: fine.
  insert into public.items
    (org_id, code, name, item_type, uom_code, unit_price, custom_fields)
  values (v_a, 'ITEM-1', 'Mesin', 'stock', 'C62', 100,
          jsonb_build_object('warranty_provider', v_supp::text,
                             'kept_at', v_wh::text))
  returning id into v_item;
  perform pg_temp.check_eq('a lookup holds the record it points at',
    (select (custom_fields ->> 'warranty_provider')::uuid
       from public.items where id = v_item), v_supp);

  -- ANOTHER COMPANY'S RECORD: REFUSED. This is the assertion the whole
  -- file is for. jsonb has no foreign key to do it, and no form could.
  perform pg_temp.check_refused('a lookup at another company''s record',
    format($q$update public.items set custom_fields =
             custom_fields || jsonb_build_object('warranty_provider', %L)
             where id = %L$q$, v_thei::text, v_item),
    'Warranty provider points at a Contact this company does not have.%',
    '23503');

  -- A record this company had and deleted is not one it has.
  update public.contacts set deleted_at = now() where id = v_gone;
  perform pg_temp.check_refused('nor at one it has since deleted',
    format($q$update public.items set custom_fields =
             custom_fields || jsonb_build_object('warranty_provider', %L)
             where id = %L$q$, v_gone::text, v_item),
    'Warranty provider points at a Contact this company does not have.%',
    '23503');

  perform pg_temp.check_refused('nor at something that is not an id at all',
    format($q$update public.items set custom_fields =
             custom_fields || '{"warranty_provider":"Pembekal Kami"}'::jsonb
             where id = %L$q$, v_item),
    '"Pembekal Kami" is not a record id for Warranty provider.%', '22P02');
  perform pg_temp.check_refused('nor at a record of the wrong kind',
    format($q$update public.items set custom_fields =
             custom_fields || jsonb_build_object('kept_at', %L)
             where id = %L$q$, v_supp::text, v_item),
    'Kept at points at a Warehouse this company does not have.%', '23503');

  -- The picker offers what the guard accepts, and nothing else. A list
  -- that offered the deleted supplier, or the other company's, would be
  -- a form that argues with the database.
  select count(*) into v_n from public.custom_field_lookup_options(v_a, 'contact');
  perform pg_temp.check_eq('the picker offers this company''s live records',
    v_n, 1);
  perform pg_temp.check_eq('and names them',
    (select label from public.custom_field_lookup_options(v_a, 'contact')),
    'Pembekal Kami');
  perform pg_temp.check_eq('and searches within them',
    (select count(*) from public.custom_field_lookup_options(v_a, 'contact', 'kami')),
    1);
  perform pg_temp.check_eq('finding nothing where there is nothing',
    (select count(*) from public.custom_field_lookup_options(v_a, 'contact', 'zzz')),
    0);
  perform pg_temp.check_refused('and it will not list a kind nothing points at',
    format($q$select * from public.custom_field_lookup_options(%L, 'planet')$q$,
           v_a),
    'Nothing points at a planet.%', 'P0002');
end $$;

-- ---------------------------------------------------------------------
-- 5. Required, archived, and what may still be changed
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Wajib Isi Sdn Bhd');
  v_c   uuid;
  v_old uuid;
begin
  -- A contact written before the field existed.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-OLD', 'Pelanggan Lama', 'customer') returning id into v_old;

  perform public.upsert_custom_field(v_org, 'contact', 'Cost centre', null,
                                     'text', true);
  perform public.upsert_custom_field(v_org, 'contact', 'Note');

  -- A NEW REQUIRED FIELD DOES NOT LOCK THE PAST. The company would
  -- otherwise add a field on Monday and find on Tuesday that it could
  -- not correct a customer's name without inventing a cost centre for a
  -- record written last year.
  update public.contacts set name = 'Pelanggan Lama Sdn Bhd' where id = v_old;
  perform pg_temp.check_eq('a record written before the field is still editable',
    (select name from public.contacts where id = v_old),
    'Pelanggan Lama Sdn Bhd');

  -- But what is written next has to carry it.
  perform pg_temp.check_refused('a new record without what is required',
    format($q$insert into public.contacts (org_id, code, name, contact_type)
             values (%L, 'C-NEW', 'Pelanggan Baru', 'customer')$q$, v_org),
    'Cost centre has to be filled in.%', '23514');
  perform pg_temp.check_refused('and touching the fields still asks for it',
    format($q$update public.contacts set custom_fields =
             '{"note":"anything"}'::jsonb where id = %L$q$, v_old),
    'Cost centre has to be filled in.%', '23514');

  insert into public.contacts (org_id, code, name, contact_type, custom_fields)
  values (v_org, 'C-NEW', 'Pelanggan Baru', 'customer',
          '{"cost_centre":"KL-02"}'::jsonb)
  returning id into v_c;
  perform pg_temp.check_eq('and with it, the record is written',
    (select custom_fields ->> 'cost_centre' from public.contacts where id = v_c),
    'KL-02');

  -- ARCHIVED IS NOT DELETED. The definition stays, so the value stays
  -- readable and the key stays known — it is only a key that was never
  -- defined that is refused.
  perform public.set_custom_field_active(v_org, 'contact', 'cost_centre', false);
  perform pg_temp.check_eq('an archived field keeps what was written in it',
    (select custom_fields ->> 'cost_centre' from public.contacts where id = v_c),
    'KL-02');
  update public.contacts set custom_fields =
    '{"cost_centre":"KL-03","note":"still fine"}'::jsonb where id = v_c;
  perform pg_temp.check_eq('and is still a key the guard knows',
    (select custom_fields ->> 'cost_centre' from public.contacts where id = v_c),
    'KL-03');
  perform pg_temp.check_refused('but an archived field is no longer typed loosely',
    format($q$update public.contacts set custom_fields =
             '{"cost_centre":5,"note":"x"}'::jsonb where id = %L$q$, v_c),
    'Cost centre is written in words.%', '22023');

  -- And archiving lifts the requirement, which is what archiving is for.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-THIRD', 'Pelanggan Ketiga', 'customer');
  perform pg_temp.check_eq('a field put away is no longer demanded',
    (select count(*) from public.contacts where org_id = v_org), 3);

  perform pg_temp.check_refused('a field nobody defined cannot be put away',
    format($q$select public.set_custom_field_active(
             %L, 'contact', 'no_such_field', false)$q$, v_org),
    'There is no field no_such_field on a contact here.%', 'P0002');
end $$;

-- ---------------------------------------------------------------------
-- 6. What a field holds cannot change underneath the values in it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tukar Jenis Sdn Bhd');
  v_c   uuid;
begin
  perform public.upsert_custom_field(v_org, 'contact', 'Reference');

  -- Nothing filled in yet: change it freely.
  perform public.upsert_custom_field(v_org, 'contact', 'Reference',
                                     'reference', 'number');
  perform pg_temp.check_eq('an empty field may still change what it holds',
    (select kind from public.custom_fields_def
      where org_id = v_org and key = 'reference'), 'number');

  insert into public.contacts (org_id, code, name, contact_type, custom_fields)
  values (v_org, 'C-1', 'Pelanggan', 'customer', '{"reference":42}'::jsonb)
  returning id into v_c;

  -- Once it holds something, no. Every value already written was
  -- written under the old rule.
  perform pg_temp.check_refused('a field in use may not change what it holds',
    format($q$select public.upsert_custom_field(
             %L, 'contact', 'Reference', 'reference', 'text')$q$, v_org),
    'Reference is already filled in on records of this company.%', '23514');

  -- The label may still change, because the label is not what the
  -- values mean.
  perform public.upsert_custom_field(v_org, 'contact', 'Their reference',
                                     'reference', 'number');
  perform pg_temp.check_eq('but its name may change whenever they like',
    (select label from public.custom_fields_def
      where org_id = v_org and key = 'reference'), 'Their reference');
end $$;

-- ---------------------------------------------------------------------
-- 7. Who may define one
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Siapa Boleh Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_stray uuid;
begin
  v_stray := pg_temp.another_user('orang.luar@contoh.test');
  perform pg_temp.sign_in_as(v_stray);
  perform pg_temp.check_refused('somebody outside the company defines nothing',
    format($q$select public.upsert_custom_field(%L, 'contact', 'Theirs')$q$,
           v_org),
    'not permitted to set up custom fields%', '42501');
  perform pg_temp.check_refused('nor puts one away',
    format($q$select public.set_custom_field_active(
             %L, 'contact', 'anything', false)$q$, v_org),
    'not permitted to set up custom fields%', '42501');
  perform pg_temp.check_refused('nor reads the list a company may fill in',
    format($q$select * from public.custom_field_lookup_options(%L, 'contact')$q$,
           v_org),
    'not a member of this company%', '42501');
  perform pg_temp.sign_in_as(v_owner);

  -- And the definitions themselves are readable by the company and
  -- writable through the function alone: no insert, update or delete
  -- policy exists on the table.
  perform pg_temp.check_eq('the definitions are written through the function only',
    (select count(*) from pg_policies
      where schemaname = 'public' and tablename = 'custom_fields_def'
        and cmd <> 'SELECT'), 0);
  perform pg_temp.check_true('and the read policy has the grant behind it',
    has_table_privilege('authenticated', 'public.custom_fields_def', 'SELECT')
    and has_table_privilege('authenticated', 'public.custom_field_entities',
                            'SELECT'));
end $$;

rollback;
