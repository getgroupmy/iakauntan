-- =====================================================================
-- iAkauntan :: the demo practice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_practice.sql
--
-- `app.demo_practice_rebuild()` is the first thing in this project to
-- use the firm layer for real. What has to hold:
--
--   * it refuses an address nobody has signed up with, because the
--     argument is an e-mail and an e-mail is not proof of anything;
--   * the real person owns none of the books. They hold a firm
--     membership, and reach four companies through it;
--   * running it twice leaves four companies, not eight;
--   * a second run does not touch the other demo tenants, or their
--     logins;
--   * `demo_teardown` can still run afterwards -- which is the whole
--     reason one line of it changed.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_who    uuid;
  v_report text;
  v_firm   uuid;
  v_n      integer;
  v_msg    text;
  v_took   boolean;
begin
  -- ------------------------------------------------------------------
  -- An address nobody owns
  -- ------------------------------------------------------------------
  begin
    perform app.demo_practice_rebuild('nobody@nowhere.invalid');
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a practice cannot be built on an address nobody has signed up with',
    not v_took);
  perform pg_temp.check_true('and it says so, and says nothing was made',
    v_msg like '%no account for%' and v_msg like '%Nothing has been created%');
  perform pg_temp.check_eq('because nothing was',
    (select count(*)::integer from public.firms), 0);

  -- ------------------------------------------------------------------
  -- The practice
  -- ------------------------------------------------------------------
  v_who := pg_temp.another_user('accountant@akauntan.test');
  v_report := app.demo_practice_rebuild('accountant@akauntan.test');
  raise notice 'practice said: %', v_report;

  select id into v_firm from public.firms where slug like 'accountant%';
  perform pg_temp.check_true('the firm exists', v_firm is not null);
  perform pg_temp.check_eq('and it is the practice by name',
    (select name from public.firms where id = v_firm), 'Accountant & Co.');

  perform pg_temp.check_eq('and the real person is a partner in it',
    (select role::text from public.firm_members
      where firm_id = v_firm and user_id = v_who), 'partner');

  perform pg_temp.check_eq('four companies in the portfolio',
    (select count(*)::integer from public.organizations
      where firm_id = v_firm), 4);

  perform pg_temp.check_eq('every one of them flagged demo',
    (select count(*)::integer from public.organizations
      where firm_id = v_firm and is_demo), 4);

  -- The point of the arrangement: the person who runs the practice owns
  -- none of the *clients'* books. Everything they can reach there, they
  -- reach through the firm, which is what a practice is and what makes
  -- the portfolio removable.
  --
  -- Narrowed by 0472, which gave the practice its own company outright.
  -- That is not the same claim and never was: a firm's own books are
  -- its own, not an engagement it holds, and the thing this assertion
  -- protects -- that ending an appointment takes nobody's books --
  -- is about the three clients.
  perform pg_temp.check_eq(
    'the real account owns none of the clients'' books',
    (select count(*)::integer from public.org_members m
       join public.organizations o on o.id = m.org_id
      where m.user_id = v_who and m.via_firm_id is null
        and o.name <> 'Accountant & Co.'), 0);
  -- Ownership of the practice's own books first, and the three
  -- borrowed rows second. Both move together when the practice is
  -- handed back to a demo login, and this order makes that mutant die
  -- saying which fact it broke rather than "expected 3, got 4".
  perform pg_temp.check_eq(
    'and owns its own books, which no demo login holds',
    (select count(*)::integer from public.org_members m
       join public.organizations o on o.id = m.org_id
      where m.user_id = v_who and m.via_firm_id is null
        and m.role = 'owner' and o.name = 'Accountant & Co.'), 1);
  -- Counted separately so that a rebuild which lost one of the three
  -- and gained a direct row on a client -- the shape of mistake this
  -- pair watches for -- cannot pass by keeping the total at four.
  perform pg_temp.check_eq('and reaches the three clients through the firm',
    (select count(*)::integer from public.org_members
      where user_id = v_who and via_firm_id = v_firm), 3);

  -- ------------------------------------------------------------------
  -- What is on the screens
  -- ------------------------------------------------------------------
  -- Three clients AND the firm. 0528 put the practice on the register
  -- it keeps for everybody else: a corp-sec firm files its own annual
  -- declaration too, and a register with no sign of the company you
  -- just signed into is a filing cabinet rather than a practice.
  perform pg_temp.check_eq('the practice keeps a statutory register',
    (select count(*)::integer from public.corp_entities e
       join public.organizations o on o.id = e.org_id
      where o.firm_id = v_firm), 4);

  perform pg_temp.check_eq('and the firm is on it, under its own number',
    (select e.registration_no from public.corp_entities e
       join public.organizations o on o.id = e.org_id
      where o.firm_id = v_firm and e.name = 'Accountant & Co.'),
    (select o.registration_no from public.organizations o
      where o.firm_id = v_firm and o.name = 'Accountant & Co.'));

  -- An LLP, not a Sdn Bhd. It matters because the two file different
  -- things: an annual declaration under s.68 of the LLP Act rather than
  -- an annual return under s.68 of the Companies Act, and the deadline
  -- screens read this column to decide which.
  perform pg_temp.check_eq('as an LLP',
    (select e.entity_type::text from public.corp_entities e
       join public.organizations o on o.id = e.org_id
      where o.firm_id = v_firm and e.name = 'Accountant & Co.'), 'llp');

  -- Partners and a compliance officer, which is what an LLP has. A
  -- director or a company secretary here would be the Companies Act
  -- shape stamped on a body that is not under it.
  perform pg_temp.check_eq('with two partners',
    (select count(*)::integer from public.corp_officers x
       join public.corp_entities e on e.id = x.entity_id
       join public.organizations o on o.id = e.org_id
      where o.firm_id = v_firm and e.name = 'Accountant & Co.'
        and x.role = 'partner'), 2);
  perform pg_temp.check_eq('and a compliance officer',
    (select count(*)::integer from public.corp_officers x
       join public.corp_entities e on e.id = x.entity_id
       join public.organizations o on o.id = e.org_id
      where o.firm_id = v_firm and e.name = 'Accountant & Co.'
        and x.role = 'compliance_officer'), 1);
  perform pg_temp.check_eq('and no company secretary, which an LLP has not',
    (select count(*)::integer from public.corp_officers x
       join public.corp_entities e on e.id = x.entity_id
       join public.organizations o on o.id = e.org_id
      where o.firm_id = v_firm and e.name = 'Accountant & Co.'
        and x.role in ('secretary', 'director')), 0);

  perform pg_temp.check_true('the client books have posted invoices',
    (select count(*) from public.sales_documents d
       join public.organizations o on o.id = d.org_id
      where o.firm_id = v_firm and d.status <> 'draft') > 20);

  -- Every company in the portfolio has something still owed -- the
  -- three clients and the practice's own retainers -- so "who owes
  -- what" has an answer and one payment across companies has four sets
  -- of books to settle in.
  perform pg_temp.check_eq(
    'and every company in the portfolio has something outstanding',
    (select count(distinct d.org_id)::integer from public.sales_documents d
       join public.organizations o on o.id = d.org_id
      where o.firm_id = v_firm and coalesce(d.balance_amount, 0) > 0), 4);

  perform pg_temp.check_true('with receipts against the older ones',
    (select count(*) from public.receipts r
       join public.organizations o on o.id = r.org_id
      where o.firm_id = v_firm and r.status = 'posted') > 0);

  -- The ledger balances in every one of them. A demo tenant that cannot
  -- produce a trial balance is the half-built tenant this project has
  -- found before.
  perform pg_temp.check_eq('and the ledger balances in all four',
    (select count(*)::integer from public.organizations o
      where o.firm_id = v_firm
        and (select round(sum(l.debit - l.credit), 2)
               from public.gl_lines l
               join public.gl_entries e on e.id = l.entry_id
              where l.org_id = o.id and e.status = 'posted') <> 0), 0);
