-- ---------------------------------------------------------------------
-- 0445  Who put the expensive things on half price
-- ---------------------------------------------------------------------
-- The last of the audit sweep 0442 started, and the one that needed a
-- change to the write path before the trail was worth having.
--
-- ### What is recorded today, and what is not
--
-- A discount *applied* at the till is recorded properly.
-- `pos_sale_promotions` carries `applied_at` and `applied_by` for every
-- sale, `pos_sales` is audited, and 0153 built the report that names
-- the person who took a price off.
--
-- The *definition* is not. `pos_promotions` says what comes off, from
-- which day, on which items, at which outlets; `upsert_pos_promotion`
-- is the only way to write it, guarded by
-- `app.can_write_module(org, 'pos')`; and the table has `created_at`
-- and `updated_at` but no `created_by`, no `updated_by` and no audit
-- trigger. So the sale that gave away half the stock is attributable
-- and the decision to give it away is not.
--
-- ### Why the trigger needed a change to the function first
--
-- `pos_promotion_items`, `_outlets` and `_channels` are where the money
-- actually is -- a promotion is harmless until something is in its
-- scope -- and `upsert_pos_promotion` rewrote all three on every save:
--
--     delete from public.pos_promotion_items where promotion_id = v_id;
--     insert into public.pos_promotion_items (promotion_id, item_id)
--     select v_id, i from unnest(p_items) i on conflict do nothing;
--
-- Correct, and fine while nothing was watching. Put an audit trigger
-- on it and correcting a promotion's *name* writes a delete and an
-- insert for every item in its scope -- forty rows saying nothing, and
-- the one row that matters buried among them. A trail that reports a
-- change nobody made is the same failure as one that misses a change
-- somebody did.
--
-- So the delete is narrowed to the rows actually leaving. The insert
-- needed nothing: `on conflict do nothing` inserts no row for one that
-- is already there, and a trigger does not fire for a row that was not
-- inserted. Which means the write path is now differential in both
-- directions, and the trail says exactly what moved.
--
-- This is worth stating on its own: the rewrite is not a performance
-- change dressed up as an audit one. Saving a promotion whose scope
-- did not change now writes no rows to those three tables at all,
-- where before it wrote 2n.
--
-- ### Filing them under the right company
--
-- None of the three has an `org_id`; each names its tenant through
-- `promotion_id`. That is the shape 0443 taught, and its guard is what
-- makes this safe: a row whose tenant cannot be resolved is not
-- written, so a promotion cascading away behind a deleted company
-- leaves nothing in the platform's trail. `record_id` comes from
-- `promotion_id` as well, since these tables have no `id` of their own
-- -- the same treatment `access_type_modules` has had since 0236.
--
-- ### Mutants
--
--   * the delete left blanket rather than narrowed -- killed by "the
--     item that was added is recorded", which read 3 where the change
--     was one row joining. The later "saving it again unchanged records
--     nothing" would have caught it too; the earlier assertion gets
--     there first, and both are worth having because they fail
--     differently;
--   * the scope tables' tenant lookup pointed at the wrong column, so
--     it resolves to nothing -- killed by "and what it was pointed at",
--     which read 0, because 0443's guard drops a row it cannot file;
--   * the trigger on `pos_promotions` narrowed to update only, which
--     keeps the apply-time count of four -- killed by "who made the
--     promotion is recorded", which read 0;
--   * `record_id` left null on the scope rows -- **SURVIVED** the first
--     time it was run. Unlike 0444's row-limit cap this one costs a
--     single line to check, so "and which promotion it belongs to" was
--     added and the mutant dies on it. A survivor is a missing
--     assertion whenever the assertion is cheap.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The trigger function, restated from the installed definition
-- ---------------------------------------------------------------------
create or replace function app.write_audit_log()
returns trigger language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_old  jsonb := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
  v_new  jsonb := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
  v_row  jsonb := coalesce(v_new, v_old);
  v_org  uuid;
  v_id   uuid;
  v_from jsonb;
  v_to   jsonb;
