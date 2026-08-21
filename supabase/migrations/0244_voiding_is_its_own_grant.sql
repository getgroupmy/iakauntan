-- =====================================================================
-- Voiding is its own grant
--
-- Taking a line off a bill after the kitchen has it is the oldest way
-- to steal from a till: ring the food up, take the customer's cash,
-- void the line, keep the difference. The bill balances, the drawer
-- balances, and the only trace is the void record — which is exactly
-- why 0225 wrote one with a name on it.
--
-- What 0225 did not do is decide who may void. It asks
-- `can_write_module(org, 'pos')`, which is the same question as "may
-- this person work the till". So every cashier could void, and a shop
-- that wanted otherwise had nowhere to say so.
--
-- ---------------------------------------------------------------------
-- A permission, not a module
--
-- 0127 put a per-company access layer in: an *access type* naming the
-- modules somebody may reach and whether they may write there. The
-- rows it is stored in, `access_type_modules`, are keyed on free text
-- and never checked that the code was a module — so a permission finer
-- than a module needs no new storage, only a name and somewhere to
-- list it.
--
-- That "somewhere" is not `platform_modules`. That table is the billing
-- catalog: what a company bought, at what price, shown in the platform
-- console. Voiding is not something anybody sells. `access_permissions`
-- is a separate list of the actions inside a module that a company can
-- hand out on their own, and it hangs off the module it lives in so the
-- editor can offer it under `pos` and only to companies that have pos.
--
-- The *reading* of those rows could not be reused, though, and the
-- reason is worth writing down because it is not visible in 0127: 0232
-- taught `app.module_access` to ask whether the company holds the
-- module before anything else, and to answer `none` when it does not.
-- A permission is not on the price list, so that path answers `none`
-- for everybody. `app.has_permission` below asks the two questions of
-- the two different things they are about instead.
--
-- ---------------------------------------------------------------------
-- Nothing changes for a shop that has not asked for it
--
-- A member with no access type assigned holds every permission, which
-- is every member of most companies, and so does every owner and
-- administrator. On those companies this is inert and every cashier
-- still voids exactly as before.
--
-- Where it bites is the case it is for: a company that has already
-- defined access types. Those members must now be granted `pos_void`
-- explicitly, because an access type grants what it lists and nothing
-- else — the rule 0127 set and the reason it is safe to add actions to
-- it later. That is a real change for those companies and it is the
-- point of the change; the alternative, defaulting an anti-theft
-- control to "on for everybody", is not a control.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The actions a company can hand out inside a module
-- ---------------------------------------------------------------------
create table if not exists public.access_permissions (
  code        text primary key,
  -- The module it lives in. A company that has not got the module is
  -- never offered the permission, because there would be nothing to
  -- do with it.
  module_code text not null,
  name        text not null,
  description text,
  sort_order  integer not null default 0
);

alter table public.access_permissions enable row level security;

-- Everybody signed in can read the list: the screen that hands out
-- access types has to name what it is handing out, and the screen that
-- explains why a button is missing has to name the reason.
create policy access_permissions_read on public.access_permissions
  for select to authenticated using (true);

-- Nobody writes it from the app. This is a catalog of what the product
-- can enforce, which changes when a migration adds an enforcement, not
-- when a company changes its mind.
grant select on public.access_permissions to authenticated;

insert into public.access_permissions
  (code, module_code, name, description, sort_order)
values
  ('pos_void', 'pos', 'Void a line after it has been sent',
   'Taking food off a bill the kitchen already has. Without this a '
   'cashier can still correct an unsent line, which changes nothing '
   'that has been cooked or charged.',
   1)
on conflict (code) do update
   set module_code = excluded.module_code,
       name        = excluded.name,
       description = excluded.description,
       sort_order  = excluded.sort_order;

comment on table public.access_permissions is
  'Actions inside a module that a company can grant separately through an access type. Not the billing catalog: nothing here is sold, and a company with the module has every permission in it until an access type says otherwise.';