end $$;

-- ---------------------------------------------------------------------
-- Twice
-- ---------------------------------------------------------------------
do $$
declare
  v_firm    uuid;
  v_before  integer;
  v_others  integer;
  v_logins  integer;
  v_other   uuid;
  v_stray   uuid;
begin
  select id into v_firm from public.firms where slug like 'accountant%';

  -- A demo tenant standing outside this firm, made here rather than
  -- assumed: counting what happens to be lying around is how an
  -- assertion about "the others" comes to be about nothing at all. The
  -- mutant that tore down every is_demo company survived this file
  -- until this company existed.
  v_other := app.demo_user('other@iakauntan.test', 'Somebody Else');
  perform app.demo_company(
    v_other, 'Syarikat Lain Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202001001111', 'C20201111222', '47190', 'Retail sale in stores',
    '10', 'Klang', '41100', 'No 1, Jalan Lain', '03-3000 0000',
    'lain@example.test', 12::smallint);

  -- And a demo login with nothing left to belong to. The global
  -- teardown sweeps these; a rebuild of one practice has no business
  -- knowing they exist.
  v_stray := app.demo_user('stray@iakauntan.test', 'Nobody At All');

  select count(*)::integer into v_others from public.organizations
   where is_demo and firm_id is distinct from v_firm;
  select count(*)::integer into v_logins from auth.users
   where raw_app_meta_data ->> 'demo' = 'true'
     and email not like '%@geswant.demo';
  perform pg_temp.check_eq('there is something outside the firm to protect',
    v_others, 1);

  perform app.demo_practice_rebuild('accountant@akauntan.test');

  perform pg_temp.check_eq('a second run leaves four companies, not eight',
    (select count(*)::integer from public.organizations
      where firm_id = v_firm), 4);
  perform pg_temp.check_eq('and one firm, not two',
    (select count(*)::integer from public.firms
      where slug like 'accountant%'), 1);
  perform pg_temp.check_eq('the other demo tenants are where they were',
    (select count(*)::integer from public.organizations
      where is_demo and firm_id is distinct from v_firm), v_others);
  perform pg_temp.check_eq('and so are their logins',
    (select count(*)::integer from auth.users
      where raw_app_meta_data ->> 'demo' = 'true'
        and email not like '%@geswant.demo'), v_logins);
  perform pg_temp.check_true(
    'including a demo login that belongs to nothing, which is not this '
    'function''s to sweep',
    exists (select 1 from auth.users where id = v_stray));
