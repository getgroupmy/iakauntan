-- =====================================================================
-- iAkauntan :: an address on the platform's domain
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/mailbox.sql
--
-- `0328` sells a company `something@iakauntan.com`, sending and
-- receiving. Three things have to hold, and all three are about
-- somebody being somebody else:
--
--   * a company cannot send as an address it was not given;
--   * mail arrives against the company the address belongs to, and is
--     readable by them and by nobody — platform staff included;
--   * a message delivered twice lands once.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
begin
  perform pg_temp.check_eq('the module is in the catalogue',
    (select count(*)::int from public.platform_modules
      where code = 'mailbox' and is_active), 1);
  perform pg_temp.check_true('and is an add-on rather than core',
    not (select is_core from public.platform_modules where code = 'mailbox'));

  -- Two modules, not one wearing two hats. A company may want the
  -- address without the door or the door without the address.
  perform pg_temp.check_true('it is separate from the web address module',
    exists (select 1 from public.platform_modules
             where code = 'workspace_address'));

  perform pg_temp.check_eq('and the domain is a setting, not a literal',
    app.mail_domain(), 'iakauntan.com');
end $$;

-- ---------------------------------------------------------------------
-- The same namespace, and the same refusals
-- ---------------------------------------------------------------------
do $$
begin
  -- The blocklist is shared with the subdomain, because the domain is.
  perform pg_temp.check_true('billing@ is refused',
    app.check_host_label('billing', 'mailbox') is not null);
  perform pg_temp.check_true('postmaster@ is refused, being owed to RFC 5321',
    app.check_host_label('postmaster', 'mailbox') is not null);
  perform pg_temp.check_true('and lhdn@ most of all',
    app.check_host_label('lhdn', 'mailbox') is not null);

  perform pg_temp.check_true('an ordinary name passes',
    app.check_host_label('hello', 'mailbox') is null);
end $$;

-- ---------------------------------------------------------------------
-- Asking, deciding, and only then having
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_org   uuid;
  v_id    uuid;
begin
  v_org := pg_temp.test_org('Sinar Teknologi', array['mailbox']);

  perform public.request_mailbox(v_org, 'Hello');
  select id into v_id from public.org_mailboxes where org_id = v_org;

  perform pg_temp.check_eq('the local part is stored folded',
    (select local_part from public.org_mailboxes where id = v_id), 'hello');
  perform pg_temp.check_eq('and starts as a request',
    (select status from public.org_mailboxes where id = v_id), 'requested');

  -- More than one address per company, unlike the subdomain: sales@ and
  -- support@ are two addresses doing two jobs.
  perform public.request_mailbox(v_org, 'accounts-payable');
  perform pg_temp.check_eq('a company may hold more than one',
    (select count(*)::int from public.org_mailboxes where org_id = v_org), 2);

  -- Nobody else may take a name already asked for, decided or not.
  declare
    v_other uuid := pg_temp.test_org('Copycat Sdn Bhd', array['mailbox']);
  begin
    begin
      perform public.request_mailbox(v_other, 'hello');
      raise exception 'FAIL: two companies got the same address';
    exception
      when others then
        if sqlerrm like 'FAIL:%' then raise; end if;
        perform pg_temp.check_true('and nobody else may have that one',
          sqlerrm like '%already taken%');
    end;
  end;

  -- Approval is an operator's, exactly as it is for a subdomain.
  delete from public.platform_admins where user_id = v_admin;
  perform pg_temp.sign_in_as(v_admin);
  begin
    perform public.decide_mailbox(v_id, true);
    raise exception 'FAIL: a tenant approved its own address';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('a tenant cannot approve its own address',
        sqlerrm like '%platform staff%');
  end;

  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform public.decide_mailbox(v_id, true);
  perform pg_temp.check_eq('an operator can approve it',
    (select status from public.org_mailboxes where id = v_id), 'approved');
end $$;

-- ---------------------------------------------------------------------
-- Sending as somebody
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Sender Sdn Bhd', array['mailbox']);
  v_other uuid := pg_temp.test_org('Other Sdn Bhd', array['mailbox']);
  v_id    uuid;
begin
  perform public.request_mailbox(v_org, 'sender');
  select id into v_id from public.org_mailboxes where org_id = v_org;

  -- Asked for is not granted. Queueing mail as an address still under
  -- review would put a name on an envelope nobody has agreed to.
  begin
    insert into public.email_outbox (org_id, to_email, subject, body, from_email)
    values (v_org, 'somebody@example.com', 'Hello', 'Body',
            'sender@iakauntan.com');
    raise exception 'FAIL: sent from an address not yet granted';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('a pending address cannot send',
        sqlerrm like '%may not send as%');
  end;

  perform public.decide_mailbox(v_id, true);

  insert into public.email_outbox (org_id, to_email, subject, body, from_email)
  values (v_org, 'somebody@example.com', 'Hello', 'Body',
          'sender@iakauntan.com');
  perform pg_temp.check_eq('and an approved one can',
    (select count(*)::int from public.email_outbox
      where org_id = v_org and from_email = 'sender@iakauntan.com'), 1);

  -- The whole point. One company must not be able to queue mail that
  -- appears to come from another.
  begin
    insert into public.email_outbox (org_id, to_email, subject, body, from_email)
    values (v_other, 'somebody@example.com', 'Hello', 'Body',
            'sender@iakauntan.com');
    raise exception 'FAIL: one company sent as another';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      perform pg_temp.check_true('and nobody else can send as it',
        sqlerrm like '%may not send as%');
  end;

  -- A message that names no sender goes out from the platform's own
  -- address, which is every message queued before today.
  insert into public.email_outbox (org_id, to_email, subject, body)
  values (v_other, 'somebody@example.com', 'Hello', 'Body');
  perform pg_temp.check_eq('naming no sender is still allowed',
    (select count(*)::int from public.email_outbox
      where org_id = v_other and from_email is null), 1);
