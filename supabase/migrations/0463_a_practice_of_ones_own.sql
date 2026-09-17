-- ---------------------------------------------------------------------
-- 0463  A practice of one's own
-- ---------------------------------------------------------------------
-- The firm layer went in at `0450` and nothing has ever used it on a
-- live project: `firms` is empty, and every demo tenant is a company
-- standing on its own. So the one thing an accounting practice does --
-- open a portfolio and move between four sets of books without signing
-- out -- cannot be shown to anybody, including to the person who asked
-- for it.
--
-- This builds that: a firm attached to a **real** login, four demo
-- companies in its portfolio, and a rebuild that can be run again
-- whenever the demonstration wants a clean start.
--
-- ### Why the login has to already exist
--
-- The same rule `0451` settled for a handover. A practice whose only
-- partner is an unaccepted invitation is a practice nobody can open, so
-- this refuses an address with no account behind it and says to sign up
-- first. It is also the safety property that matters here: the function
-- takes an e-mail, and an e-mail nobody owns is exactly how a seed
-- would come to hand a portfolio to a stranger.
--
-- ### The real account owns nothing
--
-- Every seeded company is owned by a demo login and reaches the
-- practice through `firm_id`. The real person holds a `firm_members`
-- row and nothing else, which is both the honest model of a practice --
-- the client owns the books, the accountant is appointed to them -- and
-- what keeps the teardown able to run: a demo company with a real
-- member is refused, and rightly.
--
-- ### One line of `demo_teardown` had to change
--
-- Attaching a company to a firm writes `org_members` rows carrying
-- `via_firm_id`, pointing at real people. `demo_teardown`'s guard read
-- those as "a real person is inside a company marked demo" and refused
-- the whole global rebuild the moment a firm held one.
--
-- The guard is right and the reading was wrong. A `via_firm_id` row is
-- access **lent by a firm**: `detach_company_from_firm` deletes exactly
-- those rows when the appointment ends and leaves everything a person
-- was invited to in their own right alone. Deleting the company ends
-- the appointment. It does not delete anybody's books, which is what
-- the guard exists to prevent.
--
-- ### Rebuilding
--
--   select app.demo_practice_rebuild('kabeer@kabeer.my');
--
-- It tears down **only** the `is_demo` companies attached to that
-- person's firm, and only the demo logins this seed made, which carry
-- an `@kabeer.demo` address. A company the practice keeps that is not
-- flagged demo is not touched, and neither is anything outside the
-- firm. Run it after `app.demo_rebuild()`, not before: the global one
-- removes every `is_demo` company there is, including these.
--
-- ### Mutants
--
-- Five, restated into a built database and run against
-- `supabase/tests/demo_practice.sql`. All five die. **Two survived the
-- assertions as first written**, and both for the same reason:
--
--   * the missing-account guard dropped -- killed by "it says so, and
--     says nothing was made";
--   * the real-member guard dropped -- killed by "a company with a
--     member of its own is not torn down";
--   * the teardown widened from this firm's companies to every
--     `is_demo` company -- **survived**. The file asserted that the
--     other demo tenants were where they were, counted before and
--     after; there were none, so the count was 0 before and 0 after and
--     the assertion could not fail. It now makes a demo company
--     standing outside the firm first, and checks that it made one:
--     expected 1, mutant gives 0;
--   * the login sweep widened from `@kabeer.demo` to every demo login
--     with no membership -- **survived, for the same reason**. Every
--     demo login in the fixture had a company, so there was nothing the
--     wider sweep could take. The file now leaves a demo login
--     belonging to nothing -- which the *global* teardown does sweep,
--     and a rebuild of one practice has no business knowing about --
--     and the mutant takes it: expected 2 logins, gives 1;
--   * `demo_teardown`'s `via_firm_id` clause put back the way it was --
--     killed by the last block, and by exactly the failure this
--     migration is about: "Refusing to tear down: a company marked
--     is_demo has real members. Found: Bayu Digital Sdn Bhd
--     (kabeer@kabeer.test)". One firm holding one demo company, and the
--     whole demo can no longer be rebuilt.
--
-- The lesson the two survivors share is one this project keeps
-- relearning in new clothes: **an assertion that something was left
-- alone proves nothing until there is something to leave alone.**
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The teardown, with borrowed access read as borrowed
-- ---------------------------------------------------------------------
-- Restated from the live definition; the only change is the
-- `via_firm_id` clause and the comment above it.
create or replace function app.demo_teardown()
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $function$
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
     and m.via_firm_id is null;

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

