-- =====================================================================
-- A row that names two companies at once
--
-- 0507-0521 held every column that names another row to the company the
-- row belongs to. The coverage query in `tenant_foreign_keys.sql` is
-- what keeps it that way, and it looks like this:
--
--   ... and exists (select 1 from pg_attribute o
--                    where o.attrelid = c.conrelid and o.attname = 'org_id')
--
-- A table with no `org_id` at all is therefore invisible to it. There
-- is no company on the row to hold anything to, so the query skips the
-- table rather than reporting it -- and a join table carrying two
-- foreign keys and nothing else is exactly that shape.
--
-- Four such tables exist. Three of them are the POS scope tables:
--
--   pos_menu_schedule_items (schedule_id, item_id)
--   pos_promotion_items     (promotion_id, item_id)
--   pos_promotion_outlets   (promotion_id, outlet_id)
--
-- Each names a row from one company's configuration and a row from
-- anybody's catalogue, and nothing said the two had to be the same
-- company. `upsert_pos_menu_schedule` and `upsert_pos_promotion` take
-- both as arrays of caller-supplied ids and insert them unchecked.
--
-- This is not theoretical. `app.pos_item_off` -- which the counter,
-- the kiosk and the public menu all ask before offering a dish --
-- matches schedule rows BY ITEM ALONE:
--
--   select count(*) into v_n
--     from public.pos_menu_schedule_items si
--     join public.pos_menu_schedules sc on sc.id = si.schedule_id
--    where si.item_id = p_item and sc.is_active;
--
-- so one company putting another company's item on a schedule that is
-- shut changes what the other company's own shop will sell. Probed
-- against the built database: B's nasi lemak read "(on the menu)"
-- before, and "From 04:00" at B's own outlet after A saved a breakfast
-- schedule naming it. A company can take a competitor's dish off the
-- competitor's menu, needing nothing but the POS module.
--
-- The fourth is `organizations` itself, whose `org_id` is called `id`:
--
--   default_sales_tax_code_id    -> tax_codes(id)
--   default_purchase_tax_code_id -> tax_codes(id)
--
-- A company could default its invoices to another company's SST code.
-- Same class, expressible the same way, because `tax_codes` already
-- carries the (org_id, id) key 0518 gave it.
--
-- What this migration does:
--
--   1. gives the three join tables an `org_id`, backfilled from the
--      parent they hang off, NOT NULL afterwards -- because MATCH
--      SIMPLE leaves a composite key unenforced when any part is null,
--      which is the lesson 0511 cost a run to learn;
--   2. adds both same-org keys to each: one to the parent, so the
--      org_id on the row is the parent's own, and one to the thing it
--      names;
--   3. adds the two `organizations` keys, keyed through `id`;
--   4. scopes `app.pos_item_off` to the outlet's company, which the
--      query should have said in the first place and which is the
--      belt to (1)'s braces;
--   5. teaches the two upsert RPCs to write the org and to refuse in
--      words -- the keys refuse too, but a shop manager who picked the
--      wrong dish should not be shown
--      `violates foreign key constraint "pos_promotion_items_item_same_org"`;
--   6. closes escalate_ticket, which assigned a ticket to anybody at
--      all. Its sister `assign_ticket` has always refused a stranger --
--      "That person is not an active member of this organization" --
--      and this one, which writes the same column, never learned to.
--      Probed: a ticket in A was escalated to a user of B, with B's
--      user then owning a ticket they cannot read and an SLA clock
--      running against nobody;
--   7. names the customer and the asset in create_ticket, for the
--      reason deposits.sql set out: the schema refuses, and says
--      nothing a person can act on.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The parent key the schedules table never had
-- ---------------------------------------------------------------------
alter table public.pos_menu_schedules
  add constraint pos_menu_schedules_org_id_id_key unique (org_id, id);

-- ---------------------------------------------------------------------
-- 2. The three join tables
-- ---------------------------------------------------------------------
alter table public.pos_menu_schedule_items add column if not exists org_id uuid;
update public.pos_menu_schedule_items si
   set org_id = sc.org_id
  from public.pos_menu_schedules sc
 where sc.id = si.schedule_id and si.org_id is distinct from sc.org_id;
