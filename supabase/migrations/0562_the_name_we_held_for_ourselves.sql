-- =====================================================================
-- iAkauntan :: 0562 the name we held for ourselves
--
-- `0559` gave a person their own address, `0560` let them answer from
-- it and `0561` let them find it again. The remaining piece is the door
-- itself: `mail.iakauntan.com`, an address that opens the mailbox and
-- nothing else, the way `pos.iakauntan.com` opens the till.
--
-- Almost all of that machinery already exists. `0344` gave a name a
-- purpose -- a company's, reserved, or ours -- and a module and a
-- screen to point at, and `confinementFor` in the router turns that
-- into "this address opens the inbox and nowhere else". Pointing `mail`
-- at the `mailbox` module is the whole of the feature.
--
-- Except that it could not be done, for a reason worth writing down.
--
-- ---------------------------------------------------------------------
-- The list held the name against the use it was held for
--
-- `reserved_names` carries `mail`, scope `subdomain`, reason "the mail
-- service". Somebody put it there deliberately, to stop a company
-- taking the name the platform would need. And `check_host_label` is
-- consulted by every path that could ever set one -- including the
-- platform's own -- so `platform_reserve_subdomain('mail', ...)` came
-- back "That name is reserved: the mail service."
--
-- The list was doing its job against the wrong party. A blocklist of
-- names the platform needs is a promise to itself, and a promise you
-- cannot cash is just a refusal with better wording.
--
-- So the check splits in two. The SHAPE -- three to sixty-three
-- characters, letters digits and hyphens, no punycode prefix -- applies
-- to everybody, because a malformed host is malformed whoever asked for
-- it. The BLOCKLIST applies where the name is about to be a company's.
--
-- ---------------------------------------------------------------------
-- And the two-move version of the same thing
--
-- Letting the platform hold `mail` opens a path that did not exist
-- while nobody could hold it at all: hold it as ours, then hand it to a
-- company with `platform_update_reservation`, which takes no name
-- argument on that call and so checked no name. One company owning
-- `mail.iakauntan.com` is exactly what the list exists to prevent, and
-- a rule refused in one move must not be reachable in two.
--
-- `check_host_label` itself is unchanged and still means what it always
-- did, so every other caller -- a company asking for a subdomain, a
-- company asking for a mailbox -- is untouched.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The two halves, separately askable
-- ---------------------------------------------------------------------
create or replace function app.host_label_shape(p_name text)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_name text := app.normalize_host_label(p_name);
begin
  -- RFC 1035's shape, which is also the shape of a mailbox local part
  -- narrow enough to never need quoting: letters, digits and hyphens,
  -- starting and ending with a letter or a digit.
  -- Three at least and 63 at most: the middle run is not optional,
  -- which is what stops a two-character name slipping through.
  if v_name !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
    return 'Use 3 to 63 letters, digits and hyphens, starting and '
        || 'ending with a letter or a digit.';
  end if;

  -- Two hyphens in the third and fourth position is how a punycode name
  -- announces itself. A company asking for one is either confused or
  -- spelling a name in a script this check cannot read.
  if substring(v_name from 3 for 2) = '--' then
    return 'That prefix is reserved for internationalised names.';
  end if;

  return null;
end;
$$;

comment on function app.host_label_shape(text) is
  'Whether a host label is well formed, said without reference to who '
  'is asking. A malformed name is malformed for the platform too. 0562.';

create or replace function app.host_label_reserved(p_name text, p_scope text)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_name   text := app.normalize_host_label(p_name);
  v_reason text;
begin
  select reason into v_reason
    from public.reserved_names
   where name = v_name
     and scope in ('both', p_scope);

  if v_reason is not null then
    return 'That name is reserved: ' || v_reason || '.';
  end if;

  return null;
end;
$$;

comment on function app.host_label_reserved(text, text) is
  'Whether a name is one the platform holds back. Asked separately from '
  'the shape so the platform can use what it reserved for itself. 0562.';

-- Restated over the two halves so there is one copy of each rule.
-- Every caller sees exactly what it saw before: a company asking for a
-- subdomain or a mailbox still gets the whole check.
create or replace function app.check_host_label(p_name text, p_scope text)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(app.host_label_shape(p_name),
                  app.host_label_reserved(p_name, p_scope));
$$;