-- ---------------------------------------------------------------------
-- Does this person hold a permission
-- ---------------------------------------------------------------------
--
-- Not `can_write_module(org, 'pos_void')`, which is the obvious thing
-- and is wrong. 0232 taught `app.module_access` to ask whether the
-- company holds the module *first*, and to answer `none` when it does
-- not — so a code that is not on the price list answers `none` to
-- everybody, owners included. Routing a permission through it would
-- deny every void in the product.
--
-- So the two questions are asked of the two different things they are
-- about. The entitlement question is asked about the module the
-- permission lives in, through `can_write_module`, which is also the
-- floor: a permission inside a module somebody may not write is not a
-- way in. The grant question is asked about the permission itself,
-- against the same access-type rows and by the same rule — not listed
-- is not allowed, and no access type at all is everything, which is
-- how every member of most companies stands.
create or replace function app.has_permission(p_org_id uuid, p_code text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_module text;
  v_type   uuid;
  v_access app.module_access;
begin
  if p_org_id is null or auth.uid() is null then
    return false;
  end if;
  if not app.is_org_member(p_org_id) then
    return false;
  end if;

  -- An unknown permission is not held. A typo in a call site must fail
  -- closed, or the guard it was meant to be is decoration.
  select ap.module_code into v_module
    from public.access_permissions ap where ap.code = p_code;
  if v_module is null then
    return false;
  end if;

  if not app.can_write_module(p_org_id, v_module) then
    return false;
  end if;

  -- The people who hand out access types cannot be shut out by one,
  -- which is 0127's rule and the reason an owner never locks
  -- themselves out of their own shop on a Friday night.
  if app.can_admin(p_org_id) then
    return true;
  end if;

  select m.access_type_id into v_type
    from public.org_members m
   where m.org_id = p_org_id and m.user_id = auth.uid();
  if v_type is null then
    return true;
  end if;

  select t.access into v_access
    from public.access_type_modules t
   where t.access_type_id = v_type and t.module_code = p_code;
  return coalesce(v_access, 'none') = 'write';
end;
$$;

revoke all on function app.has_permission(uuid, text) from public, anon;
grant execute on function app.has_permission(uuid, text) to authenticated;

comment on function app.has_permission(uuid, text) is
  'Whether this member holds an action inside a module. Deliberately not module_access: 0232 made that answer none for any code the company has not bought, and nobody buys a permission.';

-- ---------------------------------------------------------------------
-- May this person void
-- ---------------------------------------------------------------------
create or replace function app.can_void_pos(p_org_id uuid)
returns boolean
language sql
stable
set search_path = public, app, pg_temp
as $$
  select app.has_permission(p_org_id, 'pos_void');
$$;

revoke all on function app.can_void_pos(uuid) from public, anon;
grant execute on function app.can_void_pos(uuid) to authenticated;

comment on function app.can_void_pos(uuid) is
  'Whether this member may take a sent line off a bill. Working the till is the floor, checked inside has_permission; voiding is granted on top of it.';

-- ---------------------------------------------------------------------
-- The enforcement
-- ---------------------------------------------------------------------
--
-- Replaced whole because `create or replace` replaces whole. Only the
-- guard and its message differ from 0225.
create or replace function public.void_pos_sale_line(
  p_line   uuid,
  p_reason app.pos_void_reason,
  p_note   text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line public.pos_sale_lines;
  v_sale public.pos_sales;
  v_void uuid;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  -- Said as the thing a supervisor can fix, because the person reading
  -- it is standing at a till with a customer waiting and needs to know
  -- who to call rather than that something went wrong.
  if not app.can_void_pos(v_line.org_id) then
    raise exception
      'Voiding a sent line needs permission this account has not been given. Ask a manager.'
      using errcode = '42501';
  end if;

  select * into v_sale from public.pos_sales where id = v_line.sale_id;
  if v_sale.status <> 'parked' then
    raise exception
      'That bill is % and cannot be edited. Raise a credit note instead.',
      v_sale.status using errcode = '23514';
  end if;

  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say what happened.' using errcode = '23514';
  end if;

  -- Written before the delete, because after it there is nothing left
  -- to copy.
  insert into public.pos_sale_line_voids (
    org_id, sale_id, line_no, item_id, description, quantity,
    unit_price, line_total, was_sent_at, reason, note, voided_by)
  values (
    v_line.org_id, v_line.sale_id, v_line.line_no, v_line.item_id,
    v_line.description, v_line.quantity, v_line.unit_price,
    v_line.line_total, v_line.sent_to_kitchen_at, p_reason,
    nullif(btrim(p_note), ''), auth.uid())
  returning id into v_void;

  -- The kitchen docket line loses its pointer and keeps its text, by
  -- the `on delete set null` 0215 put there for exactly this.
  delete from public.pos_sale_lines where id = p_line;
  perform app.recalc_pos_sale(v_line.sale_id);
  return v_void;
end;
$$;

revoke all on function public.void_pos_sale_line(uuid, app.pos_void_reason, text)
  from public, anon;
grant execute on function public.void_pos_sale_line(uuid, app.pos_void_reason, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the app can ask
-- ---------------------------------------------------------------------
--
-- 0128 already answers "what am I allowed to see" in one round trip,
-- reading `platform_modules`. Unioning the permissions into the same
-- answer means the till learns whether it may offer a void from the
-- call the shell already makes on start-up, and a screen cannot
-- disagree with the database about it.
--
-- Hiding is still a courtesy. The refusal above is the control.
create or replace function public.my_module_access(p_org_id uuid)
returns table (module_code text, access text)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select m.code, app.module_access(p_org_id, m.code)::text
    from public.platform_modules m
   where app.is_org_member(p_org_id)
  union all
  select p.code,
         case when app.has_permission(p_org_id, p.code) then 'write' else 'none' end
    from public.access_permissions p
   where app.is_org_member(p_org_id)
   order by 1;
$$;

revoke all on function public.my_module_access(uuid) from public, anon;
grant execute on function public.my_module_access(uuid) to authenticated;
