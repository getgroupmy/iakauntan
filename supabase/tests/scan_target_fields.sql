-- =====================================================================
-- iAkauntan :: the columns each destination actually wants
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scan_target_fields.sql
--
-- `0681` built `scan_target_fields` so a reader could be handed a
-- destination's own columns. `0710` populated it, four migrations and
-- two bug reports later -- until then only `accounting.bank_statement`
-- had any, so every other document fell through to one fixed invoice
-- schema and `scan_extraction_targets` offered the model a choice of
-- one.
--
-- What is asserted, and the first is the one that matters most:
--
--   * EVERY COLUMN NAMED IS A REAL COLUMN on the destination's table.
--     A field list is a promise that what comes back can be written
--     somewhere, and a typo in it is a value the reader worked for and
--     the app silently drops. Walked, not listed, so a column renamed
--     tomorrow is caught here rather than in production;
--
--   * every active destination has fields at all, because
--     `scan_extraction_targets` drops one that has none -- which is
--     invisible: the target simply stops being offered;
--
--   * a payment voucher goes somewhere;
--
--   * and nobody asks the reader for a key it cannot know, or for a
--     sales document's own number.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_bad   text;
  v_n     integer;
  v_keys  text;
begin
  -- ------------------------------------------------------------------
  -- 1. Every field names a column that exists
  -- ------------------------------------------------------------------
  select string_agg(format('%s.%s wants %I.%I', f.module_code, f.action,
                           t.table_name, f.column_name), '; ')
    into v_bad
    from public.scan_target_fields f
    join public.scan_targets t
      on t.module_code = f.module_code and t.action = f.action
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public'
                        and c.table_name = t.table_name
                        and c.column_name = f.column_name);
  if v_bad is not null then
    raise exception 'FAIL a scan target asks for a column that does not '
      'exist: %', v_bad using errcode = 'P0004';
  end if;
  perform pg_temp.check_true('every field names a real column', true);

  -- ------------------------------------------------------------------
  -- 2. Every active destination has some
  --
  -- `scan_extraction_targets` drops a target with no fields, and the
  -- only symptom is that the reader is never offered it. That is how
  -- six of the seven went missing for four migrations.
  -- ------------------------------------------------------------------
  select string_agg(t.module_code || '.' || t.action, ', ')
    into v_bad
    from public.scan_targets t
   where t.is_active
     and not exists (select 1 from public.scan_target_fields f
                      where f.module_code = t.module_code
                        and f.action = t.action);
  if v_bad is not null then
    raise exception 'FAIL an active destination has no fields, so the '
      'reader is never offered it: %', v_bad using errcode = 'P0004';
  end if;

  select count(*) into v_n from public.scan_targets where is_active;
  perform pg_temp.check_eq('and every active one reaches the reader',
    jsonb_array_length(public.scan_extraction_targets()), v_n);

  -- And one with NO fields is still dropped, which is the mechanism
  -- that hid six destinations for four migrations without a word. The
  -- assertion above cannot see it -- every target has fields now, so
  -- the filter is never exercised by the real data -- so this makes
  -- the case on purpose and rolls it back with everything else.
  insert into public.scan_targets
    (module_code, action, label, table_name, destination, hint,
     sort_order, is_active, repeats)
  values ('accounting', 'nothing_asked_for', 'A target nobody described',
          'expenses', 'expense', 'Has no fields, so nothing should offer '
          'it.', 999, true, false);
  perform pg_temp.check_eq('a destination with no fields is not offered',
    jsonb_array_length(public.scan_extraction_targets()), v_n);

  -- Give it one, and it appears. Both halves, or "is not offered" is
  -- satisfied by a function that offers nothing at all.
  insert into public.scan_target_fields
    (module_code, action, column_name, description, sort_order)
  values ('accounting', 'nothing_asked_for', 'reference',
          'Anything at all.', 10);
  perform pg_temp.check_eq('and appears the moment it has one',
    jsonb_array_length(public.scan_extraction_targets()), v_n + 1);

  delete from public.scan_target_fields
   where action = 'nothing_asked_for';
  delete from public.scan_targets where action = 'nothing_asked_for';

  -- EQUIVALENT MUTANT, written down rather than left as a survivor:
  -- changing that filter's `exists (select 1 ...)` to `select 0` does
  -- not fail anything, because EXISTS ignores the select list entirely
  -- -- `select 0` and `select 1` are the same test for "is there a
  -- row". There is nothing to assert about it.

  -- ------------------------------------------------------------------
  -- 3. Nothing asks the reader for something it cannot know
  --
  -- A uuid is not on the page. A column it can only guess at is a
  -- column it will fill with something.
  -- ------------------------------------------------------------------
  select string_agg(format('%s.%s.%s', f.module_code, f.action,
                           f.column_name), ', ')
    into v_bad
    from public.scan_target_fields f
    join public.scan_targets t
      on t.module_code = f.module_code and t.action = f.action
    join information_schema.columns c
      on c.table_schema = 'public' and c.table_name = t.table_name
     and c.column_name = f.column_name
   where c.udt_name = 'uuid';
  if v_bad is not null then
    raise exception 'FAIL the reader is asked for a key it cannot know: %',
      v_bad using errcode = 'P0004';
  end if;
  perform pg_temp.check_true('nothing asks for a uuid', true);

  -- ------------------------------------------------------------------
  -- 4. The sales document's own number is not asked for
  --
  -- It is this company's own sequence, drawn when the invoice is
  -- saved. `scan_field_map.dart` has refused to write the READ number
  -- there since it was written, because filing a customer's reference
  -- as our invoice number surfaces months later in an aged receivables
  -- listing. Asking for it would put it back within reach.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a sales document''s own number is not asked for',
    (select count(*)::numeric from public.scan_target_fields
      where module_code = 'sales' and column_name = 'doc_no'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 5. A payment voucher goes somewhere
  --
  -- The kind has existed since `0614` and pointed at no target, so
  -- choosing it placed the document nowhere. It is an expense: a
  -- company's own record of money paid out.
  -- ------------------------------------------------------------------
  select target_module || '.' || target_action into v_keys
    from public.scan_document_kinds where code = 'payment_voucher';
  perform pg_temp.check_eq('a payment voucher becomes an expense',
    v_keys, 'accounting.expense');

  select string_agg(code, ', ') into v_bad
    from public.scan_document_kinds
   where is_active and target_module is not null
     and not exists (select 1 from public.scan_targets t
                      where t.module_code = target_module
                        and t.action = target_action
                        and t.is_active);
  if v_bad is not null then
    raise exception 'FAIL a kind points at a destination that is not '
      'there: %', v_bad using errcode = 'P0004';
  end if;
  perform pg_temp.check_true('and every kind that names a destination '
    'names a real one', true);

  -- ------------------------------------------------------------------
  -- 6. The expense's wording is what every destination gets
  --
  -- `targetSchema` builds ONE flat map across the non-repeating
  -- targets and keeps the first description it sees for a name.
  -- Targets arrive ordered by key, so `accounting.expense` decides the
  -- wording of every column it shares. Those four are written to read
  -- true of any document, and this is what says so out loud.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true(
    'the shared columns are described for any document, not for an expense',
    (select bool_and(description not ilike '%this expense%'
                 and description not ilike '%the expense%')
       from public.scan_target_fields
      where module_code = 'accounting' and action = 'expense'
        and column_name in ('currency', 'tax_amount', 'total_amount',
                            'reference')));

  perform pg_temp.check_eq('and the expense sorts before the rest',
    (select min(module_code || '.' || action) from public.scan_targets
      where is_active and (module_code, action) <> ('accounting',
                                                    'bank_statement')),
    'accounting.expense');

  -- ------------------------------------------------------------------
  -- 7. One destination's fields are not another's
  --
  -- `scan_target_columns` is the console's picker, and it joins the
  -- configured fields to the real columns with a FULL OUTER JOIN --
  -- which keeps an unmatched right-hand row whatever the ON clause
  -- says. With the target predicates in that ON clause, every field of
  -- every OTHER destination came back as a column of this one, marked
  -- "configured and no longer on the table".
  --
  -- Nothing could see it while the bank statement was the only target
  -- with fields: there was nothing to leak from. `0710` moved the
  -- filter; this is what keeps it moved.
  -- ------------------------------------------------------------------
  insert into public.platform_admins (user_id)
  values (pg_temp.test_user()) on conflict do nothing;
  perform pg_temp.sign_in_as(pg_temp.test_user());

  select string_agg(column_name, ', ') into v_bad
    from public.scan_target_columns('accounting', 'bank_statement')
   where is_asked
     and column_name not in (select column_name
                               from public.scan_target_fields
                              where module_code = 'accounting'
                                and action = 'bank_statement');
  if v_bad is not null then
    raise exception 'FAIL another destination''s fields are listed as '
      'this one''s: %', v_bad using errcode = 'P0004';
  end if;

  select count(*) into v_n
    from public.scan_target_columns('accounting', 'bank_statement')
   where not still_there;
  perform pg_temp.check_eq('and no column is reported as vanished that '
    'never belonged here', v_n, 0);

  raise notice 'scan target fields: every destination asks for its own';
end $$;

rollback;
