-- =====================================================================
-- iAkauntan :: taking the whole company with you
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_export.sql
--
-- 0454 is the answer to "can we leave?", and the reason a handover that
-- moves nothing is trustworthy: a company that cannot be extracted is
-- a company that has been captured, however carefully its ownership
-- row is guarded.
--
-- Most of what is asserted here is about what does *not* come out. An
-- export is the largest read anybody can perform against this schema,
-- so the interesting failures are a credential in a JSON file and a
-- table name reaching dynamic SQL.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- What is in it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_n   integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Berpindah Sdn Bhd');

  -- A neighbour, so that "only this company's rows" is a claim with
  -- something to be wrong about. Without it both counts are the same
  -- number and the assertion below passes against an export that
  -- ignored `org_id` entirely.
  perform pg_temp.test_org('Syarikat Jiran Sdn Bhd');

  -- `test_org` seeds a chart of accounts, so there is something to
  -- take. A manifest of nothing would pass every assertion below for
  -- the wrong reason.
  perform pg_temp.check_true('the company has books to take',
    exists (select 1 from public.accounts where org_id = v_org));

  select count(*)::integer into v_n
    from public.company_export_manifest(v_org);
  perform pg_temp.check_true('the manifest lists what there is', v_n > 0);

  perform pg_temp.check_eq('including the chart of accounts',
    (select m.row_count::integer from public.company_export_manifest(v_org) m
      where m.table_name = 'accounts'),
    (select count(*)::integer from public.accounts where org_id = v_org));

  -- Only what this company holds. A manifest that counted the whole
  -- table would be a row count and a cross-tenant leak in one figure.
  perform pg_temp.check_true('and nothing another company holds',
    (select m.row_count from public.company_export_manifest(v_org) m
      where m.table_name = 'accounts')
    < (select count(*) from public.accounts));

  -- Empty tables are left off rather than listed at zero: 258 tables
  -- carry `org_id` and a small company uses a few dozen of them.
  perform pg_temp.check_eq('empty tables are not listed',
    (select count(*)::integer from public.company_export_manifest(v_org) m
      where m.row_count = 0), 0);
end $$;

-- ---------------------------------------------------------------------
-- What is not in it
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Rahsia Sdn Bhd');

  -- Credentials this company lent us to act on its behalf. Handing
  -- them back in a JSON file is a leak with a download button.
  perform pg_temp.check_true('credentials are not exportable',
    not exists (select 1 from app.company_export_tables()
                 where table_name in ('einvoice_credentials',
                                      'org_ocr_credentials')));

  -- What the company bought from us, and what its scanning balance
  -- stands at, are facts about this platform.
  perform pg_temp.check_true('nor is the platform''s side of the deal',
    not exists (select 1 from app.company_export_tables()
                 where table_name in ('org_modules', 'org_credits')));

  -- Arithmetic over tables that are already in the export.
  perform pg_temp.check_true('nor a view over what is already there',
    not exists (select 1 from app.company_export_tables()
                 where table_name like 'v\_%'));

  -- And asking for one anyway is refused rather than quietly returning
  -- nothing, because the name reaches dynamic SQL.
  begin
    perform public.company_export_page(v_org, 'einvoice_credentials');
    v_took := true;
  exception when sqlstate '42P01' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and asking for one by name is refused', not v_took);

  begin
    perform public.company_export_page(v_org, 'accounts; drop table x');
    v_took := true;
  exception when sqlstate '42P01' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a table name is matched, never quoted and hoped for', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- A live credential in a table nobody would think to hold back
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_page jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Jemputan Sdn Bhd');

  insert into public.org_members
    (org_id, user_id, invited_email, role, status, invite_token)
  values (v_org, null, 'pending-0454@iakauntan.test', 'accountant',
          'invited', 'a-real-token-that-would-let-somebody-in');

  v_page := public.company_export_page(v_org, 'org_members');

  perform pg_temp.check_true('the members come out',
    jsonb_array_length(v_page -> 'rows') > 0);

  -- `org_members` is the company's own data and belongs in the export.
  -- The row carries a live invitation token, and `app.audit_redact` --
  -- the same rule the audit trail uses -- takes it out on the way.
  perform pg_temp.check_true('but not a live invitation token',
    not exists (
      select 1 from jsonb_array_elements(v_page -> 'rows') r
       where r ->> 'invite_token' is not null
         and r ->> 'invite_token' <> '***'));

  perform pg_temp.check_true('and the address it was sent to still is',
    exists (
      select 1 from jsonb_array_elements(v_page -> 'rows') r
       where r ->> 'invited_email' = 'pending-0454@iakauntan.test'));
end $$;

-- ---------------------------------------------------------------------
-- Paging, and where it stops
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_page jsonb;
  v_seen integer := 0;
  v_next text;
  v_all  integer;
  v_hops integer := 0;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Berjilid Sdn Bhd');

  select count(*)::integer into v_all
    from public.accounts where org_id = v_org;
  perform pg_temp.check_true('there is more than one page of accounts',
    v_all > 10);

  -- Walked the way a client walks it, at a page size small enough that
  -- the cursor has to work.
  loop
    v_page := public.company_export_page(v_org, 'accounts', v_next, 10);
    v_seen := v_seen + jsonb_array_length(v_page -> 'rows');
    v_next := v_page ->> 'next';
    v_hops := v_hops + 1;
    exit when v_next is null or v_hops > 100;
  end loop;

  perform pg_temp.check_eq('walking the pages sees every row once',
    v_seen, v_all);
  perform pg_temp.check_true('and it took more than one page',
    v_hops > 1);

  -- A settings table has one row per company and no `id` to page on,
  -- so it comes back whole with no cursor at all.
  --
  -- The row is inserted here on purpose: a fresh company has *no*
  -- unpaged table populated, so an assertion phrased over the manifest
  -- alone would have passed against an empty result.
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, true);

  perform pg_temp.check_true('a one-row-per-company table is not paged',
    (select not paged from public.company_export_manifest(v_org)
      where table_name = 'pos_settings'));

  v_page := public.company_export_page(v_org, 'pos_settings');
  perform pg_temp.check_eq('and comes back whole',
    jsonb_array_length(v_page -> 'rows'), 1);
  perform pg_temp.check_true('with no cursor after it',
    v_page ->> 'next' is null);
end $$;

-- ---------------------------------------------------------------------
-- Who may take it, and the record of them taking it
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_other uuid;
  v_took  boolean;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Syarikat Direkod Sdn Bhd');

  -- A bookkeeper may post every journal in this company and may not
  -- take a copy of it away.
  v_other := pg_temp.another_user('clerk-0454@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_other, 'accounts_clerk', 'active', now());

  perform pg_temp.sign_in_as(v_other);
  begin
    perform * from public.company_export_manifest(v_org);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a clerk cannot take the company away', not v_took);

  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform * from public.company_export_manifest(v_org);
  perform public.company_export_page(v_org, 'accounts');

  -- The largest read anybody can perform here. A copy leaving with no
  -- record would be the one gap in a trail that notes the reading of a
  -- single payslip.
  select count(*)::integer into v_n
    from public.security_events
   where org_id = v_org and kind = 'export'
     and target = 'company';
  perform pg_temp.check_true('and taking it is written down', v_n >= 2);
end $$;

rollback;