-- ---------------------------------------------------------------------
-- Holding one
--
-- `0344`'s function, restated with one check changed. Everything else
-- in it -- who may call it, the three-way reading of purpose, a
-- reserved name pointing nowhere -- is `0344`'s and is untouched.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.platform_reserve_subdomain(p_name text, p_org_id uuid DEFAULT NULL::uuid, p_module_code text DEFAULT NULL::text, p_landing_path text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_purpose text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_name    text;
  v_error   text;
  v_module  text := nullif(btrim(p_module_code), '');
  v_path    text := nullif(btrim(p_landing_path), '');
  -- Null means "read it off the rest of the call", which is what every
  -- caller written before this migration meant and could not say. The
  -- same three-way reading the backfill above uses, and for the same
  -- reason: a pointed name with no company was never parked, and
  -- calling it parked here would refuse the call four checks later.
  v_purpose text := coalesce(nullif(btrim(p_purpose), ''),
                             case
                               when p_org_id is not null then 'company'
                               when nullif(btrim(p_module_code), '') is not null
                                 then 'admin'
                               else 'reserved'
                             end);
  v_id      uuid;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can hold a name on our domain'
      using errcode = '42501';
  end if;

  v_name := app.normalize_host_label(p_name);
  -- The shape always. The blocklist only when the name is about to
  -- become a company's -- `0562`. `mail` is on that list with the
  -- reason "the mail service", and until now nothing could ever point
  -- it AT the mail service: the list held the name against the very
  -- use it was being held for.
  v_error := app.host_label_shape(v_name);
  if v_error is null and v_purpose = 'company' then
    v_error := app.host_label_reserved(v_name, 'subdomain');
  end if;
  if v_error is not null then
    raise exception '%', v_error using errcode = '22023';
  end if;

  if exists (select 1 from public.org_subdomains s
              where s.subdomain = v_name) then
    raise exception 'The name % is already taken', v_name
      using errcode = '23505';
  end if;

  if v_purpose not in ('company', 'reserved', 'admin') then
    raise exception 'A name is a company''s, reserved, or ours to use'
      using errcode = '22023';
  end if;

  if v_purpose = 'company' and p_org_id is null then
    raise exception 'Choose the company this address belongs to'
      using errcode = '22023';
  end if;

  if v_purpose <> 'company' and p_org_id is not null then
    raise exception 'A name that is not a company''s cannot have one on it'
      using errcode = '22023';
  end if;

  if p_org_id is not null
     and not exists (select 1 from public.organizations o
                      where o.id = p_org_id and o.deleted_at is null) then
    raise exception 'There is no such company to give it to'
      using errcode = '23503';
  end if;

  if v_module is not null
     and not exists (select 1 from public.platform_modules m
                      where m.code = v_module) then
    raise exception 'There is no module called %', v_module
      using errcode = '23503';
  end if;

  if v_path is not null and v_module is null then
    raise exception 'A screen has to belong to a module. Choose the module '
                    'first, or leave the screen empty for the whole of it'
      using errcode = '22023';
  end if;

  -- Last of the three, and the order matters. A screen with no module
  -- is wrong whoever the name belongs to, so that one keeps the
  -- sentence it has always had and answers first. This one is about
  -- what the name is for rather than the shape of the pointing, and
  -- only reaches a request that was otherwise coherent.
  --
  -- Refused rather than quietly dropped. An operator who chose a module
  -- and then parked the name has contradicted themselves, and silently
  -- keeping half of it leaves a row nobody would predict.
  if v_purpose = 'reserved' and (v_module is not null or v_path is not null) then
    raise exception 'A reserved name answers to nobody, so it cannot open '
                    'a module. Hold it, or put it to use'
      using errcode = '22023';
  end if;

  insert into public.org_subdomains
    (org_id, subdomain, status, requested_by, decided_by, decided_at,
     note, module_code, landing_path, purpose)
  values (p_org_id, v_name, 'approved', auth.uid(), auth.uid(), now(),
          nullif(btrim(p_note), ''), v_module, v_path, v_purpose)
  returning id into v_id;

  return v_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- Moving one
