-- ---------------------------------------------------------------------
-- 0472  The practice's books belong to the practice
-- ---------------------------------------------------------------------
-- `demo_practice_rebuild` built four companies and handed the practice
-- itself -- Geswant & Co., the one with the client ledger, the
-- timesheets and the statutory register -- to a login called
-- `practice-<slug>@geswant.demo`.
--
-- Nobody can sign in as that. It is created by `app.demo_user`, so its
-- password is the published demo one and its credentials are frozen by
-- `demo_credentials_locked`: it cannot be changed, and it cannot be
-- recovered, because the recovery mail goes to a domain that does not
-- exist. The person who ran the rebuild owns the firm, appears in every
-- client company through it, and is the only one who cannot open the
-- practice's own books.
--
-- So the practice's company is now owned by the account the rebuild is
-- run for. `demo_practice_rebuild('geswant@geswant.com')` gives Geswant
-- & Co. to `geswant@geswant.com`, signed into with that account's own
-- password.
--
-- ### What is deliberately not done
--
-- The address is **not** passed to `app.demo_user`. That would have
-- been the one-line version, and it would have created a *demo* login
-- at a real address: password `Demo!Akaun2026`, frozen by
-- `demo_credentials_locked` so it can never be changed, and deleted by
-- the next rebuild. Handing somebody's own e-mail address a credential
-- they cannot change is worse than the problem it fixes. Nothing in
-- this migration creates or alters an auth user.
--
-- The client companies keep their demo logins. Those are meant to be
-- signed into by whoever is being shown the product, and a shared
-- published password is the right thing for them.
--
-- ### The guard that would have refused the second rebuild
--
-- Both teardowns refuse when a company marked demo has a member who is
-- not a demo login and did not arrive through a firm -- "the flag is
-- wrong, and these are somebody's real books". Handing the practice to
-- a real account creates exactly that row, so the first rebuild would
-- have worked and the second would have refused, naming the account
-- that asked for it. This is the 0469 defect in a new coat: a seed that
-- can be run once.
--
-- The guard now also skips a member who belongs to the firm the company
-- is attached to. It is the narrowest form that works: it exempts the
-- practice from its own portfolio and nobody else, and where `firm_id`
-- is null -- every demo tenant that is not in a portfolio -- it changes
-- nothing at all.
--
-- Marking the row `via_firm_id` instead was the other candidate. It was
-- rejected: that column means "detaching the firm removes this row",
-- and it would have quietly made the owner's access to their own
-- practice detachable.
--
-- ### Mutants
--
-- Four, restated into a built database and run against
-- `supabase/tests/demo_practice.sql`. All four die:
--
--   * the owner put back to `app.demo_user(...)` -- killed by "and owns
--     its own books, which no demo login holds", 0 where 1 was wanted;
--   * the practice company's e-mail put back to a `.demo` address --
--     killed by "and the practice is contactable at the firm's own
--     address". Its own assertion rather than folded into the first:
--     the owner and the company's stated e-mail are two different
--     facts, and a rebuild that gets one right and the other wrong
--     sends the practice's own mail nowhere;
--   * the new clause dropped from the rebuild's own guard -- killed on
--     the second run, with `Refusing to rebuild: a company in this
--     portfolio has a real member of its own. Found: Geswant & Co.`,
--     which is the failure this migration is mostly about;
--   * the new clause dropped from `app.demo_teardown()` -- killed with
--     the same refusal from the global rebuild. Asserted separately
--     because the two guards are two copies of one idea, and a fix
--     applied to one of them is the likeliest way to half-fix this.
--
-- The ownership assertion is placed *before* the one counting the three
-- borrowed rows. Both move when the practice goes back to a demo login,
-- and in the other order the mutant died saying `expected 3, got 4`,
-- which does not name what broke.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.demo_teardown()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_orgs   uuid[];
  v_users  uuid[];
  v_real   text;
  v_owned  text;
  v_names  text;
  v_n      integer;
  v_count  integer;
  v_swept  text := null;
  r        record;