end $$;

-- ---------------------------------------------------------------------
-- Taking delivery
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Inbox Sdn Bhd', array['mailbox']);
  v_id  uuid;
  v_row public.inbound_emails;
begin
  perform public.request_mailbox(v_org, 'inbox');
  select id into v_id from public.org_mailboxes where org_id = v_org;
  perform public.decide_mailbox(v_id, true);

  v_row := public.receive_email(
    'inbox@iakauntan.com', 'customer@example.com', 'A Customer',
    '<msg-1@example.com>', 'A question', 'The body', null, null);

  perform pg_temp.check_eq('mail lands against the company it was sent to',
    v_row.org_id, v_org);
  perform pg_temp.check_eq('and against the address it was sent to',
    v_row.mailbox_id, v_id);
  perform pg_temp.check_true('and starts unread',
    v_row.read_at is null);

  -- Delivered twice is what a retry looks like. The sender's Message-ID
  -- is what makes it land once.
  perform public.receive_email(
    'inbox@iakauntan.com', 'customer@example.com', 'A Customer',
    '<msg-1@example.com>', 'A question', 'The body', null, null);
  perform pg_temp.check_eq('the same message twice lands once',
    (select count(*)::int from public.inbound_emails where org_id = v_org), 1);

  -- Case in the address is not a different address.
  perform public.receive_email(
    'INBOX@iakauntan.com', 'customer@example.com', 'A Customer',
    '<msg-2@example.com>', 'Another', 'Body', null, null);
  perform pg_temp.check_eq('the address is read case-insensitively',
    (select count(*)::int from public.inbound_emails where org_id = v_org), 2);

  -- Mail for a name nobody has reserved is dropped rather than stored.
  -- Keeping it would make this table the platform's spam folder.
  perform pg_temp.check_true('mail to nobody is dropped, not stored',
    public.receive_email('nobody@iakauntan.com', 'spam@example.com', null,
      '<msg-3@example.com>', 'Buy', 'Things', null, null) is null);
  perform pg_temp.check_eq('and leaves nothing behind',
    (select count(*)::int from public.inbound_emails), 2);

  -- Switch the module off and delivery stops, without the address being
  -- lost to somebody else in the meantime.
  delete from public.org_modules
   where org_id = v_org and module_code = 'mailbox';
  perform pg_temp.check_true('no module, no delivery',
    public.receive_email('inbox@iakauntan.com', 'customer@example.com', null,
      '<msg-4@example.com>', 'Later', 'Body', null, null) is null);
  perform pg_temp.check_eq('but the address is still theirs',
    (select count(*)::int from public.org_mailboxes
      where org_id = v_org and status = 'approved'), 1);
end $$;

-- ---------------------------------------------------------------------
-- Who may read what arrived
-- ---------------------------------------------------------------------
do $$
declare
  v_read text;
begin
  select qual::text into v_read
    from pg_policies
   where schemaname = 'public' and tablename = 'inbound_emails'
     and cmd = 'SELECT';

  -- Membership, not seniority: everybody at the company sees the
  -- company's mail, and the policy says so rather than the screen.
  perform pg_temp.check_true('reading mail asks whether you work there',
    v_read like '%is_org_member%');

  -- And a company that has stopped paying stops reading. Unlike an
  -- attachment filed two years ago, this is not the company's own
  -- record — it is a service still running.
  perform pg_temp.check_true('and whether the module is on',
    v_read like '%has_module%');

  -- Platform staff can see that an address exists. They have no
  -- business reading what arrives at it, and the policy does not
  -- mention them.
  perform pg_temp.check_true('platform staff are not named in it',
    v_read not like '%is_platform_admin%');

  -- Nothing a client holds may write here. What arrived is what
  -- arrived; the only human act is marking it read.
  perform pg_temp.check_eq('nothing may be inserted by a client',
    (select count(*)::int from pg_policies
      where schemaname = 'public' and tablename = 'inbound_emails'
        and cmd in ('INSERT', 'ALL')), 0);
  perform pg_temp.check_eq('and nothing deleted',
    (select count(*)::int from pg_policies
      where schemaname = 'public' and tablename = 'inbound_emails'
        and cmd = 'DELETE'), 0);

  -- The ingest path is the edge function under the service role, and
  -- nothing else — not an authenticated client holding a token.
  perform pg_temp.check_true('the ingest function is the service role''s alone',
    not has_function_privilege('authenticated',
      'public.receive_email(text, text, text, text, text, text, text, text)',
      'execute'));
  perform pg_temp.check_true('and not an anonymous caller''s',
    not has_function_privilege('anon',
      'public.receive_email(text, text, text, text, text, text, text, text)',
      'execute'));
  perform pg_temp.check_true('while the service role may',
    has_function_privilege('service_role',
      'public.receive_email(text, text, text, text, text, text, text, text)',
      'execute'));
end $$;

rollback;