begin
  if TG_TABLE_NAME = 'organizations' then
    v_org := (v_row ->> 'id')::uuid;
  elsif TG_TABLE_NAME = 'access_type_modules' then
    select t.org_id into v_org
      from public.access_types t
     where t.id = (v_row ->> 'access_type_id')::uuid;
  elsif TG_TABLE_NAME = 'leave_entitlement_bands' then
    select t.org_id into v_org
      from public.leave_types t
     where t.id = (v_row ->> 'leave_type_id')::uuid;
  elsif TG_TABLE_NAME in ('pos_promotion_items',
                          'pos_promotion_outlets',
                          'pos_promotion_channels') then
    select t.org_id into v_org
      from public.pos_promotions t
     where t.id = (v_row ->> 'promotion_id')::uuid;
  else
    v_org := nullif(v_row ->> 'org_id', '')::uuid;
  end if;

  -- The company is already gone: this row is cascading away behind it.
  -- Only on DELETE, because an insert or an update cannot name an
  -- organization that does not exist -- the source row's own foreign key
  -- has already said so -- and this must not cost a lookup on the path
  -- every invoice takes.
  if TG_OP = 'DELETE'
     and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return null;
  end if;

  -- Since 0442 a null `org_id` is not "readable by nobody"; it is the
  -- platform's own trail, which every platform administrator reads.
  -- Only the two statutory tables genuinely have no tenant. Any other
  -- table arriving here without one has lost the parent it names its
  -- tenant through -- a cascade -- and the parent's own deletion is
  -- audited against the right company. Writing this row would file a
  -- tenant's data under the platform.
  if v_org is null
     and TG_TABLE_NAME not in ('statutory_schedules', 'statutory_rates')
  then
    return null;
  end if;

  begin
    v_id := nullif(v_row ->> 'id', '')::uuid;
  exception when others then
    v_id := null;   -- a table keyed on something other than a uuid
  end;

  if v_id is null and TG_TABLE_NAME = 'access_type_modules' then
    v_id := (v_row ->> 'access_type_id')::uuid;
  end if;

  -- The three promotion scope tables are keyed on the pair, so the
  -- promotion is the record this row is about.
  if v_id is null and TG_TABLE_NAME in ('pos_promotion_items',
                                        'pos_promotion_outlets',
                                        'pos_promotion_channels') then
    v_id := (v_row ->> 'promotion_id')::uuid;
  end if;

  if TG_OP = 'UPDATE' then
    v_to := app.audit_diff(v_old, v_new);
    -- A write that changed nothing is not an event.
    if v_to = '{}'::jsonb then return null; end if;
    v_from := app.audit_diff(v_new, v_old);
  else
    v_from := app.audit_redact(v_old);
    v_to := app.audit_redact(v_new);
  end if;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data,
     ip_address, user_agent)
  values (v_org, auth.uid(), TG_TABLE_NAME, v_id, lower(TG_OP), v_from, v_to,
          nullif(split_part(coalesce(
            app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
          app.request_header('user-agent'));

  return null;
end;
$fn$;

-- ---------------------------------------------------------------------
-- The write path, so the trail reports movement rather than saving
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_promotion(
  p_org uuid,
  p_name text,
  p_kind app.pos_promo_kind,
  p_code text default null,
  p_percent numeric default 0,
  p_amount numeric default 0,
  p_buy integer default 0,
  p_get integer default 0,
  p_starts_on date default null,
  p_ends_on date default null,
  p_weekdays smallint[] default null,
  p_starts_at time without time zone default null,
  p_ends_at time without time zone default null,
  p_min_subtotal numeric default 0,
  p_max_uses integer default null,
  p_max_per_customer integer default null,
  p_items uuid[] default null,
  p_outlets uuid[] default null,
  p_channels text[] default null,
  p_id uuid default null,
  p_is_active boolean default true)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare v_id uuid;
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
    insert into public.pos_promotion_items (promotion_id, item_id)
    select v_id, i from unnest(p_items) i
    on conflict do nothing;
  end if;
  if p_outlets is not null then
    delete from public.pos_promotion_outlets x
     where x.promotion_id = v_id
       and not (x.outlet_id = any (p_outlets));
    insert into public.pos_promotion_outlets (promotion_id, outlet_id)
    select v_id, o from unnest(p_outlets) o
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
$fn$;

-- ---------------------------------------------------------------------
-- The four tables
-- ---------------------------------------------------------------------
drop trigger if exists audit_changes on public.pos_promotions;
create trigger audit_changes
  after insert or delete or update on public.pos_promotions
  for each row execute function app.write_audit_log();

drop trigger if exists audit_changes on public.pos_promotion_items;
create trigger audit_changes
  after insert or delete or update on public.pos_promotion_items
  for each row execute function app.write_audit_log();

drop trigger if exists audit_changes on public.pos_promotion_outlets;
create trigger audit_changes
  after insert or delete or update on public.pos_promotion_outlets
  for each row execute function app.write_audit_log();

drop trigger if exists audit_changes on public.pos_promotion_channels;
create trigger audit_changes
  after insert or delete or update on public.pos_promotion_channels
  for each row execute function app.write_audit_log();

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_n    integer;
  v_log  text := pg_get_functiondef(to_regprocedure('app.write_audit_log()'));
  v_up   text := pg_get_functiondef(to_regprocedure(
    'public.upsert_pos_promotion(uuid, text, app.pos_promo_kind, text, '
    'numeric, numeric, integer, integer, date, date, smallint[], time, '
    'time, numeric, integer, integer, uuid[], uuid[], text[], uuid, '
    'boolean)'));
begin
  select count(*) into v_n
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where not t.tgisinternal
     and t.tgname = 'audit_changes'
     and n.nspname = 'public'
     and c.relname in ('pos_promotions', 'pos_promotion_items',
                       'pos_promotion_outlets', 'pos_promotion_channels');
  if v_n <> 4 then
    raise exception '0445: % of 4 promotion tables audited', v_n;
  end if;

  if position('pos_promotion_items' in v_log) = 0 then
    raise exception
      '0445: write_audit_log does not resolve a scope row''s tenant';
  end if;

  -- The blanket delete this migration replaces, in the form it had.
  if position('delete from public.pos_promotion_items where' in v_up) > 0 then
    raise exception '0445: the scope is still rewritten wholesale';
  end if;
end
$do$;

comment on function public.upsert_pos_promotion(
  uuid, text, app.pos_promo_kind, text, numeric, numeric, integer, integer,
  date, date, smallint[], time, time, numeric, integer, integer, uuid[],
  uuid[], text[], uuid, boolean) is
  'Writes a promotion and its scope. The scope is written '
  'differentially -- only rows that actually joined or left -- so the '
  'audit trail 0445 put on those tables reports movement rather than '
  'saving.';
