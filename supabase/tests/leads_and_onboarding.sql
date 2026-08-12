-- =====================================================================
-- iAkauntan :: lead conversion and onboarding tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/leads_and_onboarding.sql
--
-- `leads` had a table, RLS and no screen, so the CRM began at the
-- opportunity — after somebody had already decided the enquiry was
-- real. The four onboarding tables were a complete design nothing could
-- write a row into.
--
-- Converting a lead is three writes that must not half succeed, and
-- ticking off the last mandatory task is a fact about the whole
-- checklist. Both are asserted here; the second assertion below caught
-- a real inversion in `set_onboarding_task_done` — it reported the
-- checklist finished and did not stamp it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A lead becomes a customer and an opportunity
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Funnel Sdn Bhd');
  v_pipeline uuid; v_lost uuid; v_open uuid;
  v_lead uuid; v_result jsonb; v_contact uuid; v_opportunity uuid;
begin
  insert into public.pipelines (org_id, name, is_default)
  values (v_org, 'Sales', true) returning id into v_pipeline;

  -- The losing stage deliberately sorts first. A pipeline can be
  -- ordered any way somebody likes, and opening every converted lead in
  -- whatever stage happens to sort lowest would mark them all dead on
  -- arrival.
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, stage_type, sort_order)
  values (v_org, v_pipeline, 'Closed lost', 0, 'lost', 0)
  returning id into v_lost;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, stage_type, sort_order)
  values (v_org, v_pipeline, 'Qualifying', 20, 'open', 1)
  returning id into v_open;

  insert into public.leads
    (org_id, lead_no, company_name, first_name, last_name, designation,
     email, phone, source, estimated_value, status)
  values (v_org, 'LD-001', 'Kilang Maju Sdn Bhd', 'Nurul', 'Hasan',
          'Purchasing Manager', 'nurul@example.com', '0312345678',
          'Trade show', 50000, 'qualified')
  returning id into v_lead;

  v_result := public.convert_lead(v_lead);
  v_contact := (v_result ->> 'contact_id')::uuid;
  v_opportunity := (v_result ->> 'opportunity_id')::uuid;

  perform pg_temp.check_true('the company becomes the customer',
    (select name = 'Kilang Maju Sdn Bhd' and contact_type = 'customer'
       from public.contacts where id = v_contact));

  -- The named person is not thrown away. This is the row the e-Invoice
  -- preparation and every delivery note reach for.
  perform pg_temp.check_true('and the person becomes their main contact',
    (select name = 'Nurul Hasan' and is_primary and designation = 'Purchasing Manager'
       from public.contact_persons where contact_id = v_contact));

  perform pg_temp.check_true('the lead is stamped rather than deleted',
    (select status = 'converted' and converted_contact_id = v_contact
        and converted_at is not null
       from public.leads where id = v_lead));

  perform pg_temp.check_true('the opportunity starts in the first OPEN stage',
    (select stage_id = v_open and probability = 20
       from public.opportunities where id = v_opportunity));
  perform pg_temp.check_eq('carrying the estimated value',
    (select amount from public.opportunities where id = v_opportunity), 50000);
  perform pg_temp.check_true('and remembering where it came from',
    (select lead_id = v_lead and source = 'Trade show'
       from public.opportunities where id = v_opportunity));

  begin
    perform public.convert_lead(v_lead);
    raise exception 'FAIL: converted the same lead twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a converted lead cannot be converted again';
  end;
end $$;

-- ---------------------------------------------------------------------
-- What conversion refuses, and what it leaves alone when it does
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Nameless Sdn Bhd');
  v_lead uuid;
begin
  insert into public.leads (org_id, lead_no, status)
  values (v_org, 'LD-001', 'new') returning id into v_lead;

  begin
    perform public.convert_lead(v_lead, false);
    raise exception 'FAIL: created a customer with no name';
  exception when sqlstate '23514' then
    raise notice 'ok   a lead with neither company nor person is refused';
  end;

  update public.leads set company_name = 'Anon Bhd', status = 'lost'
   where id = v_lead;
  begin
    perform public.convert_lead(v_lead, false);
    raise exception 'FAIL: converted a lost lead';
  exception when sqlstate '22023' then
    raise notice 'ok   a lost lead must be reopened first';
  end;

  -- This organization has no pipeline. Asking for an opportunity has to
  -- fail whole: a contact created and a lead left unstamped is how the
  -- same company ends up in the book twice.
  update public.leads set status = 'qualified' where id = v_lead;
  begin
    perform public.convert_lead(v_lead, true);
    raise exception 'FAIL: opened an opportunity with no pipeline';
  exception when sqlstate '23514' then
    raise notice 'ok   no pipeline, no conversion';
  end;
  perform pg_temp.check_true('and the lead was not half converted',
    (select converted_contact_id is null from public.leads where id = v_lead));
  perform pg_temp.check_eq('with no orphan customer left behind',
    (select count(*) from public.contacts where org_id = v_org), 0);

  perform public.convert_lead(v_lead, false);
  perform pg_temp.check_true('without an opportunity it converts fine',
    (select converted_contact_id is not null
        and converted_opportunity_id is null
       from public.leads where id = v_lead));
end $$;

