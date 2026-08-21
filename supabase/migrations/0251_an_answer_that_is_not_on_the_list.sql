-- =====================================================================
-- An answer that is not on the list
--
-- 0214 asks a fixed question with fixed answers, and 0250 let a shop
-- keep them. Between them they cover everything a shop thought of in
-- advance, which is not everything a customer asks for. "Tambah telur"
-- is on the list; "tambah sotong, kira empat ringgit" is the same kind
-- of thing and there is nowhere to put it.
--
-- What a till does without this is worse than nothing: it rings up a
-- second line for four ringgit called "Ayam tambah" because that was
-- the nearest button, and the kitchen docket now says something untrue
-- about a plate somebody has to cook.
--
-- ---------------------------------------------------------------------
-- The table already holds it
--
-- `pos_sale_line_modifiers` snapshots `name` and `price_delta` onto the
-- line and its `modifier_id` is nullable — it has to be, because a
-- modifier can be deleted out from under a bill that already went out.
-- A typed answer is exactly that row with the id left null: a name, a
-- price, a group, frozen at the moment of ordering like every other
-- answer. Nothing about the receipt, the kitchen docket, the repricing
-- or the e-Invoice needs to know the difference.
--
-- `pos_line_modifier_gaps` counts rows per group without looking at
-- `modifier_id`, so a typed answer closes a required question. That is
-- the right reading: "choose one" was answered, and the cook can read
-- it.
--
-- ---------------------------------------------------------------------
-- Per question, because not every question takes one
--
-- "Pedas" has three answers and a fourth is not a spice level anybody
-- can cook. "Tambah" is open by its nature. So the permission is a
-- column on the group rather than a setting on the outlet, and it is
-- off until a shop turns it on.
--
-- ---------------------------------------------------------------------
-- Upwards only
--
-- The price is typed by whoever is holding the till, which is the one
-- thing here worth being careful about. A surcharge is what this is
-- for; a negative would be a discount entered by the person taking the
-- money, with no reason recorded and no grant asked for — the shape
-- 0247 spent a whole migration closing on the void. Listed answers may
-- still be negative, because a manager configured them in advance.
--
-- Nought is allowed: "tanpa timun, tapi tulis pada docket" costs
-- nothing and still has to reach the kitchen.
-- =====================================================================

alter table public.pos_modifier_groups
  add column if not exists allows_free_text boolean not null default false;

comment on column public.pos_modifier_groups.allows_free_text is
  'Whether the till may take an answer to this question that is not on the list, typed with its own price. Off unless a shop turns it on: a spice level has a fixed set of answers, "anything else" does not.';

