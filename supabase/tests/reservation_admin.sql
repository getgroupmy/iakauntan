-- =====================================================================
-- iAkauntan :: whose name it is, and moving it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reservation_admin.sql
--
-- The console listed every reservation as "Unknown company". The rows
-- were right and the company was missing, because the screen read the
-- name through PostgREST's embed and `organizations` carries one SELECT
-- policy — `app.is_org_member(id)` — which a platform operator does not
-- satisfy for the companies they administer.
--
-- That is the assertion this file exists for, and it has to be made by
-- somebody who is *not* a member. A test that signs in as the company's
-- own owner passes against the broken version too.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A platform operator sees the company, without being in it
--
-- The operator is `another_user` and not `test_user`, and that is not
-- incidental. `test_user()` is idempotent — it hands back the same
-- fixture every time — so an operator taken from it *is* the company's
-- owner, `is_org_member` is true, and the assertion below passes
-- against the broken version. The first draft of this file did exactly
-- that; the premise check caught it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Sinar Teknologi Sdn Bhd');
  v_admin uuid := pg_temp.another_user('operator-1@iakauntan.test');
  v_id    uuid;
  v_name  text;
  v_mine  boolean;
begin
  insert into public.org_subdomains (org_id, subdomain, status, decided_at)
  values (v_org, 'sinar', 'approved', now())
  returning id into v_id;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- The premise. If this ever becomes true the assertion below stops
  -- meaning anything, so it is checked rather than assumed.
  select app.is_org_member(v_org) into v_mine;
  perform pg_temp.check_true(
    'the operator is not a member of the company they administer',
    not coalesce(v_mine, false));

  select r.org_name into v_name
    from public.platform_reservations() r where r.id = v_id;
  perform pg_temp.check_eq(
    'and still sees whose name it is',
    v_name, 'Sinar Teknologi Sdn Bhd');
end $$;

-- ---------------------------------------------------------------------
-- Both kinds arrive in one list
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Kedai Dua Sdn Bhd');
  v_admin uuid := pg_temp.another_user('operator-2@iakauntan.test');
  v_kinds text[];
begin
  insert into public.org_subdomains (org_id, subdomain, status)
  values (v_org, 'kedai-dua', 'requested');
  insert into public.org_mailboxes (org_id, local_part, status)
  values (v_org, 'hello-dua', 'requested');

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  select array_agg(distinct r.kind order by r.kind) into v_kinds
    from public.platform_reservations() r where r.org_id = v_org;
  perform pg_temp.check_true('a subdomain and a mailbox come back together',
    v_kinds = array['mailbox', 'subdomain']);
end $$;

-- ---------------------------------------------------------------------
-- A name can be moved to another company
--
-- The point of the whole change: a name given to the wrong company
-- could not be corrected without deleting it, and the company it
-- should have gone to could not then request it, because it was taken.
-- ---------------------------------------------------------------------
do $$
declare
  v_from  uuid := pg_temp.test_org('Salah Sdn Bhd');
  v_to    uuid := pg_temp.test_org('Betul Sdn Bhd');
  v_admin uuid := pg_temp.another_user('operator-3@iakauntan.test');
  v_id    uuid;
  v_org   uuid;
  v_name  text;
begin
  insert into public.org_subdomains (org_id, subdomain, status, decided_at)
  values (v_from, 'pindah', 'approved', now())
  returning id into v_id;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.platform_update_reservation('subdomain', v_id, v_to, null);
  select s.org_id into v_org from public.org_subdomains s where s.id = v_id;
  perform pg_temp.check_true('the name now belongs to the other company',
    v_org = v_to);

  -- And renaming, which is the other half of "edit".
  perform public.platform_update_reservation('subdomain', v_id, null, 'Pindah-Lagi');
  select s.subdomain into v_name from public.org_subdomains s where s.id = v_id;
  perform pg_temp.check_eq('a rename is normalised on the way in',
    v_name, 'pindah-lagi');

  -- Neither field is a save that does nothing, not an error: the
  -- console has one Save button and should not need to know.
  perform public.platform_update_reservation('subdomain', v_id, null, null);
  select s.subdomain, s.org_id into v_name, v_org
    from public.org_subdomains s where s.id = v_id;
  perform pg_temp.check_eq('a save with nothing in it changes nothing',
    v_name, 'pindah-lagi');
  perform pg_temp.check_true('and leaves the company where it was',
    v_org = v_to);
