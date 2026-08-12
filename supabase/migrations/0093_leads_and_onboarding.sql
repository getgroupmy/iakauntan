-- The top of the sales funnel, and the first fortnight of a job.
--
-- `leads` has a table, RLS and no screen, so the CRM starts at the
-- opportunity — which is to say it starts after somebody has already
-- decided the enquiry is real. `onboarding_templates`,
-- `onboarding_template_items`, `onboarding_checklists` and
-- `onboarding_tasks` are a complete four-table design that nothing can
-- create a row in.
--
-- Both gaps are mostly missing screens, but each has one step that is
-- more than an insert and belongs in the database.

-- ---------------------------------------------------------------------
-- Converting a lead
--
-- A lead becomes a contact, and usually an opportunity at the same
-- time. Doing that from the client means three writes that can half
-- succeed: a contact created, the lead not stamped, and the next person
-- converting it again into a second contact for the same company.
--
-- The lead is kept, not deleted. `converted_contact_id` is how "where
-- did this customer come from" gets answered a year later, and
-- `source` on the lead is the only record of which campaign paid for
-- them.
-- ---------------------------------------------------------------------
create or replace function public.convert_lead(
  p_lead_id uuid,
  p_create_opportunity boolean default true,
  p_pipeline_id uuid default null,
  p_amount numeric default null,
  p_expected_close_date date default null)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_lead        public.leads;
  v_contact     uuid;
  v_opportunity uuid;
  v_pipeline    uuid;
  v_stage       uuid;
  v_probability numeric(5, 2);
  v_name        text;
begin
  select * into v_lead from public.leads where id = p_lead_id;
  if v_lead.id is null then
    raise exception 'Lead not found' using errcode = 'P0002';
  end if;
  if not app.can_write(v_lead.org_id) then
    raise exception 'Insufficient privileges to convert a lead'
      using errcode = '42501';
  end if;
  if v_lead.converted_contact_id is not null then
    raise exception 'This lead was already converted' using errcode = '22023';
  end if;
  if v_lead.status = 'lost' then
    raise exception 'A lost lead cannot be converted; reopen it first'
      using errcode = '22023';
  end if;

  -- A lead may be a company, a person, or a person at a company. The
  -- contact takes whichever name there is, because a customer called
  -- "  " helps nobody.
  v_name := coalesce(
    nullif(btrim(v_lead.company_name), ''),
    nullif(btrim(concat_ws(' ', v_lead.first_name, v_lead.last_name)), ''));
  if v_name is null then
    raise exception 'This lead has neither a company nor a person to name a customer after'
      using errcode = '23514';
  end if;

  insert into public.contacts (
    org_id, code, name, contact_type, email, phone, mobile,
    address_line1, address_line2, city, postcode, state_code, country_code)
  values (
    v_lead.org_id,
    app.next_document_number_internal(v_lead.org_id, 'contact'),
    v_name, 'customer', v_lead.email, v_lead.phone, v_lead.mobile,
    v_lead.address_line1, v_lead.address_line2, v_lead.city,
    v_lead.postcode, v_lead.state_code, v_lead.country_code)
  returning id into v_contact;

  -- The named person becomes a contact person rather than being lost.
  -- This is the row the e-Invoice preparation and every delivery note
  -- reach for, and until 0092 nothing could create one.
  if nullif(btrim(concat_ws(' ', v_lead.first_name, v_lead.last_name)), '')
     is not null
     and nullif(btrim(v_lead.company_name), '') is not null then
    insert into public.contact_persons (
      org_id, contact_id, name, designation, email, phone, mobile, is_primary)
    values (
      v_lead.org_id, v_contact,
      btrim(concat_ws(' ', v_lead.first_name, v_lead.last_name)),
      v_lead.designation, v_lead.email, v_lead.phone, v_lead.mobile, true);
  end if;

  if p_create_opportunity then
    select coalesce(p_pipeline_id,
             (select id from public.pipelines
               where org_id = v_lead.org_id and is_active
               order by is_default desc, sort_order limit 1))
      into v_pipeline;

    if v_pipeline is null then
      raise exception 'No pipeline to open an opportunity in'
        using errcode = '23514';
    end if;

    -- The first open stage, not simply the first: a pipeline whose
    -- lowest sort_order is "Closed lost" would otherwise open every
    -- converted lead as already dead.
    select s.id, s.probability into v_stage, v_probability
      from public.pipeline_stages s
     where s.pipeline_id = v_pipeline and s.stage_type = 'open'
     order by s.sort_order limit 1;

    if v_stage is null then
      raise exception 'That pipeline has no open stage to start in'
        using errcode = '23514';
    end if;

    insert into public.opportunities (
      org_id, opportunity_no, name, contact_id, lead_id,
      pipeline_id, stage_id, amount, currency, probability,
      expected_close_date, source, owner_id, created_by)
    values (
      v_lead.org_id,
      app.next_document_number_internal(v_lead.org_id, 'opportunity'),
      v_name, v_contact, v_lead.id, v_pipeline, v_stage,
      coalesce(p_amount, v_lead.estimated_value, 0), v_lead.currency,
      coalesce(v_probability, 0), p_expected_close_date, v_lead.source,
      coalesce(v_lead.owner_id, auth.uid()), auth.uid())
    returning id into v_opportunity;
  end if;

  update public.leads
     set status = 'converted',
         converted_contact_id = v_contact,
         converted_opportunity_id = v_opportunity,
         converted_at = now(),
         last_activity_at = now()
   where id = p_lead_id;

  return jsonb_build_object(
    'contact_id', v_contact,
    'opportunity_id', v_opportunity);
