-- Make the credit limit mean something.
--
-- `contacts.credit_limit` has been in the schema since 0003 and the
-- contact editor has collected it since the app was built. Nothing has
-- ever read it. A field that is captured, stored, shown back and never
-- checked is worse than no field: it tells the person entering it that
-- the system is watching the exposure, and it is not.
--
-- Enforced with a trigger rather than inside `post_sales_document`,
-- because the check has to hold for every route that posts — the RPC,
-- a future bulk poster, anything. Rewriting the posting function would
-- also mean copying two hundred lines of it into this migration to
-- change four.
--
-- Three settings, because businesses genuinely differ:
--
--   off    the limit is a note, nothing more
--   warn   the screens say so; posting goes ahead   (the default)
--   block  posting is refused
--
-- The default is `warn`, not `block`. Turning this on for existing books
-- and having invoices start bouncing on limits nobody has revisited in a
-- year would be a change to the business, made by a migration.

alter table public.organizations
  add column if not exists credit_control text not null default 'warn';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'organizations_credit_control_check')
  then
    alter table public.organizations
      add constraint organizations_credit_control_check
      check (credit_control in ('off', 'warn', 'block'));
  end if;
end $$;

comment on column public.organizations.credit_control is
  'off | warn | block — what happens when a customer goes past their credit limit.';

-- ---------------------------------------------------------------------
-- Where a customer stands
--
-- In base currency, converted at each document''s own rate, so a limit
-- set in ringgit means ringgit however the invoices were raised. A limit
-- of zero is no limit rather than a limit of nothing — that is what the
-- column''s default has always meant and every existing row carries it.
-- ---------------------------------------------------------------------
create or replace function public.customer_credit_status(p_contact_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_org         uuid;
  v_limit       numeric(18, 2);
  v_outstanding numeric(18, 2);
  v_control     text;
begin
  select c.org_id, coalesce(c.credit_limit, 0) into v_org, v_limit
    from public.contacts c where c.id = p_contact_id;
  if v_org is null then
    raise exception 'Contact % not found', p_contact_id using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  select credit_control into v_control
    from public.organizations where id = v_org;

  select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
    into v_outstanding
    from public.sales_documents d
   where d.org_id = v_org and d.contact_id = p_contact_id
     and d.gl_entry_id is not null and d.status <> 'void'
     and d.deleted_at is null;

  return jsonb_build_object(
    'control', coalesce(v_control, 'warn'),
    'credit_limit', v_limit,
    'outstanding', round(v_outstanding, 2),
    'available', case when v_limit <= 0 then null
                      else round(v_limit - v_outstanding, 2) end,
    'over_limit', v_limit > 0 and v_outstanding > v_limit);
end;
$$;

-- ---------------------------------------------------------------------
-- The guard
--
-- Fires only on the transition into posted, and only for the document
-- types that increase what a customer owes. A credit note reduces the
-- exposure and must never be blocked by it — refusing to credit somebody
-- because they are over their limit is exactly backwards.
-- ---------------------------------------------------------------------
create or replace function app.enforce_credit_limit()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_control     text;
  v_limit       numeric(18, 2);
  v_outstanding numeric(18, 2);
  v_name        text;
begin
  if new.gl_entry_id is null or old.gl_entry_id is not null then
    return new;
  end if;
  if new.doc_type not in ('invoice', 'debit_note') then
    return new;
  end if;

  select credit_control into v_control
    from public.organizations where id = new.org_id;
  if coalesce(v_control, 'warn') <> 'block' then
    return new;
  end if;

  select coalesce(c.credit_limit, 0), c.name into v_limit, v_name
    from public.contacts c where c.id = new.contact_id;
  if coalesce(v_limit, 0) <= 0 then
    return new;
  end if;

  -- Everything already posted against this customer, plus what this
  -- document is about to add.
  select coalesce(sum(d.balance_amount * coalesce(d.exchange_rate, 1)), 0)
    into v_outstanding
    from public.sales_documents d
   where d.org_id = new.org_id and d.contact_id = new.contact_id
     and d.gl_entry_id is not null and d.status <> 'void'
     and d.deleted_at is null and d.id <> new.id;

  v_outstanding := v_outstanding
                 + new.balance_amount * coalesce(new.exchange_rate, 1);

  if v_outstanding > v_limit then
    raise exception
      'Posting % would take % to % against a credit limit of %. '
      'Raise the limit, take a payment, or set credit control to warn.',
      new.doc_no, v_name, round(v_outstanding, 2), round(v_limit, 2)
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_credit_limit on public.sales_documents;
create trigger enforce_credit_limit
  before update on public.sales_documents
  for each row execute function app.enforce_credit_limit();

revoke all on function app.enforce_credit_limit() from public, anon, authenticated;

revoke all on function public.customer_credit_status(uuid) from public, anon;
grant execute on function public.customer_credit_status(uuid) to authenticated;