end $$;

-- ---------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tolak Sdn Bhd');
  v_admin uuid := pg_temp.another_user('operator-4@iakauntan.test');
  v_id    uuid;
  v_ok    boolean;
begin
  insert into public.org_subdomains (org_id, subdomain, status, decided_at)
  values (v_org, 'tolak', 'approved', now())
  returning id into v_id;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- A hostname an operator typed by hand is the one that can carry a
  -- space into DNS. It goes through the same check a request does.
  v_ok := false;
  begin
    perform public.platform_update_reservation('subdomain', v_id, null, 'not a host');
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a name that is not a hostname is refused', v_ok);

  v_ok := false;
  begin
    perform public.platform_update_reservation(
      'subdomain', v_id, '00000000-0000-0000-0000-000000000000'::uuid, null);
  exception when sqlstate '23503' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a company that does not exist is refused', v_ok);

  v_ok := false;
  begin
    perform public.platform_update_reservation('something-else', v_id, null, null);
  exception when sqlstate '22023' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a kind that is neither is refused', v_ok);

  v_ok := false;
  begin
    perform public.platform_update_reservation(
      'subdomain', '00000000-0000-0000-0000-000000000000'::uuid, null, 'anything');
  exception when sqlstate 'P0002' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a reservation that is not there is refused', v_ok);
end $$;

-- ---------------------------------------------------------------------
-- Only a platform operator
--
-- Both of these are the whole platform's namespace. A company owner
-- moving a name would be taking one from somebody else.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Biasa Sdn Bhd');
  v_owner uuid;
  v_id    uuid;
  v_ok    boolean;
begin
  insert into public.org_subdomains (org_id, subdomain, status, decided_at)
  values (v_org, 'biasa', 'approved', now())
  returning id into v_id;

  v_owner := pg_temp.test_user();
  delete from public.platform_admins where user_id = v_owner;
  perform pg_temp.sign_in_as(v_owner);

  v_ok := false;
  begin
    perform public.platform_reservations();
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an owner cannot list the whole namespace', v_ok);

  v_ok := false;
  begin
    perform public.platform_update_reservation('subdomain', v_id, v_org, null);
  exception when sqlstate '42501' then v_ok := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('nor move a name in it', v_ok);
end $$;

-- ---------------------------------------------------------------------
-- Whose door it is
--
-- `0333`. A door policy rather than a security boundary — the same
-- person signs in at the bare domain and reaches the same data either
-- way, because RLS never depended on the hostname. What is asserted
-- here is only that the door tells the truth about whose it is.
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid := pg_temp.test_org('Ahli Sdn Bhd');
  v_member  uuid;
  v_outside uuid := pg_temp.another_user('outsider@iakauntan.test');
  v_admin   uuid := pg_temp.another_user('operator-5@iakauntan.test');
begin
  -- `test_org` signs in as the owner it made, so that is the member.
  select auth.uid() into v_member;
  insert into public.org_subdomains (org_id, subdomain, status, decided_at)
  values (v_org, 'ahli', 'approved', now());

  perform pg_temp.check_true('a member may use their own door',
    public.may_use_workspace('ahli.iakauntan.com'));

  perform pg_temp.sign_in_as(v_outside);
  perform pg_temp.check_true('somebody else may not',
    not public.may_use_workspace('ahli.iakauntan.com'));

  -- Everything that is not a company's door is open, and that matters
  -- more than it looks: answering false for the bare domain would lock
  -- the whole platform out the moment this is called from one.
  perform pg_temp.check_true('the bare domain is not a door',
    public.may_use_workspace('iakauntan.com'));
  perform pg_temp.check_true('nor is a name nobody holds',
    public.may_use_workspace('nosuchname.iakauntan.com'));

  -- An operator has to be able to open a company's page to see what a
  -- tenant sees.
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('a platform operator may look at any door',
    public.may_use_workspace('ahli.iakauntan.com'));

  -- A name that was asked for and never approved is not a door yet.
  -- Its own company, because 0327 gives a company one subdomain and
  -- the row above already used this one's.
  insert into public.org_subdomains (org_id, subdomain, status)
  values (pg_temp.test_org('Belum Sdn Bhd'), 'belum', 'requested');
  perform pg_temp.sign_in_as(v_outside);
  perform pg_temp.check_true('an unapproved name is not a door either',
    public.may_use_workspace('belum.iakauntan.com'));
end $$;

rollback;
