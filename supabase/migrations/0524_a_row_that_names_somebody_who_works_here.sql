-- =====================================================================
-- A row that names somebody who works here
--
-- 0507-0522 held every column naming another ROW to the company that row
-- belongs to. The columns naming a PERSON are the ones that programme
-- structurally could not reach: they point at `auth.users`, which is
-- platform-wide and carries no company, so no foreign key -- composite
-- or otherwise -- can say the person works here.
--
-- 0522 found the first of these by probe: escalate_ticket handed a
-- ticket to a user of another company, while assign_ticket, writing the
-- SAME column, had always refused with
--
--   That person is not an active member of this organization
--
-- Fifty-seven such columns exist. Most record an ACTOR -- created_by,
-- posted_by, decided_by -- written from auth.uid() by a function that
-- has already checked the caller, and those need nothing. The ones that
-- matter name somebody the row is ASSIGNED to, and a caller supplies
-- them. Probed, four more were unguarded:
--
--   upsert_pos_driver(p_user)   -> pos_drivers.user_id
--   open_matter(p_fee_earner)   -> matters.fee_earner
--   open_matter(p_responsible)  -> matters.responsible_solicitor
--   contacts.owner_id, written straight through PostgREST
--
-- The last of those is the one that shows why fixing the functions is
-- not enough. Row level security scopes a row by its own org_id and
-- says nothing about a user id carried in one of its columns, so the
-- client -- which holds update on `contacts` -- can set an owner who
-- has never worked here, without going near an RPC. Every column below
-- is reachable that way.
--
-- So the guard is a trigger, not a check in each function: one place,
-- covering the RPC path and the direct path at once.
--
-- WHEN IT FIRES is the part that took thought. Checking on every write
-- would mean that suspending a salesperson froze all fifty of their
-- contacts -- an update touching a phone number would be refused
-- because of an owner nobody was changing. It fires only when the
-- column ITSELF changes, which is the right rule anyway: the check is
-- on the act of naming somebody, not on the row's continued existence.
-- Somebody who leaves keeps their name on the history; they just cannot
-- be given anything new.
--
-- The line drawn is: GUARD WHERE A PERSON CHOOSES, EXEMPT WHERE THE
-- SYSTEM DERIVES. An admin picking a name off a list should be told at
-- once that the name is wrong; a row the system generates from a rule
-- should not refuse to exist because the rule has gone stale, because
-- then the failure lands on whoever is filing a claim rather than on
-- whoever should fix the rule.
--
-- That is why `approval_rules.approver_user_id` IS guarded -- it is
-- where an administrator names the approver -- while
-- `approval_steps.approver_user_id`, `expense_claims.approver_id` and
-- `leave_requests.approver_id` are not: all three are generated from
-- that rule when a request is raised, and a stale rule should show as a
-- routing problem on the approvals screen, not as a refusal to file.
-- Guarding the rule is the upstream fix for the same problem.
--
-- Two more are exempt for their own reasons:
--
--   employees.user_id -- an employee record is made before the person
--     accepts their invitation, so their membership is 'invited' and
--     not yet 'active'. Guarding this would break onboarding at the
--     step it exists to support.
--   tickets.requester_user_id -- who ASKED, not who is doing it.
--     `tickets_one_requester` already forces exactly one of this and
--     `requester_contact_id`, and the contact branch is the one an
--     outsider uses; but a portal login raising its own ticket is a
--     shape this should not foreclose.
--
-- `a_colleague_not_a_stranger.sql` lists every exemption by name, so
-- each is visible in the suite rather than only here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The guard
--
-- TG_ARGV[0] is the column; TG_ARGV[1] is what to call the person in
-- the message. The tail of the sentence is assign_ticket's, word for
-- word, because it is already the one the ticketing tests assert and a
-- second wording for the same rule helps nobody.
-- ---------------------------------------------------------------------
create or replace function app.names_a_colleague()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_col  text := TG_ARGV[0];
  v_noun text := TG_ARGV[1];
  v_new  uuid;
  v_old  uuid;
