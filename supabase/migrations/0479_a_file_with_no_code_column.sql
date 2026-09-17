-- ---------------------------------------------------------------------
-- 0479  A file with no code column
-- ---------------------------------------------------------------------
-- `import_contacts` has refused a row with no code since 0103: "No
-- code. Every contact needs one, and it is what an invoice will refer
-- to." True, and the wrong person is being asked to supply it. The
-- code is a number this system draws -- C-2026-00013, S-2026-00001,
-- P-2026-00343 since 0477 -- and the file somebody exports from a
-- spreadsheet of prospects, or from a system that numbered nothing,
-- has no column to put in it. They were typing three hundred codes by
-- hand to get past the refusal, or numbering the column themselves and
-- landing on codes the counter would draw next week.
--
-- ### What changes
--
--   * A row with no code validates. The preview says what it will get
--     -- "No code in the file. The next P-YYYY-NNNNN is drawn when the
--     file is imported." -- and draws nothing, so a preview run twice
--     numbers nothing twice. The shape is the organization's own
--     counter's: its prefix, its reset policy, its padding, or the
--     defaults of a counter that does not exist yet.
--   * On import, the code is drawn from the series of the row's type,
--     `app.contact_series`, so a file of suppliers is coded S- and a
--     file of prospects P-, the same as a record typed into the editor
--     or made by `create_contact_as`. The answer the import returns
--     carries the code drawn, and says it was drawn, so the person who
--     pasted the file can see what their rows were called.
--   * Rows that brought a code are written first, then the rows that
--     did not. A typed code can sit where the counter lands next --
--     0116's collision -- and the drawn row retries past it, as
--     `create_contact_as` does; done the other way round, the drawn row
--     would take the code and the typed row, which validated, would
--     fail the whole file on the unique index.
--
-- ### A refusal that came too late
--
-- The check that a code "is already a contact here" looked only at
-- live rows, and `contacts (org_id, code)` is unique over deleted rows
-- too. A code a deleted contact still holds passed the preview and
-- failed the import on the index, with the index's message -- which
-- names no row. It is refused at preview now, and says why: the code
-- is taken by a record that was deleted, and needs a different one.
--
-- ### What stays
--
--   * A row with no name is still refused, and says "No name" -- not
--     "No code", which the old order of checks would have said first.
--   * A code typed twice in one file is still refused as a duplicate.
--     Two rows with no code are not duplicates of each other.
--   * All of it or none of it. A file with one bad row writes nothing,
--     and draws nothing: the counter is only touched on commit, and an
--     exception after that rolls the counter back with everything else.
--
-- ### Mutants
--
-- Each restated into a built database and run against
-- `supabase/tests/contact_import_codes.sql`:
--
--   * the code drawn from `'contact'` regardless of type -- killed by
--     "a supplier is coded in the S- series";
--   * the preview drawing the code too (calling the counter in the
--     validation loop) -- killed by "and the preview drew nothing";
--   * the blank rows written first -- killed by "the typed code keeps
--     its number and the drawn row goes past it";
--   * the retry dropped -- killed by the same assertion, which fails
--     the whole file on the index instead;
--   * `deleted_at is null` put back on the already-here check -- killed
--     by "a code a deleted contact still holds is refused at preview";
--   * the returned code left blank on a drawn row -- killed by "the
--     answer carries the code drawn".
-- ---------------------------------------------------------------------

-- The shape of the next code in a series, for the sentence the preview
-- prints. The organization's counter if it has one; the defaults the
-- counter is created with if it does not, which is what
-- `next_document_number_internal` would do on first use.
create or replace function app.contact_code_shape(
  p_org_id uuid, p_type app.contact_type)
returns text
language sql stable
set search_path = public, app, pg_temp as $$
  select coalesce(s.prefix, app.default_doc_prefix(t.series))
      || case coalesce(s.reset_policy, 'yearly')
           when 'yearly' then 'YYYY-'
           when 'monthly' then 'YYYYMM-'
           else '' end
      || repeat('N', coalesce(s.padding, 5))
      || coalesce(s.suffix, '')
    from (select app.contact_series(p_type) as series) t
    left join public.number_sequences s
      on s.org_id = p_org_id and s.doc_type = t.series;
$$;

comment on function app.contact_code_shape(uuid, app.contact_type) is
  'What the next code drawn for a contact of this type looks like -- '
  'P-YYYY-NNNNN -- read from the organization''s counter, or from the '
  'defaults a counter starts with. For sentences; draws nothing. See 0479.';