--
-- `0344`'s function, restated with the same split applied to a rename
-- and with the two-move path closed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.platform_update_reservation(p_kind text, p_id uuid, p_org_id uuid DEFAULT NULL::uuid, p_name text DEFAULT NULL::text, p_module_code text DEFAULT NULL::text, p_landing_path text DEFAULT NULL::text, p_release boolean DEFAULT false, p_purpose text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_name    text;
  v_error   text;
  v_module  text := nullif(btrim(p_module_code), '');
  v_path    text := nullif(btrim(p_landing_path), '');
  v_purpose text := nullif(btrim(p_purpose), '');
  v_was     text;
  v_org     uuid;
  v_found   boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can move a name between companies'
      using errcode = '42501';
  end if;

  if p_kind not in ('subdomain', 'mailbox') then
    raise exception 'A reservation is a subdomain or a mailbox. Got %', p_kind
      using errcode = '22023';
  end if;

  if v_purpose is not null and v_purpose not in ('company', 'reserved', 'admin')
  then
    raise exception 'A name is a company''s, reserved, or ours to use'
      using errcode = '22023';
  end if;

  -- A mailbox is always a company's, so there is nothing here to set on
  -- one. Said rather than ignored: silently accepting it would leave a
  -- caller believing a mailbox can be ours.
  if p_kind = 'mailbox' and v_purpose is not null then
    raise exception 'A mailbox is always a company''s'
      using errcode = '22023';
  end if;

  -- Releasing without saying what it becomes is `0342`'s meaning of
  -- release: let go of the company, keep the name.
  if p_kind = 'subdomain' and p_release and v_purpose is null then
    v_purpose := 'reserved';
  end if;

  -- A company that does not exist would otherwise be caught by the
  -- foreign key, with a message nobody outside a database reads.
  if p_org_id is not null
     and not exists (select 1 from public.organizations o
                      where o.id = p_org_id and o.deleted_at is null) then
    raise exception 'There is no such company to give it to'
      using errcode = '23503';
  end if;

  if v_module is not null
     and not exists (select 1 from public.platform_modules m
                      where m.code = v_module) then
    raise exception 'There is no module called %', v_module
      using errcode = '23503';
  end if;

  if v_purpose = 'reserved' and (v_module is not null or v_path is not null) then
    raise exception 'A reserved name answers to nobody, so it cannot open '
                    'a module. Hold it, or put it to use'
      using errcode = '22023';
  end if;

  if p_name is not null then
    v_name := app.normalize_host_label(p_name);
    v_error := app.host_label_shape(v_name);
    -- A mailbox is always a company's, so the blocklist always applies
    -- to one. A subdomain is checked against it only where it is about
    -- to be a company's -- `0562`.
    if v_error is null
       and (p_kind = 'mailbox'
            or coalesce(v_purpose, 'company') = 'company') then
      v_error := app.host_label_reserved(v_name, p_kind);
    end if;
    if v_error is not null then
      raise exception '%', v_error using errcode = '22023';
    end if;
  end if;

  if p_kind = 'subdomain' then
    -- Read before writing, so that "is this about to be a company's?"
    -- can be answered from the row plus the arguments rather than from
    -- the arguments alone.
    select s.purpose, s.org_id into v_was, v_org
      from public.org_subdomains s where s.id = p_id;

    if v_was is null then
      raise exception 'No such reservation' using errcode = 'P0002';
    end if;

    if coalesce(v_purpose, v_was) = 'company'
       and coalesce(p_org_id, case when p_release then null else v_org end)
           is null then
      raise exception 'Choose the company this address belongs to'
        using errcode = '22023';
    end if;

    -- And the other direction. `0562` lets the platform hold a name off
    -- its own blocklist, which opens a path that did not exist before:
    -- handing that name to a company afterwards, with no argument
    -- naming it and so nothing checking it. `mail` becoming one
    -- company's door is the outcome the blocklist exists to prevent,
    -- and it must not be reachable in two moves when it is refused in
    -- one.
    if coalesce(v_purpose, v_was) = 'company' then
      v_error := app.host_label_reserved(
        coalesce(v_name, (select s.subdomain from public.org_subdomains s
                           where s.id = p_id)), 'subdomain');
      if v_error is not null then
        raise exception '%', v_error using errcode = '22023';
      end if;
    end if;

    update public.org_subdomains s
       set purpose   = coalesce(v_purpose, s.purpose),
           -- Released, or moved off being a company's at all. Either
           -- way there is nobody on it afterwards.
           org_id    = case when p_release
                              or coalesce(v_purpose, s.purpose) <> 'company'
                            then null
                            else coalesce(p_org_id, s.org_id) end,
           subdomain = coalesce(v_name, s.subdomain),
           module_code = case
                           when coalesce(v_purpose, s.purpose) = 'reserved'
                             then null
                           when p_module_code is null then s.module_code
                           else v_module end,
           -- Follows the module: a screen left pointing into a module
           -- the name no longer serves is a restriction nobody can
           -- reason about. Three ways that happens now — the name
           -- parked, the module cleared, and the module moved without a
           -- new screen named — and all of them leave the path behind.
           landing_path = case
                            when coalesce(v_purpose, s.purpose) = 'reserved'
                              then null
                            when p_module_code is not null and v_module is null
                              then null
                            when p_module_code is not null
                                 and v_module is distinct from s.module_code
                                 and p_landing_path is null
                              then null
                            when p_landing_path is null then s.landing_path
                            else v_path end
     where s.id = p_id;
  else
    update public.org_mailboxes m
       set org_id     = case when p_release then null
                             else coalesce(p_org_id, m.org_id) end,
           local_part = coalesce(v_name, m.local_part)
     where m.id = p_id;
  end if;

  get diagnostics v_found = row_count;
  if not v_found then
    raise exception 'No such reservation' using errcode = 'P0002';
  end if;
end;
$function$;

-- ---------------------------------------------------------------------
-- And then the name is pointed
--
-- `mail` opens the `mailbox` module. No screen is named, so the router
-- confines the address to every screen of that module, which today is
-- `/inbox` and tomorrow is whatever else the module grows -- naming the
-- screen here would freeze that.
--
-- `purpose` is `admin`: the address is the platform's, with no company
-- behind it. Somebody signing in there arrives at their own company's
-- mail, and `workspace_module_refusal` turns away an account whose
-- company does not hold the module, which is `0346`'s arrangement and
-- not this migration's.
--
-- Skipped where anything already holds the name. A deployment that
-- pointed `mail` somewhere of its own has made a decision, and a
-- migration silently overruling it would be the worst of both.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.org_subdomains where subdomain = 'mail') then
    return;
  end if;

  insert into public.org_subdomains
    (org_id, subdomain, status, requested_at, decided_at, purpose,
     module_code, note)
  values (null, 'mail', 'approved', now(), now(), 'admin', 'mailbox',
          'The webmail door. 0562.');
end $$;
