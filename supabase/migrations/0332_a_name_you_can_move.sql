-- ---------------------------------------------------------------------
-- 0332 — whose name it is, and moving it
--
-- Two things, both about the same screen.
--
-- ## The company had no name on it
--
-- The reservations console read the company through PostgREST's embed:
--
--   .select('id, org_id, subdomain, …, organizations(name)')
--
-- `organizations` carries one SELECT policy, `app.is_org_member(id)`,
-- and a platform operator is not a member of the companies they
-- administer. The embed came back null and every row on the screen
-- said "Unknown company" — for `sinar.iakauntan.com`, for all of them,
-- for as long as the module has existed. The rows themselves were
-- fine: `org_subdomains` lets a platform admin read them, so the list
-- looked complete and was simply anonymous.
--
-- It is not fixable by widening the policy, and it should not be:
-- membership is what `organizations` is for. It is fixable by asking
-- a SECURITY DEFINER function the question instead, which is how every
-- other platform console screen already does it.
--
-- ## A name should be movable
--
-- Nothing could change a reservation after it was decided. A name given
-- to the wrong company, a company that renamed itself, a test
-- reservation an operator wants to hand to a real tenant — all of them
-- meant deleting the row and asking the company to request it again,
-- which they cannot do for a name that is now taken.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Every reservation, with the company on it
--
-- Both kinds in one list, because the console shows them in one list
-- and sorting two client-side collections into one order was already
-- the awkward part of that screen.
-- ---------------------------------------------------------------------
create or replace function public.platform_reservations()
returns table (
  kind text, id uuid, org_id uuid, org_name text, name text,
  status text, requested_at timestamptz, decided_at timestamptz, note text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can see who holds which name'
      using errcode = '42501';
  end if;

  return query
    select 'subdomain'::text, s.id, s.org_id, o.name, s.subdomain,
           s.status, s.requested_at, s.decided_at, s.note
      from public.org_subdomains s
      join public.organizations o on o.id = s.org_id
    union all
    select 'mailbox'::text, m.id, m.org_id, o.name, m.local_part,
           m.status, m.requested_at, m.decided_at, m.note
      from public.org_mailboxes m
      join public.organizations o on o.id = m.org_id
    order by 6, 8 desc nulls last, 7;
end;
$$;

-- ---------------------------------------------------------------------
-- Move it, or correct it
--
-- Both fields are optional and null means "leave it". Passing neither
-- is not an error — it is a save with nothing in it, and refusing that
-- would only make the console ask the question twice.
--
-- The name goes through `app.check_host_label` exactly as a request
-- does. An operator typing directly into the field is the one caller
-- who could otherwise put a space or an underscore into a hostname,
-- and a name that cannot resolve is worse than one that was refused.
-- ---------------------------------------------------------------------
create or replace function public.platform_update_reservation(
  p_kind text,
  p_id uuid,
  p_org_id uuid default null,
  p_name text default null
)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_name  text;
  v_error text;
  v_found boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can move a name between companies'
      using errcode = '42501';
  end if;

  if p_kind not in ('subdomain', 'mailbox') then
    raise exception 'A reservation is a subdomain or a mailbox. Got %', p_kind
      using errcode = '22023';
  end if;

  -- A company that does not exist would otherwise be caught by the
  -- foreign key, with a message nobody outside a database reads.
  if p_org_id is not null
     and not exists (select 1 from public.organizations o
                      where o.id = p_org_id and o.deleted_at is null) then
    raise exception 'There is no such company to give it to'
      using errcode = '23503';
  end if;

  if p_name is not null then
    v_name := app.normalize_host_label(p_name);
    v_error := app.check_host_label(v_name, p_kind);
    if v_error is not null then
      raise exception '%', v_error using errcode = '22023';
    end if;
  end if;

  if p_kind = 'subdomain' then
    update public.org_subdomains s
       set org_id    = coalesce(p_org_id, s.org_id),
           subdomain = coalesce(v_name, s.subdomain)
     where s.id = p_id;
  else
    update public.org_mailboxes m
       set org_id     = coalesce(p_org_id, m.org_id),
           local_part = coalesce(v_name, m.local_part)
     where m.id = p_id;
  end if;

  get diagnostics v_found = row_count;
  if not v_found then
    raise exception 'No such reservation' using errcode = 'P0002';
  end if;
end;
$$;

-- `0165`'s event trigger strips privileges from anything created or
-- replaced in `public`, so the grants go back on. Both are guarded
-- inside; the grant only says who may knock.
grant execute on function public.platform_reservations() to authenticated;
grant execute on function public.platform_update_reservation(
  text, uuid, uuid, text) to authenticated;
