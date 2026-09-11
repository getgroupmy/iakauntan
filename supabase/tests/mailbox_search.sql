-- =====================================================================
-- iAkauntan :: finding a message again
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mailbox_search.sql
--
-- `0561` puts a search box over the mailbox. Most of what is asserted
-- here is that it finds things, which is the easy half. The half worth
-- the file is that it does not find what the reader may not read: a
-- search that returned a colleague's subject line would be the same
-- leak as opening their message, arriving by a door nobody thought to
-- guard because it looked like a list.
--
-- Owner bypasses RLS, so every assertion about who can find what runs
-- as `authenticated`.
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
  v_owner  uuid;
  v_clerk  uuid;
  v_org    uuid;
  v_shared uuid;
  v_mine   uuid;
  v_theirs uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Cari Mel Sdn Bhd', array['mailbox']);

  v_clerk := pg_temp.another_user('clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active');

  insert into public.org_mailboxes
    (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (v_org, 'sales', 'approved', now(), false, null)
  returning id into v_shared;

  insert into public.org_mailboxes
    (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (v_org, 'aisyah', 'approved', now(), true, v_owner)
  returning id into v_mine;

  insert into public.org_mailboxes
    (org_id, local_part, status, decided_at, is_personal, owner_id)
  values (v_org, 'meiling', 'approved', now(), true, v_clerk)
  returning id into v_theirs;

  insert into public.inbound_emails
    (org_id, mailbox_id, message_id, from_email, from_name, to_email,
     subject, body_text, received_at)
  values
    (v_org, v_shared, '<s1@example.com>', 'procurement@kilang.example',
     'Kilang Bersatu', 'sales@iakauntan.com',
     'Quotation for March delivery',
     'Please quote for fifty units delivered in March.',
     now() - interval '3 days'),
    (v_org, v_mine, '<s2@example.com>', 'ravi@akaun.example', 'Ravi',
     'aisyah@iakauntan.com', 'Two invoices outstanding',
     'The second one was raised in March.', now() - interval '2 days'),
    (v_org, v_theirs, '<s3@example.com>', 'doktor@klinik.example',
     'Klinik Sihat', 'meiling@iakauntan.com',
     'Your appointment on Thursday',
     'Permohonan cuti sakit has been approved.', now() - interval '1 day');

  create temporary table fixture on commit drop as
  select v_org as org, v_owner as owner, v_clerk as clerk,
         v_shared as shared, v_mine as mine, v_theirs as theirs;
end $$;

-- ---------------------------------------------------------------------
-- It finds things
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;

  perform pg_temp.check_eq('a word in the subject finds the message',
    (select count(*) from public.search_mail(f.org, 'quotation')), 1::bigint);

  perform pg_temp.check_eq('and a word in the body',
    (select count(*) from public.search_mail(f.org, 'fifty units')),
    1::bigint);

  -- The whole reason the configuration is `english` and not `simple`.
  -- Somebody searching "invoice" who is not shown "Two invoices
  -- outstanding" concludes the search is broken, and is right.
  perform pg_temp.check_eq('and the singular finds the plural',
    (select count(*) from public.search_mail(f.org, 'invoice')), 1::bigint);

  -- Half of looking for a message is looking for who it was with.
  perform pg_temp.check_eq('the sender''s address finds it',
    (select count(*) from public.search_mail(f.org, 'kilang')), 1::bigint);

  perform pg_temp.check_eq('and two messages can say the same word',
    (select count(*) from public.search_mail(f.org, 'march')), 2::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- And does not find what it may not read
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;

  -- THE ASSERTION THIS FILE EXISTS FOR. Aisyah's message says "March"
  -- and so does the shared one, and a clerk may read exactly one of
  -- them. A search built as a definer function over the same two
  -- tables would return both and nobody would notice until it
  -- mattered.
  perform pg_temp.check_eq('a search does not reach a colleague''s mail',
    (select count(*) from public.search_mail(f.org, 'march')), 1::bigint);

  perform pg_temp.check_eq('not even by a word only their message says',
    (select count(*) from public.search_mail(f.org, 'invoice')), 0::bigint);

  -- And her own is hers.
  perform pg_temp.check_eq('and finds her own',
    (select count(*) from public.search_mail(f.org, 'appointment')),
    1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- What was sent is as findable as what arrived
-- ---------------------------------------------------------------------
do $$
declare
  f        record;
  v_parent uuid;
begin
  select * into f from fixture;
  select id into v_parent from public.inbound_emails where mailbox_id = f.mine;

  perform pg_temp.sign_in_as(f.owner);
  perform public.send_from_mailbox(
    f.mine, 'ravi@akaun.example', 'Re: Two invoices outstanding',
    'Both are settled, receipt attached.', v_parent);

  -- A document's own mail is not in the mailbox and does not come back
  -- from a mailbox search, however well it matches.
  insert into public.email_outbox (org_id, to_email, subject, body)
  values (f.org, 'ravi@akaun.example', 'Invoice INV-9', 'Settled.');

  set local role authenticated;
  perform pg_temp.check_eq('an answer is found by what it said',
    (select count(*) from public.search_mail(f.org, 'settled')), 1::bigint);

  perform pg_temp.check_eq('and it is the one that left a mailbox',
    (select direction from public.search_mail(f.org, 'settled')), 'out');
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- Narrowed to one address
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;

  perform pg_temp.check_eq('searching one mailbox searches one mailbox',
    (select count(*) from public.search_mail(f.org, 'march', f.shared)),
    1::bigint);

  perform pg_temp.check_eq('and the other holds the other',
    (select count(*) from public.search_mail(f.org, 'march', f.mine)),
    1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- And nothing typed into it raises
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;

  -- `to_tsquery` would turn each of these into an error in front of
  -- somebody who was only typing. `websearch_to_tsquery` throws the
  -- punctuation away and searches for the word, which is the two
  -- messages that say March -- the same answer typing it cleanly gives.
  perform pg_temp.check_eq('a stray bracket is a search, not an error',
    (select count(*) from public.search_mail(f.org, 'march) & |')),
    2::bigint);

  perform pg_temp.check_eq('and a quoted phrase means the phrase',
    (select count(*) from public.search_mail(f.org, '"March delivery"')),
    1::bigint);

  perform pg_temp.check_eq('and that phrase in the other order is nothing',
    (select count(*) from public.search_mail(f.org, '"delivery March"')),
    0::bigint);

  -- An empty box is not a request for everything. A search screen that
  -- answers "" with the whole mailbox is one that dumps it the moment
  -- somebody clears the field.
  perform pg_temp.check_eq('an empty search finds nothing',
    (select count(*) from public.search_mail(f.org, '   ')), 0::bigint);
  perform pg_temp.check_eq('and so does no search at all',
    (select count(*) from public.search_mail(f.org, null)), 0::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- The index is used, not read past
-- ---------------------------------------------------------------------
do $$
declare v_def text;
begin
  -- A stored column with no index on it is the per-query version with
  -- extra storage: the point of the column is the GIN index beside it.
  perform pg_temp.check_true('the received side is indexed',
    exists (select 1 from pg_indexes
             where indexname = 'inbound_emails_search_idx'
               and indexdef like '%gin%search%'));
  perform pg_temp.check_true('and so is the sent side',
    exists (select 1 from pg_indexes
             where indexname = 'email_outbox_search_idx'
               and indexdef like '%gin%search%'));

  -- Invoker rights. A definer function here would answer past the
  -- policies, which is the leak the block above asserts is closed --
  -- asserted twice, because the failure is silent.
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_mail';
  perform pg_temp.check_true('search runs as whoever is searching',
    v_def not ilike '%security definer%');
end $$;

rollback;
