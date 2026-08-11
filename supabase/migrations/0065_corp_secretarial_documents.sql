-- =====================================================================
-- iAkauntan :: 0065 the document generator
--
-- The point of the module: a resolution that disagrees with the
-- register is worse than no resolution, because it looks authoritative.
-- So the merge values are read out of the registers rather than retyped
-- into a form.
-- =====================================================================

create or replace function app.corp_merge_context(p_entity_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  e public.corp_entities;
  v jsonb;
  v_directors text;
  v_secretaries text;
  v_members text;
  v_capital text;
begin
  select * into e from public.corp_entities where id = p_entity_id;
  if e.id is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;

  select string_agg(p.full_name || coalesce(' (' || p.nric || ')', ''), E'\n')
    into v_directors
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
   where o.entity_id = p_entity_id and o.role = 'director'
     and o.resigned_on is null;

  select string_agg(p.full_name ||
           coalesce(' (' || o.licence_body || ' ' || o.licence_no || ')', ''), E'\n')
    into v_secretaries
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
   where o.entity_id = p_entity_id and o.role = 'secretary'
     and o.resigned_on is null;

  select string_agg(format('%s — %s %s shares (%s%%)',
           r.member_name, to_char(r.shares, 'FM999,999,999,990'),
           r.share_class, to_char(r.percent, 'FM990.00')), E'\n')
    into v_members
    from public.corp_register_of_members(p_entity_id) r;

  select string_agg(format('%s: %s shares for %s',
           c.share_class, to_char(c.shares, 'FM999,999,999,990'),
           to_char(c.consideration, 'FM"RM "999,999,999,990.00')), E'\n')
    into v_capital
    from public.corp_issued_capital(p_entity_id) c;

  -- FM on the date masks: to_char pads month names to nine characters,
  -- so a plain 'DD Month YYYY' produces "12 March     2024" in the
  -- middle of a resolution.
  v := jsonb_build_object(
    'company_name',        e.name,
    'registration_no',     coalesce(e.registration_no, ''),
    'old_registration_no', coalesce(e.old_registration_no, ''),
    'entity_type',         case e.entity_type
                             when 'sdn_bhd' then 'Private company limited by shares (Sdn Bhd)'
                             when 'berhad'  then 'Public company (Berhad)'
                             when 'llp'     then 'Limited liability partnership (PLT)'
                             when 'clbg'    then 'Company limited by guarantee'
                             else initcap(replace(e.entity_type::text, '_', ' ')) end,
    'incorporated_on',     coalesce(to_char(e.incorporated_on, 'FMDD FMMonth YYYY'), ''),
    'registered_office',   coalesce(e.registered_office, ''),
    'business_address',    coalesce(e.business_address, ''),
    'nature_of_business',  coalesce(e.nature_of_business, ''),
    'financial_year_end',  coalesce(
        to_char(app.corp_fye(e, extract(year from current_date)::int),
                'FMDD FMMonth'), ''),
    'directors',           coalesce(v_directors, ''),
    'secretaries',         coalesce(v_secretaries, ''),
    'members',             coalesce(v_members, ''),
    'issued_capital',      coalesce(v_capital, ''),
    'today',               to_char(current_date, 'FMDD FMMonth YYYY'),
    'today_iso',           to_char(current_date, 'YYYY-MM-DD'));

  return v;
end;
$$;

-- Substitutes {{placeholder}} throughout. A placeholder with no value
-- is left standing rather than silently blanked: an empty line in a
-- resolution reads as deliberate, an obvious {{director_name}} does not.
create or replace function app.corp_render(p_body text, p_values jsonb)
returns text
language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare
  v_out text := p_body;
  k text;
begin
  for k in select jsonb_object_keys(p_values) loop
    if jsonb_typeof(p_values -> k) in ('object', 'array') then continue; end if;
    v_out := replace(v_out, '{{' || k || '}}', coalesce(p_values ->> k, ''));
  end loop;
  return v_out;
end;
$$;

create or replace function public.corp_generate_document(
  p_entity_id uuid, p_template_code text,
  p_extra jsonb default '{}'::jsonb, p_title text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  e public.corp_entities;
  t public.corp_templates;
  v_values jsonb;
  v_body text;
  v_id uuid;
begin
  select * into e from public.corp_entities where id = p_entity_id;
  if e.id is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;
  if not app.can_write(e.org_id) then
    raise exception 'Not permitted to generate documents' using errcode = '42501';
  end if;

  -- The firm's own version of a template wins over the platform's.
  select * into t from public.corp_templates
   where code = p_template_code and is_active
     and (org_id = e.org_id or org_id is null)
   order by org_id nulls last limit 1;
  if t.id is null then
    raise exception 'No template %', p_template_code using errcode = 'P0002';
  end if;
  if t.applies_to is not null and not (e.entity_type = any (t.applies_to)) then
    raise exception '% does not apply to a %', t.name, e.entity_type
      using errcode = '22023';
  end if;

  v_values := app.corp_merge_context(p_entity_id) || coalesce(p_extra, '{}'::jsonb);
  v_body := app.corp_render(t.body, v_values);

  insert into public.corp_documents
    (org_id, entity_id, template_code, title, body, merged_values, generated_by)
  values (e.org_id, p_entity_id, t.code,
          coalesce(p_title, t.name || ' — ' || e.name),
          v_body, v_values, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

-- Which placeholders a template uses, and whether the register can fill
-- them. Shown before generating, so a missing registered office is
-- caught before the document is signed rather than after.
create or replace function public.corp_template_placeholders(
  p_entity_id uuid, p_template_code text)
returns table (placeholder text, value text, is_filled boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  e public.corp_entities;
  t public.corp_templates;
  v_values jsonb;
begin
  select * into e from public.corp_entities where id = p_entity_id;
  if e.id is null or not app.is_org_member(e.org_id) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into t from public.corp_templates
   where code = p_template_code and is_active
     and (org_id = e.org_id or org_id is null)
   order by org_id nulls last limit 1;
  if t.id is null then
    raise exception 'No template %', p_template_code using errcode = 'P0002';
  end if;

  v_values := app.corp_merge_context(p_entity_id);

  return query
  select m.name,
         nullif(v_values ->> m.name, ''),
         coalesce(nullif(v_values ->> m.name, ''), '') <> ''
    from (select distinct (regexp_matches(t.body, '\{\{([a-z0-9_]+)\}\}', 'g'))[1] as name) m
   order by m.name;
end;
$$;
