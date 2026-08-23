-- =====================================================================
-- iAkauntan :: the operator console, and the wall around it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/platform_console.sql
--
-- The platform_* functions are the only way anybody reaches across
-- tenants: every company's turnover, every company's modules, every
-- company's status. They are the largest blast radius in the database,
-- and none of them was called by a test.
--
-- The failure here is not a wrong number. It is somebody who runs one
-- company reading, or changing, another company's. So the file is
-- built the other way round from the rest of the suite: the negative
-- assertions are the point, and the positive ones exist to prove the
-- negatives are not passing because the console is broken for
-- everybody.
--
-- Two things were checked before writing it, and both hold:
--
--   Every one of these functions re-checks app.is_platform_admin(),
--   which is `select exists (...)` -- always true or false, never null.
--   The guard shape 0283 had to fix in submit_leave_request, where a
--   comparison went null and `if not null then raise` did nothing, does
--   not arise here.
--
--   `authenticated` holds SELECT on platform_admins and nothing else,
--   and the table's only policy is `user_id = auth.uid()`. There is no
--   route by which somebody signs themselves up as an operator, which
--   is what makes the guard worth having.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_owner   uuid := pg_temp.test_user();
  v_admin   uuid;
  v_org_a   uuid;
  v_org_b   uuid;
  v_invoice uuid;
  v_role    text;
  v_seen    integer;
  v_wrote   boolean;
  v_read    integer;
  j         jsonb;
  r         record;
