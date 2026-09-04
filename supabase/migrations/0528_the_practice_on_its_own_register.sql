-- =====================================================================
-- The practice on its own register
--
-- "Accountant & Co." is already a company secretarial firm in every
-- respect but one: 0484 gives it the `secretarial` and `mbrs` modules,
-- its MSIC nature of business reads "Accounting, bookkeeping and
-- company secretarial services", and `app.demo_books_amanah` seeds it
-- three client companies with directors, a secretary, share classes and
-- statutory deadlines.
--
-- What it does not have is ITSELF.
--
-- Every corp-sec practice in Malaysia is a registered body that files
-- its own returns, and an LLP under the LLP Act 2012 has obligations of
-- its own: an annual declaration under s.68, a compliance officer under
-- s.27, and partners rather than directors. A demo of a secretarial
-- practice whose own register contains three clients and no sign of the
-- firm is a demo of a filing cabinet rather than of a practice --
-- somebody opening the statutory register looks for the company they
-- just signed into and does not find it.
--
-- So this adds the firm to the register it keeps, with the two things
-- an LLP register actually holds: its partners, and the compliance
-- officer who is answerable for the filings. It is the same shape as
-- the client entities, which is the point -- a practice reads its own
-- record on the screen it reads everybody else's.
--
-- Idempotent, and safe to run against a demo that already exists: the
-- ON CONFLICT clauses are the same ones 0485 uses, because the demo
-- rebuild calls this whenever it runs.
-- =====================================================================