-- ---------------------------------------------------------------------
-- Onboarding: offsets become dates, and the last box closes the list
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Joiner Sdn Bhd');
  v_emp uuid; v_template uuid; v_empty uuid; v_checklist uuid;
  v_it uuid; v_epf uuid; v_bag uuid;
  v_finished boolean;
begin
  insert into public.employees
    (org_id, employee_no, user_id, full_name, hire_date, employment_status)
  values (v_org, 'EMP-001', pg_temp.test_user(), 'New Joiner',
          date '2026-09-01', 'active')
  returning id into v_emp;

  insert into public.onboarding_templates (org_id, name)
  values (v_org, 'Standard') returning id into v_template;
  insert into public.onboarding_template_items
    (org_id, template_id, title, category, due_offset_days,
     is_mandatory, sort_order)
  values (v_org, v_template, 'Create IT account', 'IT', 0, true, 1),
         (v_org, v_template, 'Register with EPF', 'Statutory', 3, true, 2),
         (v_org, v_template, 'Order a laptop bag', 'Facilities', 7, false, 3);

  v_checklist := public.start_onboarding(v_emp, v_template);

  perform pg_temp.check_eq('three tasks materialised',
    (select count(*) from public.onboarding_tasks
      where checklist_id = v_checklist), 3);
  perform pg_temp.check_true('the checklist starts on the hire date',
    (select start_date = date '2026-09-01'
       from public.onboarding_checklists where id = v_checklist));

  -- Copied, not referenced: editing the template next year must not
  -- move the due dates of an onboarding that finished last year.
  perform pg_temp.check_true('offsets became real dates',
    (select due_date = date '2026-09-04' from public.onboarding_tasks
      where checklist_id = v_checklist and title = 'Register with EPF'));

  begin
    perform public.start_onboarding(v_emp, v_template);
    raise exception 'FAIL: opened a second onboarding for the same person';
  exception when sqlstate '22023' then
    raise notice 'ok   one open checklist of a kind per employee';
  end;

  select id into v_it from public.onboarding_tasks
   where checklist_id = v_checklist and title = 'Create IT account';
  select id into v_epf from public.onboarding_tasks
   where checklist_id = v_checklist and title = 'Register with EPF';
  select id into v_bag from public.onboarding_tasks
   where checklist_id = v_checklist and title = 'Order a laptop bag';

  v_finished := public.set_onboarding_task_done(v_it);
  perform pg_temp.check_true('one mandatory task left', v_finished = false);
  perform pg_temp.check_true('so the checklist is still open',
    (select completed_at is null
       from public.onboarding_checklists where id = v_checklist));

  v_finished := public.set_onboarding_task_done(v_epf);
  perform pg_temp.check_true('the last mandatory one finishes it', v_finished);
  perform pg_temp.check_true('and the checklist is stamped',
    (select completed_at is not null
       from public.onboarding_checklists where id = v_checklist));

  -- The optional task is optional. A checklist that waits for the
  -- laptop bag is a checklist nobody ever closes.
  perform pg_temp.check_true('the optional task is still outstanding',
    (select not is_done from public.onboarding_tasks where id = v_bag));

  v_finished := public.set_onboarding_task_done(v_epf, false);
  perform pg_temp.check_true('un-ticking reopens it', v_finished = false);
  perform pg_temp.check_true('and clears the completion',
    (select completed_at is null
       from public.onboarding_checklists where id = v_checklist));
  perform pg_temp.check_true('and forgets who did it and when',
    (select done_at is null and done_by is null
       from public.onboarding_tasks where id = v_epf));

  insert into public.onboarding_templates (org_id, name)
  values (v_org, 'Empty') returning id into v_empty;
  begin
    perform public.start_onboarding(v_emp, v_empty, null, 'offboarding');
    raise exception 'FAIL: started from a template with nothing in it';
  exception when sqlstate '23514' then
    raise notice 'ok   an empty template would look finished from every angle';
  end;

  begin
    perform public.start_onboarding(v_emp, v_template, null, 'sabbatical');
    raise exception 'FAIL: accepted a checklist kind that does not exist';
  exception when sqlstate '22023' then
    raise notice 'ok   an unknown kind is refused';
  end;
end $$;

-- Another organization's template is not available, even to somebody
-- who is a member of both.
do $$
declare
  v_a uuid := pg_temp.test_org('Mine Sdn Bhd');
  v_emp uuid; v_b uuid; v_theirs uuid;
begin
  insert into public.employees
    (org_id, employee_no, user_id, full_name, hire_date, employment_status)
  values (v_a, 'EMP-001', pg_temp.test_user(), 'Somebody',
          date '2026-01-01', 'active')
  returning id into v_emp;

  v_b := pg_temp.test_org('Theirs Sdn Bhd');
  insert into public.onboarding_templates (org_id, name)
  values (v_b, 'Their standard') returning id into v_theirs;

  perform pg_temp.sign_in_as(
    (select created_by from public.organizations where id = v_a));
  begin
    perform public.start_onboarding(v_emp, v_theirs);
    raise exception 'FAIL: used another organization''s template';
  exception when sqlstate '42501' then
    raise notice 'ok   a template belongs to one organization';
  end;
end $$;

rollback;
