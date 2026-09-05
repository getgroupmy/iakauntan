-- =====================================================================
-- 0543. Required is asked of a person, not of a document the software
--       raises
--
-- 0542 shipped `is_required` and enforced it on every write. That is
-- wrong, and the way it is wrong was found by asking the database
-- rather than by thinking about it:
--
--   select p.proname from pg_proc p
--    where p.prosrc ~ 'insert into public\.(items|employees|leads|...)'
--
-- FORTY-ONE FUNCTIONS create one of the eleven carriers. Not one of
-- them passes a custom field, because not one of them can — there is
-- nobody there to ask. `transfer_document` turns a quotation into an
-- invoice. `complete_pos_sale` raises the counter invoice.
-- `raise_recurring_document` raises this month's. `create_contact_as`
-- makes the customer record for a prospect. `hire_applicant` makes the
-- employee. `import_contacts` makes a hundred at once.
--
-- So on 0542's rule, a company that ticked "it has to be filled in" on
-- a sales document stopped being able to invoice a quotation, ring a
-- sale through the till, raise a standing order or credit an invoice —
-- all with the same message, none of it about the thing they had just
-- done. That is measured: the transfer fails with "Cost centre has to
-- be filled in" before this migration and succeeds after it.
--
-- THE RULE NOW: a row that arrives carrying no custom fields at all was
-- not filled in by anybody, and passes. The moment any are supplied the
-- whole set is held to the definitions — required included.
--
-- That is what makes it work from the form as well, and the other half
-- of it is in the app: `CustomFieldsSection` now always sends a key for
-- every REQUIRED field it drew, null where the box is empty. So a
-- person who leaves one blank sends `{"cost_centre": null}` and is
-- refused by the database, rather than sending `{}` and being refused
-- only by the form. The form is not the authority; it simply stops
-- hiding the question.
--
-- What this does not do is carry a quotation's custom fields onto the
-- invoice raised from it. That is still the open question 0542 named,
-- and it is still worth its own decision and its own assertion.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.custom_fields_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_entity text := tg_argv[0];
  v_ent    public.custom_field_entities;
  d        record;
  v_val    jsonb;
  v_empty  boolean;
  v_txt    text;
  v_id     uuid;
  v_ok     boolean;
  v_key    text;
