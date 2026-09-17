-- =====================================================================
-- iAkauntan :: whose mail it is
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/personal_mailbox.sql
--
-- `0328` made an address the COMPANY's: everything that arrived at any
-- of them was readable by everybody who worked there. That is right for
-- `sales@` and wrong for `aisyah@`, and the first thing anybody assumes
-- about an address with their own name on it is that their colleagues
-- cannot read it.
--
-- `0559` gives a mailbox three states, and this file is about which of
-- them lets who read what. The assertion that matters is the negative
-- one: a colleague, and an administrator, cannot read a personal
-- mailbox. Every other assertion here would pass with the policy
-- reverted to `is_org_member`.
--
-- Owner bypasses RLS, so everything below runs as `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The fixture: one company, two people, three mailboxes
-- ---------------------------------------------------------------------
do $$
declare
  v_owner    uuid;
  v_clerk    uuid;
  v_org      uuid;
  v_shared   uuid;
  v_mine     uuid;
  v_theirs   uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Sinar Mel Sdn Bhd', array['mailbox']);

  v_clerk := pg_temp.another_user('clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active');

  -- The company's own address, and one each.
  -- `org_mailboxes_decided`: an approved row carries the moment it was
  -- decided, which is 0328's and not this migration's business.
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
    (org_id, mailbox_id, message_id, from_email, to_email, subject)
  values
    (v_org, v_shared, 'm-shared@test', 'customer@example.com',
     'sales@iakauntan.com', 'A quotation, please'),
    (v_org, v_mine, 'm-mine@test', 'customer@example.com',
     'aisyah@iakauntan.com', 'About your invoice'),
    (v_org, v_theirs, 'm-theirs@test', 'customer@example.com',
     'meiling@iakauntan.com', 'Something personal');

  -- Kept where the blocks below can find them without re-deriving.
  create temporary table fixture on commit drop as
  select v_org as org, v_owner as owner, v_clerk as clerk,
         v_shared as shared, v_mine as mine, v_theirs as theirs;
end $$;

-- ---------------------------------------------------------------------
-- The company's address is the company's
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  perform pg_temp.check_eq('a clerk reads the company''s own address',
    (select count(*) from public.inbound_emails
      where mailbox_id = f.shared), 1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- A personal one is not
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;

  -- THE ASSERTION THIS FILE EXISTS FOR. With `0328`'s policy this is 1,
  -- and every other assertion in this file still passes.
  perform pg_temp.check_eq('a colleague cannot read somebody''s mail',
    (select count(*) from public.inbound_emails
      where mailbox_id = f.mine), 0::bigint);

  perform pg_temp.check_eq('and reads their own',
    (select count(*) from public.inbound_emails
      where mailbox_id = f.theirs), 1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- Nor is it the administrator's
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;

  -- Being able to take a mailbox over is a different thing from being
  -- able to read it, and only one of the two leaves a row behind.
  perform pg_temp.check_eq(
    'the company''s owner cannot read a colleague''s mail',
    (select count(*) from public.inbound_emails
      where mailbox_id = f.theirs), 0::bigint);

  perform pg_temp.check_eq('but reads their own and the shared one',
    (select count(*) from public.inbound_emails
      where mailbox_id in (f.mine, f.shared)), 2::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- Until nobody owns it
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  -- What happens when the account is deleted: `on delete set null`.
  update public.org_mailboxes set owner_id = null where id = f.theirs;

  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;
  perform pg_temp.check_eq(
    'an administrator can reach a mailbox nobody owns',
    (select count(*) from public.inbound_emails
      where mailbox_id = f.theirs), 1::bigint);
  reset role;

  -- And a clerk still cannot: orphaned is not shared.
  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  perform pg_temp.check_eq('and a clerk still cannot',
    (select count(*) from public.inbound_emails
      where mailbox_id = f.theirs), 0::bigint);
  reset role;

  update public.org_mailboxes set owner_id = f.clerk where id = f.theirs;
end $$;

-- ---------------------------------------------------------------------
-- The attachments follow the message
-- ---------------------------------------------------------------------
do $$
declare
  f       record;
  v_email uuid;
begin
  select * into f from fixture;
  select id into v_email from public.inbound_emails
   where mailbox_id = f.theirs;

  insert into public.inbound_email_attachments
    (email_id, filename, content_type, size_bytes, storage_path)
  values (v_email, 'private.pdf', 'application/pdf', 1024, 'x/private.pdf');

  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;
  -- A policy that guarded the message and not what was attached to it
  -- would be a door with the letter behind it and the envelope open.
  perform pg_temp.check_eq('an attachment is as private as its message',
    (select count(*) from public.inbound_email_attachments
      where email_id = v_email), 0::bigint);
  reset role;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  perform pg_temp.check_eq('and its owner can open it',
    (select count(*) from public.inbound_email_attachments
      where email_id = v_email), 1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- Marking one read is reading it
-- ---------------------------------------------------------------------
do $$
declare
  f       record;
  v_email uuid;
begin
  select * into f from fixture;
  select id into v_email from public.inbound_emails where mailbox_id = f.mine;

  perform pg_temp.sign_in_as(f.clerk);
  set local role authenticated;
  update public.inbound_emails set read_at = now() where id = v_email;
  reset role;

  -- The update touched nothing, which is what an UPDATE refused by a
  -- policy looks like: no error, no rows.
  perform pg_temp.check_true('a colleague cannot mark my mail read',
    (select read_at from public.inbound_emails where id = v_email) is null);
end $$;

-- ---------------------------------------------------------------------
-- Asking for one, and handing it over
-- ---------------------------------------------------------------------
do $$
declare
  f     record;
  v_box public.org_mailboxes;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);

  v_box := public.request_mailbox(f.org, 'Enquiries');
  perform pg_temp.check_true('a company address has no owner',
    not v_box.is_personal and v_box.owner_id is null);

  v_box := public.request_mailbox(f.org, 'ravi', f.clerk);
  perform pg_temp.check_true('and a personal one is asked for with its owner',
    v_box.is_personal and v_box.owner_id = f.clerk);

  -- An address for somebody who does not work here is an address its
  -- owner cannot read.
  perform pg_temp.check_refused(
    'a mailbox cannot be given to an outsider',
    format('select public.request_mailbox(%L, %L, %L)',
           f.org, 'stranger', pg_temp.another_user('outsider@iakauntan.test')),
    '%not in this company%', '22023');

  -- Handing over is the door an administrator has instead of reading.
  v_box := public.assign_mailbox(v_box.id, f.owner);
  perform pg_temp.check_eq('a mailbox can be moved to somebody else',
    v_box.owner_id, f.owner);

  v_box := public.assign_mailbox(v_box.id, null);
  perform pg_temp.check_true('and back to the company, deliberately',
    not v_box.is_personal and v_box.owner_id is null);
end $$;

-- ---------------------------------------------------------------------
-- And a clerk may not move one
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.clerk);

  perform pg_temp.check_refused(
    'moving a mailbox is an administrator''s call',
    format('select public.assign_mailbox(%L, %L)', f.shared, f.clerk),
    '%owner or administrator%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The fourth combination does not exist
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  -- A shared mailbox with an owner would read as personal to anybody
  -- looking at the row and behave as shared.
  perform pg_temp.check_refused(
    'a shared mailbox cannot have an owner',
    format('update public.org_mailboxes set is_personal = false, '
           'owner_id = %L where id = %L', f.owner, f.mine),
    '%org_mailboxes_owner_is_personal%', '23514');
end $$;

rollback;