begin
  execute format('select ($1).%I', v_col) into v_new using NEW;
  if v_new is null then
    return NEW;
  end if;

  -- Only the act of naming somebody. See the header: firing on every
  -- write would freeze a departed colleague's rows against edits that
  -- have nothing to do with them.
  if TG_OP = 'UPDATE' then
    execute format('select ($1).%I', v_col) into v_old using OLD;
    if v_old is not distinct from v_new then
      return NEW;
    end if;
  end if;

  if not exists (
       select 1 from public.org_members m
        where m.org_id = NEW.org_id and m.user_id = v_new
          and m.status = 'active') then
    raise exception '% is not an active member of this organization', v_noun
      using errcode = '23503';
  end if;
  return NEW;
end;
$$;

revoke all on function app.names_a_colleague() from public, anon;

comment on function app.names_a_colleague() is
  'Refuses a row that hands work to somebody who does not work at the company. For the columns pointing at auth.users, which no foreign key can hold. Fires only when the column itself changes.';

-- ---------------------------------------------------------------------
-- Where it goes
-- ---------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('contacts',              'owner_id',              'That person'),
      ('leads',                 'owner_id',              'That person'),
      ('opportunities',         'owner_id',              'That person'),
      ('activities',            'assigned_to',           'That person'),
      ('collection_attempts',   'assigned_to',           'That person'),
      ('matters',               'fee_earner',            'The fee earner'),
      ('matters',               'responsible_solicitor', 'The responsible solicitor'),
      ('corp_entities',         'responsible_secretary', 'The responsible secretary'),
      ('pos_drivers',           'user_id',               'That driver'),
      ('pos_service_providers', 'user_id',               'That person'),
      ('ticket_team_members',   'user_id',               'That person'),
      ('tickets',               'assignee_id',           'That person'),
      ('approval_rules',        'approver_user_id',      'That approver')
    ) as t(tbl, col, noun)
  loop
    execute format(
      'drop trigger if exists names_a_colleague_%s on public.%I', r.col, r.tbl);
    execute format(
      'create trigger names_a_colleague_%s
         before insert or update on public.%I
         for each row execute function app.names_a_colleague(%L, %L)',
      r.col, r.tbl, r.col, r.noun);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- And the two functions that were handing work out unchecked
--
-- The trigger refuses these now, so both checks are belt to its braces
-- -- and both are here for the reason deposits.sql sets out: the
-- trigger's message names the column's noun, but it fires from inside a
-- write the caller cannot see, and a function that took a person's id
-- as an argument should answer for that argument itself.
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_driver(p_id uuid, p_org uuid, p_name text, p_phone text DEFAULT NULL::text, p_vehicle text DEFAULT NULL::text, p_plate text DEFAULT NULL::text, p_outlet uuid DEFAULT NULL::uuid, p_user uuid DEFAULT NULL::uuid, p_active boolean DEFAULT true)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A driver needs a name.' using errcode = '23514';
  end if;
  if p_outlet is not null
     and not exists (select 1 from public.pos_outlets o
                      where o.id = p_outlet and o.org_id = p_org) then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;

  -- A driver row is how a delivery reaches somebody's phone. Pointing
  -- it at a stranger does not fail; the run is simply assigned and
  -- never seen, because row level security keeps them out of the very
  -- rows the app would fetch.
  if p_user is not null and not exists (
       select 1 from public.org_members m
        where m.org_id = p_org and m.user_id = p_user
          and m.status = 'active') then
    raise exception 'That driver is not an active member of this organization'
      using errcode = '23503';
  end if;

  if p_id is null then
    insert into public.pos_drivers
      (org_id, outlet_id, name, phone, vehicle, plate_no, user_id, is_active)
    values
      (p_org, p_outlet, btrim(p_name),
       nullif(btrim(coalesce(p_phone, '')), ''),
       nullif(btrim(coalesce(p_vehicle, '')), ''),
       nullif(btrim(coalesce(p_plate, '')), ''),
       p_user, coalesce(p_active, true))
    returning id into v_id;
  else
    update public.pos_drivers d
       set outlet_id = p_outlet,
           name = btrim(p_name),
           phone = nullif(btrim(coalesce(p_phone, '')), ''),
           vehicle = nullif(btrim(coalesce(p_vehicle, '')), ''),
           plate_no = nullif(btrim(coalesce(p_plate, '')), ''),
           user_id = p_user,
           is_active = coalesce(p_active, true),
           updated_at = now()
     where d.id = p_id and d.org_id = p_org
    returning d.id into v_id;
    if v_id is null then
      raise exception 'No such driver.' using errcode = 'P0002';
    end if;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_driver(uuid, uuid, text, text, text, text, uuid, uuid, boolean) from public, anon;