-- ---------------------------------------------------------------------
-- Typing one in
-- ---------------------------------------------------------------------
--
-- The same shape as `add_line_modifier`, with the name and the price
-- coming from the counter instead of the menu. It does not upsert:
-- "tambah sotong" and "tambah sotong lagi" are two different things
-- somebody typed, and the unique index does not apply to a null
-- `modifier_id` anyway.
create or replace function public.add_line_free_modifier(
  p_line        uuid,
  p_group       uuid,
  p_name        text,
  p_price_delta numeric default 0,
  p_quantity    integer default 1)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line  public.pos_sale_lines;
  v_stat  app.pos_sale_status;
  v_group public.pos_modifier_groups;
  v_name  text;
  v_id    uuid;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select s.status into v_stat from public.pos_sales s where s.id = v_line.sale_id;
  if v_stat <> 'parked' then
    raise exception 'That bill is % and cannot be changed.', v_stat
      using errcode = '23514';
  end if;
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'A modifier needs a quantity.' using errcode = '23514';
  end if;

  select * into v_group from public.pos_modifier_groups where id = p_group;
  if v_group.id is null or v_group.org_id <> v_line.org_id then
    raise exception 'That is not one of this company''s questions.'
      using errcode = 'P0002';
  end if;
  if not v_group.is_active then
    raise exception '% is not being asked.', v_group.name
      using errcode = '23514';
  end if;
  if not v_group.allows_free_text then
    raise exception
      '% only takes the answers on its list.', v_group.name
      using errcode = '23514';
  end if;

  v_name := btrim(coalesce(p_name, ''));
  if v_name = '' then
    raise exception 'Say what it is.' using errcode = '23514';
  end if;
  -- It goes on a kitchen docket and on a receipt, both of which are
  -- narrow. Refused rather than truncated: silently cutting a cook's
  -- instruction in half is how the wrong plate goes out.
  if length(v_name) > 60 then
    raise exception 'Keep it under sixty characters — it has to fit on a docket.'
      using errcode = '23514';
  end if;

  -- See the header. Upwards or nothing: a negative typed at the till is
  -- a discount with no reason and no grant behind it.
  if coalesce(p_price_delta, 0) < 0 then
    raise exception
      'An answer typed at the till cannot take money off the plate.'
      using errcode = '23514';
  end if;

  if v_line.base_unit_price is null then
    update public.pos_sale_lines l
       set base_unit_price = l.unit_price where l.id = p_line;
  end if;

  -- `modifier_id` null: there is no menu row behind it, which is the
  -- whole point. The name and the price are the record, exactly as they
  -- are for a listed answer once it has been snapshotted.
  insert into public.pos_sale_line_modifiers
    (org_id, line_id, modifier_id, group_id, name, price_delta, quantity)
  values (v_line.org_id, p_line, null, p_group, v_name,
          coalesce(p_price_delta, 0), p_quantity)
  returning id into v_id;

  perform app.reprice_pos_line(p_line);
  return v_id;
end;
$$;

revoke all on function
  public.add_line_free_modifier(uuid, uuid, text, numeric, integer)
  from public, anon;
grant execute on function
  public.add_line_free_modifier(uuid, uuid, text, numeric, integer)
  to authenticated;

comment on function
  public.add_line_free_modifier(uuid, uuid, text, numeric, integer) is
  'Puts an answer nobody listed onto a line: a name and a price typed at the counter, snapshotted like any other. Only for a question whose group allows it, and never for less than nothing.';

-- ---------------------------------------------------------------------
-- The sheet has to know which questions are open
-- ---------------------------------------------------------------------
--
-- Dropped and recreated rather than replaced, because a `returns table`
-- cannot gain a column any other way.
drop function if exists public.item_modifier_options(uuid);

create function public.item_modifier_options(p_item uuid)
returns table (
  group_id         uuid,
  group_name       text,
  min_select       integer,
  max_select       integer,
  allows_free_text boolean,
  modifier_id      uuid,
  name             text,
  price_delta      numeric,
  is_default       boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select g.id, g.name, g.min_select, g.max_select, g.allows_free_text,
         m.id, m.name, m.price_delta, m.is_default
    from public.item_modifier_groups img
    join public.pos_modifier_groups g on g.id = img.group_id and g.is_active
    left join public.pos_modifiers m on m.group_id = g.id and m.is_active
   where img.item_id = p_item
     and app.can_read_module(img.org_id, 'pos')
   order by img.sort_order, g.name, m.sort_order, m.name;
$$;

grant execute on function public.item_modifier_options(uuid) to authenticated;

comment on function public.item_modifier_options(uuid) is
  'What can be asked about a dish: the questions attached to it, their rules, whether each takes an answer that is not listed, and the answers that are.';

-- ---------------------------------------------------------------------
-- And the editor has to be able to turn it on
-- ---------------------------------------------------------------------
--
-- Both of these gain a column, and neither can gain one in place: a
-- parameter list and a `returns table` are part of a function's
-- identity. Dropped and recreated rather than left as overloads —
-- two `upsert_pos_modifier_group`s differing only by a defaulted
-- trailing argument is a call nobody can read and Postgres may refuse
-- as ambiguous.
drop function if exists public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean);

