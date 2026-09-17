-- ---------------------------------------------------------------------
-- 0476  A contact can change what it is
-- ---------------------------------------------------------------------
-- A company you buy from starts selling to you. Somebody you were only
-- talking to places an order. The contact is the same contact; what it
-- *is* to you has changed, and until now the only way to say so was to
-- pick a different value in a dropdown and hope.
--
-- ### Why a trigger and not a function
--
-- `contacts` is written by a direct `update` under RLS -- there is no
-- `update_contact()` -- so a rule written into a function would be
-- decoration the contact editor walks straight past. Measured before
-- writing it: `contacts` had `set_updated_at`, `audit_changes` and the
-- attachment sweeper, and nothing that looked at `contact_type` at all.
--
-- So the rule is a trigger, and it is the only enforcement. The
-- advisory below reads the same helper, because a rule stated twice is
-- a rule that will disagree with itself -- see 0474.
--
-- ### What the rule is
--
-- Not "which types may follow which". That list would be arbitrary and
-- would get in the way. The rule is narrower and comes from what the
-- app actually does with the value: the customer picker asks for
-- `customer` and `both`, the supplier picker for `supplier` and `both`.
--
-- So a type change may not take away a role the contact is *using*.
-- Retype a supplier with open bills to `customer` and those bills stop
-- being payable through the normal flow -- the contact is no longer in
-- the picker the payment screen offers. Nothing errors; the money is
-- simply unreachable, which is the worst way for a system to say no.
--
-- Adding a role is always allowed, because it takes nothing away.
-- `both` is how you say "and now they are also a customer", and it is
-- what the refusal points people at.
--
-- `prospect` is the strictest, from `0471`'s own words -- somebody you
-- have not sold to yet. Anyone with trading history of either kind is
-- refused it, which is the same rule, not a second one: prospect drops
-- both roles at once.
--
-- ### What it does not do
--
-- No document is touched, no history rewritten, nothing renamed. A
-- contact's past stays exactly as it was posted; this decides only what
-- the contact is offered as next.
--
-- `employee` and `other` are left alone. They are not roles this rule
-- knows how to reason about, and inventing an answer for them would be
-- guessing.
--
-- ### Mutants
--
-- Three, restated into a built database and run against
-- `supabase/tests/contact_conversion.sql`:
--
--   * the trigger dropped -- killed by "a supplier with bills cannot be
--     made customer-only";
--   * the trigger narrowed to fire only on `prospect` -- the shape
--     somebody would write reading the ticket rather than the rule --
--     killed by the same assertion, which is why the prospect case has
--     an assertion of its own that this mutant leaves passing;
--   * the advisory answering from the type instead of from the helper
--     -- killed by "and the screen was offered both", where a prospect
--     that has traded with nobody is wrongly reported as blocked by the
--     role its *label* implies. Worth its own assertions because a menu
--     that hides a fine option, or offers a doomed one, is a different
--     failure from one that lets a bad change through -- and neither
--     touches the trigger.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- What a contact is actually doing
-- ---------------------------------------------------------------------
--
-- One place, read by both the trigger and the advisory. Void and
-- deleted documents do not count: a cancelled invoice is not a trading
-- relationship, and refusing on one would strand a contact created by
-- mistake.
create or replace function app.contact_roles_in_use(p_contact_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select coalesce(array_agg(distinct r order by r), '{}'::text[])
    from (
      select 'customer'::text as r
       where exists (select 1 from public.sales_documents d
                      where d.contact_id = p_contact_id
                        and d.status <> 'void' and d.deleted_at is null)
          or exists (select 1 from public.receipts x
                      where x.contact_id = p_contact_id
                        and x.status <> 'void' and x.deleted_at is null)
          or exists (select 1 from public.pos_sales s
                      where s.contact_id = p_contact_id
                        and s.status <> 'voided')
      union all
      select 'supplier'::text
       where exists (select 1 from public.purchase_documents d
                      where d.contact_id = p_contact_id
                        and d.status <> 'void' and d.deleted_at is null)
          or exists (select 1 from public.purchase_payments p
                      where p.contact_id = p_contact_id
                        and p.status <> 'void' and p.deleted_at is null)
          or exists (select 1 from public.expenses e
                      where e.contact_id = p_contact_id
                        and e.status <> 'void' and e.deleted_at is null)
    ) t;
$$;

comment on function app.contact_roles_in_use(uuid) is
  'Which of customer and supplier a contact is actually trading as, '
  'ignoring void and deleted documents. The one place that answers it: '
  'the type-change trigger and contact_conversions both read this, so '
  'the menu cannot offer what the trigger will refuse. See 0476.';

-- ---------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------
create or replace function app.contact_type_still_fits()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_in_use text[];
  v_lost   text[];
begin
  if new.contact_type is not distinct from old.contact_type then
    return new;
  end if;

  v_in_use := app.contact_roles_in_use(new.id);

  -- Which roles the new type no longer carries. `both` carries both,
  -- `customer` and `supplier` one each, everything else neither --
  -- which is what makes `prospect` strict without a rule of its own.
  select coalesce(array_agg(r), '{}'::text[]) into v_lost
    from unnest(v_in_use) r
   where not (
     r = 'customer' and new.contact_type in ('customer', 'both')
     or r = 'supplier' and new.contact_type in ('supplier', 'both'));

  if array_length(v_lost, 1) is null then
    return new;
  end if;

  raise exception
    '% is still trading as a %. Making them % would take that away, and '
    'their documents would stop appearing where they are paid. Use '
    'Both to add a role instead of replacing one.',
    new.name, array_to_string(v_lost, ' and a '), new.contact_type
    using errcode = '23514';
end $$;

drop trigger if exists contact_type_still_fits on public.contacts;
create trigger contact_type_still_fits
  before update on public.contacts
  for each row execute function app.contact_type_still_fits();

-- ---------------------------------------------------------------------
-- What the screen may offer
-- ---------------------------------------------------------------------
create or replace function public.contact_conversions(p_contact_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org    uuid;
  v_type   text;
  v_name   text;
  v_in_use text[];
  v_out    jsonb := '[]'::jsonb;
  t        text;
  v_lost   text[];
begin
  select c.org_id, c.contact_type::text, c.name
    into v_org, v_type, v_name
    from public.contacts c
   where c.id = p_contact_id and c.deleted_at is null;
  if v_org is null then
    raise exception 'No such contact' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  v_in_use := app.contact_roles_in_use(p_contact_id);

  foreach t in array array['customer', 'supplier', 'both', 'prospect']
  loop
    continue when t = v_type;

    -- The trigger's own arithmetic, on the same answer, rather than a
    -- second opinion about it.
    select coalesce(array_agg(r), '{}'::text[]) into v_lost
      from unnest(v_in_use) r
     where not (r = 'customer' and t in ('customer', 'both')
             or r = 'supplier' and t in ('supplier', 'both'));

    v_out := v_out || jsonb_build_object(
      'to', t,
      'allowed', array_length(v_lost, 1) is null,
      'blocked_by', to_jsonb(v_lost));
  end loop;

  return jsonb_build_object(
    'contact_type', v_type,
    'name', v_name,
    'roles_in_use', to_jsonb(v_in_use),
    'options', v_out);
end $$;

comment on function public.contact_conversions(uuid) is
  'What this contact may be turned into, and what stops the rest. Reads '
  'app.contact_roles_in_use, the same helper the trigger enforces on, so '
  'the menu and the refusal cannot disagree. See 0476.';

grant execute on function public.contact_conversions(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
begin
  -- The enforcement, not a function nobody has to call.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.contacts'::regclass
       and tgname = 'contact_type_still_fits'
       and not tgisinternal) then
    raise exception
      '0476: the rule is not on the table, so the editor walks past it';
  end if;

  -- Both halves reading one helper. Two copies of this arithmetic is
  -- how a menu comes to offer what the trigger refuses.
  if position('app.contact_roles_in_use' in
        pg_get_functiondef(to_regprocedure('app.contact_type_still_fits()'))) = 0
     or position('app.contact_roles_in_use' in
        pg_get_functiondef(to_regprocedure('public.contact_conversions(uuid)'))) = 0
  then
    raise exception
      '0476: the trigger and the advisory no longer read the same helper';
  end if;

  if not has_function_privilege('authenticated',
       to_regprocedure('public.contact_conversions(uuid)'), 'execute') then
    raise exception '0476: the screen cannot ask what it may offer';
  end if;
end
$do$;
