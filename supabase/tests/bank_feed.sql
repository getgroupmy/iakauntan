-- =====================================================================
-- iAkauntan :: a statement that arrives by itself
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_feed.sql
--
-- `0567` builds what a bank feed needs around `import_bank_transactions`
-- and deliberately writes no connector, because there is no bank API in
-- the environment it was built in and a connector written against a
-- guessed response would look finished.
--
-- So what is asserted is the half that can be, and the first assertion
-- is the one the whole idea rests on: A FEED RE-DELIVERING AN
-- OVERLAPPING WINDOW IMPORTS NOTHING TWICE. A person uploads a CSV
-- once and chooses the range; a feed re-delivers forever, and an import
-- without that property doubles every transaction in the overlap --
-- silently, and found at reconciliation.
--
-- The second is that the credential cannot be read by anybody holding
-- the publishable key, which is the same two barriers `0107` and `0412`
-- put around an LHDN private key and an acquirer secret.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The fixture
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_clerk uuid;
  v_org   uuid;
  v_acct  uuid;
  v_gl    uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Suapan Bank Sdn Bhd');

  select id into v_gl from public.accounts
   where org_id = v_org and account_type = 'asset' limit 1;

  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, currency, account_id)
  values (v_org, 'Current', 'Maybank', '512345678901', 'MYR', v_gl)
  returning id into v_acct;

  v_clerk := pg_temp.another_user('clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active');

  create temporary table fixture on commit drop as
  select v_org as org, v_owner as owner, v_clerk as clerk, v_acct as acct;
end $$;

-- ---------------------------------------------------------------------
-- The property the whole idea rests on
-- ---------------------------------------------------------------------
do $$
declare
  f       record;
  v_first jsonb;
  v_again jsonb;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);

  -- Three days of statement, with the running balance that makes it a
  -- statement rather than a list.
  v_first := public.import_bank_transactions(f.acct, jsonb_build_array(
    jsonb_build_object('transaction_date', '2026-03-01', 'amount', 1000,
                       'description', 'Opening transfer',
                       'running_balance', 1000),
    jsonb_build_object('transaction_date', '2026-03-02', 'amount', -250,
                       'description', 'Supplier payment',
                       'running_balance', 750),
    jsonb_build_object('transaction_date', '2026-03-03', 'amount', 400,
                       'description', 'Customer receipt',
                       'running_balance', 1150)));

  perform pg_temp.check_eq('the first pull imports the statement',
    (v_first ->> 'imported')::int, 3);

  -- THE ASSERTION THIS FILE EXISTS FOR. A feed does not choose its
  -- window the way a person does: it re-delivers the last few days
  -- every time it runs, forever. Two of these three lines have been
  -- seen before.
  v_again := public.import_bank_transactions(f.acct, jsonb_build_array(
    jsonb_build_object('transaction_date', '2026-03-02', 'amount', -250,
                       'description', 'Supplier payment',
                       'running_balance', 750),
    jsonb_build_object('transaction_date', '2026-03-03', 'amount', 400,
                       'description', 'Customer receipt',
                       'running_balance', 1150),
    jsonb_build_object('transaction_date', '2026-03-04', 'amount', -100,
                       'description', 'Bank charges',
                       'running_balance', 1050)));

  perform pg_temp.check_eq('an overlapping window imports only what is new',
    (v_again ->> 'imported')::int, 1);
  perform pg_temp.check_eq('and skips what it has already delivered',
    (v_again ->> 'skipped')::int, 2);

  perform pg_temp.check_eq('so the account holds four lines, not six',
    (select count(*)::int from public.bank_transactions
      where bank_account_id = f.acct), 4);

  -- And the same day twice is not the same line twice: the balance is
  -- in the key precisely so two identical withdrawals both land.
  perform pg_temp.check_eq('two identical payments on one day both import',
    (public.import_bank_transactions(f.acct, jsonb_build_array(
      jsonb_build_object('transaction_date', '2026-03-05', 'amount', -50,
                         'description', 'Parking', 'running_balance', 1000),
      jsonb_build_object('transaction_date', '2026-03-05', 'amount', -50,
                         'description', 'Parking', 'running_balance', 950)))
     ->> 'imported')::int, 2);
end $$;

-- ---------------------------------------------------------------------
-- The credential, and the two barriers around it
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);

  perform public.connect_bank_feed(f.acct, 'maybank', 'secret-key',
                                   'secret-signing', 'ACC-1');

  -- Two barriers, and the OUTER one answers first: nothing is granted,
  -- so a select is refused before row level security is consulted at
  -- all. That is the right order and it is worth knowing which one is
  -- speaking -- a test that expected zero rows would pass just as well
  -- with the grant restored and the policies gone.
  -- As the role the app holds. Owner bypasses both barriers, so this
  -- has to be asked as somebody the barriers apply to.
  set local role authenticated;
  perform pg_temp.check_refused(
    'nobody holding the publishable key reads the feed row',
    'select count(*) from public.bank_feeds',
    '%permission denied%');
  reset role;

  perform pg_temp.check_true('because nothing is granted on it',
    not has_table_privilege('authenticated', 'public.bank_feeds', 'select'));
  perform pg_temp.check_true('nor to anon',
    not has_table_privilege('anon', 'public.bank_feeds', 'select'));

  -- And the inner one is there too, so removing the grant alone does
  -- not open it. `0107`'s shape: RLS enabled with no policies at all.
  perform pg_temp.check_true('and row level security is on with no policies',
    (select relrowsecurity from pg_class
      where oid = 'public.bank_feeds'::regclass)
    and not exists (select 1 from pg_policy
                     where polrelid = 'public.bank_feeds'::regclass));