end;
$$;

-- ---------------------------------------------------------------------
-- Starting somebody's onboarding
--
-- The template holds offsets — "IT account, day 0", "EPF registration,
-- day 3" — and the checklist turns them into dates against a start.
-- Copying rather than referencing is deliberate: editing the template
-- next year must not silently move the due dates of an onboarding that
-- finished last year, or resurrect a task somebody deleted.
-- ---------------------------------------------------------------------
create or replace function public.start_onboarding(
  p_employee_id uuid,
  p_template_id uuid default null,
  p_start_date date default null,
  p_kind text default 'onboarding')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org       uuid;
  v_hire      date;
  v_checklist uuid;
  v_start     date;
  v_n         integer;
begin
  select org_id, hire_date into v_org, v_hire
    from public.employees where id = p_employee_id;
  if v_org is null then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_org) then
    raise exception 'Only HR may start an onboarding checklist'
      using errcode = '42501';
  end if;
  if p_kind not in ('onboarding', 'offboarding') then
    raise exception 'Unknown checklist kind %', p_kind using errcode = '22023';
  end if;

  if p_template_id is not null
     and not exists (select 1 from public.onboarding_templates
                      where id = p_template_id and org_id = v_org) then
    raise exception 'That template belongs to another organization'
      using errcode = '42501';
  end if;

  -- An offboarding starts today; an onboarding starts on the hire date,
  -- which is usually in the future when somebody sets this up.
  v_start := coalesce(p_start_date,
    case when p_kind = 'onboarding' then v_hire else current_date end,
    current_date);

  if exists (select 1 from public.onboarding_checklists
              where employee_id = p_employee_id and kind = p_kind
                and completed_at is null) then
    raise exception 'This employee already has an open % checklist', p_kind
      using errcode = '22023';
  end if;

  insert into public.onboarding_checklists
    (org_id, employee_id, template_id, kind, start_date)
  values (v_org, p_employee_id, p_template_id, p_kind, v_start)
  returning id into v_checklist;

  insert into public.onboarding_tasks
    (org_id, checklist_id, title, description, category, due_date,
     is_mandatory, sort_order)
  select v_org, v_checklist, i.title, i.description, i.category,
         v_start + i.due_offset_days, i.is_mandatory, i.sort_order
    from public.onboarding_template_items i
   where i.template_id = p_template_id
   order by i.sort_order;

  get diagnostics v_n = row_count;

  -- An empty template produces an empty checklist, which looks finished
  -- from every angle without anybody having done anything.
  if p_template_id is not null and v_n = 0 then
    raise exception 'That template has no items in it' using errcode = '23514';
  end if;

  return v_checklist;
end;
$$;

-- Ticking a task off, and closing the checklist when the last mandatory
-- one is done.
--
-- Not a trigger: the checklist completing is a fact about the whole set
-- that the person ticking the last box wants to see, and a trigger that
-- fires on every row update to recount them is the sort of thing that
-- makes a bulk import take a minute.
create or replace function public.set_onboarding_task_done(
  p_task_id uuid, p_done boolean default true)
returns boolean
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_checklist uuid;
  v_org       uuid;
  v_owner     uuid;
  v_open      integer;
begin
  select t.checklist_id, t.org_id, t.owner_employee_id
    into v_checklist, v_org, v_owner
    from public.onboarding_tasks t where t.id = p_task_id;
  if v_checklist is null then
    raise exception 'Task not found' using errcode = 'P0002';
  end if;

  -- Whoever the task belongs to may tick it. That is the point of
  -- assigning one to a line manager rather than to HR.
  if not (app.can_manage_hr(v_org)
          or (v_owner is not null and v_owner = app.my_employee_id(v_org))) then
    raise exception 'This task is not yours to complete' using errcode = '42501';
  end if;

  update public.onboarding_tasks
     set is_done = coalesce(p_done, true),
         done_at = case when coalesce(p_done, true) then now() end,
         done_by = case when coalesce(p_done, true) then auth.uid() end
   where id = p_task_id;

  select count(*) into v_open from public.onboarding_tasks
   where checklist_id = v_checklist and is_mandatory and not is_done;

  -- Written only when the answer changes, so ticking the fourth
  -- optional task does not keep moving the completion timestamp of a
  -- checklist that finished last week. The comparison is between what
  -- the row currently says and what it should say.
  update public.onboarding_checklists
     set completed_at = case when v_open = 0 then now() end
   where id = v_checklist
     and (completed_at is not null) <> (v_open = 0);

  return v_open = 0;
end;
$$;

revoke all on function public.convert_lead(uuid, boolean, uuid, numeric, date)
  from public, anon;
grant execute on function public.convert_lead(uuid, boolean, uuid, numeric, date)
  to authenticated;

revoke all on function public.start_onboarding(uuid, uuid, date, text)
  from public, anon;
grant execute on function public.start_onboarding(uuid, uuid, date, text)
  to authenticated;

revoke all on function public.set_onboarding_task_done(uuid, boolean)
  from public, anon;
grant execute on function public.set_onboarding_task_done(uuid, boolean)
  to authenticated;
