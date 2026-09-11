-- =====================================================================
-- iAkauntan :: the name we held for ourselves
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/webmail_door.sql
--
-- `reserved_names` carries `mail` with the reason "the mail service",
-- and until `0562` nothing could ever point it AT the mail service:
-- every path that set a name -- including the platform's own -- went
-- through one check that refused it. The list was holding the name
-- against the use it was being held for.
--
-- Two assertions matter here and they pull in opposite directions:
--
--   * the platform can now hold `mail`, or the feature does not exist;
--   * a COMPANY still cannot get it, by asking or by being given it
--     afterwards -- the second is the path `0562` opens and closes in
--     the same migration.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The halves say what they each say
-- ---------------------------------------------------------------------
do $$
begin
  -- Shape is about the name, not about who asked.
  perform pg_temp.check_true('a malformed name is malformed for everybody',
    app.host_label_shape('a') is not null);
  perform pg_temp.check_true('and punycode announces itself',
    app.host_label_shape('xn--80ak6aa92e') is not null);
  perform pg_temp.check_true('a well-formed name passes the shape',
    app.host_label_shape('mail') is null);

  -- The blocklist is about who gets it.
  perform pg_temp.check_true('mail is on the list',
    app.host_label_reserved('mail', 'subdomain') is not null);
  perform pg_temp.check_true('and says why',
    app.host_label_reserved('mail', 'subdomain') like '%mail service%');
  perform pg_temp.check_true('an ordinary name is not',
    app.host_label_reserved('sinar', 'subdomain') is null);

  -- And the old function still means exactly what it meant. Every
  -- caller outside this migration reads it, so a change here would be
  -- a change to a company asking for a subdomain.
  perform pg_temp.check_true('the old check still refuses mail',
    app.check_host_label('mail', 'subdomain') is not null);
  perform pg_temp.check_true('and still refuses a malformed name',
    app.check_host_label('a', 'subdomain') is not null);
  perform pg_temp.check_true('and still lets an ordinary one through',
    app.check_host_label('sinar', 'subdomain') is null);
end $$;

-- ---------------------------------------------------------------------
-- A company still cannot have it
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_org  uuid;
begin
  perform pg_temp.sign_in_as(v_user);
  -- `workspace_address` too, or the refusal below is the module's and
  -- not the blocklist's -- which is a test that passes for the wrong
  -- reason the day somebody turns the blocklist off.
  v_org := pg_temp.test_org('Sinar Mel Sdn Bhd',
                            array['mailbox', 'workspace_address']);

  -- The reason the name is on the list in the first place.
  perform pg_temp.check_refused(
    'a company asking for mail is refused',
    format('select public.request_subdomain(%L, %L)', v_org, 'mail'),
    '%mail service%');
end $$;

-- ---------------------------------------------------------------------
-- And the platform can
-- ---------------------------------------------------------------------
do $$
declare
  v_staff uuid := pg_temp.another_user('ops@iakauntan.test');
  v_id    uuid;
  v_row   public.org_subdomains;
begin
  insert into public.platform_admins (user_id) values (v_staff)
  on conflict do nothing;
  perform pg_temp.sign_in_as(v_staff);

  -- `0562` seeds this, so the name is already held. Released first, so
  -- what is asserted below is the function and not the seed.
  delete from public.org_subdomains where subdomain = 'mail';

  v_id := public.platform_reserve_subdomain(
    'mail', null, 'mailbox', null, 'The webmail door', 'admin');
  select * into v_row from public.org_subdomains where id = v_id;

  perform pg_temp.check_eq('the platform can hold the name it reserved',
    v_row.subdomain, 'mail');
  perform pg_temp.check_eq('pointed at the mailbox module',
    v_row.module_code, 'mailbox');
  perform pg_temp.check_true('as ours, with no company on it',
    v_row.purpose = 'admin' and v_row.org_id is null);

  -- No screen named, deliberately: the router confines to every screen
  -- of the module, so naming one here would freeze the address on
  -- whatever the module happens to have today.
  perform pg_temp.check_true('and not pinned to one screen',
    v_row.landing_path is null);
end $$;

-- ---------------------------------------------------------------------
-- But not as a company's, and not by the back door
-- ---------------------------------------------------------------------
do $$
declare
  v_staff uuid;
  v_owner uuid;
  v_org   uuid;
  v_id    uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Pengambil Nama Sdn Bhd', array['mailbox']);

  select user_id into v_staff from public.platform_admins limit 1;
  perform pg_temp.sign_in_as(v_staff);
  select id into v_id from public.org_subdomains where subdomain = 'mail';

  -- Holding a reserved name straight onto a company is the one-move
  -- version, and it is still refused. `mail` itself is taken by now, so
  -- the assertion uses the other name on the list.
  perform pg_temp.check_refused(
    'the platform cannot hold a reserved name FOR a company',
    format('select public.platform_reserve_subdomain(%L, %L)',
           'postmaster', v_org),
    '%RFC 5321%', '22023');

  -- THE ASSERTION THIS FILE EXISTS FOR. Holding `mail` as ours is new,
  -- and it opens a path that could not exist while nobody could hold
  -- it: hand it over afterwards, on a call that names no name and so
  -- checked no name. One company owning mail.iakauntan.com is the
  -- outcome the list exists to prevent.
  perform pg_temp.check_refused(
    'and cannot hand it to one afterwards',
    format('select public.platform_update_reservation(%L, %L, %L, null, '
           'null, null, false, %L)', 'subdomain', v_id, v_org, 'company'),
    '%mail service%', '22023');

  -- Nor by renaming a name the company already has to this one.
  perform pg_temp.check_true('the name is still ours',
    (select purpose from public.org_subdomains where id = v_id) = 'admin');
end $$;

-- ---------------------------------------------------------------------
-- An ordinary name still moves
-- ---------------------------------------------------------------------
do $$
declare
  v_staff uuid;
  v_owner uuid;
  v_org   uuid;
  v_id    uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Biasa Sdn Bhd', array['mailbox']);

  select user_id into v_staff from public.platform_admins limit 1;
  perform pg_temp.sign_in_as(v_staff);

  -- The check that would fail if `0562` had turned the blocklist off
  -- for companies instead of for the platform.
  v_id := public.platform_reserve_subdomain('biasa', null, null, null, null,
                                            'reserved');
  perform public.platform_update_reservation(
    'subdomain', v_id, v_org, null, null, null, false, 'company');
  perform pg_temp.check_eq('a name nobody reserved reaches its company',
    (select org_id from public.org_subdomains where id = v_id), v_org);
end $$;

-- ---------------------------------------------------------------------
-- And the door is there without anybody pointing it
-- ---------------------------------------------------------------------
do $$
declare v_row public.org_subdomains;
begin
  -- The blocks above deleted and remade it; this asserts the shape the
  -- seed leaves, which is what a fresh deployment gets.
  select * into v_row from public.org_subdomains where subdomain = 'mail';
  perform pg_temp.check_true('mail answers, approved and ours',
    v_row.status = 'approved' and v_row.purpose = 'admin');
  perform pg_temp.check_eq('and opens the mailbox module',
    v_row.module_code, 'mailbox');
end $$;

rollback;
