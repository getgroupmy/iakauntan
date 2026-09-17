-- =====================================================================
-- iAkauntan :: the short lists you can add to from the box
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/quick_add_lists.sql
--
-- `Repo.createQuickRow` writes ONE SHAPE of row -- org_id, code, name --
-- to nine tables, and the whole design rests on a claim about those
-- tables: that nothing else about them is required. A migration that
-- later adds a NOT NULL column with no default to any of them turns
-- every "Add …" offer in the product into a 400 at the moment somebody
-- is mid-invoice, and nothing in the Dart would say so.
--
-- So the claim is asserted here, against `information_schema`, for each
-- table `app/lib/src/data/models.dart :: quickAddTables` names. And
-- separately: that an insert of exactly that shape SUCCEEDS as
-- `authenticated`, because a required column is only half of what can
-- refuse a row -- row level security is the other half, and the suite
-- connects as `postgres`, which bypasses it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

do $$
declare
  -- The tables `quickAddTables` names, and whether each has a code.
  -- Kept in this order so a reader can diff the two lists by eye.
  v_tables text[] := array[
    'projects', 'departments', 'price_levels', 'leave_types',
    'claim_types', 'ticket_categories', 'pos_outlets', 'pipelines',
    'item_categories'
  ];
  v_coded  boolean[] := array[
    true, true, true, true, true, true, true, false, true
  ];
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_table  text;
  v_extra  text;
  v_role   text;
  v_n      integer;
  v_i      integer;
  v_other  uuid;
  v_ok     boolean;
begin
  v_org := pg_temp.test_org('Kedai Senarai Pendek Sdn Bhd');
  perform pg_temp.sign_in_as(v_me);

  for v_i in 1 .. array_length(v_tables, 1) loop
    v_table := v_tables[v_i];

    -- 1. The table exists. A renamed table is the other way this rots.
    perform pg_temp.check_eq(
      format('%s is a table', v_table),
      (select count(*)::numeric from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = v_table
         and c.relkind = 'r'), 1);

    -- 2. Nothing beyond org_id, code and name is required of it.
    select string_agg(column_name, ', ' order by column_name)
      into v_extra
      from information_schema.columns
     where table_schema = 'public'
       and table_name = v_table
       and is_nullable = 'NO'
       and column_default is null
       and is_identity = 'NO'
       and column_name not in ('org_id', 'code', 'name');

    perform pg_temp.check_true(
      format('%s requires nothing beyond org_id, code and name%s',
             v_table, coalesce(' -- but wants ' || v_extra, '')),
      v_extra is null);

    -- 3. And it has the columns the writer sends.
    perform pg_temp.check_eq(
      format('%s has a name column', v_table),
      (select count(*)::numeric from information_schema.columns
        where table_schema = 'public' and table_name = v_table
          and column_name = 'name'), 1);
    perform pg_temp.check_eq(
      format('%s has a code column: %s', v_table, v_coded[v_i]),
      (select count(*)::numeric from information_schema.columns
        where table_schema = 'public' and table_name = v_table
          and column_name = 'code'),
      case when v_coded[v_i] then 1 else 0 end);
  end loop;

  -- ---------------------------------------------------------------
  -- And the write itself, under row level security
  --
  -- The suite connects as `postgres`, a superuser, which does not
  -- consult a policy at all. Without `set local role authenticated`
  -- this block would assert that a superuser can insert -- which is
  -- true of every table and says nothing about the product.
  -- ---------------------------------------------------------------
  for v_i in 1 .. array_length(v_tables, 1) loop
    v_table := v_tables[v_i];
    begin
      set local role authenticated;
      v_role := current_user;
      if v_coded[v_i] then
        execute format(
          'insert into public.%I (org_id, code, name) values ($1, $2, $3)',
          v_table) using v_org, 'QA' || v_i, 'Added from the box';
      else
        execute format(
          'insert into public.%I (org_id, name) values ($1, $2)',
          v_table) using v_org, 'Added from the box';
      end if;
    end;
    reset role;

    execute format(
      'select count(*) from public.%I where org_id = $1 '
      'and name = ''Added from the box''', v_table)
      into v_n using v_org;
    perform pg_temp.check_eq(
      format('a member may add a row to %s', v_table), v_n::numeric, 1);
  end loop;

  perform pg_temp.check_eq(
    'and every one of those inserts ran under row level security',
    v_role, 'authenticated');

  -- And the control, without which "a member may add a row" is
  -- satisfied by a policy that lets ANYBODY add one. A company this
  -- person is not a member of has to refuse the same insert.
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Syarikat Lain Sdn Bhd',
          'lain-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          pg_temp.another_user('lain@senarai.test'))
  returning id into v_other;

  begin
    begin
      set local role authenticated;
      insert into public.projects (org_id, code, name)
      values (v_other, 'QAX', 'Not mine');
    end;
    reset role;
    v_ok := true;
  exception when others then
    reset role;
    v_ok := false;
  end;
  perform pg_temp.check_true(
    'and a company I am not a member of refuses the same insert', not v_ok);

  raise notice 'quick_add_lists.sql: all assertions passed';
end $$;

rollback;
