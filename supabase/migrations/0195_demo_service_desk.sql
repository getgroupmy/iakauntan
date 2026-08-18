-- Sinar gets a service desk.
--
-- `0192` registered the module, which makes it an active module — and
-- `supabase/tests/demo_rebuild.sql` asserts that no active module is
-- left without a demo tenant to show it in. That assertion exists
-- precisely so a module cannot ship with nowhere to look at it, so this
-- is not an optional extra: registering the module and not seeding it
-- would fail the build, correctly.
--
-- Sinar is the right tenant for it. It wholesales computers, it already
-- has staff, customers and assets, and a company that sells hardware is
-- a company whose printers stop working.
--
-- ## Backdated, and the deadlines recomputed to match
--
-- `create_ticket` stamps `opened_at = now()` and computes both
-- deadlines from that moment, which is right in production and useless
-- for a demo: twelve tickets all raised this morning is not a queue,
-- it is a screenshot. Each ticket is backdated afterwards and its
-- deadlines recomputed from the backdated moment through the same SLA
-- clock, which is also the only honest way to arrive at genuinely
-- breached tickets rather than flags set by hand.
--
-- ## The printers are one problem, not six incidents
--
-- Three of the printer incidents are given a parent of type `problem`.
-- That relationship is the entire reason problem management is a
-- separate archetype — "why do the level 3 printers fail every Tuesday"
-- is a different question from any of the individual failures, and a
-- demo that shows six unrelated incidents shows the tool failing to do
-- the one thing it is for.