alter table public.pos_menu_schedule_items alter column org_id set not null;
alter table public.pos_menu_schedule_items
  add constraint pos_menu_schedule_items_org_id_fkey
      foreign key (org_id) references public.organizations (id) on delete cascade,
  add constraint pos_menu_schedule_items_schedule_same_org
      foreign key (org_id, schedule_id)
      references public.pos_menu_schedules (org_id, id) on delete cascade,
  add constraint pos_menu_schedule_items_item_same_org
      foreign key (org_id, item_id)
      references public.items (org_id, id) on delete cascade;

alter table public.pos_promotion_items add column if not exists org_id uuid;
update public.pos_promotion_items pi
   set org_id = p.org_id
  from public.pos_promotions p
 where p.id = pi.promotion_id and pi.org_id is distinct from p.org_id;
alter table public.pos_promotion_items alter column org_id set not null;
alter table public.pos_promotion_items
  add constraint pos_promotion_items_org_id_fkey
      foreign key (org_id) references public.organizations (id) on delete cascade,
  add constraint pos_promotion_items_promotion_same_org
      foreign key (org_id, promotion_id)
      references public.pos_promotions (org_id, id) on delete cascade,
  add constraint pos_promotion_items_item_same_org
      foreign key (org_id, item_id)
      references public.items (org_id, id) on delete cascade;

alter table public.pos_promotion_outlets add column if not exists org_id uuid;
update public.pos_promotion_outlets po
   set org_id = p.org_id
  from public.pos_promotions p
 where p.id = po.promotion_id and po.org_id is distinct from p.org_id;
alter table public.pos_promotion_outlets alter column org_id set not null;
alter table public.pos_promotion_outlets
  add constraint pos_promotion_outlets_org_id_fkey
      foreign key (org_id) references public.organizations (id) on delete cascade,
  add constraint pos_promotion_outlets_promotion_same_org
      foreign key (org_id, promotion_id)
      references public.pos_promotions (org_id, id) on delete cascade,
  add constraint pos_promotion_outlets_outlet_same_org
      foreign key (org_id, outlet_id)
      references public.pos_outlets (org_id, id) on delete cascade;

-- ---------------------------------------------------------------------
-- 3. A company's own default tax codes
--
-- `on delete set null` with the column list, for the reason 0511
-- exists: without it, deleting the tax code would null the company's
-- `id` as well, and `id` is NOT NULL, so the delete would fail with a
-- message about a column nobody touched.
-- ---------------------------------------------------------------------
alter table public.organizations
  add constraint organizations_default_sales_tax_same_org
      foreign key (id, default_sales_tax_code_id)
      references public.tax_codes (org_id, id)
      on delete set null (default_sales_tax_code_id),
  add constraint organizations_default_purchase_tax_same_org
      foreign key (id, default_purchase_tax_code_id)
      references public.tax_codes (org_id, id)
      on delete set null (default_purchase_tax_code_id);

-- ---------------------------------------------------------------------
-- 4. A dish's timetable is its own company's timetable
--
-- The three lookups matched by item alone. Every one now goes through
-- the schedule's company, taken from the outlet being asked about --
-- which is what "is this dish on at this shop" always meant.
-- ---------------------------------------------------------------------
create or replace function app.pos_item_off(p_item uuid, p_outlet uuid)
returns text
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  v_date date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_org  uuid;
  v_stop text;
  v_n    integer;
  v_when text;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;

  -- The kitchen's answer beats the timetable's: a dish that is both
  -- out of season and sold out is sold out, which is the more useful
  -- half to hear.
  select coalesce(nullif(btrim(coalesce(s.reason, '')), ''), 'Sold out')
    into v_stop
    from public.pos_item_stops s
   where s.outlet_id = p_outlet and s.item_id = p_item and s.on_date = v_date;
  if v_stop is not null then
    return v_stop;
  end if;

  select count(*)::integer into v_n
    from public.pos_menu_schedule_items si
    join public.pos_menu_schedules sc on sc.id = si.schedule_id
   where si.item_id = p_item and sc.is_active and sc.org_id = v_org;

  -- On no schedule at all is always on. Empty means always, the same
  -- rule the promotions use.
  if v_n = 0 then
    return null;
  end if;

  if exists (
    select 1
      from public.pos_menu_schedule_items si
      join public.pos_menu_schedules sc on sc.id = si.schedule_id
     where si.item_id = p_item
       and sc.is_active
       and sc.org_id = v_org
       and app.pos_window_open(sc.weekdays, sc.starts_at, sc.ends_at,
                               sc.starts_on, sc.ends_on)
  ) then
    return null;
  end if;

  -- Off, so say when it comes back. The earliest start among the
  -- schedules it is on, which is the answer to "what time do you do
  -- breakfast" even when there are two breakfast schedules.
  select to_char(min(sc.starts_at), 'HH24:MI') into v_when
    from public.pos_menu_schedule_items si
    join public.pos_menu_schedules sc on sc.id = si.schedule_id
   where si.item_id = p_item and sc.is_active and sc.org_id = v_org
     and sc.starts_at is not null;

  return case when v_when is null then 'Not on the menu today'
              else 'From ' || v_when end;