end $$;

-- ---------------------------------------------------------------------
-- What a screen may know
-- ---------------------------------------------------------------------
do $$
declare
  f      record;
  v_seen jsonb;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);
  v_seen := public.bank_feed_status(f.acct);

  perform pg_temp.check_eq('the screen is told which bank',
    v_seen ->> 'provider', 'maybank');
  perform pg_temp.check_true('and that a key is set',
    (v_seen ->> 'has_api_key')::boolean);

  -- Whether one is set, never what it is. A status function that
  -- carried the key would undo both barriers above in one line.
  perform pg_temp.check_true('and never what the key is',
    v_seen::text not like '%secret-key%'
    and v_seen::text not like '%secret-signing%');

  -- A clerk works here, so the status is theirs to read: whether the
  -- bank feed is working is exactly what a bookkeeper needs.
  perform pg_temp.sign_in_as(f.clerk);
  perform pg_temp.check_eq('a clerk is told the same thing',
    public.bank_feed_status(f.acct) ->> 'provider', 'maybank');
end $$;

-- ---------------------------------------------------------------------
-- Who may connect one
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.clerk);

  -- Connecting a feed hands a third party a reader on the company's
  -- bank statements. That is not an ordinary bookkeeping act, and it
  -- is guarded the way the credential tables are.
  perform pg_temp.check_refused(
    'a clerk cannot connect a bank feed',
    format('select public.connect_bank_feed(%L, %L, %L)',
           f.acct, 'maybank', 'their-key'),
    '%owner or administrator%', '42501');

  perform pg_temp.check_refused(
    'nor disconnect one',
    format('select public.disconnect_bank_feed(%L)', f.acct),
    '%owner or administrator%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- Saving the rest of the form does not clear the key
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);

  -- The screen cannot read the key back, so an empty box means
  -- "unchanged". A version that read it as "clear" would disconnect the
  -- feed every time somebody corrected the account reference.
  perform public.connect_bank_feed(f.acct, 'maybank', null, null, 'ACC-2');
  perform pg_temp.check_true('an empty key box leaves the key alone',
    (public.bank_feed_status(f.acct) ->> 'has_api_key')::boolean);
  perform pg_temp.check_eq('and the rest of the form still saves',
    public.bank_feed_status(f.acct) ->> 'account_ref', 'ACC-2');
end $$;

-- ---------------------------------------------------------------------
-- A feed that has stopped is visible
-- ---------------------------------------------------------------------
do $$
declare
  f      record;
  v_feed uuid;
  v_seen jsonb;
begin
  select * into f from fixture;
  select id into v_feed from public.bank_feeds where bank_account_id = f.acct;

  -- The worker's own function, under the role the worker holds.
  set local role service_role;
  perform public.record_bank_feed_run(v_feed, false, 0, 0,
                                      'The token has expired');
  reset role;

  perform pg_temp.sign_in_as(f.owner);
  v_seen := public.bank_feed_status(f.acct);

  -- The failure mode of a feed is silence, not a wrong figure. This is
  -- what makes it audible.
  perform pg_temp.check_eq('a failed pull marks the feed failed',
    v_seen ->> 'status', 'failed');
  perform pg_temp.check_eq('and says what went wrong',
    v_seen ->> 'last_error', 'The token has expired');
  perform pg_temp.check_true('and the run is on the record',
    (v_seen -> 'last_run' ->> 'ok')::boolean is false);

  -- Re-entering the credential is how somebody mends it, so it must
  -- not leave a screen saying broken after it was fixed.
  perform public.connect_bank_feed(f.acct, 'maybank', 'a-new-key');
  perform pg_temp.check_eq('and a new key mends it',
    public.bank_feed_status(f.acct) ->> 'status', 'connected');
end $$;

-- ---------------------------------------------------------------------
-- And only the worker may say a feed is fine
-- ---------------------------------------------------------------------
do $$
declare
  f      record;
  v_feed uuid;
begin
  select * into f from fixture;
  select id into v_feed from public.bank_feeds where bank_account_id = f.acct;
  perform pg_temp.sign_in_as(f.owner);

  -- A client that could call this could make a working feed look
  -- broken -- or a broken one look fine, which is the direction that
  -- costs somebody a reconciliation.
  perform pg_temp.check_true('a client cannot write a run at all',
    not has_function_privilege('authenticated',
      'public.record_bank_feed_run(uuid,boolean,integer,integer,text,text)',
      'execute'));
  perform pg_temp.check_true('and the worker can',
    has_function_privilege('service_role',
      'public.record_bank_feed_run(uuid,boolean,integer,integer,text,text)',
      'execute'));
end $$;

-- ---------------------------------------------------------------------
-- Disconnecting keeps the record of where the statements came from
-- ---------------------------------------------------------------------
do $$
declare
  f      record;
  v_seen jsonb;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);
  perform public.disconnect_bank_feed(f.acct);
  v_seen := public.bank_feed_status(f.acct);

  perform pg_temp.check_eq('the feed is revoked', v_seen ->> 'status',
    'revoked');
  perform pg_temp.check_true('the credential is gone',
    not (v_seen ->> 'has_api_key')::boolean
    and not (v_seen ->> 'has_api_secret')::boolean);
  -- The row and its runs stay. What was imported and when is the
  -- company's record of where its statements came from.
  perform pg_temp.check_true('and the runs behind it stay',
    (v_seen -> 'last_run') is not null);
end $$;

rollback;