create or replace function app.demo_tickets_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_svc uuid; v_net uuid; v_app uuid;
  v_std uuid; v_247 uuid;
  v_clerk uuid;
  v_cust uuid;
  v_row record;
  v_id uuid;
  v_when timestamptz;
  v_pol uuid;
  v_prio app.ticket_priority;
  v_due record;
  v_n integer := 0;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['ticketing']);

  insert into public.ticket_teams (org_id, code, name, description, is_default)
  values (p_org, 'SVC', 'Service Desk', 'First line, everything starts here', true),
         (p_org, 'NET', 'Network & Infrastructure', 'Switches, wifi, printers', false),
         (p_org, 'APP', 'Applications', 'The ordering system and the website', false)
  on conflict (org_id, code) do nothing;
  select id into v_svc from public.ticket_teams where org_id = p_org and code = 'SVC';
  select id into v_net from public.ticket_teams where org_id = p_org and code = 'NET';
  select id into v_app from public.ticket_teams where org_id = p_org and code = 'APP';

  insert into public.sla_policies
    (org_id, code, name, business_hours_only, is_default, time_zone)
  values (p_org, 'STD', 'Standard — office hours', true, true, 'Asia/Kuala_Lumpur'),
         (p_org, 'CRIT', 'Critical — round the clock', false, false, 'Asia/Kuala_Lumpur')
  on conflict (org_id, code) do nothing;
  select id into v_std from public.sla_policies where org_id = p_org and code = 'STD';
  select id into v_247 from public.sla_policies where org_id = p_org and code = 'CRIT';

  insert into public.sla_targets
    (org_id, policy_id, priority, response_minutes, resolution_minutes)
  values (p_org, v_std, 'p1', 15, 240),
         (p_org, v_std, 'p2', 60, 480),
         (p_org, v_std, 'p3', 240, 2880),
         (p_org, v_std, 'p4', 480, 7200),
         (p_org, v_247, 'p1', 15, 120),
         (p_org, v_247, 'p2', 30, 480)
  on conflict (policy_id, priority) do nothing;

  -- Network runs on the round-the-clock policy: a warehouse with no wifi
  -- at two in the morning is not a problem that waits for nine o'clock.
  insert into public.ticket_categories
    (org_id, code, name, default_type, default_priority, team_id, sla_policy_id)
  values
    (p_org,'PRINTER','Printing','incident','p2', v_net, v_std),
    (p_org,'NETWORK','Network & wifi','incident','p1', v_net, v_247),
    (p_org,'LAPTOP','Hardware request','service_request','p3', v_svc, v_std),
    (p_org,'ACCESS','Access & accounts','service_request','p3', v_svc, v_std),
    (p_org,'ORDERS','Ordering system','incident','p2', v_app, v_std)
  on conflict (org_id, code) do nothing;

  insert into public.canned_responses (org_id, code, title, body, created_by)
  values
    (p_org,'PWD-RESET','Password reset done',
     'Your password has been reset. You will be asked to set a new one at '
     'your next sign-in. If that was not you who asked, tell us straight away.',
     p_owner),
    (p_org,'HW-ORDERED','Hardware ordered',
     'Your request is approved and the hardware is on order. We will let '
     'you know as soon as it arrives, usually within five working days.',
     p_owner),
    (p_org,'NEED-INFO','More detail needed',
     'We need a little more to go on: the exact wording of the error, and '
     'roughly what time it happened. We have put the ticket on hold until '
     'we hear back.', p_owner)
  on conflict (org_id, code) do nothing;

  select m.user_id into v_clerk from public.org_members m
    join auth.users u on u.id = m.user_id
   where m.org_id = p_org and u.email = 'clerk@iakauntan.my';
  select id into v_cust from public.contacts
   where org_id = p_org and contact_type = 'customer' order by code limit 1;

  for v_row in
    select * from (values
      (58, 'The printer on level 3 is offline',     'PRINTER', 'closed',   true),
      (52, 'New laptop for the new sales hire',     'LAPTOP',  'closed',   false),
      (44, 'Wifi keeps dropping in the warehouse',  'NETWORK', 'closed',   false),
      (37, 'Cannot log in to the ordering system',  'ACCESS',  'closed',   false),
      (30, 'Orders page times out at checkout',     'ORDERS',  'resolved', false),
      (24, 'Printer jams every Tuesday morning',    'PRINTER', 'open',     true),
      (18, 'Second monitor for the accounts desk',  'LAPTOP',  'pending',  false),
      (12, 'Warehouse wifi again — same corner',    'NETWORK', 'open',     false),
      (9,  'Access for the new accounts clerk',     'ACCESS',  'resolved', false),
      (6,  'Ordering system slow after the update', 'ORDERS',  'on_hold',  false),
      (3,  'Keyboard replacement',                  'LAPTOP',  'open',     false),
      (1,  'Printer out of toner',                  'PRINTER', 'new',      false)
    ) as t(days_ago, subject, cat, want, from_customer)
  loop
    v_when := now() - make_interval(days => v_row.days_ago);

    v_id := public.create_ticket(
      p_org, v_row.subject, null, v_row.cat, null, null,
      case when v_row.from_customer then 'email' else 'web' end::app.ticket_channel,
      case when v_row.from_customer then null else p_owner end,
      case when v_row.from_customer then v_cust else null end);

    -- The policy has to be read out first: an UPDATE cannot pass its own
    -- target's columns into a set-returning function in its FROM clause.
    select sla_policy_id, priority into v_pol, v_prio
      from public.tickets where id = v_id;
    select * into v_due from app.sla_deadlines(p_org, v_pol, v_prio, v_when);

    update public.tickets
       set opened_at = v_when,
           created_at = v_when,
           response_due_at   = v_due.response_due,
           resolution_due_at = v_due.resolution_due
     where id = v_id;

    if v_row.want <> 'new' then
      perform public.add_ticket_comment(v_id, 'Picked this up, taking a look.', false);
      perform public.assign_ticket(v_id, coalesce(v_clerk, p_owner));
    end if;

    if v_row.want in ('pending', 'on_hold') then
      perform public.transition_ticket(v_id, v_row.want::app.ticket_status,
                                       'Waiting on the requester');
    elsif v_row.want in ('resolved', 'closed') then
      perform public.transition_ticket(v_id, 'resolved', 'Sorted and confirmed with the user');
      if v_row.want = 'closed' then
        perform public.transition_ticket(v_id, 'closed');
      end if;
    end if;

    v_n := v_n + 1;
  end loop;

  v_id := public.create_ticket(
    p_org, 'Why do the level 3 printers fail every Tuesday?',
    'Three incidents in six weeks, all Tuesday morning, all the same floor.',
    'PRINTER', 'p2', 'problem', 'web', p_owner);
  update public.tickets set opened_at = now() - interval '20 days' where id = v_id;
  update public.tickets
     set parent_id = v_id
   where org_id = p_org
     and category_id = (select id from public.ticket_categories
                         where org_id = p_org and code = 'PRINTER')
     and id <> v_id and ticket_type = 'incident';
  v_n := v_n + 1;

  -- Run the sweep rather than setting the flags by hand, so the breached
  -- ones are breached for the same reason a real one would be.
  perform public.ticket_sla_sweep(p_org);
  perform set_config('request.jwt.claims', '', true);

  return format('Sinar service desk: %s tickets across %s teams, %s breached.',
                v_n,
                (select count(*) from public.ticket_teams where org_id = p_org),
                (select count(*) from public.tickets
                  where org_id = p_org and (response_breached or resolution_breached)));