revoke all on function app.contact_code_shape(uuid, app.contact_type)
  from public, anon;

-- Restated from 0471; the changes are the blank code, the order the
-- rows are written in, and the check against deleted rows.
CREATE OR REPLACE FUNCTION public.import_contacts(p_org_id uuid, p_rows jsonb, p_commit boolean DEFAULT false)
 RETURNS TABLE(row_no integer, code text, status text, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r jsonb;
  i integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_seen text[] := '{}';
  v_bad integer := 0;
  v_code text; v_name text; v_type text; v_currency text;
  v_country text; v_state text; v_limit numeric; v_problem text;
  v_note text;
  v_taken public.contacts;
  v_drawn boolean;
  v_attempt integer;
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
    v_note := null;

    v_code := app.import_text(r, 'code');
    v_name := app.import_text(r, 'name');
    v_type := lower(coalesce(app.import_text(r, 'contact_type'), 'customer'));
    v_currency := upper(coalesce(app.import_text(r, 'currency'), 'MYR'));
    v_country := upper(coalesce(app.import_text(r, 'country_code'), 'MYS'));
    v_state := upper(coalesce(app.import_text(r, 'state_code'), ''));
    v_limit := app.import_number(app.import_text(r, 'credit_limit'));

    -- A code the file brought is checked against the file and the
    -- table. A code the file did not bring is drawn on import, and
    -- there is nothing to check it against yet.
    if v_code is not null then
      select * into v_taken from public.contacts c
       where c.org_id = p_org_id and lower(c.code) = lower(v_code)
       order by (c.deleted_at is null) desc
       limit 1;
    else
      v_taken := null;
    end if;

    if v_name is null then
      v_problem := 'No name.';
    elsif v_code is not null and lower(v_code) = any (v_seen) then
      -- Caught here rather than by the unique index, because the index
      -- would fail the whole import on the second occurrence without
      -- saying which two rows clashed.
      v_problem := format('The code %s is in this file more than once.', v_code);
    elsif v_taken.id is not null and v_taken.deleted_at is null then
      v_problem := format('%s is already a contact here.', v_code);
    elsif v_taken.id is not null then
      -- The index is over deleted rows too. Refused here, naming the
      -- row, rather than on import by an index that names nothing.
      v_problem := format(
        '%s was %s, a contact here that has been deleted, and a deleted '
        'contact keeps its code. Give this row a different one, or leave '
        'it blank and one is drawn.', v_code, v_taken.name);
    elsif not exists (
      select 1 from unnest(enum_range(null::app.contact_type)) t
       where t::text = v_type) then
      -- Read out of the type rather than typed here again. The list was
      -- five names hardcoded, and the message named three of them; a
      -- sixth was added by 0471 and neither would have known. Now the
      -- type is the only place the answer lives.
      v_problem := format(
        '"%s" is not a contact type. Use one of: %s.', v_type,
        (select string_agg(t::text, ', ' order by t::text)
           from unnest(enum_range(null::app.contact_type)) t));
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
    elsif v_code is null then
      -- Not a problem; the sentence that says what the row will get.
      -- After the type check, because the shape is the type's.
      v_note := format(
        'No code in the file. The next %s is drawn when the file is imported.',
        app.contact_code_shape(p_org_id, v_type::app.contact_type));
    end if;

    if v_problem is null then
      if v_code is not null then
        v_seen := v_seen || lower(v_code);
      end if;
    else
      v_bad := v_bad + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row_no', i,
      'code', coalesce(v_code, ''),
      'status', case when v_problem is null then 'ok' else 'error' end,
      'message', coalesce(v_problem, v_note, ''));
  end loop;

  -- All of it or none of it.
  if p_commit and v_bad > 0 then
    raise exception
      'Nothing was imported: % of % rows have a problem. Fix the file and '
      'run it again.', v_bad, i using errcode = '22023';
  end if;

  if p_commit then
    -- Two passes: the rows that brought a code, then the rows that did
    -- not. A typed code can sit where the counter lands next, and the
    -- drawn row is the one that can step past it.
    for v_drawn in select unnest(array[false, true])
    loop
      i := 0;
      for r in select * from jsonb_array_elements(p_rows)
      loop
        i := i + 1;
        v_code := app.import_text(r, 'code');
        if (v_code is null) <> v_drawn then
          continue;
        end if;
        v_type := lower(coalesce(app.import_text(r, 'contact_type'), 'customer'));

        -- The retry 0116 explains: the counter does not look at the
        -- table. Every attempt takes the next number, so the second is
        -- a different code by construction. Only a drawn code retries;
        -- a typed one that collides is a real refusal, and the preview
        -- has already said so for every case but a race.
        for v_attempt in 1 .. 5 loop
          if v_drawn then
            v_code := app.next_document_number_internal(
              p_org_id, app.contact_series(v_type::app.contact_type));
          end if;
          begin
            insert into public.contacts (
              org_id, code, name, legal_name, contact_type,
              tin, registration_no, sst_registration_no,
              email, phone, mobile, website,
              address_line1, address_line2, address_line3,
              postcode, city, state_code, country_code,
              currency, credit_limit, notes)
            values (
              p_org_id,
              v_code,
              app.import_text(r, 'name'),
              app.import_text(r, 'legal_name'),
              v_type::app.contact_type,
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
            exit;
          exception when unique_violation then
            if not v_drawn or v_attempt >= 5 then
              raise;
            end if;
          end;
        end loop;

        if v_drawn then
          -- The answer carries the code the row was given, and says
          -- that it was given rather than brought.
          v_results := jsonb_set(
            jsonb_set(v_results, array[(i - 1)::text, 'code'], to_jsonb(v_code)),
            array[(i - 1)::text, 'message'],
            to_jsonb('No code in the file; this one was drawn.'::text));
        end if;
      end loop;
    end loop;

    v_results := (
      select jsonb_agg(jsonb_set(x, '{status}', '"imported"'))
        from jsonb_array_elements(v_results) x);
  end if;

  return query
    select (x ->> 'row_no')::integer, x ->> 'code', x ->> 'status', x ->> 'message'
      from jsonb_array_elements(v_results) x
     order by 1;
end; $function$;

comment on function public.import_contacts(uuid, jsonb, boolean) is
  'Validate (p_commit false) or write (p_commit true) a pasted contact '
  'list. All rows or none. A row with no code is coded on import from '
  'the series of its type -- C-, S- or P-YYYY-NNNNN -- and the preview '
  'says so without drawing one. See 0103, 0471 and 0479.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('public.import_contacts(uuid, jsonb, boolean)'));
begin
  -- The code is drawn from the row's series, not from one series.
  if position('app.contact_series(v_type::app.contact_type)' in v_src) = 0 then
    raise exception '0479: import_contacts does not draw from the row''s series';
  end if;
  -- And drawn on commit, not on preview: the counter is named once.
  if (length(v_src) - length(replace(v_src, 'app.next_document_number_internal', '')))
       / length('app.next_document_number_internal') <> 1 then
    raise exception '0479: the counter is called other than once in import_contacts';
  end if;
  -- The preview names the shape.
  if position('app.contact_code_shape' in v_src) = 0 then
    raise exception '0479: the preview does not say what a blank code gets';
  end if;
  -- The old refusal is gone.
  if position('Every contact needs one' in v_src) > 0 then
    raise exception '0479: a blank code is still refused';
  end if;
  -- Deleted rows are in the already-here check.
  if position('has been deleted' in v_src) = 0 then
    raise exception '0479: a deleted contact''s code is not refused at preview';
  end if;
  -- The shape reads the counter and falls back to the defaults.
  if position('number_sequences' in pg_get_functiondef(
       to_regprocedure('app.contact_code_shape(uuid, app.contact_type)'))) = 0
     or position('default_doc_prefix' in pg_get_functiondef(
       to_regprocedure('app.contact_code_shape(uuid, app.contact_type)'))) = 0 then
    raise exception '0479: contact_code_shape does not read the counter and its default';
  end if;
  -- Who may call what.
  if not has_function_privilege('authenticated',
       'public.import_contacts(uuid, jsonb, boolean)', 'execute') then
    raise exception '0479: authenticated lost import_contacts';
  end if;
  if has_function_privilege('anon',
       'public.import_contacts(uuid, jsonb, boolean)', 'execute') then
    raise exception '0479: anon can call import_contacts';
  end if;
  if has_function_privilege('anon',
       'app.contact_code_shape(uuid, app.contact_type)', 'execute') then
    raise exception '0479: anon can call contact_code_shape';
  end if;
end $do$;