grant execute on function public.upsert_pos_driver(uuid, uuid, text, text, text, text, uuid, uuid, boolean) to authenticated;

create or replace function public.open_matter(p_org uuid, p_matter_no text, p_name text, p_client uuid, p_opposing_party text DEFAULT NULL::text, p_matter_type text DEFAULT NULL::text, p_fee_earner uuid DEFAULT NULL::uuid, p_responsible uuid DEFAULT NULL::uuid, p_agreed_fee numeric DEFAULT NULL::numeric, p_hourly_rate numeric DEFAULT 0, p_conflict_note text DEFAULT NULL::text)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_conflicts integer;
  v_first     text;
  v_matter    uuid;
begin
  if not app.can_write(p_org) then
    raise exception 'not permitted to open a matter' using errcode = '42501';
  end if;
  if not app.has_module(p_org, 'legal') then
    raise exception 'The legal practice module is not enabled.'
      using errcode = '42501';
  end if;
  if p_client is null then
    raise exception 'A matter is opened for a client.' using errcode = '23502';
  end if;
  if btrim(coalesce(p_matter_no, '')) = ''
     or btrim(coalesce(p_name, '')) = '' then
    raise exception 'A matter has a number and a name.'
      using errcode = '23514';
  end if;

  select count(*), min(matter_no) into v_conflicts, v_first
    from public.check_matter_conflict(p_org, p_client, p_opposing_party);

  if v_conflicts > 0
     and btrim(coalesce(p_conflict_note, '')) = '' then
    raise exception
      'This would put the firm on both sides. % open or closed file(s) '
      'touch these parties, starting with %. Rule 3 of the Legal '
      'Profession (Practice and Etiquette) Rules 1978 is the reason to '
      'stop and look. If it has been considered and cleared, write down '
      'why — the file is what is looked at afterwards.',
      v_conflicts, v_first using errcode = '23514';
  end if;

  -- Who is on the file. The Legal Profession Act's question, and not
  -- one to answer with somebody who does not work at the practice.
  if p_fee_earner is not null and not exists (
       select 1 from public.org_members mm
        where mm.org_id = p_org and mm.user_id = p_fee_earner
          and mm.status = 'active') then
    raise exception 'The fee earner is not an active member of this organization'
      using errcode = '23503';
  end if;
  if p_responsible is not null and not exists (
       select 1 from public.org_members mm
        where mm.org_id = p_org and mm.user_id = p_responsible
          and mm.status = 'active') then
    raise exception
      'The responsible solicitor is not an active member of this organization'
      using errcode = '23503';
  end if;

  insert into public.matters
    (org_id, matter_no, name, client_id, opposing_party, matter_type,
     fee_earner, responsible_solicitor, agreed_fee, hourly_rate,
     notes, created_by)
  values (p_org, btrim(p_matter_no), btrim(p_name), p_client,
          nullif(btrim(coalesce(p_opposing_party, '')), ''), p_matter_type,
          coalesce(p_fee_earner, auth.uid()),
          coalesce(p_responsible, auth.uid()),
          p_agreed_fee, coalesce(p_hourly_rate, 0),
          nullif(btrim(coalesce(p_conflict_note, '')), ''), auth.uid())
  returning id into v_matter;

  return v_matter;
end $$;

revoke all on function public.open_matter(uuid, text, text, uuid, text, text, uuid, uuid, numeric, numeric, text) from public, anon;
grant execute on function public.open_matter(uuid, text, text, uuid, text, text, uuid, uuid, numeric, numeric, text) to authenticated;