end;
$$;

-- ---------------------------------------------------------------------
-- 5a. The menu scheduler writes the company, and says which dish
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_menu_schedule(
  p_org       uuid,
  p_name      text,
  p_weekdays  smallint[] default null,
  p_starts_at time default null,
  p_ends_at   time default null,
  p_starts_on date default null,
  p_ends_on   date default null,
  p_items     uuid[] default null,
  p_id        uuid default null,
  p_is_active boolean default true)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid; v_stray uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A schedule needs a name. "Breakfast" will do.'
      using errcode = '23514';
  end if;
  if (p_starts_at is null) <> (p_ends_at is null) then
    raise exception 'An hours window needs both a start and an end.'
      using errcode = '23514';
  end if;
  if p_weekdays is not null
     and exists (select 1 from unnest(p_weekdays) d where d < 1 or d > 7) then
    raise exception 'Weekdays run from 1 (Monday) to 7 (Sunday).'
      using errcode = '23514';
  end if;

  -- Before anything is written, so a bad list does not leave a schedule
  -- behind it. `pos_menu_schedule_items_item_same_org` refuses this too
  -- since 0522; what it cannot do is name the dish.
  if p_items is not null then
    select i into v_stray from unnest(p_items) i
     where not exists (select 1 from public.items t
                        where t.id = i and t.org_id = p_org)
     limit 1;
    if v_stray is not null then
      raise exception 'No such dish on this company''s menu.'
        using errcode = 'P0002';
    end if;
  end if;

  if p_id is null then
    insert into public.pos_menu_schedules
      (org_id, name, weekdays, starts_at, ends_at, starts_on, ends_on, is_active)
    values (p_org, btrim(p_name), p_weekdays, p_starts_at, p_ends_at,
            p_starts_on, p_ends_on, coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.pos_menu_schedules s
       set name = btrim(p_name),
           weekdays = p_weekdays,
           starts_at = p_starts_at,
           ends_at = p_ends_at,
           starts_on = p_starts_on,
           ends_on = p_ends_on,
           is_active = coalesce(p_is_active, true),
           updated_at = now()
     where s.id = p_id and s.org_id = p_org;
    if not found then
      raise exception 'No such schedule.' using errcode = 'P0002';
    end if;
    v_id := p_id;
  end if;

  -- Null leaves the list alone; an empty array clears it, which is how
  -- a schedule is emptied without deleting it.
  if p_items is not null then
    delete from public.pos_menu_schedule_items where schedule_id = v_id;
    insert into public.pos_menu_schedule_items (org_id, schedule_id, item_id)
    select p_org, v_id, i from unnest(p_items) i
    on conflict do nothing;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_menu_schedule(
  uuid, text, smallint[], time, time, date, date, uuid[], uuid, boolean)
  from public, anon;
grant execute on function public.upsert_pos_menu_schedule(
  uuid, text, smallint[], time, time, date, date, uuid[], uuid, boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- 5b. The promotion editor, the same
--
-- Two lists here rather than one, and they fail differently: an item
-- from another catalogue and an outlet from another company are
-- separate mistakes with separate sentences.
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_promotion(p_org uuid, p_name text, p_kind app.pos_promo_kind, p_code text DEFAULT NULL::text, p_percent numeric DEFAULT 0, p_amount numeric DEFAULT 0, p_buy integer DEFAULT 0, p_get integer DEFAULT 0, p_starts_on date DEFAULT NULL::date, p_ends_on date DEFAULT NULL::date, p_weekdays smallint[] DEFAULT NULL::smallint[], p_starts_at time without time zone DEFAULT NULL::time without time zone, p_ends_at time without time zone DEFAULT NULL::time without time zone, p_min_subtotal numeric DEFAULT 0, p_max_uses integer DEFAULT NULL::integer, p_max_per_customer integer DEFAULT NULL::integer, p_items uuid[] DEFAULT NULL::uuid[], p_outlets uuid[] DEFAULT NULL::uuid[], p_channels text[] DEFAULT NULL::text[], p_id uuid DEFAULT NULL::uuid, p_is_active boolean DEFAULT true)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid; v_stray uuid;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A promotion needs a name. It goes on the receipt.'
      using errcode = '23514';
  end if;

  -- Each kind has one number that makes it mean anything, and a
  -- promotion saved without it is a promotion that takes nothing off
  -- and looks like it is working.
  if p_kind = 'percent_off' and coalesce(p_percent, 0) <= 0 then
    raise exception 'A percentage off has to be more than nought.'
      using errcode = '23514';
  end if;
  if p_kind = 'amount_off' and coalesce(p_amount, 0) <= 0 then
    raise exception 'An amount off has to be more than nought.'
      using errcode = '23514';
  end if;
  if p_kind = 'buy_x_get_y' then
    if coalesce(p_buy, 0) <= 0 or coalesce(p_get, 0) <= 0 then
      raise exception
        'Say how many are bought and how many come free. Three for two '
        'is buy 2, get 1.'
        using errcode = '23514';
    end if;
    if coalesce(p_percent, 0) <= 0 then
      raise exception
        'Say how much comes off the free ones. A hundred per cent is '
        'free; fifty is half price.'
        using errcode = '23514';
    end if;
  end if;
  if (p_starts_at is null) <> (p_ends_at is null) then
    raise exception 'An hours window needs both a start and an end.'
      using errcode = '23514';
  end if;
  if p_weekdays is not null
     and exists (select 1 from unnest(p_weekdays) d where d < 1 or d > 7) then
    raise exception 'Weekdays run from 1 (Monday) to 7 (Sunday).'
      using errcode = '23514';
  end if;

  -- Before anything is written, so a bad list does not leave a
  -- promotion behind it. Since 0522 the keys refuse these too; what a
  -- key cannot do is say which of the two lists was wrong.
  if p_items is not null then
    select i into v_stray from unnest(p_items) i
     where not exists (select 1 from public.items t
                        where t.id = i and t.org_id = p_org)
     limit 1;
    if v_stray is not null then
      raise exception 'No such item in this company''s catalogue.'
        using errcode = 'P0002';
    end if;
  end if;
  if p_outlets is not null then
    select o into v_stray from unnest(p_outlets) o
     where not exists (select 1 from public.pos_outlets t
                        where t.id = o and t.org_id = p_org)
     limit 1;
    if v_stray is not null then
      raise exception 'No such outlet in this company.'
        using errcode = 'P0002';
    end if;
  end if;

  if p_id is null then
    insert into public.pos_promotions
      (org_id, code, name, kind, percent, amount, buy_quantity, get_quantity,
       starts_on, ends_on, weekdays, starts_at, ends_at, min_subtotal,
       max_uses, max_per_customer, is_active)
    values (p_org, nullif(btrim(coalesce(p_code, '')), ''), btrim(p_name),
            p_kind, coalesce(p_percent, 0), coalesce(p_amount, 0),
            coalesce(p_buy, 0), coalesce(p_get, 0),
            p_starts_on, p_ends_on, p_weekdays, p_starts_at, p_ends_at,
            coalesce(p_min_subtotal, 0), p_max_uses, p_max_per_customer,
            coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.pos_promotions p
       set code = nullif(btrim(coalesce(p_code, '')), ''),
           name = btrim(p_name),
           kind = p_kind,
           percent = coalesce(p_percent, 0),
           amount = coalesce(p_amount, 0),
           buy_quantity = coalesce(p_buy, 0),
           get_quantity = coalesce(p_get, 0),
           starts_on = p_starts_on,
           ends_on = p_ends_on,
           weekdays = p_weekdays,
           starts_at = p_starts_at,
           ends_at = p_ends_at,
           min_subtotal = coalesce(p_min_subtotal, 0),
           max_uses = p_max_uses,
           max_per_customer = p_max_per_customer,
           is_active = coalesce(p_is_active, true),
           updated_at = now()
     where p.id = p_id and p.org_id = p_org;
    if not found then
      raise exception 'No such promotion.' using errcode = 'P0002';
    end if;
    v_id := p_id;
  end if;

  -- Only what actually left. `= any` over an empty array is false, so
  -- an empty list still clears the scope, which is what passing one
  -- means. The insert needs no such care: `on conflict do nothing`
  -- inserts nothing for a row already there, and a trigger does not
  -- fire for a row that was not inserted.
  if p_items is not null then
    delete from public.pos_promotion_items x
     where x.promotion_id = v_id
       and not (x.item_id = any (p_items));
    insert into public.pos_promotion_items (org_id, promotion_id, item_id)
    select p_org, v_id, i from unnest(p_items) i
    on conflict do nothing;
  end if;
  if p_outlets is not null then
    delete from public.pos_promotion_outlets x
     where x.promotion_id = v_id
       and not (x.outlet_id = any (p_outlets));
    insert into public.pos_promotion_outlets (org_id, promotion_id, outlet_id)
    select p_org, v_id, o from unnest(p_outlets) o
    on conflict do nothing;
  end if;
  if p_channels is not null then
    delete from public.pos_promotion_channels x
     where x.promotion_id = v_id
       and not (x.channel::text = any (p_channels));
    insert into public.pos_promotion_channels (promotion_id, channel)
    select v_id, c::app.pos_order_channel from unnest(p_channels) c
    on conflict do nothing;
  end if;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_promotion(uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer, date, date, smallint[], time, time, numeric, integer, integer, uuid[], uuid[], text[], uuid, boolean) from public, anon;
grant execute on function public.upsert_pos_promotion(uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer, date, date, smallint[], time, time, numeric, integer, integer, uuid[], uuid[], text[], uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Escalating a ticket to somebody who works here
-- ---------------------------------------------------------------------
create or replace function public.escalate_ticket(p_ticket uuid, p_kind app.ticket_escalation, p_to_team uuid DEFAULT NULL::uuid, p_to_user uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_t public.tickets;
begin
  select * into v_t from public.tickets where id = p_ticket;
  if not found then raise exception 'Ticket % not found', p_ticket; end if;
  if not app.can_write_module(v_t.org_id, 'ticketing') then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  if p_kind = 'functional' and p_to_team is null then
    raise exception 'A functional escalation has to name the team it goes to'
      using errcode = '22023';
  end if;
  if p_kind = 'hierarchic' and p_to_user is null then
    raise exception 'A hierarchic escalation has to name the person it goes to'
      using errcode = '22023';
  end if;
  if p_to_team is not null and not exists (
       select 1 from public.ticket_teams where id = p_to_team and org_id = v_t.org_id) then
    raise exception 'No such team in this organization' using errcode = '23503';
  end if;

  -- The same check assign_ticket has always made, in the other function
  -- that writes the same column. `tickets.assignee_id` points at
  -- `auth.users`, which is platform-wide and carries no company, so no
  -- foreign key can hold this one -- it has to be asked. Without it an
  -- escalation could hand a ticket to somebody at another company, who
  -- would never see it (row level security keeps them out) while its
  -- resolution clock ran on against a name that cannot answer.
  if p_to_user is not null and not exists (
       select 1 from public.org_members m
        where m.org_id = v_t.org_id and m.user_id = p_to_user
          and m.status = 'active') then
    raise exception 'That person is not an active member of this organization'
      using errcode = '23503';
  end if;

  update public.tickets
     set team_id = coalesce(p_to_team, team_id),
         assignee_id = coalesce(p_to_user, assignee_id),
         escalation_level = escalation_level + 1,
         status = case when status = 'new' then 'open'::app.ticket_status else status end
   where id = p_ticket;

  insert into public.ticket_events
    (org_id, ticket_id, event_type, from_value, to_value, note, actor_id)
  values (v_t.org_id, p_ticket, 'escalated', v_t.escalation_level::text,
          (v_t.escalation_level + 1)::text,
          coalesce(p_reason, '') || ' (' || p_kind::text || ')', auth.uid());
end $$;

revoke all on function public.escalate_ticket(
  uuid, app.ticket_escalation, uuid, uuid, text) from public, anon;
grant execute on function public.escalate_ticket(
  uuid, app.ticket_escalation, uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. And raising one for a customer this company has
-- ---------------------------------------------------------------------
create or replace function public.create_ticket(p_org_id uuid, p_subject text, p_description text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_priority app.ticket_priority DEFAULT NULL::app.ticket_priority, p_type app.ticket_type DEFAULT NULL::app.ticket_type, p_channel app.ticket_channel DEFAULT 'web'::app.ticket_channel, p_requester_user_id uuid DEFAULT NULL::uuid, p_requester_contact_id uuid DEFAULT NULL::uuid, p_asset_id uuid DEFAULT NULL::uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_cat    public.ticket_categories;
  v_team   uuid;
  v_policy uuid;
  v_prio   app.ticket_priority;
  v_type   app.ticket_type;
  v_req    uuid := p_requester_user_id;
  v_id     uuid;
  v_due    record;
begin
  if not app.can_write_module(p_org_id, 'ticketing') then
    raise exception 'Insufficient privileges to raise a ticket'
      using errcode = '42501';
  end if;

  -- Somebody has to own the question. When neither is given the caller
  -- is raising it for themselves, which is the self-service case.
  if v_req is null and p_requester_contact_id is null then
    v_req := auth.uid();
  end if;

  -- Named, because `tickets_contact_fk` and `tickets_asset_fk` refuse
  -- these already and say so in the language of a constraint. A support
  -- desk that picked the wrong customer from a stale list should read a
  -- sentence, not the name of a key.
  if p_requester_contact_id is not null and not exists (
       select 1 from public.contacts t
        where t.id = p_requester_contact_id and t.org_id = p_org_id) then
    raise exception 'No such contact.' using errcode = 'P0002';
  end if;
  if p_asset_id is not null and not exists (
       select 1 from public.fixed_assets t
        where t.id = p_asset_id and t.org_id = p_org_id) then
    raise exception 'No such asset.' using errcode = 'P0002';
  end if;

  if p_category is not null then
    select * into v_cat from public.ticket_categories
     where org_id = p_org_id and code = p_category and is_active;
    if not found then
      raise exception 'No active ticket category % in this organization', p_category
        using errcode = 'P0002';
    end if;
  end if;

  v_prio := coalesce(p_priority, v_cat.default_priority, 'p3');
  v_type := coalesce(p_type, v_cat.default_type, 'incident');

  -- Routing: the category's team, else whichever team is marked
  -- default. A ticket with no team is a queue nobody is looking at.
  v_team := coalesce(v_cat.team_id,
                     (select id from public.ticket_teams
                       where org_id = p_org_id and is_default and is_active));

  v_policy := coalesce(v_cat.sla_policy_id,
                       (select id from public.sla_policies
                         where org_id = p_org_id and is_default and is_active));

  select * into v_due
    from app.sla_deadlines(p_org_id, v_policy, v_prio, now());

  insert into public.tickets
    (org_id, ticket_no, subject, description, ticket_type, priority, status,
     channel, category_id, team_id, requester_user_id, requester_contact_id,
     asset_id, sla_policy_id, opened_at, response_due_at, resolution_due_at,
     created_by)
  values
    (p_org_id, app.next_document_number_internal(p_org_id, 'ticket'),
     p_subject, p_description, v_type, v_prio, 'new',
     p_channel, v_cat.id, v_team, v_req, p_requester_contact_id,
     p_asset_id, v_policy, now(), v_due.response_due, v_due.resolution_due,
     auth.uid())
  returning id into v_id;

  insert into public.ticket_events (org_id, ticket_id, event_type, to_value, actor_id)
  values (p_org_id, v_id, 'created', v_prio::text, auth.uid());

  return v_id;
end $$;

revoke all on function public.create_ticket(uuid, text, text, text, app.ticket_priority, app.ticket_type, app.ticket_channel, uuid, uuid, uuid) from public, anon;
grant execute on function public.create_ticket(uuid, text, text, text, app.ticket_priority, app.ticket_type, app.ticket_channel, uuid, uuid, uuid) to authenticated;