create function public.upsert_pos_modifier_group(
  p_org             uuid,
  p_code            text,
  p_name            text,
  p_min_select      integer default 0,
  p_max_select      integer default null,
  p_id              uuid    default null,
  p_sort_order      integer default 0,
  p_is_active       boolean default true,
  p_allows_free_text boolean default false)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id       uuid;
  v_defaults integer;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to configure this organization'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_code, '')), '') is null
     or nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A question needs a code and a name.'
      using errcode = '23514';
  end if;
  if coalesce(p_min_select, 0) < 0 then
    raise exception 'A question cannot ask for fewer than none.'
      using errcode = '23514';
  end if;
  if p_max_select is not null and p_max_select < 1 then
    raise exception
      'A maximum of none is a question nobody can answer. Leave it '
      'empty for "as many as you like".'
      using errcode = '23514';
  end if;
  if p_max_select is not null and p_max_select < coalesce(p_min_select, 0) then
    raise exception 'At least % but at most % is not a rule.',
      p_min_select, p_max_select using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.pos_modifier_groups
      (org_id, code, name, min_select, max_select, sort_order, is_active,
       allows_free_text)
    values (p_org, btrim(p_code), btrim(p_name),
            coalesce(p_min_select, 0), p_max_select,
            coalesce(p_sort_order, 0), coalesce(p_is_active, true),
            coalesce(p_allows_free_text, false))
    returning id into v_id;
    return v_id;
  end if;

  -- Tightening the maximum below the answers already ticked by default
  -- would leave every plate opening the sheet over the limit. Said
  -- here, where somebody can fix it, rather than at the counter.
  if p_max_select is not null then
    select count(*) into v_defaults
      from public.pos_modifiers m
     where m.group_id = p_id and m.is_default and m.is_active;
    if v_defaults > p_max_select then
      raise exception
        'That question has % answers ticked by default and you are '
        'capping it at %. Untick one first.',
        v_defaults, p_max_select
        using errcode = '23514';
    end if;
  end if;

  update public.pos_modifier_groups g
     set code             = btrim(p_code),
         name             = btrim(p_name),
         min_select       = coalesce(p_min_select, g.min_select),
         max_select       = p_max_select,
         sort_order       = coalesce(p_sort_order, g.sort_order),
         is_active        = coalesce(p_is_active, g.is_active),
         allows_free_text = coalesce(p_allows_free_text, g.allows_free_text)
   where g.id = p_id and g.org_id = p_org;
  if not found then
    raise exception 'No such question.' using errcode = 'P0002';
  end if;
  return p_id;
end;
$$;

revoke all on function public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean, boolean)
  from public, anon;
grant execute on function public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean, boolean)
  to authenticated;

comment on function public.upsert_pos_modifier_group(
  uuid, text, text, integer, integer, uuid, integer, boolean, boolean) is
  'Creates or renames a modifier group -- the question a dish comes with -- including whether the till may answer it with something that is not on the list. Refuses a maximum below the number of answers already ticked by default, because the till starts those selected.';

drop function if exists public.pos_modifier_groups_admin(uuid);

create function public.pos_modifier_groups_admin(p_org uuid)
returns table (
  id               uuid,
  code             text,
  name             text,
  min_select       integer,
  max_select       integer,
  sort_order       integer,
  is_active        boolean,
  allows_free_text boolean,
  option_count     integer,
  item_count       integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select g.id, g.code, g.name, g.min_select, g.max_select, g.sort_order,
         g.is_active, g.allows_free_text,
         (select count(*)::integer from public.pos_modifiers m
           where m.group_id = g.id and m.is_active),
         (select count(*)::integer from public.item_modifier_groups img
           where img.group_id = g.id)
    from public.pos_modifier_groups g
   where g.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by g.is_active desc, g.sort_order, g.name;
$$;

grant execute on function public.pos_modifier_groups_admin(uuid) to authenticated;

comment on function public.pos_modifier_groups_admin(uuid) is
  'Every modifier group a company has, retired ones included, with how many answers it holds, how many dishes ask it, and whether it takes an answer that is not on the list.';