begin
  -- Two unrelated companies. The owner of A is an owner in A and a
  -- stranger to B, which is the whole point of the fixture.
  v_org_a := pg_temp.test_org('Company A');
  v_org_b := pg_temp.test_org('Company B');
  -- test_org signs in as its creator; both are owned by v_owner here,
  -- so an explicit second owner is what makes B genuinely somebody
  -- else's company.
  v_admin := pg_temp.another_user('operator@iakauntan.test');

  insert into public.platform_invoices
    (invoice_no, org_id, issuer_name, bill_to_name, description,
     subtotal, total_amount, status)
  values ('PINV-1', v_org_b, 'iAkauntan', 'Company B', 'Subscription',
          100, 100, 'issued')
  returning id into v_invoice;

  -- ==================================================================
  -- Somebody who runs a company is not an operator
  -- ==================================================================
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an org owner is not a platform admin',
    not public.am_i_platform_admin());

  begin
    perform public.platform_stats();
    raise exception 'FAIL: an org owner read the platform statistics';
  exception when sqlstate '42501' then
    raise notice 'ok   an org owner cannot read the platform statistics';
  end;
  begin
    perform * from public.platform_organizations();
    raise exception 'FAIL: an org owner listed every company';
  exception when sqlstate '42501' then
    raise notice 'ok   nor list every company on the platform';
  end;
  begin
    perform public.platform_set_module(v_org_a, 'einvoice', true);
    raise exception 'FAIL: an org owner granted their own company a module';
  exception when sqlstate '42501' then
    raise notice 'ok   nor grant their own company a module they have not bought';
  end;
  begin
    perform public.platform_set_org_status(v_org_b, 'suspended');
    raise exception 'FAIL: an org owner suspended another company';
  exception when sqlstate '42501' then
    raise notice 'ok   nor suspend somebody else''s company';
  end;
  begin
    perform public.platform_update_setting('signups_open', 'false'::jsonb);
    raise exception 'FAIL: an org owner changed a platform setting';
  exception when sqlstate '42501' then
    raise notice 'ok   nor change a platform setting';
  end;
  begin
    perform public.platform_mark_invoice_paid(v_invoice);
    raise exception 'FAIL: an org owner marked a platform invoice paid';
  exception when sqlstate '42501' then
    raise notice 'ok   nor write off what they owe';
  end;
  begin
    perform * from public.platform_credit_summary();
    raise exception 'FAIL: an org owner read every company''s credit';
  exception when sqlstate '42501' then
    raise notice 'ok   nor read every company''s credit balance';
  end;

  -- ==================================================================
  -- And cannot make themselves one
  --
  -- Under `authenticated`, because the file otherwise runs as the owner
  -- of the database, who is subject to neither grants nor policies --
  -- a refusal observed as the owner would be no refusal at all.
  -- ==================================================================
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      insert into public.platform_admins (user_id) values (v_owner);
      v_wrote := true;
    exception when insufficient_privilege then v_wrote := false;
    end;
    -- Everything except the one key a member's own menu is drawn
    -- from. 0298 opened `nav_grouping` deliberately and narrowly; this
    -- counts what is left, so the assertion below still says what it
    -- always said — the platform's own business stays the platform's.
    select count(*) into v_read from public.platform_settings
     where key <> 'nav_grouping';
  end;
  reset role;

  perform pg_temp.check_eq('the escalation test ran under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_true('nobody signs themselves up as an operator',
    not v_wrote);
  perform pg_temp.check_eq(
    'and the platform''s own settings are not theirs to read',
    v_read, 0);

  -- ==================================================================
  -- The console, for somebody who is one
  -- ==================================================================
  insert into public.platform_admins (user_id, note)
  values (v_admin, 'For the test');

  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_true('an operator is a platform admin',
    public.am_i_platform_admin());

  -- Across tenants: the operator is a member of neither company.
  select count(*) into v_seen from public.platform_organizations()
   where id in (v_org_a, v_org_b);
  perform pg_temp.check_eq('and sees companies they do not belong to',
    v_seen, 2);

  j := public.platform_stats();
  perform pg_temp.check_true('the statistics count the companies',
    (j ->> 'organizations')::integer >= 2);
  perform pg_temp.check_true('and the people',
    (j ->> 'users')::integer >= 1);

  -- ------------------------------------------------------------------
  -- Granting a module
  -- ------------------------------------------------------------------
  perform public.platform_set_module(v_org_b, 'einvoice', false);
  perform pg_temp.check_true('an operator can switch a module off',
    not app.has_module(v_org_b, 'einvoice'));
  perform public.platform_set_module(v_org_b, 'einvoice', true);
  perform pg_temp.check_true('and back on',
    app.has_module(v_org_b, 'einvoice'));
  perform pg_temp.check_eq('recording who did it',
    (select enabled_by from public.org_modules
      where org_id = v_org_b and module_code = 'einvoice'), v_admin);

  -- A core module is what the product is. Switching it off would leave
  -- a company paying for an accounting system that cannot post.
  --
  -- Written with a flag rather than `raise ... exception when others`:
  -- that shape catches the FAIL it raises itself, so the assertion can
  -- never fail. The refusal here carries no errcode, so there is no
  -- specific sqlstate to catch instead.
  begin
    perform public.platform_set_module(v_org_b, 'accounting', false);
    v_wrote := true;
  exception when others then v_wrote := false;
  end;
  perform pg_temp.check_true('a core module cannot be switched off',
    not v_wrote);
  perform pg_temp.check_true('and is still switched on afterwards',
    app.has_module(v_org_b, 'accounting'));

  -- ------------------------------------------------------------------
  -- Suspending a company
  -- ------------------------------------------------------------------
  perform public.platform_set_org_status(v_org_b, 'suspended');
  perform pg_temp.check_eq('an operator can suspend a company',
    (select status from public.organizations where id = v_org_b),
    'suspended');
  begin
    perform public.platform_set_org_status(v_org_b, 'deleted');
    v_wrote := true;
  exception when others then v_wrote := false;
  end;
  perform pg_temp.check_true('and only to a status the platform knows',
    not v_wrote);
  perform pg_temp.check_eq('and the refused status did not stick',
    (select status from public.organizations where id = v_org_b),
    'suspended');
  perform public.platform_set_org_status(v_org_b, 'active');

  -- ------------------------------------------------------------------
  -- Platform settings
  -- ------------------------------------------------------------------
  perform public.platform_update_setting('signups_open', 'true'::jsonb);
  perform pg_temp.check_eq('a setting is written',
    (select value::text from public.platform_settings where key = 'signups_open'),
    'true');
  perform public.platform_update_setting('signups_open', 'false'::jsonb);
  perform pg_temp.check_eq('and updated in place rather than duplicated',
    (select value::text from public.platform_settings where key = 'signups_open'),
    'false');
  perform pg_temp.check_eq('leaving one row',
    (select count(*) from public.platform_settings where key = 'signups_open'),
    1);
  perform pg_temp.check_eq('stamped with whoever changed it',
    (select updated_by from public.platform_settings
      where key = 'signups_open'), v_admin);

  -- ------------------------------------------------------------------
  -- Marking an invoice paid
  -- ------------------------------------------------------------------
  perform public.platform_mark_invoice_paid(v_invoice, 'Bank transfer');
  select * into r from public.platform_invoices where id = v_invoice;
  perform pg_temp.check_eq('an issued invoice is marked paid', r.status,
    'paid');
  perform pg_temp.check_true('with the date it was paid', r.paid_at is not null);
  perform pg_temp.check_eq('and the note', r.paid_note, 'Bank transfer');

  -- Only an issued invoice moves. Marking a paid one again is a no-op
  -- -- deliberately silent, and worth writing down, because the caller
  -- gets no signal either way and a screen showing "done" after doing
  -- nothing is how a void invoice quietly reads as settled.
  perform public.platform_mark_invoice_paid(v_invoice, 'Twice');
  perform pg_temp.check_eq('marking a paid invoice again changes nothing',
    (select paid_note from public.platform_invoices where id = v_invoice),
    'Bank transfer');

  -- ------------------------------------------------------------------
  -- Credit across every company
  -- ------------------------------------------------------------------
  insert into public.org_credits (org_id, balance) values (v_org_a, 25)
  on conflict (org_id) do update set balance = 25;
  select count(*) into v_seen from public.platform_credit_summary()
   where org_id in (v_org_a, v_org_b);
  perform pg_temp.check_eq('every company appears in the credit summary',
    v_seen, 2);
  perform pg_temp.check_eq('with the balance it holds',
    (select balance from public.platform_credit_summary()
      where org_id = v_org_a), 25);
  -- Lowest balance first: the list is a list of who is about to run out.
  perform pg_temp.check_true('and the emptiest account is at the top',
    (select org_id from public.platform_credit_summary() limit 1) = v_org_b);

  perform pg_temp.sign_out();
end $$;

rollback;
