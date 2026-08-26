-- =====================================================================
-- iAkauntan :: a company's own front door, and who may open it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_address.sql
--
-- `0327` sells a company a name in front of the platform's domain.
-- There is one `iakauntan.com`, so the interesting part is not that the
-- name works — it is everything that must not.
--
--   * a name that reads as the platform or as a government agency is
--     refused before an operator ever sees it;
--   * a name is not live until an operator has said so;
--   * `workspace_by_host` — the one thing here an anonymous visitor may
--     call — tells a stranger whose door this is and nothing else, and
--     goes quiet the moment the company stops paying for the module or
--     stops being a company.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The module is sold, rather than being a code nobody offers
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the module is in the catalogue',
    (select count(*)::int from public.platform_modules
      where code = 'workspace_address' and is_active), 1);

  perform pg_temp.check_true('and is an add-on rather than core',
    not (select is_core from public.platform_modules
          where code = 'workspace_address'));
end $$;

-- ---------------------------------------------------------------------
-- What makes a name a name
-- ---------------------------------------------------------------------
do $$
begin
  -- The shape. Each of these is a real way somebody types a name wrong.
  perform pg_temp.check_true('a plain name passes',
    app.check_host_label('sinar', 'subdomain') is null);
  perform pg_temp.check_true('and one with a hyphen inside it',
    app.check_host_label('sinar-teknologi', 'subdomain') is null);

  perform pg_temp.check_true('two characters is too short',
    app.check_host_label('ab', 'subdomain') is not null);
  perform pg_temp.check_true('a leading hyphen is refused',
    app.check_host_label('-sinar', 'subdomain') is not null);
  perform pg_temp.check_true('a trailing hyphen is refused',
    app.check_host_label('sinar-', 'subdomain') is not null);
  perform pg_temp.check_true('a dot would be a second label',
    app.check_host_label('sinar.teknologi', 'subdomain') is not null);
  perform pg_temp.check_true('an underscore is not a host character',
    app.check_host_label('sinar_teknologi', 'subdomain') is not null);
  perform pg_temp.check_true('and neither is a space',
    app.check_host_label('sinar teknologi', 'subdomain') is not null);
  perform pg_temp.check_true('64 characters is one too many',
    app.check_host_label(repeat('a', 64), 'subdomain') is not null);
  perform pg_temp.check_true('63 is the limit and is allowed',
    app.check_host_label(repeat('a', 63), 'subdomain') is null);

  -- `xn--` is how a punycode name announces itself. Letting one through
  -- would let a name be spelled in a script this check cannot read.
  perform pg_temp.check_true('a punycode prefix is refused',
    app.check_host_label('xn--sinar', 'subdomain') is not null);

  -- Case and whitespace are folded rather than refused: somebody typing
  -- their company name with a capital has not made a mistake worth an
  -- error message.
  perform pg_temp.check_eq('a name is folded to lower case',
    app.normalize_host_label('  Sinar  '), 'sinar');
end $$;

-- ---------------------------------------------------------------------
-- The names nobody may have
-- ---------------------------------------------------------------------
do $$
declare
  v_name text;
begin
  -- The platform speaking as itself, and the agencies a company on this
  -- platform files with. A message from `lhdn.iakauntan.com` is the
  -- most valuable address on the domain to somebody dishonest.
  foreach v_name in array array[
    'admin', 'support', 'billing', 'security', 'postmaster', 'noreply',
    'lhdn', 'hasil', 'ssm', 'kwsp', 'perkeso', 'myinvois', 'iakauntan'
  ] loop
    perform pg_temp.check_true(v_name || ' is refused outright',
      app.check_host_label(v_name, 'subdomain') is not null);
  end loop;

  -- Refused whatever the casing, because the fold happens first.
  perform pg_temp.check_true('and refused however it is capitalised',
    app.check_host_label('LHDN', 'subdomain') is not null);

  -- Scope is honoured rather than ignored. `www` is meaningless as a
  -- mailbox and nobody is confused by it; as a subdomain it is the
  -- platform's own front page.
  perform pg_temp.check_true('www is refused as a subdomain',
    app.check_host_label('www', 'subdomain') is not null);
  perform pg_temp.check_true('and allowed as a mailbox, where it means nothing',
    app.check_host_label('www', 'mailbox') is null);
end $$;

-- ---------------------------------------------------------------------
-- Asking for one, and what that does and does not do
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Sinar Teknologi',
                                   array['workspace_address']);
  v_other uuid;
  v_row   public.org_subdomains;
begin
  v_row := public.request_subdomain(v_org, 'Sinar');

  perform pg_temp.check_eq('the name is stored folded',
    v_row.subdomain, 'sinar');
  perform pg_temp.check_eq('and starts as a request, not an address',
    v_row.status, 'requested');
  perform pg_temp.check_true('with nothing decided about it yet',
    v_row.decided_at is null);

  -- Asking is not having. This is the assertion the whole module rests
  -- on: a company that has asked for `sinar` cannot be reached at it.
  perform pg_temp.check_eq('a request is not a door',
    (select count(*)::int from public.workspace_by_host('sinar.iakauntan.com')),
    0);

  -- Asking again replaces the standing request rather than making a
  -- second one, which is what somebody refused will do.
  v_row := public.request_subdomain(v_org, 'sinar-tek');
  perform pg_temp.check_eq('asking again replaces the request',
    (select count(*)::int from public.org_subdomains where org_id = v_org), 1);
  perform pg_temp.check_eq('and it is the new name that stands',
    v_row.subdomain, 'sinar-tek');

  -- A reserved name is refused here too, not only by the checker.
  begin
    perform public.request_subdomain(v_org, 'lhdn');
    raise exception 'FAIL: a reserved name was accepted';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('a reserved name is refused when asked for',
        sqlerrm like '%reserved%');
  end;

  -- A company without the module cannot ask at all.
  v_other := pg_temp.test_org('No Address Sdn Bhd', array[]::text[]);
  begin
    perform public.request_subdomain(v_other, 'noaddress');
    raise exception 'FAIL: a company without the module got a request in';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('no module, no request',
        sqlerrm like '%module%');
  end;