create or replace function app.demo_practice_entity(
  p_org uuid, p_owner uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_entity uuid;
begin
  -- The firm, with the registration number 0484 gave the organization
  -- itself. Read from the row rather than repeated, so the two can
  -- never drift into being two different companies with one name.
  insert into public.corp_entities (
    org_id, name, registration_no, entity_type, status,
    incorporated_on, incorporated_in,
    financial_year_end_day, financial_year_end_month,
    nature_of_business, msic_code, is_audit_exempt, engaged_on,
    created_by)
  select
    p_org, o.name, o.registration_no, 'llp'::app.corp_entity_type,
    'incorporated'::app.corp_entity_status,
    date '2012-07-02', 'Malaysia', 31, 12,
    'Accounting, bookkeeping and company secretarial services',
    '69200',
    -- An LLP is not audit exempt by the Companies Act route; it is
    -- outside that Act altogether and audits only if its partnership
    -- agreement says so. False is the honest value here: the flag
    -- answers a Companies Act question this entity does not face, and
    -- true would read as "no audit needed" for the wrong reason.
    false, date '2012-07-02', p_owner
  from public.organizations o
  where o.id = p_org
  on conflict (org_id, registration_no) do nothing;

  select id into v_entity from public.corp_entities
   where org_id = p_org and entity_type = 'llp'
   order by created_at limit 1;
  if v_entity is null then return null; end if;

  -- The partners, and the compliance officer. An LLP has no directors
  -- and no company secretary: s.27 of the LLP Act 2012 requires a
  -- compliance officer instead, and that is who answers for the annual
  -- declaration. Nurul is the practice's own licensed secretary, who
  -- already signs for the three client companies, and it is right that
  -- the same person carries this: it is what a small practice does.
  insert into public.corp_persons (
    org_id, kind, full_name, nric, nationality, is_resident_in_malaysia, email)
  values
    (p_org, 'individual', 'Sharifah binti Omar', '740518-14-5266', 'MY',
     true, 'sharifah@accountantco.demo'),
    (p_org, 'individual', 'Chan Wai Keong', '690227-10-5142', 'MY',
     true, 'wk.chan@accountantco.demo')
  on conflict (org_id, nric) where nric is not null do nothing;

  insert into public.corp_officers (
    org_id, entity_id, person_id, role, appointed_on, consent_received_on)
  select p_org, v_entity, pr.id, o.role::app.corp_officer_role,
         o.appointed_on, o.appointed_on
    from (values
      ('Sharifah binti Omar',  'partner',            date '2012-07-02'),
      ('Chan Wai Keong',       'partner',            date '2014-04-01'),
      ('Nurul Hakim bin Idris','compliance_officer', date '2012-07-02')
    ) as o(person, role, appointed_on)
    join public.corp_persons pr
      on pr.org_id = p_org and pr.full_name = o.person
   where not exists (
     select 1 from public.corp_officers x
      where x.entity_id = v_entity and x.person_id = pr.id
        and x.role = o.role::app.corp_officer_role);

  -- Capital contributions rather than shares. An LLP has no share
  -- capital, so the register of members is a register of what each
  -- partner put in -- but `corp_share_classes` is the only structure
  -- this schema has for it, and modelling contributions as a class
  -- named for what they are keeps the screens working while saying on
  -- the record that they are not shares.
  insert into public.corp_share_classes (
    org_id, entity_id, code, name, currency, votes_per_share)
  values (p_org, v_entity, 'CONTRIB', 'Capital contribution', 'MYR', 1)
  on conflict do nothing;

  return v_entity;
end;
$$;

comment on function app.demo_practice_entity(uuid, uuid) is
  'Puts the demo practice on the statutory register it keeps for its '
  'clients: an LLP with partners and a compliance officer rather than '
  'directors and a secretary. See 0528.';

revoke all on function app.demo_practice_entity(uuid, uuid)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- And the builder calls it
--
-- `app.demo_practice_rebuild` is 0484's, re-emitted here whole with one
-- line added, because migrations are append-only and 0484 has long
-- since reached the hosted project. Everything else below is byte for
-- byte what the database already had -- read it as a diff of one
-- statement, which is what it is.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_practice_rebuild(p_email text DEFAULT 'accountant@iakauntan.com'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_user     uuid;
  v_firm     uuid;
  v_orgs     uuid[];
  v_names    text;
  v_real     text;
  v_users    integer := 0;
  v_practice uuid;
  v_client   uuid;
  v_owner    uuid;
  v_sec      text;
  v_books    text := '';
  -- The firm's slug, which `create_firm` already made unique. It is
  -- what keeps two practices on one deployment from asking for the same
  -- demo login. See 0469.
  v_tag      text;
  r          record;
begin
  select id into v_user from auth.users
   where lower(email) = lower(btrim(p_email)) limit 1;

  if v_user is null then
    raise exception
      'There is no account for %. A practice is built on a real login: '
      'sign up with that address first, then run this again. Nothing '
      'has been created.', p_email using errcode = 'P0002';
  end if;

  -- ------------------------------------------------------------------
  -- The firm, made the way a person would make one
  -- ------------------------------------------------------------------
  perform app.demo_act_as(v_user);

  -- Either slug. `0463` built this practice as `kabeer-co`, and a
  -- project that has already run it must be *renamed* rather than given
  -- a second firm sitting beside the first with the same companies
  -- moving between them. The slug is left alone: it is a stable
  -- identifier, not a label, and changing it would strand exactly the
  -- lookup this line is doing.
  select f.id into v_firm from public.firms f
    join public.firm_members m on m.firm_id = f.id
   where m.user_id = v_user
     and (f.slug like 'accountant%' or f.slug like 'geswant%'
          or f.slug like 'kabeer-co%')
   order by f.created_at limit 1;

  if v_firm is null then
    v_firm := public.create_firm(
      'Accountant & Co.', 'AF 002026', p_email, '03-2181 4500');
  else
    update public.firms
       set name = 'Accountant & Co.', email = p_email
     where id = v_firm;
  end if;

  select f.slug into v_tag from public.firms f where f.id = v_firm;

  -- ------------------------------------------------------------------
  -- Teardown, scoped to this firm's own demo companies
  -- ------------------------------------------------------------------
  select array_agg(o.id), string_agg(o.name, ', ' order by o.name)
    into v_orgs, v_names
    from public.organizations o
   where o.firm_id = v_firm and o.is_demo;

  if v_orgs is not null then
    -- The same guard `demo_teardown` makes, narrowed to this firm. A
    -- person who was invited to one of these companies in their own
    -- right -- `via_firm_id` null -- is somebody whose books these are,
    -- and the flag is wrong rather than the membership.
    select string_agg(distinct o.name || ' (' || u.email || ')', ', ')
      into v_real
      from public.organizations o
      join public.org_members m on m.org_id = o.id
      join auth.users u on u.id = m.user_id
     where o.id = any (v_orgs)
       and coalesce(u.raw_app_meta_data ->> 'demo', '') <> 'true'
       and m.via_firm_id is null
       -- See app.demo_teardown(); the same exemption, for the same
       -- reason. The account this rebuild is being run for owns the
       -- practice's books, and it is not somebody else's real member.
       and not exists (
         select 1 from public.firm_members fm
          where fm.firm_id = o.firm_id and fm.user_id = m.user_id);

    if v_real is not null then
      raise exception
        'Refusing to rebuild: a company in this portfolio has a real '
        'member of its own. Found: %', v_real using errcode = '42501';
    end if;

    delete from public.chat_messages     where sender_org_id  = any (v_orgs);
    delete from public.chat_calls        where started_by_org = any (v_orgs);
    delete from public.platform_invoices where org_id         = any (v_orgs);
    delete from public.organizations where id = any (v_orgs);

    -- Only the logins this seed makes. Scoped by address rather than by
    -- the demo flag, so a rebuild of the practice can never take the
    -- other demo tenants' logins with it.
    with gone as (
      delete from auth.users u
       where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
         and (u.email like '%@geswant.demo' or u.email like '%@kabeer.demo')
         and not exists (select 1 from public.org_members m
                          where m.user_id = u.id)
      returning 1)
    select count(*) into v_users from gone;
  end if;

  -- ------------------------------------------------------------------
  -- The practice's own books
  -- ------------------------------------------------------------------
  -- The practice's books belong to the person whose practice it is.
  --
  -- They used to belong to `practice-<slug>@geswant.demo`, a demo login
  -- with a published password that nobody could sign in as without
  -- being told it -- so the one company in this portfolio the owner
  -- most wants to open was the one they could not. Handing it to the
  -- account the rebuild is being run for costs nothing and removes a
  -- shared-password login from the practice's own ledger.
  --
  -- No credential is created or changed here. `app.demo_user` would
  -- have frozen this address under `demo_credentials_locked` -- no
  -- password change, no address change, ever -- which is not something
  -- to do to somebody's real login.
  v_owner := v_user;
  v_practice := app.demo_company(
    v_owner, 'Accountant & Co.', 'llp'::app.entity_type,
    'LLP0026789-LGN', 'C20268901234', '69200',
    'Accounting, bookkeeping and company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Level 15, Menara Akauntan, Jalan Sultan Ismail', '03-2181 4500',
    p_email, 12::smallint);
  perform app.demo_modules(v_practice, array[
    'secretarial', 'einvoice', 'purchases', 'timesheets', 'crm', 'mbrs',
    'chat']);

  -- The secretarial side, reused whole. It seeds three client
  -- companies into the statutory register, and the three tenants below
  -- carry the same names deliberately: the practice that files their
  -- returns is the one that keeps their books, which is the thing a
  -- combined firm actually is.
  v_sec := app.demo_books_amanah(v_practice, v_owner);

  -- 0528. And the practice itself, on the register it keeps for them.
  -- Added here rather than inside `demo_books_amanah` because that
  -- function also builds Amanah Setiausaha, whose own facts are its
  -- own; this line is about THIS firm.
  perform app.demo_practice_entity(v_practice, v_owner);

  -- ------------------------------------------------------------------
  -- The portfolio
  -- ------------------------------------------------------------------
  for r in
    select * from (values
      ('Kilang Lestari Sdn Bhd', '201903001234', 'C20191234567', '22192',
       'Manufacture of rubber products', '05', 'Seremban', '70200',
       'Lot 12, Kawasan Perindustrian Senawang', 'Rubber mouldings',
       4800::numeric),
      ('Pinang Holdings Berhad', '201501009012', 'C20159012345', '64200',
       'Investment holding', '07', 'George Town', '10450',
       'Tingkat 9, Wisma Pinang, Jalan Burma', 'Management fee',
       9500::numeric),
      ('Bayu Digital Sdn Bhd', '202209005678', 'C20225678901', '62010',
       'Computer programming activities', '10', 'Cyberjaya', '63000',
       'Blok 3, Star Central, Lingkaran Cyber Point', 'Software retainer',
       6200::numeric)
    ) as t(name, reg, tin, msic, activity, state, city, postcode,
           address, what, fee)
  loop
    v_owner := app.demo_user(
      'client' || substr(md5(r.name), 1, 4) || '-' || v_tag
        || '@geswant.demo', r.name);

    v_client := app.demo_company(
      v_owner, r.name, 'sdn_bhd'::app.entity_type, r.reg, r.tin, r.msic,
      r.activity, r.state, r.city, r.postcode, r.address,
      '03-0000 0000',
      'accounts@' || lower(regexp_replace(split_part(r.name, ' ', 1),
                                          '[^A-Za-z0-9]', '', 'g')) || '.demo',
      12::smallint);
    perform app.demo_modules(v_client, array['einvoice', 'purchases']);

    -- Appointed, rather than joined. `attach_company_to_firm` asks the
    -- caller to be an admin of the company *and* a member of the firm,
    -- which is a question about a person appointing a practice; a seed
    -- is not a person, so it writes what that function writes and calls
    -- the same synchroniser.
    update public.organizations
       set firm_id = v_firm, firm_member_role = 'accountant'
     where id = v_client;

    v_books := v_books || ' ' || app.demo_practice_books(
      v_client, v_owner, r.what, r.fee);
  end loop;

  update public.organizations
     set firm_id = v_firm, firm_member_role = 'accountant'
   where id = v_practice;
  perform app.sync_firm_access(v_firm);

  perform app.demo_modules_in_use();
  perform set_config('request.jwt.claims', '', true);

  return format(
    'Practice for %s: removed %s [%s] and %s login(s); rebuilt 4 '
    'companies. %s%s',
    p_email,
    coalesce(array_length(v_orgs, 1), 0), coalesce(v_names, 'nothing'),
    v_users, v_sec, v_books);
end $function$;
