-- =====================================================================
-- iAkauntan :: 0064 the register of members, computed
-- =====================================================================

-- Positions are computed from the events, the way the ledger computes
-- balances from journals. A register you can edit directly is a
-- register that will drift from the returns already lodged.
create or replace function public.corp_register_of_members(p_entity_id uuid)
returns table (
  person_id uuid,
  member_name text,
  nric text,
  registration_no text,
  share_class_id uuid,
  share_class text,
  shares numeric,
  percent numeric,
  first_acquired date,
  last_movement date)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.corp_entities where id = p_entity_id;
  if v_org is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  return query
  with movements as (
    select e.to_person_id as pid, e.share_class_id, e.quantity as qty, e.event_date
      from public.corp_share_events e
     where e.entity_id = p_entity_id and e.to_person_id is not null
    union all
    select e.from_person_id, e.share_class_id, -e.quantity, e.event_date
      from public.corp_share_events e
     where e.entity_id = p_entity_id and e.from_person_id is not null
  ),
  positions as (
    select m.pid, m.share_class_id,
           sum(m.qty) as shares,
           min(m.event_date) filter (where m.qty > 0) as first_acquired,
           max(m.event_date) as last_movement
      from movements m
     group by m.pid, m.share_class_id
    having sum(m.qty) <> 0
  ),
  totals as (
    select p.share_class_id, sum(p.shares) as total from positions p
     group by p.share_class_id
  )
  select p.pid, pr.full_name, pr.nric, pr.registration_no,
         p.share_class_id, sc.name, p.shares,
         round(p.shares * 100.0 / nullif(t.total, 0), 4),
         p.first_acquired, p.last_movement
    from positions p
    join public.corp_persons pr on pr.id = p.pid
    join public.corp_share_classes sc on sc.id = p.share_class_id
    join totals t on t.share_class_id = p.share_class_id
   order by p.shares desc, pr.full_name;
end;
$$;

-- Nobody can transfer away shares they do not hold. Enforced in the
-- database because a register that can go negative has already lied to
-- the Registrar.
create or replace function app.corp_check_share_event()
returns trigger language plpgsql
set search_path = public, app, pg_temp as $$
declare v_held numeric;
begin
  if NEW.from_person_id is null then return NEW; end if;

  select coalesce(sum(case when e.to_person_id = NEW.from_person_id
                           then e.quantity else -e.quantity end), 0)
    into v_held
    from public.corp_share_events e
   where e.entity_id = NEW.entity_id
     and e.share_class_id = NEW.share_class_id
     and (e.to_person_id = NEW.from_person_id
          or e.from_person_id = NEW.from_person_id)
     and e.event_date <= NEW.event_date
     and e.id is distinct from NEW.id;

  if v_held < NEW.quantity then
    raise exception
      'Holder has % shares of that class on %, cannot move %',
      v_held, NEW.event_date, NEW.quantity using errcode = '23514';
  end if;
  return NEW;
end;
$$;

drop trigger if exists check_share_event on public.corp_share_events;
create trigger check_share_event
  before insert or update on public.corp_share_events
  for each row execute function app.corp_check_share_event();

-- Issued capital, which under the 2016 Act is the only capital figure
-- there is: par value and authorised capital were abolished.
create or replace function public.corp_issued_capital(p_entity_id uuid)
returns table (share_class text, shares numeric, consideration numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.corp_entities where id = p_entity_id;
  if v_org is null or not app.is_org_member(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select sc.name,
         coalesce(sum(case when e.event_type = 'allotment' then e.quantity
                           when e.event_type = 'cancellation' then -e.quantity
                           else 0 end), 0),
         coalesce(sum(case when e.event_type = 'allotment'
                           then e.total_consideration else 0 end), 0)
    from public.corp_share_classes sc
    left join public.corp_share_events e on e.share_class_id = sc.id
   where sc.entity_id = p_entity_id
   group by sc.id, sc.name
   order by sc.name;
end;
$$;