end $$;


-- ---------------------------------------------------------------------
-- A practice that was already built under the old name
-- ---------------------------------------------------------------------
--
-- 0463 named this Kabeer & Co, and `create_firm` derived the slug
-- `kabeer-co` from it. Anywhere the practice has already been built,
-- 0468 has to rename that firm rather than stand a second one beside
-- it — two firms, one portfolio moving between them depending on which
-- somebody opens.
do $$
declare
  v_who  uuid;
  v_old  uuid;
  v_firm uuid;
begin
  v_who := pg_temp.another_user('older@akauntan.test');
  perform pg_temp.sign_in_as(v_who);

  -- The firm exactly as 0463 would have left it.
  v_old := public.create_firm('Kabeer & Co', 'AF 002026',
                              'older@akauntan.test', '03-2181 4500');
  perform pg_temp.check_eq('the old firm has the old slug',
    (select slug from public.firms where id = v_old), 'kabeer-co');

  perform app.demo_practice_rebuild('older@akauntan.test');

  -- The count first, deliberately. Losing the old slug from the lookup
  -- and losing the rename are two different mistakes with two different
  -- consequences — a second firm, and a firm still called the old
  -- thing — and asserting the name first would have both mutants dying
  -- on the same line, which tells you less than it looks like it does.
  perform pg_temp.check_eq('there is still one firm, not two',
    (select count(*)::integer from public.firms f
       join public.firm_members m on m.firm_id = f.id
      where m.user_id = v_who), 1);
  perform pg_temp.check_eq('and the practice built under the old name is renamed',
    (select name from public.firms where id = v_old), 'Accountant & Co.');
  perform pg_temp.check_eq('with the whole portfolio on it',
    (select count(*)::integer from public.organizations
      where firm_id = v_old), 4);

  -- The slug is left alone on purpose: nothing shows it, and changing
  -- it would strand the lookup that has to find this firm next time.
  perform pg_temp.check_eq('and the slug it is found by is untouched',
    (select slug from public.firms where id = v_old), 'kabeer-co');

  -- Whose books the practice's own company is. Before 0472 this was
  -- `practice-kabeer-co@geswant.demo`, a login with a published
  -- password that the owner of the firm could not sign in as.
  perform pg_temp.check_eq(
    'the practice''s books belong to the account it was built for',
    (select count(*)::integer from public.org_members m
       join public.organizations o on o.id = m.org_id
      where o.firm_id = v_old and o.name = 'Accountant & Co.'
        and m.user_id = v_who and m.role = 'owner'), 1);
  perform pg_temp.check_true(
    'and no demo login is left holding them',
    not exists (select 1
                  from public.org_members m
                  join public.organizations o on o.id = m.org_id
                  join auth.users u on u.id = m.user_id
                 where o.firm_id = v_old and o.name = 'Accountant & Co.'
                   and coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'));
  -- Two different facts. A rebuild that gets the owner right and the
  -- address wrong sends the practice's own mail to a domain that does
  -- not exist.
  perform pg_temp.check_eq(
    'and the practice is contactable at the firm''s own address',
    (select email from public.organizations
      where firm_id = v_old and name = 'Accountant & Co.'),
    'older@akauntan.test');

  select id into v_firm from public.firms where id = v_old;
  -- The one this migration is mostly about. The owner is now a real,
  -- non-demo, directly-joined member of a company marked demo, which is
  -- precisely what the teardown guard refuses -- so without the
  -- exemption the first run works and the second says the books are
  -- somebody's own.
  perform pg_temp.check_true('so a second run finds it again',
    app.demo_practice_rebuild('older@akauntan.test') is not null);
  perform pg_temp.check_eq('and the portfolio is still four, not eight',
    (select count(*)::integer from public.organizations
      where firm_id = v_old), 4);
  perform pg_temp.check_eq('and still does not make another',
    (select count(*)::integer from public.firms f
       join public.firm_members m on m.firm_id = f.id
      where m.user_id = v_who), 1);

  -- Two practices on one deployment, which is the whole point of the
  -- firm layer and which the seed could not do until 0469: the demo
  -- logins were fixed addresses, so the second account got
  -- `duplicate key value violates unique constraint
  -- "users_email_partial_key"` part-way through, after its firm had
  -- been created.
  perform pg_temp.check_true('two practices can stand side by side',
    (select count(*) from public.firms where slug like 'accountant%'
        or slug like 'kabeer-co%') >= 2);
  -- Asserted on the *client* logins, which are the ones that still
  -- exist. 0472 gave the practice's own books to the real account, so
  -- there is no `practice-...@geswant.demo` left to count -- and an
  -- assertion that counts nothing twice and finds the two counts equal
  -- passes for the rest of time without ever reading anything.
  perform pg_temp.check_true('there are client logins to compare',
    (select count(*) from auth.users
      where email like 'client%@geswant.demo') >= 6);
  perform pg_temp.check_eq(
    'each practice with client logins of its own, named after its firm',
    (select count(distinct split_part(email, '@', 1))::integer
       from auth.users where email like 'client%@geswant.demo'),
    (select count(*)::integer from auth.users
      where email like 'client%@geswant.demo'));
  perform pg_temp.check_eq(
    'and no login stands in for a practice any more',
    (select count(*)::integer from auth.users
      where email like 'practice%@geswant.demo'), 0);
end $$;

-- ---------------------------------------------------------------------
-- And the global teardown still runs
-- ---------------------------------------------------------------------
--
-- This is the assertion the one changed line of `demo_teardown` is for.
-- Before it, a firm holding a single demo company made every rebuild of
-- the whole demo refuse: the borrowed `org_members` row points at a
-- real person, and the guard read that as somebody's own books.
do $$
declare v_report text;
begin
  v_report := app.demo_teardown();
  raise notice 'teardown said: %', v_report;

  perform pg_temp.check_eq('the practice''s companies go with the rest',
    (select count(*)::integer from public.organizations where is_demo), 0);
  perform pg_temp.check_eq('and the firm is left with nothing in it',
    (select count(*)::integer from public.organizations
      where firm_id is not null), 0);

  -- The firm itself stays. It belongs to a real person, and a teardown
  -- of demo data is not the place to close somebody's practice.
  perform pg_temp.check_eq('but the practice itself is still there',
    (select count(*)::integer from public.firms where slug like 'accountant%'),
    1);
end $$;

-- ---------------------------------------------------------------------
-- A company somebody joined in their own right still stops it
-- ---------------------------------------------------------------------
do $$
declare
  v_who  uuid;
  v_firm uuid;
  v_org  uuid;
  v_out  uuid;
  v_msg  text;
  v_took boolean;
begin
  v_who := pg_temp.another_user('accountant2@akauntan.test');
  perform app.demo_practice_rebuild('accountant2@akauntan.test');
  select f.id into v_firm from public.firms f
    join public.firm_members m on m.firm_id = f.id
   where m.user_id = v_who;
  select o.id into v_org from public.organizations o
   where o.firm_id = v_firm order by o.name limit 1;

  -- Somebody real, invited to this company by the company — not lent to
  -- it by the practice. The flag is wrong, not the membership, and the
  -- rebuild has to stop rather than delete their books.
  v_out := pg_temp.another_user('theirs@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_out, 'admin', 'active', now());

  begin
    perform app.demo_practice_rebuild('accountant2@akauntan.test');
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a company with a member of its own is not torn down', not v_took);
  perform pg_temp.check_true('and the refusal names it',
    v_msg like '%theirs@example.test%');
end $$;

rollback;