-- ---------------------------------------------------------------------
-- A client company's year
-- ---------------------------------------------------------------------
-- Deliberately plain: a customer, a bank account, a monthly invoice,
-- and the older ones settled. What it is for is that every screen a
-- practice opens on a client -- the ledger, the ageing, the trial
-- balance -- has something on it, and that the two most recent months
-- are still owed, so the practice has invoices in four companies and
-- one payer to settle them with.
create or replace function app.demo_practice_books(
  p_org      uuid,
  p_owner    uuid,
  p_what     text,
  p_fee      numeric,
  p_customer text default 'Kumpulan Awan Sdn Bhd')
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rev      uuid;
  v_na       uuid;
  v_rate     numeric;
  v_cust     uuid;
  v_bank     uuid;
  v_doc      uuid;
  v_rcp      uuid;
  v_month    date;
  v_date     date;
  v_raised   integer := 0;
  v_settled  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_rev from public.accounts
   where org_id = p_org and code = '4100';
  select id, rate into v_na, v_rate from public.tax_codes
   where org_id = p_org and code = 'NA';

  insert into public.contacts (org_id, code, name, contact_type, entity_type,
                               email, city, state_code, created_by)
  values (p_org, 'CUST-001', p_customer, 'customer', 'sdn_bhd',
          'accounts@kumpulanawan.demo', 'Kuala Lumpur', '14', p_owner)
  on conflict (org_id, code) do nothing;
  select id into v_cust from public.contacts
   where org_id = p_org and code = 'CUST-001';

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (p_org,
          (select id from public.accounts where org_id = p_org and code = '1120'),
          'Current account', 'Malayan Banking Berhad',
          '5' || lpad((abs(hashtext(p_org::text)) % 100000000)::text, 11, '0'),
          'MYR', 0, 0, true)
  on conflict do nothing;
  select id into v_bank from public.bank_accounts
   where org_id = p_org and is_default order by created_at limit 1;

  v_month := date_trunc('year', app.today())::date;
  while v_month <= app.today() loop
    v_date := least(v_month + 6, app.today());

    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subject, created_by)
    values (p_org, 'invoice',
            app.next_document_number_internal(p_org, 'invoice'),
            v_date, v_date + 30, v_cust, 'draft', 'MYR', 1,
            p_what || ' — ' || to_char(v_month, 'Mon YYYY'), p_owner)
    returning id into v_doc;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, tax_code_id, tax_rate, account_id)
    values (p_org, v_doc, 1, 'item', p_what, 1, p_fee, v_na, v_rate, v_rev);

    perform public.post_sales_document(v_doc);
    v_raised := v_raised + 1;

    -- Anything older than two months has been paid. The two that have
    -- not are what the portfolio's "who owes what" is made of, and what
    -- a single payment across four companies settles.
    if v_date < (app.today() - 60) then
      insert into public.receipts
        (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
         payment_mode_code, currency, exchange_rate, amount,
         unapplied_amount, reference, created_by)
      values (p_org, app.next_document_number_internal(p_org, 'receipt'),
              v_date + 30, v_cust, v_bank, '03', 'MYR', 1, p_fee, p_fee,
              'Bank transfer', p_owner)
      returning id into v_rcp;

      perform public.allocate_with_discount(v_rcp, v_doc, p_fee, null,
                                            v_date + 30);
      perform public.post_receipt(v_rcp);
      v_settled := v_settled + 1;
    end if;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('%s: %s invoices, %s settled.',
                (select name from public.organizations where id = p_org),
                v_raised, v_settled);
end $$;

-- ---------------------------------------------------------------------
-- The practice, and everything in its portfolio
-- ---------------------------------------------------------------------
create or replace function app.demo_practice_rebuild(
  p_email text default 'kabeer@kabeer.my')
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
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

  select f.id into v_firm from public.firms f
    join public.firm_members m on m.firm_id = f.id
   where m.user_id = v_user and f.slug like 'kabeer-co%'
   order by f.created_at limit 1;

  if v_firm is null then
    v_firm := public.create_firm(
      'Kabeer & Co', 'AF 002026', p_email, '03-2181 4500');
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
         and u.email like '%@kabeer.demo'
         and not exists (select 1 from public.org_members m
                          where m.user_id = u.id)
      returning 1)
    select count(*) into v_users from gone;
  end if;

  -- ------------------------------------------------------------------
  -- The practice's own books
  -- ------------------------------------------------------------------
  v_owner := app.demo_user('practice@kabeer.demo', 'Kabeer Advisory');
  v_practice := app.demo_company(
    v_owner, 'Kabeer & Co', 'llp'::app.entity_type,
    'LLP0026789-LGN', 'C20268901234', '69200',
    'Accounting, bookkeeping and company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Level 15, Menara Kabeer, Jalan Sultan Ismail', '03-2181 4500',
    'practice@kabeer.demo', 12::smallint);
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
      'client' || substr(md5(r.name), 1, 4) || '@kabeer.demo', r.name);

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
end $$;

revoke all on function app.demo_practice_books(uuid, uuid, text, numeric, text)
  from public, anon, authenticated;
revoke all on function app.demo_practice_rebuild(text)
  from public, anon, authenticated;

comment on function app.demo_practice_rebuild(text) is
  'Builds the demo accounting and secretarial practice on a real login: '
  'a firm, its own books, and three client companies in its portfolio. '
  'Tears down only the is_demo companies attached to that firm and the '
  '@kabeer.demo logins it made. Run after app.demo_rebuild(). See 0463.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_td text := pg_get_functiondef(to_regprocedure('app.demo_teardown()'));
  v_pr text := pg_get_functiondef(
    to_regprocedure('app.demo_practice_rebuild(text)'));
begin
  if position('m.via_firm_id is null' in v_td) = 0 then
    raise exception
      '0463: demo_teardown still reads borrowed firm access as somebody''s '
      'own books, so a firm holding one demo company blocks every rebuild';
  end if;

  -- The guard that makes the address safe to pass in.
  if position('There is no account for' in v_pr) = 0 then
    raise exception
      '0463: the practice can be built on an address nobody owns';
  end if;

  -- Scoped teardown. A rebuild of one practice must not reach the other
  -- demo tenants, and the firm is what bounds it.
  if position('o.firm_id = v_firm and o.is_demo' in v_pr) = 0 then
    raise exception
      '0463: the practice rebuild is not scoped to its own firm';
  end if;

  if position('@kabeer.demo' in v_pr) = 0 then
    raise exception
      '0463: the practice rebuild deletes demo logins it did not make';
  end if;
end
$do$;