begin
  select array_agg(id), string_agg(name, ', ' order by name)
    into v_orgs, v_names
    from public.organizations where is_demo;

  if v_orgs is null then
    return 'Nothing is marked is_demo; nothing removed.';
  end if;

  -- The guard. A real person inside a company marked demo means the flag
  -- is wrong, and the right response is to stop and say whose account it
  -- is — not to delete their books and report success.
  --
  -- Access lent by a firm is not that. `via_firm_id` says the row was
  -- written by `attach_company_to_firm` and belongs to the appointment,
  -- not to the person; `detach_company_from_firm` deletes exactly these
  -- and leaves what somebody was invited to in their own right. Ending
  -- the appointment by deleting the company takes nobody's books.
  select string_agg(distinct o.name || ' (' || u.email || ')', ', ')
    into v_real
    from public.organizations o
    join public.org_members m on m.org_id = o.id
    join auth.users u on u.id = m.user_id
   where o.id = any (v_orgs)
     and coalesce(u.raw_app_meta_data ->> 'demo', '') <> 'true'
     and m.via_firm_id is null
     -- ...and is not the practice whose books these are. A firm's own
     -- demo company is now owned by the firm's real account rather than
     -- by a throwaway login (see 0472), so without this the second
     -- rebuild would refuse on the account that asked for the first.
     -- Narrow on purpose: it exempts members of the firm the company is
     -- already attached to, and nobody else.
     and not exists (
       select 1 from public.firm_members fm
        where fm.firm_id = o.firm_id and fm.user_id = m.user_id);

  if v_real is not null then
    raise exception
      'Refusing to tear down: a company marked is_demo has real members. '
      'Clear is_demo on it, or remove the member first. Found: %', v_real
      using errcode = '42501';
  end if;

  -- And the same disagreement the other way round. A demo login that
  -- has joined a real company cannot be deleted without taking a
  -- decision about that company, so it is not a decision this function
  -- takes.
  select string_agg(distinct u.email || ' in ' || o.name, ', ')
    into v_owned
    from auth.users u
    join public.org_members m on m.user_id = u.id
    join public.organizations o on o.id = m.org_id
   where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
     and not o.is_demo;

  if v_owned is not null then
    raise exception
      'Refusing to tear down: a demo login is a member of a company that '
      'is not marked demo. Somebody created it while signed in as the '
      'demo. Remove the membership, or mark the company demo, and run '
      'this again. Found: %', v_owned
      using errcode = '42501';
  end if;

  -- The three that will not follow the organization out. Note the column
  -- names: chat rows point at the *sender's* company, not at an owning
  -- one, because a conversation can span two tenants.
  delete from public.chat_messages     where sender_org_id  = any (v_orgs);
  delete from public.chat_calls        where started_by_org = any (v_orgs);
  delete from public.platform_invoices where org_id         = any (v_orgs);

  delete from public.organizations where id = any (v_orgs);

  -- Who is actually going. After the companies are gone, and given the
  -- guard above, this is every demo login.
  select array_agg(u.id) into v_users
    from auth.users u
   where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
     and not exists (select 1 from public.org_members m where m.user_id = u.id);

  if v_users is not null then
    -- Everything still pointing at them, read from the catalogue rather
    -- than from a list somebody has to remember to update. Restricted to
    -- `public`: the `auth` schema's own references cascade, and this is
    -- not the place to reach into them.
    for r in
      select n.nspname as sch, cl.relname as tbl, a.attname as col, a.attnotnull as nn
        from pg_constraint c
        join pg_class cl on cl.oid = c.conrelid
        join pg_namespace n on n.oid = cl.relnamespace
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f'
         and c.confrelid = 'auth.users'::regclass
         and c.confdeltype in ('a', 'r')
         -- Single-column only. A composite key into auth.users would
         -- need a decision this loop is not equipped to make, and
         -- silently reading its first column would be worse than not
         -- touching it.
         and array_length(c.conkey, 1) = 1
         and n.nspname = 'public'
       order by cl.relname, a.attname
    loop
      if r.nn then
        execute format('delete from %I.%I where %I = any($1)', r.sch, r.tbl, r.col)
          using v_users;
      else
        execute format('update %I.%I set %I = null where %I = any($1)',
                       r.sch, r.tbl, r.col, r.col)
          using v_users;
      end if;

      get diagnostics v_n = row_count;
      if v_n > 0 then
        v_swept := concat_ws(', ', v_swept,
          format('%s.%s %s %s row(s)', r.tbl, r.col,
                 case when r.nn then 'deleted' else 'cleared' end, v_n));
      end if;
    end loop;

    delete from auth.users u where u.id = any (v_users);
    get diagnostics v_count = row_count;
  else
    v_count := 0;
  end if;

  return format('Removed %s demo company(ies) [%s] and %s demo user(s).%s',
                array_length(v_orgs, 1), v_names, v_count,
                case when v_swept is null then ''
                     else ' Also released: ' || v_swept || '.' end);
end $function$;

CREATE OR REPLACE FUNCTION app.demo_practice_rebuild(p_email text DEFAULT 'geswant@geswant.com'::text)
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
     and (f.slug like 'geswant%' or f.slug like 'kabeer-co%')
   order by f.created_at limit 1;

  if v_firm is null then
    v_firm := public.create_firm(
      'Geswant & Co.', 'AF 002026', p_email, '03-2181 4500');
  else
    update public.firms
       set name = 'Geswant & Co.', email = p_email
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
    v_owner, 'Geswant & Co.', 'llp'::app.entity_type,
    'LLP0026789-LGN', 'C20268901234', '69200',
    'Accounting, bookkeeping and company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Level 15, Menara Geswant, Jalan Sultan Ismail', '03-2181 4500',
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
  'Builds the demo accounting and secretarial practice, Geswant & Co., '
  'on a real account: the firm, its own books, and three client '
  'companies attached to it. The practice company belongs to the '
  'account named, which signs in with its own password; the client '
  'companies keep demo logins named after the firm slug. Idempotent -- '
  'see 0472 for why the second run used to refuse.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_reb text := pg_get_functiondef(
    to_regprocedure('app.demo_practice_rebuild(text)'));
  v_td  text := pg_get_functiondef(to_regprocedure('app.demo_teardown()'));
begin
  if position('practice-'' || v_tag' in v_reb) <> 0 then
    raise exception
      '0472: the practice is still owned by a login nobody can sign in as';
  end if;

  -- The client logins still hang off the firm slug -- 0469's fix, which
  -- this migration must not undo while removing the login beside it.
  if position('|| ''-'' || v_tag' in v_reb) = 0 then
    raise exception
      '0472: the client demo logins are no longer named after the firm, '
      'so a second practice on this deployment would collide with the first';
  end if;

  if position('public.firm_members fm' in v_reb) = 0
     or position('public.firm_members fm' in v_td) = 0 then
    raise exception
      '0472: a teardown still reads the practice''s own account as '
      'somebody else''s real member, so the rebuild can only be run once';
  end if;
end
$do$;