begin
  -- A row whose custom fields nobody touched is a row that was already
  -- checked when they were written. Skipping it is what stops a field
  -- marked required today from freezing every record written before it
  -- existed. See the header: a required field applies to what is
  -- written next, not backwards over the year.
  if tg_op = 'UPDATE' and new.custom_fields is not distinct from old.custom_fields then
    return new;
  end if;

  if new.custom_fields is null then
    new.custom_fields := '{}'::jsonb;
  end if;
  if jsonb_typeof(new.custom_fields) <> 'object' then
    raise exception
      'The custom fields on a % are a set of named values, not a %.',
      v_entity, jsonb_typeof(new.custom_fields) using errcode = '22023';
  end if;

  -- A ROW THAT CARRIES NO CUSTOM FIELDS IS NOT SOMEBODY'S FORM.
  --
  -- 0542 asked for a required field here whatever wrote the row, and
  -- that was wrong in a way only measurement showed. FORTY-ONE
  -- functions in this schema create one of the eleven carriers —
  -- `transfer_document`, `complete_pos_sale`, `create_contact_as`,
  -- `create_ticket`, `open_matter`, `hire_applicant`, `import_contacts`,
  -- `raise_recurring_document`, `credit_sales_invoice`,
  -- `create_po_from_suggestions` and the rest — and not one of them
  -- passes custom fields, because none of them can: there is nobody
  -- there to ask.
  --
  -- So a company that ticked "it has to be filled in" on a sales
  -- document broke `transfer_document` with "Cost centre has to be
  -- filled in", and with it the till, the standing orders and the
  -- credit notes. Measured, not reasoned about: the fixture in
  -- `custom_fields_required.sql` fails on 0542's rule and passes on
  -- this one.
  --
  -- The rule that survives contact with those forty-one is the one a
  -- person would have written in the first place: REQUIRED IS ASKED OF
  -- SOMEBODY FILLING THE RECORD IN. A row that arrives carrying no
  -- custom fields at all was not filled in by anybody, and is let
  -- through. The moment any are supplied — which is every save from
  -- the form, because the section always sends its required keys — the
  -- whole set is held to the definitions.
  if new.custom_fields = '{}'::jsonb then
    return new;
  end if;

  -- A key nobody defined is a typo that would sit in the row for ever.
  for v_key in select jsonb_object_keys(new.custom_fields) loop
    if not exists (select 1 from public.custom_fields_def f
                    where f.org_id = new.org_id and f.entity = v_entity
                      and f.key = v_key) then
      raise exception
        '% is not a field on a % for this company.', v_key, v_entity
        using errcode = '23514';
    end if;
  end loop;

  for d in
    select * from public.custom_fields_def f
     where f.org_id = new.org_id and f.entity = v_entity
     order by f.sort_order, f.key
  loop
    v_val := new.custom_fields -> d.key;
    v_empty := v_val is null
            or jsonb_typeof(v_val) = 'null'
            or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '');

    if v_empty then
      if d.is_required and d.is_active then
        raise exception '% has to be filled in.', d.label
          using errcode = '23514';
      end if;
      continue;
    end if;

    if d.kind = 'text' then
      if jsonb_typeof(v_val) <> 'string' then
        raise exception '% is written in words.', d.label using errcode = '22023';
      end if;
      if d.max_length is not null
         and length(v_val #>> '{}') > d.max_length then
        raise exception
          '% is longer than the % characters allowed.', d.label, d.max_length
          using errcode = '22001';
      end if;

    elsif d.kind = 'number' then
      if jsonb_typeof(v_val) <> 'number' then
        raise exception
          '% is a number. Quotation marks round it make it words.', d.label
          using errcode = '22023';
      end if;
      if d.min_value is not null and (v_val #>> '{}')::numeric < d.min_value then
        raise exception '% cannot be less than %.', d.label, d.min_value
          using errcode = '23514';
      end if;
      if d.max_value is not null and (v_val #>> '{}')::numeric > d.max_value then
        raise exception '% cannot be more than %.', d.label, d.max_value
          using errcode = '23514';
      end if;

    elsif d.kind = 'boolean' then
      if jsonb_typeof(v_val) <> 'boolean' then
        raise exception '% is yes or no.', d.label using errcode = '22023';
      end if;

    elsif d.kind = 'date' then
      if jsonb_typeof(v_val) <> 'string' then
        raise exception '% is a date, written as text.', d.label
          using errcode = '22023';
      end if;
      begin
        perform (v_val #>> '{}')::date;
      exception when others then
        raise exception
          '% is a date. "%" is not one — write it as YYYY-MM-DD.',
          d.label, v_val #>> '{}' using errcode = '22007';
      end;

    elsif d.kind = 'select' then
      if jsonb_typeof(v_val) <> 'string'
         or not exists (select 1 from jsonb_array_elements_text(d.options) o
                         where o = v_val #>> '{}') then
        raise exception
          '"%" is not one of the choices for %.', v_val #>> '{}', d.label
          using errcode = '23514';
      end if;

    elsif d.kind = 'lookup' then
      -- THE ONE THAT CANNOT LIVE IN A FORM. jsonb has no foreign keys,
      -- so without this a company could store another company's
      -- contact id and read its name back through the picker. 0512 had
      -- to hold every column that names a contact to one company's
      -- contacts; this is that rule for a column the company invented.
      if jsonb_typeof(v_val) <> 'string' then
        raise exception '% names a record, by its id.', d.label
          using errcode = '22023';
      end if;
      v_txt := v_val #>> '{}';
      begin
        v_id := v_txt::uuid;
      exception when others then
        raise exception '"%" is not a record id for %.', v_txt, d.label
          using errcode = '22P02';
      end;

      select * into v_ent from public.custom_field_entities
       where entity = d.target_entity;
      execute format(
        'select exists (select 1 from public.%I t'
        '                where t.id = $1 and t.org_id = $2 %s)',
        v_ent.table_name,
        case when v_ent.deleted_column is null then ''
             else format('and t.%I is null', v_ent.deleted_column) end)
        into v_ok using v_id, new.org_id;

      if not v_ok then
        raise exception
          '% points at a % this company does not have.', d.label, v_ent.label
          using errcode = '23503';
      end if;
    end if;
  end loop;

  return new;
end;
$function$;

comment on function app.custom_fields_guard() is
  'Holds one company''s custom field values to the definitions it wrote. A row carrying no custom fields at all was written by the software rather than by somebody filling a form in, and is let through; anything else is held to every rule, required included.';
