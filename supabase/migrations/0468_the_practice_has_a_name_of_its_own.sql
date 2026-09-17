-- ---------------------------------------------------------------------
-- 0468  The practice has a name and an address of its own
-- ---------------------------------------------------------------------
-- `0463` built the demo practice as **Kabeer & Co** on
-- `kabeer@kabeer.my`, which were placeholders taken from the account
-- that asked for it. The practice is **Geswant & Co.** and the account
-- is `geswant@geswant.com`.
--
-- A rename would be a one-line thing if `0463` had not already run
-- anywhere. It has, so this is the part that matters:
--
-- ### Renaming, not building a second one
--
-- The firm is found by slug, and `create_firm` derived `kabeer-co` from
-- the old name. Looking only for `geswant%` would find nothing on a
-- project that already has the practice, build a **second** firm beside
-- the first, and leave two firms whose portfolios the companies move
-- between depending on which one somebody opens. So the lookup accepts
-- either slug and renames what it finds.
--
-- The slug itself is left as it is. It is an identifier rather than a
-- label -- nothing in the app shows it -- and changing it would strand
-- the very lookup that has to keep working next time.
--
-- ### The logins move too
--
-- The seed makes its own demo logins and tears down only its own,
-- recognised by their address. They are `@geswant.demo` now, and the
-- teardown accepts `@kabeer.demo` as well: a rebuild that did not would
-- leave `0463`'s logins behind for ever, belonging to nothing, which is
-- exactly the orphan state `demo_teardown` was written to sweep and
-- this function deliberately does not reach.
--
-- ### Mutants
--
-- Two, restated into a built database and run against
-- `supabase/tests/demo_practice.sql`. Both die, and on different lines,
-- which took a change to the file to arrange:
--
--   * the old slug dropped from the lookup -- killed by "there is still
--     one firm, not two", 2 where 1 was expected;
--   * the rename not applied to a firm that already exists -- killed by
--     "the practice built under the old name is renamed", which came
--     back "Kabeer & Co".
--
-- Both originally died on the *name* assertion, because it came first
-- and aborted the block before the count was reached. That is a pass
-- either way and tells you less than it looks like: two different
-- mistakes with two different consequences were being witnessed by one
-- line. The count now runs first, and each mutant dies on the thing it
-- actually breaks.
-- ---------------------------------------------------------------------

-- Restated from the live definition; the changes are the name, the
-- address, the slug lookup, and the teardown's two domains.
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
       and m.via_firm_id is null;

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
  v_owner := app.demo_user('practice@geswant.demo', 'Geswant Advisory');
  v_practice := app.demo_company(
    v_owner, 'Geswant & Co.', 'llp'::app.entity_type,
    'LLP0026789-LGN', 'C20268901234', '69200',
    'Accounting, bookkeeping and company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Level 15, Menara Geswant, Jalan Sultan Ismail', '03-2181 4500',
    'practice@geswant.demo', 12::smallint);
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
      'client' || substr(md5(r.name), 1, 4) || '@geswant.demo', r.name);

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
  'on a real login: a firm, its own books, and three client companies '
  'in its portfolio. Tears down only the is_demo companies attached to '
  'that firm and the demo logins it made. Run after app.demo_rebuild(). '
  'See 0463, 0468.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('app.demo_practice_rebuild(text)'));
begin
  if position('Geswant & Co.' in v_src) = 0 then
    raise exception '0468: the practice still carries the old name';
  end if;

  -- The half that is easy to lose. Without the old slug in the lookup a
  -- project that already ran 0463 gets a second firm rather than a
  -- renamed one, and nothing anywhere reports it.
  if position('f.slug like ''kabeer-co%''' in v_src) = 0 then
    raise exception
      '0468: a project that already has the practice would get a second '
      'firm instead of a renamed one';
  end if;

  if position('u.email like ''%@kabeer.demo''' in v_src) = 0 then
    raise exception
      '0468: the rebuild would leave 0463''s demo logins behind, '
      'belonging to nothing';
  end if;

  -- And it is still scoped to its own firm. 0463's whole safety
  -- argument is one line, and this file restates the function it is in.
  if position('o.firm_id = v_firm and o.is_demo' in v_src) = 0 then
    raise exception '0468: restating the rebuild dropped 0463''s scope';
  end if;
  if position('There is no account for' in v_src) = 0 then
    raise exception '0468: restating the rebuild dropped the account check';
  end if;
end
$do$;