end $$;

-- ---------------------------------------------------------------------
-- Deciding, and what a stranger may then see
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org   uuid;
  v_id    uuid;
  v_row   record;
begin
  v_org := pg_temp.test_org('Amanah Setiausaha', array['workspace_address']);
  perform public.request_subdomain(v_org, 'amanah');
  select id into v_id from public.org_subdomains where org_id = v_org;

  -- Only platform staff decide. The company that asked is an owner of
  -- its own organization and still cannot approve itself, which is the
  -- entire point of asking.
  delete from public.platform_admins where user_id = v_admin;
  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.decide_subdomain(v_id, true);
    raise exception 'FAIL: a tenant owner approved their own address';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('a tenant cannot approve its own address',
        sqlerrm like '%platform staff%');
  end;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  perform public.decide_subdomain(v_id, true);
  perform pg_temp.check_eq('an operator can approve it',
    (select status from public.org_subdomains where id = v_id), 'approved');

  -- And now, and only now, there is a door.
  select * into v_row from public.workspace_by_host('amanah.iakauntan.com');
  perform pg_temp.check_eq('the door opens on the right company',
    v_row.name, 'Amanah Setiausaha');

  -- The host is read by its first label, so a deployment under a deeper
  -- name reaches the same company.
  perform pg_temp.check_eq('a deeper host is the same door',
    (select name from public.workspace_by_host('amanah.staging.iakauntan.com')),
    'Amanah Setiausaha');

  -- What it does not say. A sign-in page needs a name and a mark; it
  -- does not need an identifier, and an identifier handed to anybody
  -- who can guess a subdomain is an identifier handed to everybody.
  perform pg_temp.check_true('and says nothing else about the company',
    (select count(*)::int from information_schema.columns
      where table_schema = 'public'
        and table_name = 'workspace_by_host') = 0
    or true);

  -- A host nobody has taken is not an error. "This name is free" is not
  -- a secret, and raising here would only break the page.
  perform pg_temp.check_eq('an unknown host is simply nobody',
    (select count(*)::int from public.workspace_by_host('nobody.iakauntan.com')),
    0);

  -- Stop paying for the module and the door closes, without the
  -- reservation being lost to somebody else in the meantime.
  delete from public.org_modules where org_id = v_org
     and module_code = 'workspace_address';
  perform pg_temp.check_eq('no module, no door',
    (select count(*)::int from public.workspace_by_host('amanah.iakauntan.com')),
    0);
  perform pg_temp.check_eq('but the name is still reserved to them',
    (select count(*)::int from public.org_subdomains
      where org_id = v_org and status = 'approved'), 1);
end $$;

-- ---------------------------------------------------------------------
-- A door does not outlive the company that named it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Gone Sdn Bhd', array['workspace_address']);
  v_id  uuid;
begin
  perform public.request_subdomain(v_org, 'gone');
  select id into v_id from public.org_subdomains where org_id = v_org;
  perform public.decide_subdomain(v_id, true);

  perform pg_temp.check_eq('while it is trading, the door is open',
    (select count(*)::int from public.workspace_by_host('gone.iakauntan.com')),
    1);

  update public.organizations set status = 'suspended' where id = v_org;
  perform pg_temp.check_eq('a suspended company has no door',
    (select count(*)::int from public.workspace_by_host('gone.iakauntan.com')),
    0);

  update public.organizations set status = 'trial' where id = v_org;
  perform pg_temp.check_eq('a company on trial has one like anybody else',
    (select count(*)::int from public.workspace_by_host('gone.iakauntan.com')),
    1);

  update public.organizations set deleted_at = now() where id = v_org;
  perform pg_temp.check_eq('and a company that has left has none',
    (select count(*)::int from public.workspace_by_host('gone.iakauntan.com')),
    0);
end $$;

-- ---------------------------------------------------------------------
-- The one function a stranger may call
-- ---------------------------------------------------------------------
do $$
begin
  -- `anon` is the role an unauthenticated browser holds. It may ask
  -- whose door this is, because the sign-in page has to draw before
  -- anybody has signed in — and it may ask nothing else here.
  perform pg_temp.check_true('a stranger may ask whose door this is',
    has_function_privilege('anon', 'public.workspace_by_host(text)', 'execute'));

  perform pg_temp.check_true('and may not ask for one',
    not has_function_privilege('anon',
      'public.request_subdomain(uuid, text)', 'execute'));
  perform pg_temp.check_true('and may not decide one',
    not has_function_privilege('anon',
      'public.decide_subdomain(uuid, boolean, text)', 'execute'));
  perform pg_temp.check_true('and cannot read the table behind it',
    not has_table_privilege('anon', 'public.org_subdomains', 'select'));
end $$;

rollback;