end $$;

-- ---------------------------------------------------------------------
-- One call still rebuilds the whole demo
-- ---------------------------------------------------------------------
create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed text; v_demo uuid; v_clerk uuid; v_auditor uuid;
  v_secretary uuid; v_property uuid;
  v_sinar uuid; v_amanah uuid; v_harta uuid;
  v_books text; v_books_a text; v_books_h text;
  v_cash text; v_assets text; v_pay text; v_desk text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.my',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.my',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.my',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.my', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.my',  'Tan Chee Keong');

  v_sinar := app.demo_company(
    v_demo, 'Sinar Teknologi Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201901004567', 'C20194567890', '46510',
    'Wholesale of computers and peripherals',
    '10', 'Petaling Jaya', '46200',
    'Level 8, Menara Sinar, Jalan Utara', '03-7955 1200',
    'accounts@sinartek.demo', 12::smallint);
  perform public.set_sst_registration(
    v_sinar, true, date_trunc('year', current_date)::date - 365,
    'W10-1808-31000123', 'ST8');
  perform app.demo_member(v_sinar, v_clerk,   'accounts_clerk');
  perform app.demo_member(v_sinar, v_auditor, 'auditor');
  perform app.demo_modules(v_sinar, array[
    'einvoice', 'purchases', 'inventory', 'crm', 'hr', 'payroll',
    'fixed_assets', 'approvals', 'manufacturing', 'branches',
    'timesheets', 'chat', 'mbrs']);
  v_books  := app.demo_books_sinar(v_sinar, v_demo);
  v_cash   := app.demo_sinar_bank(v_sinar, v_demo);
  v_assets := app.demo_sinar_assets(v_sinar, v_demo);
  v_pay    := app.demo_sinar_payroll(v_sinar, v_demo);
  v_desk   := app.demo_tickets_sinar(v_sinar, v_demo);
  perform app.demo_sync_bank_balance(v_sinar);

  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat']);
  v_books_a := app.demo_books_amanah(v_amanah, v_secretary);

  v_harta := app.demo_company(
    v_property, 'Harta Prima Management Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202101007890', 'C20217890123', '68201',
    'Property management on a fee or contract basis',
    '10', 'Shah Alam', '40150',
    'Ground Floor, Blok A, Pusat Perniagaan Harta', '03-5511 4400',
    'admin@hartaprima.demo', 12::smallint);
  perform app.demo_modules(v_harta, array[
    'property_strata', 'property_nonstrata', 'purchases', 'fixed_assets',
    'approvals', 'chat']);
  v_books_h := app.demo_books_harta(v_harta, v_property);

  perform set_config('request.jwt.claims', '', true);

  return format('%s Rebuilt 3 tenants, 5 logins. %s %s %s %s %s %s %s',
                v_removed, v_books, v_cash, v_assets, v_pay, v_desk,
                v_books_a, v_books_h);
end $$;

revoke all on function app.demo_tickets_sinar(uuid, uuid) from public, anon, authenticated;
