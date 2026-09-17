-- ---------------------------------------------------------------------
-- 0484  The practice under its own name
-- ---------------------------------------------------------------------
-- The demo practice was called Geswant & Co. and was reached through
-- `geswant@geswant.com`. Neither reads as a demo: every other demo
-- login on this deployment is `<what they are>@iakauntan.com`, and
-- somebody looking for the accounting firm among warung@, salon@ and
-- legal@ will not think to try a surname. It is now Accountant & Co.
-- at `accountant@iakauntan.com`.
--
-- ### What does not change
--
-- The slug. 0468 settled that `firms.slug` is a stable identifier
-- rather than a label, and this function finds the practice by it --
-- renaming the slug would strand the very lookup that keeps a second
-- run from building a second firm beside the first. A deployment that
-- already ran this has `geswant-co` and keeps it, so `accountant%` is
-- added to the patterns rather than replacing them.
--
-- The client logins keep their `@geswant.demo` addresses for the same
-- reason: they are derived from the slug, and the teardown finds them
-- by that domain. They are the client companies' own logins, not the
-- practice's, and nobody signs in to the demo as one.
--
-- The old login is not deleted where it has already posted documents.
-- `refuse_posted_document_change` will not let `posted_by` be rewritten
-- on a posted invoice, which is the append-only rule doing its job:
-- who posted a document is part of the record. Moving the partner's
-- chair is a membership change, not a rewrite of history.
--
-- ### Mutants
--
-- Run against `supabase/tests/demo_practice.sql`, each named with the
-- assertion that kills it:
--   * the firm named anything else -- "the firm exists", because the
--     test finds it by the slug `create_firm` derives from the name;
--   * the old-name slug patterns dropped, on the deployment this
--     migration is actually for -- "there is still one firm, not two";
--   * the practice company named anything else -- "the real account
--     owns none of the clients' books", because the exclusion that
--     assertion makes is by name.
-- ---------------------------------------------------------------------

create or replace function app.demo_practice_rebuild(
  p_email text default 'accountant@iakauntan.com')
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

comment on function app.demo_practice_rebuild(text) is
  'Builds the demo accounting and secretarial practice, Accountant & '
  'Co., on a real account: the firm, its own books, and three client '
  'companies attached to it. The practice company belongs to the '
  'account named, which signs in with its own password; the client '
  'companies keep demo logins named after the firm slug. Idempotent -- '
  'see 0472 for why the second run used to refuse.';

revoke all on function app.demo_practice_rebuild(text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    'app.demo_practice_rebuild(text)'::regprocedure);
begin
  if position('Accountant & Co.' in v_src) = 0 then
    raise exception '0484: the practice is still named after somebody else';
  end if;
  if position('Geswant & Co.' in v_src) > 0 then
    raise exception '0484: the old name is still written somewhere';
  end if;
  if position('accountant@iakauntan.com' in v_src) = 0 then
    raise exception '0484: the default address was not changed';
  end if;
  -- The patterns that find a practice built before this migration.
  if position('f.slug like ''geswant%''' in v_src) = 0
     or position('f.slug like ''kabeer-co%''' in v_src) = 0 then
    raise exception '0484: a deployment built under the old name is lost';
  end if;
  if has_function_privilege('authenticated',
       'app.demo_practice_rebuild(text)', 'execute') then
    raise exception '0484: the rebuild is a client surface';
  end if;
end $do$;
