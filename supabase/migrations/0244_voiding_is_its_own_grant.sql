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
-- enforcement function, `app.module_access`, takes any code — it never
-- checked that the code was a module. So a permission finer than a
-- module needs no new machinery, only a name and somewhere to list it.
--
-- That "somewhere" is not `platform_modules`. That table is the billing
-- catalog: what a company bought, at what price, shown in the platform
-- console. Voiding is not something anybody sells. `access_permissions`
-- is a separate list of the actions inside a module that a company can
-- hand out on their own, and it hangs off the module it lives in so the
-- editor can offer it under `pos` and only to companies that have pos.
--
-- ---------------------------------------------------------------------
-- Nothing changes for a shop that has not asked for it
--
-- `app.module_access` returns `write` for a member with no access type
-- assigned, which is every member of most companies, and always for
-- owners and administrators. So on those companies this is inert and
-- every cashier still voids exactly as before.
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
-- May this person void
-- ---------------------------------------------------------------------
--
-- Both, and in this order: working the till is the floor, and voiding
-- is a thing you do while working the till. Somebody who may not sell
-- has no business voiding whatever else they hold.
create or replace function app.can_void_pos(p_org_id uuid)
returns boolean
language sql
stable
set search_path = public, app, pg_temp
as $$
  select app.can_write_module(p_org_id, 'pos')
     and app.can_write_module(p_org_id, 'pos_void');
$$;

revoke all on function app.can_void_pos(uuid) from public, anon;
grant execute on function app.can_void_pos(uuid) to authenticated;

comment on function app.can_void_pos(uuid) is
  'Whether this member may take a sent line off a bill. Working the till is the floor; voiding is granted on top of it.';

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
  select p.code, app.module_access(p_org_id, p.code)::text
    from public.access_permissions p
   where app.is_org_member(p_org_id)
   order by 1;
$$;

revoke all on function public.my_module_access(uuid) from public, anon;
grant execute on function public.my_module_access(uuid) to authenticated;
